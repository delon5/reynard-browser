//
//  FairPlayStreamParser.swift
//  GeckoView
//
//  The MSE half of FairPlay: key origination without an AVURLAsset.
//
//  AVPlayerHost covers native HLS, where AVFoundation owns the URL and an
//  AVURLAsset is the AVContentKeyRecipient. MSE has no asset in either
//  process, so no AVContentKeyRequest is ever raised and FairPlayCDMProxy
//  parks every generateRequest forever - which is why Apple TV+, Netflix
//  and HBO Max reach MediaKeys::Init and stop.
//
//  AVStreamDataParser is the way out, and it is measured rather than
//  assumed. A device probe (AVStreamDataParserProbe.m, since retired)
//  established on iOS 26.2:
//
//    - the class exists at runtime, as SPI
//    - it declares AVContentKeyRecipient conformance
//    - addContentKeyRecipient: accepts it - "recipients now 1"
//    - fed Apple's encrypted sinf/cbcs init segment from the FPS SDK, it
//      raised streamDataParser:didProvideContentKeySpecifier:forTrackID:
//
//  So a parser originates key requests from plain MSE bytes with no asset
//  anywhere. That is the whole reason this file exists.
//
//  SPI, so every entry point is resolved by name and every failure is
//  reported rather than trapped. A missing selector here means the OS
//  moved, and the log has to say which one so the next step is a rename
//  and not an investigation.
//

import AVFoundation
import Foundation
import ObjectiveC
// For the decode probe in runDecodeProbe: a decompression session that
// answers "do these samples decode" without going through the display
// layer, so the sink and the samples can be blamed separately.
import VideoToolbox
// For the on-screen proof in showLayerIfRequested. This file otherwise
// touches no UI at all.
#if canImport(UIKit)
import UIKit
#endif

/// One EME generateRequest: the id the content process filed it under,
/// and the bytes it was raised from.
///
/// Both are needed for the whole life of the exchange and neither can be
/// recovered later. FairPlayCDMProxy files its session under base64 of
/// the init data and matches the SPC coming back by exactly that string,
/// so the SPC must be reported under the id it ARRIVED with; and a
/// request raised with a nil identifier can only be addressed by reading
/// a key id back out of the init data that raised it.
struct FairPlayOrigination {
    let contentId: String
    let initData: Data
}

@objc(ReynardFairPlayStreamParser)
public final class FairPlayStreamParser: NSObject {
    public static let shared = FairPlayStreamParser()

    /// One parser and one key session per EME session id.
    ///
    /// Per session, not per process: MediaKeySession is the object the
    /// page holds and updates, and a page with two protected elements
    /// runs two licence exchanges that must not collide. The native HLS
    /// path keys by player id for the same reason.
    private final class Entry {
        let parser: NSObject
        /// The same object as `parser`, carrying the conformance Swift
        /// cannot see statically. AVStreamDataParser is SPI, so it is
        /// NSObject to the compiler; the probe confirmed
        /// class_conformsToProtocol(AVContentKeyRecipient) is YES, which
        /// is what makes the runtime cast in createSession succeed.
        let recipient: AVContentKeyRecipient
        let keySession: AVContentKeySession
        let delegate: ParserDelegate
        /// Retained because setDelegate(_:queue:) does not.
        let keyDelegate: KeySessionDelegate
        /// Track ids the parser has raised a key request for, in arrival
        /// order. The SPC call needs one and the CKC is addressed to one,
        /// and neither EME message carries it - the page has never heard
        /// of a track id.
        var trackIDs: [Int32] = []
        /// Originations this session has asked for and whose key
        /// requests have not come back yet, oldest first.
        ///
        /// A QUEUE, not a slot, and that is the correction. One
        /// AVContentKeySession serves a whole content process, but EME
        /// raises one generateRequest per MediaKeySession and real
        /// services raise several - separate audio and video keys, and
        /// again on rotation. Two scalars here meant request #2
        /// overwrote request #1's identity before #1's SPC callback had
        /// run, so every SPC went out under the last content id seen and
        /// every earlier EME session hung with no message at all.
        ///
        /// Drained by the delegate, which pins one origination to the
        /// request object that answers it - see claimOrigination.
        var pendingOriginations: [FairPlayOrigination] = []
        /// Whether requestKey drives this session's key requests.
        ///
        /// True for anything parserAppendInitData opened, false for the
        /// render probe. Both routes end at the same
        /// processContentKeyRequest, so a session driven directly must
        /// not ALSO raise one from the parser's specifier callback when
        /// a real init segment happens to parse - that answers one EME
        /// exchange with two AVContentKeyRequests.
        ///
        /// A flag, not a count: a session with three exchanges queued
        /// still wants three requests. This says which route makes them.
        var directRouteOwnsSession = false
        /// A sinf box lifted from an init segment the page appended.
        ///
        /// Used as the TEMPLATE for the JSON handed to
        /// processContentKeyRequest: it carries the true frma and the
        /// true constant IV, and a PSSH carries neither. Only its key id
        /// is swapped for the one being asked about, so one template
        /// serves every key in the presentation.
        var templateSinf: Data?
        /// Track ids the parsed asset reported.
        ///
        /// Separate from trackIDs, which only ever holds tracks a KEY
        /// REQUEST named. Media data is asked for per track, and the
        /// tracks that carry media are the asset's - on this route the
        /// key request arrives through the session rather than the
        /// parser, so trackIDs can be empty while the asset has two.
        var assetTrackIDs: [Int32] = []

        init(parser: NSObject,
             recipient: AVContentKeyRecipient,
             keySession: AVContentKeySession,
             delegate: ParserDelegate,
             keyDelegate: KeySessionDelegate) {
            self.parser = parser
            self.recipient = recipient
            self.keySession = keySession
            self.delegate = delegate
            self.keyDelegate = keyDelegate
        }
    }

    private var entries: [String: Entry] = [:]
    /// Has the process's audio session been made playback-capable? Once
    /// per process - see prepareAudioSession.
    private var audioSessionPrepared = false
    /// Stream parsers by "<sessionId>|<stream>". See append(_:stream:).
    fileprivate var streamParsers: [String: StreamParser] = [:]
    private let lock = NSLock()

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Delivers key-session callbacks off the main thread - see
    /// createSession for why that matters.
    private static let keyDelegateQueue =
        DispatchQueue(label: "com.reynard.fairplay.keysession")

    fileprivate static func log(_ message: String) {
        fputs("fpsParser: \(message)\n", stderr)
    }

    /// Hands a specifier to the key session so a REAL request comes back.
    ///
    /// The parser reports `AVContentKeySpecifier`, which a method dump
    /// showed is a value object - identifier, initializationData,
    /// keySystem, options, and nothing that makes an SPC. It is the input
    /// to processContentKeyRequest, and the AVContentKeyRequest that
    /// answers it is the object carrying
    /// makeStreamingContentKeyRequestDataForApp:.
    ///
    /// Four builds went into asking the parser directly for an SPC, on
    /// the strength of a selector its own method dump listed. Every one
    /// returned nil with no NSError, because that is not the supported
    /// path. This is.
    fileprivate func processSpecifier(sessionId: String, specifier: AnyObject) {
        guard let entry = withState({ entries[sessionId] }) else {
            return
        }
        // A nil identifier is normal here, and requiring one was a bug
        // that cost a build. The specifier's own initialisers say so:
        // alongside initForKeySystem:identifier:... there is
        // initForKeySystem:initializationData: with no identifier at all.
        // Native HLS names a key with an skd:// URI; MSE names it with
        // the init data itself - the sinf or PSSH - so for this path the
        // initialisation data IS the identity.
        //
        // Refuse only when BOTH are absent, because then there is nothing
        // to address a key request with.
        let identifier = specifier.value(forKey: "identifier")
        let initializationData = specifier.value(forKey: "initializationData") as? Data
        guard identifier != nil || initializationData != nil else {
            Self.log("specifier carries neither identifier nor initialisation data")
            return
        }
        // Stand down when the direct route drives this session.
        //
        // Both routes end at the same processContentKeyRequest, so if a
        // real init segment does parse here, raising one now would be
        // the SECOND request answering a single EME exchange - the first
        // having come from requestKey the moment the bytes arrived.
        //
        // The render probe is unaffected: it never calls requestKey, so
        // this callback remains its only way to raise a key request, and
        // it is the path the 6480-byte SPC came back through.
        if withState({ entry.directRouteOwnsSession }) {
            Self.log("session \(sessionId) parser raised a specifier, but the "
                     + "direct route already asked for this key - not raising "
                     + "a second request")
            return
        }
        Self.log("handing the specifier to the key session - id "
                 + "\(identifier.map { String(describing: $0) } ?? "nil"), "
                 + "\(initializationData?.count ?? 0) bytes of init data")
        // THE SHAPE THAT WORKS, in full.
        //
        // These are the bytes AVFoundation's own parser produced from a
        // real init segment, and the ones processContentKeyRequest
        // accepts every time - it raises a genuine AVContentKeyRequest
        // from them, and that made an 8816-byte SPC. The page's PSSH is
        // refused in both its shapes. So this is the difference, and in
        // this whole series it has never once been printed.
        //
        // The whole thing, not a prefix: the point is to reconstruct it
        // from a PSSH, and a truncated dump would hide precisely the
        // tail a reconstruction gets wrong.
        if let initializationData {
            Self.log("  specifier init data: "
                     + initializationData.map { String(format: "%02x", $0) }
                                         .joined())
        }
        entry.keySession.processContentKeyRequest(withIdentifier: identifier,
                                                  initializationData: initializationData,
                                                  options: nil)
    }

    /// A file in the app's Documents, for probe inputs the user drops in.
    ///
    /// NSSearchPath rather than ReynardDirectories: this file is in the
    /// GeckoView framework, which does not link the app's own types.
    private func documentsPath(_ name: String) -> String {
        let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true)
        return (documents.first ?? "") + "/" + name
    }

    // MARK: - Lifecycle

    /// Build a parser bound to its own key session, or report why not.
    ///
    /// Returns false rather than throwing: the caller is Gecko over IPC
    /// and has no way to handle a Swift error, and a false here has to
    /// become an EME rejection on the page rather than silence - silence
    /// is exactly the parking behaviour this replaces.
    @discardableResult
    @objc public func createSession(_ sessionId: String) -> Bool {
        guard let parserClass = NSClassFromString("AVStreamDataParser") as? NSObject.Type else {
            Self.log("AVStreamDataParser is absent - MSE FairPlay has no route on this OS")
            return false
        }
        let parser = parserClass.init()
        let delegate = ParserDelegate(sessionId: sessionId)

        let setDelegate = NSSelectorFromString("setDelegate:")
        guard parser.responds(to: setDelegate) else {
            Self.log("no setDelegate: on AVStreamDataParser - cannot hear key requests")
            return false
        }
        parser.perform(setDelegate, with: delegate)

        // Runtime cast, because the conformance is real but invisible:
        // AVStreamDataParser is SPI and types as NSObject here, while the
        // probe read class_conformsToProtocol(AVContentKeyRecipient) as
        // YES and addContentKeyRecipient: then accepted it. If a future
        // OS drops the declaration this fails here, with a line saying
        // so, instead of at the first key request that never comes.
        guard let recipient = parser as? AVContentKeyRecipient else {
            Self.log("AVStreamDataParser no longer declares AVContentKeyRecipient")
            return false
        }

        // The session gets a delegate, and that correction is the whole
        // point of this revision.
        //
        // This code used to say the session needed no delegate - that the
        // parser's delegate reported the key request and the session's
        // was "the AVURLAsset path's mechanism", a second conflicting
        // source of the same event. That was reasoned, not tested, and it
        // was wrong. The parser's delegate reports an
        // AVContentKeySpecifier, which is a description of what needs a
        // key; the session's delegate is where the AVContentKeyRequest
        // arrives, and only that object can make an SPC. Without a
        // delegate here the request had nowhere to be delivered, which is
        // why four builds of asking the parser directly returned nil.
        let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        let keyDelegate = KeySessionDelegate(sessionId: sessionId)
        // A dedicated serial queue, NOT main. The probe that drives this
        // runs on the main thread during launch, before GeckoRuntime.main
        // starts the runloop - so a callback queued to main sits behind a
        // runloop that has not begun, and the first attempt saw
        // processContentKeyRequest accepted with no request ever
        // delivered. Off-main it arrives regardless of who is blocking.
        keySession.setDelegate(keyDelegate, queue: Self.keyDelegateQueue)
        keySession.addContentKeyRecipient(recipient)

        withState {
            entries[sessionId] = Entry(parser: parser, recipient: recipient,
                                       keySession: keySession, delegate: delegate,
                                       keyDelegate: keyDelegate)
        }
        Self.log("session \(sessionId) ready - parser \(parser), "
                 + "recipients \(keySession.contentKeyRecipients.count)")
        return true
    }

    @objc public func destroySession(_ sessionId: String) {
        guard let entry = withState({ entries.removeValue(forKey: sessionId) }) else {
            return
        }
        entry.keySession.removeContentKeyRecipient(entry.recipient)

        // The per-stream half, which used to be left behind entirely.
        //
        // Stream parsers, display layers, audio renderers, their
        // key-session registrations, their notification observers and the
        // overlay all outlived the session that owned them - and adopt()
        // finds its target by searching for the busiest stream with a
        // picture, so orphans from a dead session were candidates for the
        // next playback's compositor layer.
        let orphans = withState { () -> [(String, StreamParser)] in
            // The key list is snapshotted before anything is removed.
            // streamParsers.keys is a view over the dictionary, and
            // mutating it while iterating that view is not something
            // Swift defines.
            let doomed = Array(streamParsers.keys)
                .filter { $0.hasPrefix(sessionId + "|") }
            var out: [(String, StreamParser)] = []
            for key in doomed {
                if let slot = streamParsers.removeValue(forKey: key) {
                    out.append((key, slot))
                }
            }
            return out
        }
        for (key, slot) in orphans {
            entry.keySession.removeContentKeyRecipient(slot.recipient)
            if let layer = slot.displayLayer,
               let recipient = (layer as AnyObject) as? AVContentKeyRecipient {
                entry.keySession.removeContentKeyRecipient(recipient)
            }
            if let renderer = slot.audioRenderer {
                if let recipient = (renderer as AnyObject)
                    as? AVContentKeyRecipient {
                    entry.keySession.removeContentKeyRecipient(recipient)
                }
                renderer.stopRequestingMediaData()
                renderer.flush()
            }
            slot.audioSynchronizer?.rate = 0
            slot.displayLayer?.stopRequestingMediaData()
            if let observer = slot.failObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = slot.audioFlushObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            // Only layers this parser built. A compositor layer lives in
            // NativeLayerCA's tree and is not ours to remove.
            let owned = slot.ownsDisplayLayer ? slot.displayLayer : nil
            let overlay = slot.retiringOverlay
            let proof = slot.proofLayer
            DispatchQueue.main.async {
                owned?.removeFromSuperlayer()
                overlay?.removeFromSuperlayer()
                proof?.removeFromSuperlayer()
            }
            Self.log("stream \(key) torn down with its session")
        }
        Self.log("session \(sessionId) destroyed")
    }

    /// Rebuild a session that has stopped raising key requests, and ask
    /// again.
    ///
    /// See the watchdog in requestKey for why this exists: an
    /// AVContentKeySession that already holds the key raises no request
    /// for it, which is correct and leaves the content process waiting
    /// for a licence forever. A rebuilt session holds nothing.
    ///
    /// The certificate is carried across. Without it the new delegate
    /// would hold the request rather than produce an SPC, and the page
    /// only sends a certificate while handling an 'encrypted' event -
    /// which this is trying to answer.
    fileprivate func recycleSession(_ sessionId: String, contentId: String,
                                    initData: Data) {
        let certificate = withState { entries[sessionId]?.keyDelegate }?
            .certificate
        Self.log("session \(sessionId) is deaf - rebuilding it and asking "
                 + "again. A key session raises no request for a key it "
                 + "already holds, and this one served an earlier "
                 + "playback in the same content process.")
        destroySession(sessionId)
        guard createSession(sessionId) else {
            Self.log("session \(sessionId) could not be rebuilt - this "
                     + "playback has no route")
            return
        }
        if let certificate {
            setCertificate(sessionId, certificate: certificate)
        } else {
            Self.log("session \(sessionId) rebuilt with NO certificate - "
                     + "the request will be held until one arrives")
        }
        requestKey(sessionId, contentId: contentId, initData: initData)
    }

    // MARK: - Init data in

    /// Feed an MSE initialisation segment. The key request, if any, comes
    /// back through the delegate.
    ///
    /// appendStreamData: rather than appendStreamData:withFlags: - the
    /// flags variant exists but its flag values are undocumented, and the
    /// probe raised a key request through the plain one.
    @discardableResult
    @objc public func append(_ sessionId: String, initSegment: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("append for unknown session \(sessionId)")
            return false
        }
        let append = NSSelectorFromString("appendStreamData:")
        guard entry.parser.responds(to: append) else {
            Self.log("no appendStreamData: on the parser")
            return false
        }
        entry.parser.perform(append, with: initSegment)
        // Keep any sinf this segment carries. The page appends real init
        // segments now, and a real sinf is a better template for the key
        // request JSON than anything reconstructible from a PSSH - it
        // has the actual sample format and constant IV.
        if let sinf = Self.sinfBox(in: initSegment) {
            let isNew = withState { () -> Bool in
                guard entry.templateSinf == nil else { return false }
                entry.templateSinf = sinf
                return true
            }
            if isNew {
                Self.log("session \(sessionId) kept a \(sinf.count)-byte sinf "
                         + "from this segment as the key request template")
            }
        }
        Self.log("session \(sessionId) appended \(initSegment.count) bytes")
        return true
    }

    // MARK: - Key origination without a parsed segment

    /// Raise a key request from EME initialisation data alone.
    ///
    /// The parser cannot do this, and the device log is unambiguous
    /// about it - "appended 104 bytes" and then silence, with no key
    /// request and no parse error. AVStreamDataParser wants an init
    /// segment (ftyp/moov carrying sinf); a cenc PSSH is not one, so it
    /// is dropped without comment.
    ///
    /// The session has no such requirement. processContentKeyRequest
    /// takes initialisation data, raises a genuine AVContentKeyRequest,
    /// and that object is the one carrying
    /// makeStreamingContentKeyRequestData - the call processSpecifier
    /// already makes, reached here without waiting for a parser callback
    /// that this shape of bytes will never produce.
    ///
    /// Identifier nil, deliberately. ccf88e5 established that a nil
    /// identifier is the normal MSE shape and that on this path the
    /// initialisation data IS the identity. The key id is read out and
    /// logged rather than passed, so the next capture can say whether
    /// AVFoundation wanted one without this call having changed two
    /// things at once.
    @discardableResult
    @objc public func requestKey(_ sessionId: String,
                                 contentId: String,
                                 initData: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("key request for unknown session \(sessionId)")
            return false
        }
        withState {
            entry.pendingOriginations.append(
                FairPlayOrigination(contentId: contentId, initData: initData))
            entry.directRouteOwnsSession = true
        }
        let keyId = Self.keyIdentifier(inPSSH: initData)
        // CHANGED - see fix_key_request_unwraps_pssh.py's docstring.
        // What the page hands us is a complete MP4 PSSH box, and
        // AVFoundation ignores one in silence: six calls with the box
        // produced no key request at all, while the probe's 147
        // sinf-derived bytes produce one every time. The FairPlay data
        // is the box's PAYLOAD, so that is what goes to the session.
        //
        // The bytes as they ARRIVED are still what the exchange is
        // keyed by - FairPlayCDMProxy files the session under base64 of
        // exactly them - so entry.initData above is left alone. Only
        // what AVFoundation is handed changes.
        // What goes to the session is a JSON sinf document, because that
        // is what this API takes. Decoded from the probe's own specifier:
        //
        //   {"sinf":["<base64 of an 89-byte sinf box>"]}
        //
        // Both MP4 shapes - the whole pssh box and its payload - have
        // been refused twice each now, once with a nil identifier and
        // once with a correct key id, so the container was always the
        // difference. psshPayload stays only for the log line below.
        let payload = Self.psshPayload(in: initData)
        let template = withState { entry.templateSinf }
        let forSession = Self.sinfInitialisationJSON(
            keyId: keyId, template: template, sessionId: sessionId)
            ?? (payload ?? initData)
        Self.log("session \(sessionId) raising a key request from "
                 + "\(forSession.count) bytes - key id "
                 + (keyId.map { "\($0.count) bytes" } ?? "not found"))
        // The key id, PASSED this time.
        //
        // It has been extracted and printed since the fkri reader landed
        // and then dropped at the call: every capture reads "key id 16
        // bytes" and then hands AVFoundation withIdentifier: nil. So the
        // runs that refused the whole box (six of them) and the payload
        // were ALL nil-identifier runs, and the identifier hypothesis
        // has never been tested. "Shape is the only remaining variable"
        // could not have been concluded from them.
        //
        // One variable: what is sent stays the payload, exactly as
        // today. Only the identity changes.
        entry.keySession.processContentKeyRequest(withIdentifier: keyId,
                                                  initializationData: forSession,
                                                  options: nil)

        // ADDED - see fix_key_request_watchdog.py's docstring. The
        // call above returns void and says nothing when it declines,
        // which is how this path has failed silently twice and how
        // the parser failed silently before it. Five seconds is far
        // longer than the callback has ever taken - the probe's
        // arrives immediately once its delegate queue is off main -
        // so this only ever fires on a real refusal.
        //
        // The delegate is captured rather than looked up again: by
        // the time this runs the session may be gone, and a
        // torn-down one should not be resurrected just to report on.
        let delegate = entry.keyDelegate
        let sentCount = forSession.count
        let sentShape = payload == nil ? "init data as it arrived"
                                       : "the PSSH payload"
        let namedKey = keyId != nil
        // The COUNT before the call, not the flag afterwards. sawRequest
        // latches on the first request this delegate ever sees, and a
        // second playback in the same content process reuses the
        // delegate - so on the run that failed to reload, this watchdog
        // was already satisfied by two exchanges from the previous
        // playthrough and never said a word.
        let seenBefore = delegate.requestsSeen
        let askedFor = contentId
        Self.keyDelegateQueue.asyncAfter(deadline: .now() + 5) {
            guard delegate.requestsSeen == seenBefore else {
                return
            }
            Self.log("session \(sessionId) raised NO key request from "
                     + "\(sentCount) bytes sent as \(sentShape) with "
                     + (namedKey ? "a named key id" : "no identifier")
                     + " - AVFoundation did not recognise it, and said "
                     + "nothing about it. Requests seen before this one: "
                     + "\(seenBefore)")

            // A SESSION THAT HAS ANSWERED BEFORE AND HAS GONE QUIET IS
            // NOT REFUSING THE SHAPE - IT ALREADY HAS THE KEY.
            //
            // AVContentKeySession raises no request for a key it holds.
            // The page reloaded inside the same content process, the
            // session id is that process, so the entry was reused - and
            // HBO asked for the identical key id the first playthrough
            // had already licensed. Correct behaviour, and fatal, because
            // the content process is waiting for a licence that only a
            // request could produce.
            //
            // Rebuilding gives a session with no keys, which raises the
            // request the old one would not. It cannot loop: a fresh
            // delegate has seen nothing, so seenBefore is 0 next time and
            // this branch is not taken.
            if seenBefore > 0 {
                FairPlayStreamParser.shared.recycleSession(
                    sessionId, contentId: askedFor, initData: initData)
                return
            }

            // The second experiment, sequential and labelled: the same
            // key id with the shape that was not sent. Two shapes and
            // two identities is four combinations, and device cycles are
            // the expensive part - running the pair that share this key
            // id in one pass halves them without ever having two
            // variables in flight at once.
            //
            // Nothing invented: the alternate is the bytes as they
            // arrived, which is the whole box when a payload was sent.
            guard payload != nil else {
                Self.log("session \(sessionId) sent the bytes as they "
                         + "arrived - there is no alternate shape to try")
                return
            }
            guard let live = FairPlayStreamParser.shared.liveSession(sessionId) else {
                return
            }
            Self.log("session \(sessionId) retrying with the WHOLE PSSH box, "
                     + "\(initData.count) bytes, same key id")
            live.processContentKeyRequest(withIdentifier: keyId,
                                          initializationData: initData,
                                          options: nil)
            Self.keyDelegateQueue.asyncAfter(deadline: .now() + 5) {
                guard !delegate.sawRequest else {
                    return
                }
                Self.log("session \(sessionId) BOTH shapes refused WITH a "
                         + "named key id - the identifier is not the "
                         + "obstacle either, and what is left is the "
                         + "internal shape the parser produces; compare "
                         + "against the specifier init data the render "
                         + "probe now dumps")
            }
        }
        return true
    }

    /// This session's AVContentKeySession, or nil once it is gone.
    ///
    /// Looked up late rather than captured, so a retry that fires after
    /// teardown reports nothing instead of resurrecting an entry.
    fileprivate func liveSession(_ sessionId: String) -> AVContentKeySession? {
        return withState { entries[sessionId]?.keySession }
    }

    /// The initialisation data processContentKeyRequest actually takes.
    ///
    /// A JSON document, not an MP4 box - decoded from the specifier the
    /// probe's parser produced, which this API accepts every time:
    ///
    ///     {"sinf":["<base64 sinf box>"]}
    ///
    /// Nil when there is no key id to name, since a sinf without a KID
    /// describes nothing.
    static func sinfInitialisationJSON(keyId: Data?, template: Data?,
                                       sessionId: String) -> Data? {
        guard let keyId, keyId.count == 16 else {
            log("session \(sessionId) has no key id - cannot build a sinf")
            return nil
        }
        let sinf: Data
        if let template, let rekeyed = replacingKeyId(in: template, with: keyId) {
            sinf = rekeyed
            log("session \(sessionId) using the page's own sinf as the "
                + "template, \(sinf.count) bytes")
        } else {
            sinf = canonicalSinf(keyId: keyId)
            log("session \(sessionId) no sinf template yet - synthesising "
                + "\(sinf.count) bytes with a zero constant IV")
        }
        let base64 = sinf.base64EncodedString()
        // Serialised the way Foundation serialises it, because that
        // is the exact byte sequence AVFoundation produced and
        // accepted. The probe's specifier is 147 bytes; the compact
        // form of the same object is 133, and prettyPrinted - spaces
        // around the colon included - is 147 with nothing left over.
        //
        // A parser should not care about whitespace, and if this API
        // merely parses then either form works. It is matched anyway
        // because this call refuses in SILENCE: a refusal and a
        // non-call are indistinguishable from outside, which has
        // already cost device cycles. The known-good bytes are known,
        // so there is no reason to send different ones.
        let document: Data
        if let serialised = try? JSONSerialization.data(
            withJSONObject: ["sinf": [base64]],
            options: [.prettyPrinted]) {
            document = serialised
        } else {
            // Cannot happen for a dictionary of strings, but a silent
            // nil here would be another invisible failure on a path
            // that has had too many.
            log("session \(sessionId) could not serialise the sinf "
                + "JSON - falling back to the compact form")
            document = Data(("{\"sinf\":[\"" + base64 + "\"]}").utf8)
        }
        log("session \(sessionId) init data JSON, \(document.count) "
            + "bytes (the probe's specifier is 147): "
            + (String(data: document, encoding: .utf8) ?? "<unreadable>"))
        return document
    }

    /// A sinf box built to the probe's exact structure.
    ///
    /// Every field is the one AVFoundation's own parser emitted, with
    /// the key id substituted and a zero constant IV. The IV plays no
    /// part in NAMING a key - the request comes back identified by the
    /// KID, which is what the probe showed - so a placeholder is honest
    /// here in a way it would not be for decryption.
    static func canonicalSinf(keyId: Data) -> Data {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let total = 8 + body.count
            var out: [UInt8] = []
            for shift in [24, 16, 8, 0] {
                out.append(UInt8((total >> shift) & 0xff))
            }
            out.append(contentsOf: Array(type.utf8))
            out.append(contentsOf: body)
            return out
        }
        let frma = box("frma", Array("avc1".utf8))
        // version+flags 0, scheme 'cbcs', scheme version 0x00010000
        let schm = box("schm", [0, 0, 0, 0] + Array("cbcs".utf8)
                               + [0x00, 0x01, 0x00, 0x00])
        var tencBody: [UInt8] = [0x01, 0x00, 0x00, 0x00]  // version 1
        tencBody.append(0x00)        // reserved
        tencBody.append(0x19)        // crypt 1, skip 9 - cbcs
        tencBody.append(0x01)        // default_isProtected
        tencBody.append(0x00)        // per-sample IV size: none
        tencBody.append(contentsOf: [UInt8](keyId))
        tencBody.append(0x10)        // constant IV size
        tencBody.append(contentsOf: [UInt8](repeating: 0, count: 16))
        let schi = box("schi", box("tenc", tencBody))
        return Data(frma + schm + schi)
    }

    /// The first complete sinf box in a buffer, or nil.
    static func sinfBox(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        let marker: [UInt8] = [0x73, 0x69, 0x6e, 0x66]  // "sinf"
        var typeAt = 4
        while typeAt + 4 <= bytes.count {
            if Array(bytes[typeAt..<(typeAt + 4)]) == marker {
                let boxAt = typeAt - 4
                let size = (Int(bytes[boxAt]) << 24) | (Int(bytes[boxAt + 1]) << 16)
                         | (Int(bytes[boxAt + 2]) << 8) | Int(bytes[boxAt + 3])
                guard size >= 8, boxAt + size <= bytes.count else {
                    return nil
                }
                // The BODY, without the sinf header: the probe's base64
                // decodes to frma/schm/schi with no enclosing box.
                return Data(bytes[(boxAt + 8)..<(boxAt + size)])
            }
            typeAt += 1
        }
        return nil
    }

    /// The same sinf, naming a different key.
    ///
    /// One template serves every key in a presentation; only the tenc's
    /// default_KID changes between them.
    static func replacingKeyId(in sinf: Data, with keyId: Data) -> Data? {
        var bytes = [UInt8](sinf)
        let marker: [UInt8] = [0x74, 0x65, 0x6e, 0x63]  // "tenc"
        var typeAt = 0
        while typeAt + 4 <= bytes.count {
            if Array(bytes[typeAt..<(typeAt + 4)]) == marker {
                let kidAt = typeAt + 12   // past type, version/flags, 4 fields
                guard kidAt + 16 <= bytes.count else {
                    return nil
                }
                bytes.replaceSubrange(kidAt..<(kidAt + 16),
                                      with: [UInt8](keyId))
                return Data(bytes)
            }
            typeAt += 1
        }
        return nil
    }

    /// The first bytes of a sample's payload, and its total length.
    ///
    /// Contiguity is not assumed: a block buffer may be scattered, and
    /// CMBlockBufferGetDataPointer only speaks for the contiguous run it
    /// finds. Copying the prefix out is both simpler and correct for
    /// either layout.
    static func samplePrefix(_ sampleBuffer: CMSampleBuffer,
                             count: Int) -> ([UInt8], Int) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return ([], 0)
        }
        let total = CMBlockBufferGetDataLength(block)
        let wanted = min(count, total)
        guard wanted > 0 else {
            return ([], total)
        }
        var bytes = [UInt8](repeating: 0, count: wanted)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                              dataLength: wanted,
                                              destination: base)
        }
        guard status == noErr else {
            return ([], total)
        }
        return (bytes, total)
    }

    /// Whether a payload prefix reads as length-prefixed H.264.
    ///
    /// Four big-endian length bytes, then a NAL header: forbidden_zero
    /// clear, type in 1...23, and a length that fits what is actually
    /// there. Deliberately strict - the point is a test ciphertext fails.
    static func h264Framing(_ head: [UInt8], total: Int) -> String {
        func plausibleNAL(_ byte: UInt8) -> Bool {
            guard byte & 0x80 == 0 else { return false }
            let nalType = byte & 0x1f
            return nalType >= 1 && nalType <= 23
        }
        // Length-prefixed: four big-endian bytes that fit the buffer,
        // then a NAL header.
        if head.count >= 5 {
            let length = (Int(head[0]) << 24) | (Int(head[1]) << 16)
                       | (Int(head[2]) << 8) | Int(head[3])
            if length > 0, length <= total - 4, plausibleNAL(head[4]) {
                return "length-prefixed"
            }
        }
        // Raw: the payload IS the NAL, header first. What this parser
        // actually produces.
        if let first = head.first, plausibleNAL(first) {
            return "raw NAL type \(first & 0x1f)"
        }
        return "neither"
    }

    /// Ask the parser for media data on every track it knows about.
    ///
    /// Called once a licence is applied. Both track lists are tried: the
    /// asset's, which is where media actually lives, and any a key
    /// request named - on this route the request comes through the
    /// session rather than the parser, so the second list is usually
    /// empty and the first is the one that matters.
    ///
    /// Whatever comes back arrives at the delegate's didProvideMediaData,
    /// below. Nothing is enqueued anywhere yet: the question is whether
    /// samples exist and whether they are decrypted, and a display layer
    /// would only add a second thing that could be wrong.
    func requestMediaData(_ sessionId: String) {
        // Every STREAM parser for this session, each with its OWN tracks.
        //
        // This used to pool assetTrackIDs across the session and arm the
        // session's parser with them. Once each SourceBuffer got its own
        // parser that became the same defect that aborted the app: the
        // pooled list holds the video parser's tracks as well as the
        // audio parser's, and arming either with the other's throws.
        //
        // The session's own parser is deliberately not armed here. It is
        // fed EME init data and the render probe's segment, never media,
        // so it has no tracks to drain and nothing to say.
        let streams = withState { () -> [(String, StreamParser)] in
            streamParsers.filter { $0.key.hasPrefix(sessionId + "|") }
                         .map { ($0.key, $0.value) }
        }
        guard !streams.isEmpty else {
            Self.log("session \(sessionId) has a licence but no stream "
                     + "parsers yet - nothing has been appended")
            return
        }
        for (key, slot) in streams {
            Self.drainMediaData(slot.parser, tracks: slot.trackIDs, label: key)
        }
    }

    fileprivate func noteAssetTracks(sessionId: String, tracks: [Int32]) {
        withState {
            guard let entry = entries[sessionId] else { return }
            for track in tracks where !entry.assetTrackIDs.contains(track) {
                entry.assetTrackIDs.append(track)
            }
        }
    }

    /// Take the oldest origination this session has not yet matched to a
    /// key request.
    ///
    /// Claimed rather than read, so two requests can never resolve to
    /// the same exchange. Nil when a request arrives that nothing here
    /// asked for, which the delegate reports rather than guessing at.
    func claimOrigination(for sessionId: String) -> FairPlayOrigination? {
        return withState { () -> FairPlayOrigination? in
            guard let entry = entries[sessionId],
                  !entry.pendingOriginations.isEmpty else {
                return nil
            }
            return entry.pendingOriginations.removeFirst()
        }
    }

    /// The originations this session is still waiting on, for logging.
    func pendingOriginationCount(for sessionId: String) -> Int {
        return withState { entries[sessionId]?.pendingOriginations.count ?? 0 }
    }

    /// The key id inside a cenc PSSH box, or nil when the bytes are not
    /// one.
    ///
    /// Big-endian throughout: [4 size][4 'pssh'][1 version][3 flags]
    /// [16 system id], then for version >= 1 [4 kid count][16 bytes
    /// each], and finally [4 data size][data]. A version 0 box names no
    /// key ids in the header; Apple's FairPlay box opens its payload
    /// with one.
    ///
    /// Read rather than passed - see requestKey - but read so the log
    /// can say whether what arrived was even the shape it claims to be.
    /// Copied to an array first: this Data comes across from
    /// Objective-C, where a non-zero startIndex is legal and indexing a
    /// Data by absolute offset is a well-known way to read the wrong
    /// bytes.
    /// FairPlay Streaming's registered SystemID,
    /// 94CE86FB-07FF-4F43-ADB8-93D2FA968CA2, as it sits in the box.
    static let fairPlaySystemId: [UInt8] = [
        0x94, 0xCE, 0x86, 0xFB, 0x07, 0xFF, 0x4F, 0x43,
        0xAD, 0xB8, 0x93, 0xD2, 0xFA, 0x96, 0x8C, 0xA2,
    ]

    /// The key id for the FairPlay key this init data names, or nil.
    static func keyIdentifier(inPSSH data: Data) -> Data? {
        let bytes = [UInt8](data)

        func be32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return -1 }
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }

        func fourCC(_ at: Int) -> String {
            guard at + 4 <= bytes.count else { return "????" }
            return String(bytes[at..<(at + 4)].map { byte -> Character in
                (byte >= 0x20 && byte <= 0x7e) ? Character(UnicodeScalar(byte))
                                               : "."
            })
        }

        // The first bytes, always, so a shape this cannot read is
        // diagnosable from the capture instead of from another build.
        // Every failure on this path has been silent; this is the line
        // that makes the NEXT unknown layout cost a log line rather than
        // a device cycle.
        Self.log("init data \(bytes.count) bytes, box \(fourCC(4)), head "
                 + bytes.prefix(40).map { String(format: "%02x", $0) }
                        .joined())

        var fallback: Data?
        var boxAt = 0

        // "cenc" initialisation data is a CONCATENATION of pssh boxes,
        // one per DRM the content was packaged for, so this walks by each
        // box's own length rather than reading only the first.
        while boxAt + 8 <= bytes.count {
            let size = be32(boxAt)
            guard size >= 8, boxAt + size <= bytes.count else {
                break
            }
            guard fourCC(boxAt + 4) == "pssh", boxAt + 32 <= bytes.count else {
                boxAt += size
                continue
            }

            let version = bytes[boxAt + 8]
            let systemId = Array(bytes[(boxAt + 12)..<(boxAt + 28)])
            let isFairPlay = systemId == Self.fairPlaySystemId
            Self.log("  pssh v\(version) system "
                     + systemId.map { String(format: "%02x", $0) }.joined()
                     + (isFairPlay ? " (FairPlay)" : ""))

            var cursor = boxAt + 28
            if version >= 1 {
                let count = be32(cursor)
                cursor += 4
                if count > 0, cursor + 16 <= bytes.count {
                    let kid = Data(bytes[cursor..<(cursor + 16)])
                    if isFairPlay {
                        return kid
                    }
                    // Under Common Encryption the KID is often shared
                    // across systems, so another system's is better than
                    // nothing - but it is a guess, and it says so.
                    if fallback == nil {
                        fallback = kid
                    }
                }
            } else if isFairPlay {
                // Apple's own layout, decoded from a device capture:
                // the v0 payload is a box tree, fpsd > fpsk > fkri, and
                // fkri's body is four reserved bytes followed by the key
                // id. Confirmed against the identifier AVFoundation
                // derived from the matching init segment - they are the
                // same sixteen bytes.
                let payloadSize = be32(cursor)
                cursor += 4
                let payloadEnd = min(cursor + max(payloadSize, 0),
                                     boxAt + size)
                if let kid = Self.fkriKeyIdentifier(bytes, from: cursor,
                                                    to: payloadEnd) {
                    return kid
                }
                // Older packagings really do open the payload with the
                // key id. Tried only after the box tree, and only for a
                // FairPlay box, so it can no longer fire on a foreign
                // system's private payload.
                if cursor + 16 <= payloadEnd {
                    Self.log("  no fkri - taking the payload's first 16 bytes")
                    return Data(bytes[cursor..<(cursor + 16)])
                }
            }
            boxAt += size
        }

        if fallback != nil {
            Self.log("no FairPlay key id - falling back to another system's, "
                     + "which may not be the right key")
        }
        return fallback
    }

    /// The key id inside a FairPlay PSSH payload's fkri box.
    ///
    /// Scanned for within the payload rather than walked through
    /// fpsd > fpsk, because only this one field is wanted and the
    /// surrounding nesting has already varied between packagers. The
    /// scan is bounded to this box's payload, and "fkri" preceded by its
    /// own length cannot occur by accident in a structure this small.
    ///
    /// Layout from the start of the fkri box: size 4, type 4, reserved
    /// 4, then the key id for 16.
    static func fkriKeyIdentifier(_ bytes: [UInt8], from: Int,
                                  to: Int) -> Data? {
        guard from >= 0, to <= bytes.count, from < to else {
            return nil
        }
        let marker: [UInt8] = [0x66, 0x6b, 0x72, 0x69]  // "fkri"
        var typeAt = from
        while typeAt + 4 <= to {
            if Array(bytes[typeAt..<(typeAt + 4)]) == marker {
                let kidAt = typeAt + 8       // past type, past reserved
                guard kidAt + 16 <= to else {
                    return nil
                }
                let kid = Data(bytes[kidAt..<(kidAt + 16)])
                Self.log("  fkri key id "
                         + kid.map { String(format: "%02x", $0) }.joined())
                return kid
            }
            typeAt += 1
        }
        return nil
    }

    /// Whether the bytes at `at` open an MP4 box that fills `within`.
    ///
    /// ADDED - see fix_key_request_unwraps_pssh.py's docstring. Both
    /// tests matter: a 16-byte key id can begin with anything, so the
    /// declared size has to account for the whole payload before a box
    /// is the better reading of it.
    private static func looksLikeBox(_ bytes: [UInt8], at: Int,
                                     within: Int) -> Bool {
        guard bytes.count >= at + 8 else { return false }
        let size = (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        guard size == within else { return false }
        return bytes[(at + 4)..<(at + 8)].allSatisfy {
            $0 >= 0x20 && $0 <= 0x7E
        }
    }

    /// The data payload of a PSSH box, or nil when these bytes are not
    /// one.
    ///
    /// ADDED - see fix_key_request_unwraps_pssh.py's docstring. This is
    /// what AVFoundation wants: the FairPlay initialisation data, with
    /// the MP4 wrapper the page delivers it in taken off.
    ///
    /// Same layout walk as keyIdentifier(inPSSH:) above, and copied to
    /// an array first for the same reason - this Data crosses from
    /// Objective-C, where a non-zero startIndex is legal and indexing
    /// by absolute offset reads the wrong bytes.
    static func psshPayload(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 32,
              bytes[4] == 0x70, bytes[5] == 0x73,
              bytes[6] == 0x73, bytes[7] == 0x68 else {
            return nil
        }
        func be32(_ at: Int) -> Int {
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        var cursor = 28  // size, type, version+flags, system id
        if bytes[8] >= 1 {
            guard bytes.count >= cursor + 4 else { return nil }
            cursor += 4 + 16 * be32(cursor)
        }
        guard bytes.count >= cursor + 4 else { return nil }
        let length = be32(cursor)
        cursor += 4
        guard length > 0, bytes.count >= cursor + length else {
            return nil
        }
        return Data(bytes[cursor..<(cursor + length)])
    }

    /// One parser per stream, all recipients of the session's ONE key
    /// session.
    ///
    /// A page appends audio and video to separate SourceBuffers, and
    /// AVStreamDataParser parses a single stream: fed two presentations
    /// it reports one track as `soun` and another as `vide` under the
    /// same id, then fails -11853 and never recovers.
    ///
    /// The key session stays shared, and that is deliberate rather than
    /// convenient - a licence applied to a request on it decrypts for
    /// every recipient, so the whole EME exchange (key request, SPC,
    /// CKC, all keyed by child) is untouched by this.
    fileprivate final class StreamParser {
        let parser: NSObject
        let recipient: AVContentKeyRecipient
        let delegate: ParserDelegate
        /// AVFoundation says a failed parser cannot recover - "create a
        /// new AVStreamDataParser to try again" - so this marks one for
        /// replacement rather than pretending it still works.
        var failed = false
        /// Tracks THIS parser reported, from its own
        /// didParseStreamDataAsAsset. Nothing is ever armed for a track
        /// that is not in here.
        ///
        /// Per stream rather than per session, because fix 19 gave each
        /// SourceBuffer its own parser: arming the audio parser with the
        /// video parser's track id throws exactly as arming an invented
        /// one does.
        var trackIDs: [Int32] = []
        /// The sink under test. Built on the first video sample, never
        /// added to a view hierarchy - this measures whether the layer
        /// ACCEPTS these samples, and showing it would add a second
        /// thing that could be wrong.
        var displayLayer: AVSampleBufferDisplayLayer?
        /// So 422 identical status lines do not bury the one that
        /// changes.
        var lastReport = ""
        var enqueued = 0
        /// Has the layer got somewhere to render yet?
        ///
        /// Fix 21 fed it from the moment it was constructed, and
        /// showLayerIfRequested attaches it on the main queue - which in
        /// the capture ran sixty log lines later. Every sample before
        /// that went into a layer attached to nothing, which fills and
        /// stops. Nothing is fed until this is true.
        var layerAttached = false
        /// Samples waiting for the layer to want them.
        ///
        /// Bounded: a queue that grows without limit turns a display
        /// stall into a memory problem, and this is a diagnostic.
        var pending: [CMSampleBuffer] = []
        var overflowed = 0
        /// requestMediaDataWhenReady calls its block in a loop while the
        /// layer is hungry, so it is stopped when the queue empties and
        /// re-armed when something arrives. Otherwise it spins.
        var drainArmed = false
        var failObserver: NSObjectProtocol?
        var drainQueue: DispatchQueue?
        /// The independent decode probe - see runDecodeProbe.
        var probeSession: VTDecompressionSession?
        var probeIn = 0
        var probeOut = 0
        /// So the "these are protected, the probe cannot help" note is
        /// made once rather than 360 times.
        var probeSkippedLogged = false
        /// The last DECODE stamp taken in, which is what discontinuity
        /// detection actually uses.
        ///
        /// Presentation stamps reorder and decode stamps do not - that
        /// is what a decode stamp is for. A seventeen-frame
        /// hierarchical-B mini-GOP arrives as
        ///
        ///     pts 12.28  dts 12.24
        ///     pts 13.00  dts 12.28
        ///     pts 12.64  dts 12.32
        ///     pts 12.36  dts 12.36
        ///
        /// and against a presentation high-water mark the fourth line
        /// reads as a 0.64s regression. Fix 27 set the threshold at half
        /// a second on content that reordered by 0.042s; this content
        /// reorders by 0.68s, so the threshold sat inside the ordinary
        /// case and flushed 234 samples for nothing.
        ///
        /// The decode stamp cannot do that, and a real timeline change
        /// moves it too - the one genuine discontinuity in that capture
        /// was dts 15.588 -> 10.000. No high-water mark is needed here
        /// because this value only ever goes forwards.
        var lastIntakeDTS = Double.nan
        /// The newest PTS ever handed to the display layer.
        ///
        /// The clock being past THIS is the fatal condition: no sample
        /// the layer holds can be due, so nothing it decodes will be
        /// presented, and it reports that state as status 1 with no
        /// error. Compared against a high-water mark rather than the
        /// sample in hand because presentation stamps reorder.
        var maxEnqueuedPTS = Double.nan
        var clockCorrections = 0
        /// The same, for the audio renderer's own clock.
        var maxAudioPTS = Double.nan
        var audioClockCorrections = 0
        /// Host time of the last sample taken in, on either half.
        ///
        /// The only liveness signal this file has. Streams from a
        /// finished playback are never removed - destroySession tears
        /// them down, but a page that reloads inside the same content
        /// process does not destroy the session - so the table keeps
        /// corpses, and a corpse's timebase carries on running. One of
        /// them anchored a new audio renderer twenty-five seconds into a
        /// future its media never reached.
        ///
        /// Zero until the first sample, which reads as "not live" and is
        /// correct: a stream that has never been fed cannot be the one
        /// currently playing.
        var lastSampleAt: Double = 0
        /// Host time of the last clock correction, so a correction that
        /// achieves nothing reports a handful of times instead of once
        /// per sample.
        var lastCorrectionAt: Double = 0
        var lastAudioCorrectionAt: Double = 0
        /// Said once, not thirty-two times.
        var reportedUnmovedClock = false
        /// The samples taken in since the last sync sample.
        ///
        /// Kept so that a new sink can be started without waiting for
        /// the next keyframe: these are exactly the samples it needs to
        /// decode the picture that is on screen right now, and they have
        /// already been handed to the layer being replaced. Cleared on
        /// every sync sample, so it holds one GOP and no more.
        var currentGOP: [CMSampleBuffer] = []
        /// Did this parser build the layer it is feeding?
        ///
        /// True for the hardcoded overlay it makes itself, false once the
        /// compositor's has been adopted. Only an owned layer may be
        /// removed from its superlayer - a compositor layer lives in
        /// NativeLayerCA's own tree, and retiring one would tear it out.
        var ownsDisplayLayer = true
        /// Highest PTS taken IN so far, kept for the handover's fallback
        /// anchor. No longer the discontinuity signal - see
        /// lastIntakeDTS.
        ///
        /// Intake order is the order the layer will see, so a jump shows
        /// up here before it can strand anything. NaN until the first
        /// sample.
        var lastIntakePTS = Double.nan
        /// After a flush or a drop, nothing is fed until a sync sample: a
        /// display layer handed a mid-GOP frame has no reference to
        /// decode from.
        var needsSyncSample = false
        var flushes = 0
        var videoSeen = 0
        /// The second sink: a plain CALayer whose contents are set from
        /// the decoded pixel buffers. No renderer, no timebase, no
        /// readiness - it either shows the image or it does not.
        var proofLayer: CALayer?
        var proofFrames = 0
        /// The layer the compositor's replaced, held until the new one
        /// has actually taken a sample.
        ///
        /// Removing the overlay at handover would trade a working
        /// picture in the wrong place for a blank screen if the new
        /// layer refuses, and there is no way to know which it will be
        /// before feeding it one.
        var retiringOverlay: AVSampleBufferDisplayLayer?

        /// The audio half. Everything below mirrors the video state
        /// above, because the renderer takes samples through the same
        /// protocol the display layer does and there is no reason for
        /// the two to be shaped differently.
        ///
        /// Separate from the video state rather than shared with it: fix
        /// 19 gave every SourceBuffer its own parser, so a StreamParser
        /// is either the video stream or the audio stream and never
        /// both. These fields are simply the ones that get used when it
        /// is the audio one.
        var audioRenderer: AVSampleBufferAudioRenderer?
        /// An audio renderer has no controlTimebase of its own - this is
        /// what clocks it.
        var audioSynchronizer: AVSampleBufferRenderSynchronizer?
        var audioQueue: DispatchQueue?
        var audioPending: [CMSampleBuffer] = []
        var audioOverflowed = 0
        var audioDrainArmed = false
        var audioEnqueued = 0
        var audioSeen = 0
        var audioFlushes = 0
        var audioLastReport = ""
        /// Has the synchronizer been given a rate? Nothing is fed before
        /// it has, for fix 26's reason: a renderer clocked at a time the
        /// samples have already passed discards all of them and reports
        /// no error.
        var audioStarted = false
        var lastAudioIntakePTS = Double.nan
        var audioFlushObserver: NSObjectProtocol?

        init(parser: NSObject, recipient: AVContentKeyRecipient,
             delegate: ParserDelegate) {
            self.parser = parser
            self.recipient = recipient
            self.delegate = delegate
        }
    }

    /// Append to the parser for one stream, building it if needed.
    @discardableResult
    @objc public func append(_ sessionId: String, stream: String,
                             segment: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("segment for unknown session \(sessionId)")
            return false
        }
        let key = sessionId + "|" + stream
        var slot = withState { streamParsers[key] }
        if let existing = slot, existing.failed {
            Self.log("stream \(stream) parser had failed - building a new one")
            entry.keySession.removeContentKeyRecipient(existing.recipient)
            withState { streamParsers[key] = nil }
            slot = nil
        }
        if slot == nil {
            guard let built = Self.buildParser(sessionId: sessionId,
                                               stream: stream) else {
                return false
            }
            entry.keySession.addContentKeyRecipient(built.recipient)
            withState { streamParsers[key] = built }
            Self.log("stream \(stream) parser built and added to the key "
                     + "session - recipients "
                     + "\(entry.keySession.contentKeyRecipients.count)")
            slot = built
        }
        guard let slot else {
            return false
        }
        let append = NSSelectorFromString("appendStreamData:")
        guard slot.parser.responds(to: append) else {
            Self.log("no appendStreamData: on the stream parser")
            return false
        }
        slot.parser.perform(append, with: segment)
        Self.log("stream \(stream) appended \(segment.count) bytes")
        // Asked for again after EVERY append, not once when the licence
        // landed. setShouldProvideMediaData is armed per track and
        // providePendingMediaData drains what is pending NOW - fragments
        // that arrive later were simply never asked for, which is why
        // eight forwarded fragments produced one sample.
        Self.drainMediaData(slot.parser, tracks: slot.trackIDs, label: stream)
        return true
    }

    /// A parser bound to one stream, with its own delegate.
    private static func buildParser(sessionId: String,
                                    stream: String) -> StreamParser? {
        guard let parserClass = NSClassFromString("AVStreamDataParser") as? NSObject.Type else {
            log("AVStreamDataParser is absent")
            return nil
        }
        let parser = parserClass.init()
        // The delegate carries the stream key, so the tracks it reports
        // are recorded against the parser that reported them rather than
        // pooled per session. Pooling would arm the audio parser with
        // the video parser's track id, which throws.
        let delegate = ParserDelegate(sessionId: sessionId,
                                      streamKey: sessionId + "|" + stream)
        let setDelegate = NSSelectorFromString("setDelegate:")
        guard parser.responds(to: setDelegate) else {
            log("no setDelegate: on the stream parser")
            return nil
        }
        parser.perform(setDelegate, with: delegate)
        guard let recipient = parser as? AVContentKeyRecipient else {
            log("stream parser does not declare AVContentKeyRecipient")
            return nil
        }
        return StreamParser(parser: parser, recipient: recipient,
                            delegate: delegate)
    }

    /// Arm every track and drain whatever is pending.
    private static func drainMediaData(_ parser: NSObject, tracks: [Int32],
                                       label: String) {
        // Nothing is armed without a track the parser itself reported.
        //
        // The previous version walked 1...2 on the assumption that arming
        // an absent track was a no-op. It is not:
        // setShouldProvideMediaData:forTrackID: raises an Objective-C
        // exception, Swift cannot catch one, and the first 802-byte init
        // segment - appended before any asset had parsed, so before any
        // track existed - aborted the app on the main thread.
        guard !tracks.isEmpty else {
            log("stream \(label) has no parsed tracks yet - nothing to arm")
            return
        }
        let shouldProvide = NSSelectorFromString("setShouldProvideMediaData:forTrackID:")
        let provide = NSSelectorFromString("providePendingMediaData")
        if parser.responds(to: shouldProvide),
           let implementation = parser.method(for: shouldProvide) {
            typealias ProvideFunction =
                @convention(c) (AnyObject, Selector, Bool, Int32) -> Void
            let call = unsafeBitCast(implementation, to: ProvideFunction.self)
            for trackID in tracks {
                // Guarded even so. This is undocumented SPI whose
                // behaviour is being established by experiment, and it
                // has already proved it throws.
                if let failure = GeckoRuntimeBridge.catchException(from: {
                    call(parser, shouldProvide, true, trackID)
                }) {
                    log("stream \(label) refused arming track \(trackID): "
                        + failure)
                }
            }
        }
        if parser.responds(to: provide) {
            if let failure = GeckoRuntimeBridge.catchException(from: {
                parser.perform(provide)
            }) {
                log("stream \(label) refused providePendingMediaData: "
                    + failure)
            }
        }
        log("stream \(label) armed tracks \(tracks) and drained")
    }

    /// Tracks a stream's parser reported, recorded and then acted on.
    ///
    /// Driven from the asset callback because that is the moment they
    /// become known - an append cannot arm anything before the parse it
    /// triggers has finished.
    fileprivate func noteStreamTracks(streamKey: String, tracks: [Int32]) {
        let slot = withState { () -> StreamParser? in
            guard let slot = streamParsers[streamKey] else { return nil }
            for track in tracks where !slot.trackIDs.contains(track) {
                slot.trackIDs.append(track)
            }
            return slot
        }
        guard let slot else {
            return
        }
        Self.drainMediaData(slot.parser, tracks: slot.trackIDs,
                            label: streamKey)
    }

    fileprivate func noteStreamParseFailure(sessionId: String) {
        withState {
            for (key, slot) in streamParsers where key.hasPrefix(sessionId + "|") {
                slot.failed = true
            }
        }
    }

    /// Enqueue a decrypted video sample and report what the layer makes
    /// of it.
    ///
    /// THE LAST PLATFORM QUESTION on this route. Decrypt is settled - the
    /// parser hands back clear length-prefixed H.264 - and the only step
    /// still capable of refusing on authorization grounds is the sink.
    /// If a display layer takes these samples, the remaining work is
    /// compositor wiring and nothing more; if it refuses, its error says
    /// so in as many words and no amount of wiring would have helped.
    fileprivate func enqueueForDisplay(streamKey: String,
                                       sampleBuffer: CMSampleBuffer,
                                       mediaType: String) {
        // Audio now has somewhere to go.
        //
        // This used to be "Video only. Audio has no display layer to go
        // to, and the question is about pixels" followed by a return, and
        // that is where every qaac sample HBO Max produced ended up. The
        // comment was true for fix 21's question - does a display layer
        // ACCEPT protected samples - and has not been true for several
        // rounds since.
        //
        // "soun" is what AVFoundation calls an audio track and is
        // AVMediaType.audio's raw value; both spellings are tested
        // because this string arrives from an SPI delegate and costs
        // nothing to check twice. Anything that is neither video nor
        // audio - a subtitle or timed metadata track - still returns,
        // and should.
        if mediaType != "vide" {
            if mediaType == "soun" || mediaType == AVMediaType.audio.rawValue {
                enqueueForPlayback(streamKey: streamKey,
                                   sampleBuffer: sampleBuffer)
            }
            return
        }
        guard let slot = withState({ streamParsers[streamKey] }) else {
            return
        }

        if slot.displayLayer == nil {
            let layer = AVSampleBufferDisplayLayer()
            // A control timebase, because a layer with no clock has
            // nothing to schedule against and can report itself ready
            // while showing nothing - which would read as acceptance and
            // mean nothing.
            //
            // STARTED PAUSED, at rate 0, and that is the whole of fix 26.
            // Fix 21 started it at rate 1 the instant the layer was
            // constructed, and the layer is not attached to anything for
            // another sixty log lines - so 2.3 seconds of media time
            // elapsed on the clock while the queue filled with frames due
            // at times the clock had already passed. Every one of them
            // was late before the layer had anywhere to paint. The rate
            // is released in markLayerAttached, when there is a renderer
            // for it to be a clock for.
            var timebase: CMTimebase?
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                               sourceClock: CMClockGetHostTimeClock(),
                                               timebaseOut: &timebase) == noErr,
               let timebase {
                CMTimebaseSetTime(timebase, time: start)
                CMTimebaseSetRate(timebase, rate: 0.0)
                layer.controlTimebase = timebase
            }
            layer.videoGravity = .resizeAspect
            withState {
                slot.displayLayer = layer
                slot.drainQueue = DispatchQueue(
                    label: "org.reynard.fps.display")
            }
            joinKeySession(layer, streamKey: streamKey)
            Self.observeDecodeFailures(layer, label: streamKey)
            Self.log("stream \(streamKey) built a display layer - "
                     + "status \(layer.status.rawValue) "
                     + "timebase \(timebase != nil) - paused until attached")
            if Self.showLayerMarkerPresent() {
                Self.showLayerIfRequested(layer, label: streamKey)
            } else {
                // No marker, so no placement is coming and none is
                // wanted: this is fix 21's original measurement, which
                // asks only whether the layer ACCEPTS the samples. Waiting
                // for an attachment that will never happen would turn
                // that measurement into silence.
                markLayerAttached(streamKey: streamKey)
            }
        }
        guard let layer = withState({ slot.displayLayer }) else {
            return
        }

        // ONE discontinuity in the whole capture, and it ended the
        // picture.
        //
        // 429 samples produced 200 apparent PTS regressions. 199 were the
        // ordinary B-frame reorder, one frame interval apart. The other
        // one was not:
        //
        //     sample 191:  pts 17.9246 -> 17.8829   back 0.042s
        //     sample 193:  pts 17.9663 -> 10.0000   back 7.966s
        //
        // At 193 the page re-appended the same range at a higher bitrate -
        // 110-byte frames the first time through, 50506 the second - which
        // is an ABR upswitch and entirely normal. The timebase was at 16.5,
        // so every sample after it was six seconds stale and could never
        // be presented. The layer kept accepting; the screen kept the last
        // frame it had.
        //
        // Half a second of threshold. The reorder is 0.042s here and the
        // real jump was 8s; nothing meaningful lives in between, so no
        // finer policy is needed. Forwards is checked too, at 2s, because
        // a seek strands the queue the same way in the other direction.
        let intakePTS =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // In DECODE order. A presentation high-water mark cannot tell a
        // hierarchical-B reorder from a seek, and on content with a
        // seventeen-frame mini-GOP it called three reorders
        // discontinuities and flushed 234 samples for them. A decode
        // stamp only ever goes forwards, so anything that goes backwards
        // in it is a real timeline change.
        //
        // Falls back to the presentation stamp when a sample carries no
        // decode stamp at all, which for H.264 in MP4 means the two are
        // equal anyway.
        let stamped = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        let intakeDTS = stamped.isValid ? stamped.seconds : intakePTS
        let arrivedAt = Self.hostNow()
        let jump = withState { () -> Double? in
            slot.videoSeen += 1
            slot.lastSampleAt = arrivedAt
            slot.lastIntakePTS = max(slot.lastIntakePTS.isFinite
                                     ? slot.lastIntakePTS : intakePTS,
                                     intakePTS)
            guard slot.lastIntakeDTS.isFinite, intakeDTS.isFinite else {
                slot.lastIntakeDTS = intakeDTS
                return nil
            }
            let delta = intakeDTS - slot.lastIntakeDTS
            slot.lastIntakeDTS = intakeDTS
            guard delta < -0.5 || delta > 2.0 else {
                return nil
            }
            return delta
        }
        if let jump {
            resynchronise(streamKey: streamKey, to: intakePTS, jump: jump)
        }

        // Nothing is fed mid-GOP. After a flush the layer has no
        // reference frame, and after a drop there is a hole where one
        // used to be - either way the next usable sample is a keyframe
        // and everything before it decodes to garbage.
        if withState({ slot.needsSyncSample }) {
            guard Self.isSyncSample(sampleBuffer) else {
                return
            }
            withState { slot.needsSyncSample = false }
            Self.log("stream \(streamKey) resync complete - first sync "
                     + "sample at pts \(intakePTS)")
        }

        // The independent answer, before anything to do with the layer:
        // whether these bytes decode is a fact about the bytes, and it
        // should not depend on the sink being wired correctly.
        runDecodeProbe(streamKey: streamKey, sampleBuffer: sampleBuffer)

        // Held, not enqueued. The layer is asked for samples through
        // requestMediaDataWhenReady, which is the API that exists because
        // pushing into a full renderer is undefined - and fix 21 pushed
        // 429 frames at a layer that stopped consuming after 55.
        // 900 rather than 240. A run that was otherwise healthy dropped
        // 100+ samples at 240, because 240 frames is under ten seconds at
        // 24fps and MSE buffers much further ahead than that - the parser
        // hands over a whole appended segment at once, not in real time.
        // 900 frames of compressed video is roughly 20MB at the sizes in
        // that capture, which is real memory, and acceptable only because
        // this whole path is behind a marker file.
        let isSync = Self.isSyncSample(sampleBuffer)
        let queued = withState { () -> Int in
            guard slot.pending.count < 900 else {
                slot.overflowed += 1
                // A hole in the middle of a GOP decodes to garbage, so
                // the feed restarts at the next keyframe rather than
                // resuming mid-picture.
                slot.needsSyncSample = true
                return -1
            }
            // The current GOP, kept so a new sink can be handed the
            // samples it needs to decode the picture on screen instead
            // of waiting for the next keyframe. Reset on every sync
            // sample, so this holds one GOP.
            //
            // Cleared outright rather than trimmed past 300, because a
            // GOP that long - twelve seconds at 25fps - means the reset
            // is not happening, and half of one is worth nothing: the
            // whole value of this is that it starts at a keyframe.
            if isSync {
                slot.currentGOP.removeAll()
            }
            if slot.currentGOP.count >= 300 {
                slot.currentGOP.removeAll()
            } else {
                slot.currentGOP.append(sampleBuffer)
            }
            slot.pending.append(sampleBuffer)
            return slot.pending.count
        }
        if queued < 0 {
            let dropped = withState { slot.overflowed }
            if dropped == 1 || dropped % 100 == 0 {
                Self.log("stream \(streamKey) pending queue FULL - "
                         + "\(dropped) samples dropped, will restart at the "
                         + "next sync sample. The layer is not draining.")
            }
            return
        }
        armDrainIfNeeded(streamKey: streamKey)
    }

    /// The layer has somewhere to render. Start its clock and start
    /// feeding it.
    ///
    /// Called from the placement block on the main queue - through every
    /// exit of it, including the failures, because a feeder that waits
    /// for an attachment that did not happen produces no rectangle at all
    /// rather than an empty one, and those look identical in a log.
    fileprivate func markLayerAttached(streamKey: String) {
        let started = withState { () -> Bool in
            guard let slot = streamParsers[streamKey],
                  !slot.layerAttached else { return false }
            slot.layerAttached = true
            return true
        }
        guard started else { return }
        if let layer = withState({ streamParsers[streamKey]?.displayLayer }),
           let timebase = layer.controlTimebase {
            // Re-anchored to the OLDEST sample still waiting, not to
            // wherever the clock was left. The point of pausing was that
            // the queue's contents should not be stale when the clock
            // starts, and that only holds if the clock starts where the
            // queue starts.
            let head = withState { streamParsers[streamKey]?.pending.first }
            if let head {
                CMTimebaseSetTime(
                    timebase,
                    time: CMSampleBufferGetPresentationTimeStamp(head))
            }
            CMTimebaseSetRate(timebase, rate: 1.0)
            Self.log("stream \(streamKey) released the timebase at "
                     + "\(CMTimebaseGetTime(timebase).seconds) - layer "
                     + "attached, feeding starts now")
            // The master clock just started. Any audio renderer in this
            // session that started before it was anchored to its own
            // first sample instead, which is the wrong reference by
            // however long placement took - so it is re-anchored here,
            // to the one clock that matters.
            realignAudioClock(
                sessionId: String(streamKey.split(separator: "|").first ?? ""),
                to: CMTimebaseGetTime(timebase))
        }
        armDrainIfNeeded(streamKey: streamKey)
    }

    /// Ask the layer to come and get them, if it is not already asking.
    private func armDrainIfNeeded(streamKey: String) {
        let work = withState { () -> (layer: AVSampleBufferDisplayLayer,
                                      queue: DispatchQueue)? in
            guard let slot = streamParsers[streamKey],
                  slot.layerAttached, !slot.drainArmed,
                  !slot.pending.isEmpty,
                  let layer = slot.displayLayer,
                  let queue = slot.drainQueue else { return nil }
            slot.drainArmed = true
            return (layer, queue)
        }
        guard let work else { return }
        work.layer.requestMediaDataWhenReady(on: work.queue) {
            [weak layer = work.layer] in
            guard let layer else { return }
            FairPlayStreamParser.shared.drainPending(streamKey: streamKey,
                                                     layer: layer)
        }
    }

    /// Feed the layer while it is hungry, and stop asking when it is not.
    fileprivate func drainPending(streamKey: String,
                                  layer: AVSampleBufferDisplayLayer) {
        while layer.isReadyForMoreMediaData {
            let next = withState { () -> CMSampleBuffer? in
                guard let slot = streamParsers[streamKey],
                      !slot.pending.isEmpty else { return nil }
                return slot.pending.removeFirst()
            }
            guard let sample = next else {
                // Nothing left. Stop, or the block spins on an empty
                // queue for as long as the layer stays ready.
                layer.stopRequestingMediaData()
                withState { streamParsers[streamKey]?.drainArmed = false }
                return
            }
            // Guarded: enqueue RAISES on a sample it dislikes rather than
            // returning an error, and this route has already had one
            // AVFoundation SPI take the process down.
            if let failure = GeckoRuntimeBridge.catchException(from: {
                layer.enqueue(sample)
            }) {
                Self.log("stream \(streamKey) layer REFUSED the sample: "
                         + failure)
                return
            }
            let count = withState { () -> Int in
                guard let slot = streamParsers[streamKey] else { return 0 }
                slot.enqueued += 1
                return slot.enqueued
            }

            // A sample went into the compositor's layer, so the overlay
            // has done its job and can go. This is the only place that
            // retires it: it is the only place that knows the new sink
            // accepted anything.
            let retiring = withState { () -> AVSampleBufferDisplayLayer? in
                guard let slot = streamParsers[streamKey],
                      let overlay = slot.retiringOverlay else { return nil }
                slot.retiringOverlay = nil
                return overlay
            }
            if let retiring {
                // Deregistration moved to the handover, which every
                // superseded layer goes through - this path is only ever
                // reached by the overlay.
                DispatchQueue.main.async {
                    retiring.removeFromSuperlayer()
                    Self.log("stream \(streamKey) retired the overlay - the "
                             + "picture is now in the page's own box")
                }
            }

            // Reported on change, plus the first one. status 2 is .failed
            // and is where an authorization refusal would appear.
            // requiresFlushToResumeDecoding is the one property whose
            // true value would explain everything seen so far: the layer
            // accepts and discards until flushed, with no error and a
            // rendering status. Nothing has ever read it.
            //
            // Through KVC with a responds(to:) guard, not referenced
            // directly - it is newer than this deployment target, and a
            // diagnostic has already broken a build on this route once.
            let flushKey = "requiresFlushToResumeDecoding"
            let needsFlush = layer.responds(to: NSSelectorFromString(flushKey))
                ? String(describing: layer.value(forKey: flushKey) ?? "?")
                : "n/a"
            let report = "status=\(layer.status.rawValue) "
                + "ready=\(layer.isReadyForMoreMediaData) "
                + "needsFlush=\(needsFlush) "
                + "error=\(layer.error.map { String(describing: $0) } ?? "nil")"
            let changed = withState { () -> Bool in
                guard let slot = streamParsers[streamKey],
                      slot.lastReport != report else { return false }
                slot.lastReport = report
                return true
            }
            if changed || count == 1 {
                Self.log("stream \(streamKey) enqueued \(count) - " + report)
            }
            // A CLOCK AHEAD OF THE MEDIA IS FATAL, AND SILENT.
            //
            // Drift has been printed here for several rounds and never
            // acted on. It should have been: the run that stopped went
            //
            //     at 540 - timebase 3773.856 vs pts 3775.313, drift  -1.458
            //     at 570 - timebase 3783.124 vs pts 3772.560, drift +10.563
            //
            // across a pause the element took and this clock did not.
            // The timebase runs at rate 1.0 on the host clock from
            // wherever it was anchored; the page's clock stops when the
            // page stops, and nothing tells this side. It came back ten
            // and a half seconds ahead, and from then on every sample
            // was late - decoded, not presented, status 1, error nil,
            // needsFlush 0, and nothing on screen.
            //
            // The page's real position cannot be read from here, so the
            // condition is measured where it bites: if the clock is past
            // the NEWEST sample this layer has ever been given, nothing
            // it holds can ever be due. A whole second of slack, because
            // this compares against a high-water mark and a
            // hierarchical-B reorder is up to 0.68s.
            //
            // Audio moves with it. This is a correction to OUR clock,
            // not a stream discontinuity - the two are different, and
            // dragging audio is right for one and wrong for the other.
            if let timebase = layer.controlTimebase {
                let now = CMTimebaseGetTime(timebase).seconds
                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let ranAhead = withState { () -> (late: Double, nth: Int)? in
                    guard let slot = streamParsers[streamKey] else { return nil }
                    if pts.isFinite {
                        slot.maxEnqueuedPTS = slot.maxEnqueuedPTS.isFinite
                            ? max(slot.maxEnqueuedPTS, pts) : pts
                    }
                    let checkedAt = Self.hostNow()
                    guard now.isFinite, pts.isFinite,
                          slot.maxEnqueuedPTS.isFinite,
                          now - slot.maxEnqueuedPTS > 1.0,
                          // At most one a second. A correction that does
                          // not take would otherwise fire on every
                          // sample, and thirty-two identical lines say
                          // no more than three do.
                          checkedAt - slot.lastCorrectionAt > 1.0
                    else { return nil }
                    slot.lastCorrectionAt = checkedAt
                    let late = now - slot.maxEnqueuedPTS
                    slot.clockCorrections += 1
                    slot.maxEnqueuedPTS = pts
                    return (late, slot.clockCorrections)
                }
                if let ranAhead {
                    let to = CMTime(seconds: pts, preferredTimescale: 90_000)
                    CMTimebaseSetTime(timebase, time: to)
                    realignAudioClock(
                        sessionId: String(
                            streamKey.split(separator: "|").first ?? ""),
                        to: to)
                    Self.log("stream \(streamKey) CLOCK RAN AHEAD by "
                             + "\(ranAhead.late)s - every sample was late "
                             + "and none could be presented. Put back on "
                             + "the media at \(pts). "
                             + "Correction \(ranAhead.nth).")
                }
                if count % 30 == 0 {
                    Self.log("stream \(streamKey) at \(count) - timebase "
                             + "\(now) vs sample pts \(pts), drift "
                             + "\(now - pts)")
                }
            }
        }
    }

    /// Does VideoToolbox decode these samples, independently of the layer?
    ///
    /// The display layer can be starved, misclocked or unattached, and all
    /// three look the same from outside: a black rectangle. A
    /// decompression session has none of those failure modes. It takes the
    /// same format description and the same samples and either produces
    /// pixels or says why not.
    ///
    /// Eight frames, marker gated on the same file as the on-screen layer,
    /// because this is a measurement and not a decode path.
    private func runDecodeProbe(streamKey: String,
                                sampleBuffer: CMSampleBuffer) {
        guard Self.showLayerMarkerPresent() else { return }
        // Every sample in, every fortieth reported.
        //
        // Feeding every sample is what makes the later reports mean
        // anything: a session handed only every fortieth frame has no
        // reference frames and fails on all of them. Fix 26 reported the
        // first eight and they were all mean luma 16 - true, and
        // unrepresentative, because those eight are the black fade-in.
        // The same run had a p50 of 25821 bytes and a max of 372645 at
        // 720p, which is a real picture nobody had looked at yet.
        guard let slot = withState({ streamParsers[streamKey] }),
              slot.probeIn < 500,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return }

        // A decompression session created here has no relationship with
        // the content key session, so protected samples can only
        // malfunction in it. HBO Max produced 360 of exactly that, every
        // one -12911, which buried the one line worth reading. Say it
        // once and stop.
        let mediaSubtype = Self.pixelFormatName(
            CMFormatDescriptionGetMediaSubType(format))
        if Self.protectedSubtypes.contains(mediaSubtype) {
            let first = withState { () -> Bool in
                guard !slot.probeSkippedLogged else { return false }
                slot.probeSkippedLogged = true
                return true
            }
            if first {
                Self.log("stream \(streamKey) decode probe SKIPPED - these "
                         + "samples are \(mediaSubtype), which decrypts "
                         + "inside the decoder. A decompression session "
                         + "created here holds no key and can only report "
                         + "-12911, so it is not asked.")
            }
            return
        }

        if slot.probeSession == nil {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var sets = 0
            var nalLength: Int32 = 0
            let parameterStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &sets,
                nalUnitHeaderLengthOut: &nalLength)
            Self.log("stream \(streamKey) decode probe format - "
                     + "\(dimensions.width)x\(dimensions.height), "
                     + "parameter sets \(sets) (status \(parameterStatus)), "
                     + "NAL length prefix \(nalLength)")
            var session: VTDecompressionSession?
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ]
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session)
            guard status == noErr, let session else {
                Self.log("stream \(streamKey) decode probe could NOT create a "
                         + "decompression session - status \(status). The "
                         + "format description itself is unusable.")
                withState { slot.probeIn = 99 }
                return
            }
            withState { slot.probeSession = session }
        }
        guard let session = withState({ slot.probeSession }) else { return }
        let index = withState { () -> Int in
            slot.probeIn += 1
            return slot.probeIn
        }
        let submitStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [],
            infoFlagsOut: nil
        ) { decodeStatus, _, image, framePTS, _ in
            guard decodeStatus == noErr, let image else {
                // Failures are always reported. A decode that starts
                // working and then stops is the interesting shape, and
                // sampling would hide it.
                FairPlayStreamParser.log(
                    "stream \(streamKey) decode probe frame \(index) FAILED - "
                    + "status \(decodeStatus)")
                return
            }
            FairPlayStreamParser.shared.withStateNoteProbeFrame(
                streamKey: streamKey)
            // The other sink, before the log line: a CVPixelBuffer needs
            // nothing from AVFoundation to reach the screen.
            FairPlayStreamParser.shared.presentProofFrame(
                streamKey: streamKey, image: image, index: index)
            guard index % 40 == 1 || index <= 2 else { return }
            let width = CVPixelBufferGetWidth(image)
            let height = CVPixelBufferGetHeight(image)
            let pixelFormat = CVPixelBufferGetPixelFormatType(image)
            let luma = FairPlayStreamParser.lumaStats(image)
            FairPlayStreamParser.log(
                "stream \(streamKey) decode probe frame \(index) - "
                + "\(width)x\(height) format "
                + "\(FairPlayStreamParser.pixelFormatName(pixelFormat)) "
                + "luma min \(luma.min) mean \(luma.mean) max \(luma.max) "
                + "at pts \(framePTS.seconds) - all three equal is a flat "
                + "frame, a spread is real picture content")
        }
        if submitStatus != noErr {
            Self.log("stream \(streamKey) decode probe submit \(index) failed "
                     + "- status \(submitStatus)")
        }
    }

    /// A new timeline started. Throw away the old one and re-anchor.
    ///
    /// The held queue goes too, and that is the point: those samples
    /// belong to a timeline the stream has abandoned, and feeding them
    /// after the flush would put the layer straight back into the state
    /// this exists to leave.
    private func resynchronise(streamKey: String, to pts: Double,
                               jump: Double) {
        let work = withState { () -> (layer: AVSampleBufferDisplayLayer,
                                      queue: DispatchQueue, abandoned: Int,
                                      count: Int, at: Int)? in
            guard let slot = streamParsers[streamKey],
                  let layer = slot.displayLayer,
                  let queue = slot.drainQueue else { return nil }
            let abandoned = slot.pending.count
            slot.pending.removeAll()
            slot.needsSyncSample = true
            slot.flushes += 1
            return (layer, queue, abandoned, slot.flushes, slot.videoSeen)
        }
        guard let work else { return }
        // The sample index is in the line because that is how the last
        // one was found - by hand, counting through 429 samples to reach
        // 193. It should not take that twice.
        Self.log("stream \(streamKey) DISCONTINUITY \(jump)s at video "
                 + "sample \(work.at) - flushing (\(work.abandoned) held "
                 + "samples abandoned), re-anchoring the timebase to "
                 + "\(pts). Flush \(work.count).")
        // On the drain queue, because that is where enqueue happens.
        // flush() racing an enqueue is the one collision these two calls
        // can have, and a serial queue is the cheapest way to not have it.
        work.queue.async {
            work.layer.flush()
            if let timebase = work.layer.controlTimebase {
                CMTimebaseSetTime(timebase,
                                  time: CMTime(seconds: pts,
                                               preferredTimescale: 90_000))
            }
        }
    }

    // ==================================================================
    // AUDIO
    //
    // The picture arrives through a display layer with its own control
    // timebase. Sound cannot: AVSampleBufferAudioRenderer has no
    // timebase property, and is clocked by an
    // AVSampleBufferRenderSynchronizer instead. Everything else - the
    // bounded queue, requestMediaDataWhenReady, the content key
    // recipient registration, the discontinuity handling - is the same
    // shape as the video half, because the sample flow is the same.
    // ==================================================================

    /// Take one audio sample, and build the sink on the first one.
    fileprivate func enqueueForPlayback(streamKey: String,
                                        sampleBuffer: CMSampleBuffer) {
        guard let slot = withState({ streamParsers[streamKey] }) else {
            return
        }

        if withState({ slot.audioRenderer == nil }) {
            let renderer = AVSampleBufferAudioRenderer()
            let synchronizer = AVSampleBufferRenderSynchronizer()
            synchronizer.addRenderer(renderer)
            withState {
                slot.audioRenderer = renderer
                slot.audioSynchronizer = synchronizer
                slot.audioQueue = DispatchQueue(
                    label: "org.reynard.fps.audio")
            }
            // Before anything is enqueued: a renderer attached to a
            // session that cannot play is silent and reports nothing.
            prepareAudioSession()
            joinKeySession(audio: renderer, streamKey: streamKey)
            Self.observeAudioFlushes(renderer, label: streamKey)
            startAudioClock(
                streamKey: streamKey,
                fallback: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            Self.log("stream \(streamKey) built an audio renderer - "
                     + "status \(renderer.status.rawValue) "
                     + "volume \(renderer.volume) "
                     + "muted \(renderer.isMuted)")
        }

        // Fix 27's discontinuity test, on this stream's own intake.
        //
        // Same thresholds, and for the same reason: half a second is
        // clear of any legitimate reordering and well under a real
        // timeline change. Unlike video there is no sync-sample gate
        // afterwards - every AAC frame decodes on its own, so a gap in
        // the audio queue is a gap in the sound rather than a picture
        // full of garbage, and waiting for a keyframe that does not
        // exist would stop the sound permanently.
        let intakePTS =
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let audioArrivedAt = Self.hostNow()
        let jump = withState { () -> Double? in
            slot.audioSeen += 1
            slot.lastSampleAt = audioArrivedAt
            guard slot.lastAudioIntakePTS.isFinite, intakePTS.isFinite else {
                slot.lastAudioIntakePTS = intakePTS
                return nil
            }
            let delta = intakePTS - slot.lastAudioIntakePTS
            guard delta < -0.5 || delta > 2.0 else {
                slot.lastAudioIntakePTS = max(slot.lastAudioIntakePTS,
                                              intakePTS)
                return nil
            }
            slot.lastAudioIntakePTS = intakePTS
            return delta
        }
        if let jump {
            resynchroniseAudio(streamKey: streamKey, to: intakePTS,
                               jump: jump)
        }

        let queued = withState { () -> Int in
            guard slot.audioPending.count < 900 else {
                slot.audioOverflowed += 1
                return -1
            }
            slot.audioPending.append(sampleBuffer)
            return slot.audioPending.count
        }
        if queued < 0 {
            let dropped = withState { slot.audioOverflowed }
            if dropped == 1 || dropped % 100 == 0 {
                Self.log("stream \(streamKey) audio pending queue FULL - "
                         + "\(dropped) samples dropped. The renderer is "
                         + "not draining.")
            }
            return
        }
        armAudioDrainIfNeeded(streamKey: streamKey)
    }

    /// Give the synchronizer a rate, anchored to the video if there is
    /// one.
    ///
    /// The video timebase is the master. If it is already running, the
    /// audio clock starts at whatever media time it currently reads, so
    /// the two agree from the first sample. If it is not - audio can
    /// easily arrive first - the first audio PTS is used and
    /// markLayerAttached re-anchors as soon as the picture starts.
    private func startAudioClock(streamKey: String, fallback: CMTime) {
        let sessionId = String(streamKey.split(separator: "|").first ?? "")
        var master = videoClock(sessionId: sessionId)
        // A video anchor a long way from the first audio sample is the
        // wrong stream, not drift. The two clocks describe one timeline
        // and start within a fraction of a second of each other; the
        // capture that prompted this had a gap of twenty-five, taken
        // from a previous playback's timebase.
        //
        // Checked even though the liveness test above should already
        // have excluded that stream. This guard does not depend on the
        // heuristic being right, and the failure it prevents is total -
        // an audio renderer anchored into a future its media never
        // reaches produces no sound at all.
        if let candidate = master, fallback.seconds.isFinite,
           abs(candidate.seconds - fallback.seconds) > 5.0 {
            Self.log("stream \(streamKey) REFUSED a video anchor at "
                     + "\(candidate.seconds) - the first audio sample is "
                     + "at \(fallback.seconds), and a gap that size is the "
                     + "wrong stream rather than drift")
            master = nil
        }
        let anchor = master ?? fallback
        guard let synchronizer = withState({
            streamParsers[streamKey]?.audioSynchronizer
        }) else { return }
        synchronizer.setRate(1.0, time: anchor)
        withState { streamParsers[streamKey]?.audioStarted = true }
        let origin = master != nil ? "from the video timebase"
                                   : "from the first audio sample"
        Self.log("stream \(streamKey) audio clock started at "
                 + "\(anchor.seconds) (\(origin))")
        armAudioDrainIfNeeded(streamKey: streamKey)
    }

    /// Where the picture's clock is now, if it is running.
    ///
    /// nil rather than zero when it is not: a stopped timebase reads a
    /// real time and anchoring to it would be worse than not anchoring
    /// at all.
    /// The host clock, for liveness only.
    ///
    /// Not the media timeline - this answers "how long since anything
    /// happened", which is a question about wall time.
    fileprivate static func hostNow() -> Double {
        return CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// How long a stream may be silent and still count as playing.
    ///
    /// Generous on purpose. A stream is fed in bursts as segments are
    /// appended, so gaps of a second are ordinary; a stream from a
    /// previous playback has been silent for minutes. Nothing meaningful
    /// lives in between.
    fileprivate static let livenessWindow: Double = 2.0

    private func videoClock(sessionId: String) -> CMTime? {
        let cutoff = Self.hostNow() - Self.livenessWindow
        let layer = withState { () -> AVSampleBufferDisplayLayer? in
            // LIVE streams only, and the most recently fed of them.
            //
            // The first attached layer in the table used to win, and in a
            // session that had already played once that was a corpse
            // whose timebase had been running for twenty-five seconds -
            // which is what a new audio renderer was then anchored to.
            // Dictionary order is not ordered by anything, so "first"
            // was never a choice, only an accident.
            var newest: (layer: AVSampleBufferDisplayLayer, fedAt: Double)?
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") {
                guard slot.layerAttached, slot.lastSampleAt > cutoff,
                      let found = slot.displayLayer else { continue }
                if newest == nil || slot.lastSampleAt > newest!.fedAt {
                    newest = (found, slot.lastSampleAt)
                }
            }
            return newest?.layer
        }
        guard let layer, let timebase = layer.controlTimebase,
              CMTimebaseGetRate(timebase) != 0 else {
            return nil
        }
        return CMTimebaseGetTime(timebase)
    }

    /// Move every started audio clock in this session onto the picture's.
    fileprivate func realignAudioClock(sessionId: String, to time: CMTime) {
        let cutoff = Self.hostNow() - Self.livenessWindow
        let started = withState {
            () -> [(String, AVSampleBufferRenderSynchronizer)] in
            var out: [(String, AVSampleBufferRenderSynchronizer)] = []
            // Live renderers only. The previous playback's renderer was
            // still in this table and was being re-anchored by every
            // realign, which moved a clock nothing was listening to and
            // said so in the log as if it mattered.
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") {
                if slot.audioStarted, slot.lastSampleAt > cutoff,
                   let sync = slot.audioSynchronizer {
                    out.append((key, sync))
                }
            }
            return out
        }
        for (key, synchronizer) in started {
            synchronizer.setRate(1.0, time: time)
            Self.log("stream \(key) audio clock re-anchored to "
                     + "\(time.seconds) - following the video timebase")
        }
    }

    /// A new audio timeline started: drop what was held and re-anchor.
    ///
    /// The video timebase is NOT touched here, and that is deliberate.
    /// Fix 27's discontinuity was a video-only ABR re-append; dragging
    /// the picture back because the sound moved, or the sound back
    /// because the picture moved, produces a repeat the stream never
    /// asked for. Each side follows its own intake, and they meet again
    /// at the next markLayerAttached.
    private func resynchroniseAudio(streamKey: String, to pts: Double,
                                    jump: Double) {
        let work = withState { () -> (renderer: AVSampleBufferAudioRenderer,
                                      sync: AVSampleBufferRenderSynchronizer,
                                      queue: DispatchQueue, abandoned: Int,
                                      count: Int, at: Int)? in
            guard let slot = streamParsers[streamKey],
                  let renderer = slot.audioRenderer,
                  let sync = slot.audioSynchronizer,
                  let queue = slot.audioQueue else { return nil }
            let abandoned = slot.audioPending.count
            slot.audioPending.removeAll()
            slot.audioFlushes += 1
            return (renderer, sync, queue, abandoned, slot.audioFlushes,
                    slot.audioSeen)
        }
        guard let work else { return }
        Self.log("stream \(streamKey) AUDIO DISCONTINUITY \(jump)s at "
                 + "sample \(work.at) - flushing (\(work.abandoned) held "
                 + "samples abandoned), re-anchoring to \(pts). "
                 + "Flush \(work.count).")
        // On the drain queue, for the same collision flush() and
        // enqueue() can have on the video side.
        work.queue.async {
            work.renderer.flush()
            work.sync.setRate(1.0, time: CMTime(seconds: pts,
                                                preferredTimescale: 90_000))
        }
    }

    /// Ask the renderer to come and get them, if it is not already
    /// asking.
    private func armAudioDrainIfNeeded(streamKey: String) {
        let work = withState { () -> (renderer: AVSampleBufferAudioRenderer,
                                      queue: DispatchQueue)? in
            guard let slot = streamParsers[streamKey],
                  slot.audioStarted, !slot.audioDrainArmed,
                  !slot.audioPending.isEmpty,
                  let renderer = slot.audioRenderer,
                  let queue = slot.audioQueue else { return nil }
            slot.audioDrainArmed = true
            return (renderer, queue)
        }
        guard let work else { return }
        work.renderer.requestMediaDataWhenReady(on: work.queue) {
            [weak renderer = work.renderer] in
            guard let renderer else { return }
            FairPlayStreamParser.shared.drainAudioPending(
                streamKey: streamKey, renderer: renderer)
        }
    }

    /// Feed the renderer while it is hungry, and stop asking when it is
    /// not.
    fileprivate func drainAudioPending(
        streamKey: String, renderer: AVSampleBufferAudioRenderer) {
        while renderer.isReadyForMoreMediaData {
            let next = withState { () -> CMSampleBuffer? in
                guard let slot = streamParsers[streamKey],
                      !slot.audioPending.isEmpty else { return nil }
                return slot.audioPending.removeFirst()
            }
            guard let sample = next else {
                renderer.stopRequestingMediaData()
                withState { streamParsers[streamKey]?.audioDrainArmed = false }
                return
            }
            // Guarded exactly as the video enqueue is: these renderers
            // raise on a sample they dislike rather than returning an
            // error, and this route has already taken the process down
            // once through an AVFoundation SPI.
            if let failure = GeckoRuntimeBridge.catchException(from: {
                renderer.enqueue(sample)
            }) {
                Self.log("stream \(streamKey) audio renderer REFUSED the "
                         + "sample: \(failure)")
                return
            }
            let count = withState { () -> Int in
                guard let slot = streamParsers[streamKey] else { return 0 }
                slot.audioEnqueued += 1
                return slot.audioEnqueued
            }
            let report = "status=\(renderer.status.rawValue) "
                + "ready=\(renderer.isReadyForMoreMediaData) "
                + "error=\(renderer.error.map { String(describing: $0) } ?? "nil")"
            let changed = withState { () -> Bool in
                guard let slot = streamParsers[streamKey],
                      slot.audioLastReport != report else { return false }
                slot.audioLastReport = report
                return true
            }
            if changed || count == 1 {
                Self.log("stream \(streamKey) audio enqueued \(count) - "
                         + report)
            }
            // The same correction, for the same reason - see the video
            // half. An audio renderer discards late samples silently
            // too, and the synchronizer's clock is exposed to every
            // pause the page takes.
            //
            // Through setRate rather than CMTimebaseSetTime: a
            // synchronizer owns its timebase and that is the supported
            // way to move it.
            if let sync = withState({
                   streamParsers[streamKey]?.audioSynchronizer }) {
                let now = CMTimebaseGetTime(sync.timebase).seconds
                let pts =
                    CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let ranAhead = withState { () -> (late: Double, nth: Int)? in
                    guard let slot = streamParsers[streamKey] else { return nil }
                    if pts.isFinite {
                        slot.maxAudioPTS = slot.maxAudioPTS.isFinite
                            ? max(slot.maxAudioPTS, pts) : pts
                    }
                    let checkedAt = Self.hostNow()
                    guard now.isFinite, pts.isFinite,
                          slot.maxAudioPTS.isFinite,
                          now - slot.maxAudioPTS > 1.0,
                          checkedAt - slot.lastAudioCorrectionAt > 1.0
                    else { return nil }
                    slot.lastAudioCorrectionAt = checkedAt
                    let late = now - slot.maxAudioPTS
                    slot.audioClockCorrections += 1
                    slot.maxAudioPTS = pts
                    return (late, slot.audioClockCorrections)
                }
                if let ranAhead {
                    sync.setRate(1.0, time: CMTime(seconds: pts,
                                                   preferredTimescale: 90_000))
                    Self.log("stream \(streamKey) AUDIO CLOCK RAN AHEAD by "
                             + "\(ranAhead.late)s - put back on the media "
                             + "at \(pts). Correction \(ranAhead.nth).")
                    // READ IT BACK. The last capture corrected
                    // thirty-two times and the clock reported 35.3555 on
                    // every one of them - so either setRate did nothing
                    // or something moved it back, and arithmetic on a log
                    // is a poor way to find out which. Said once.
                    let after = CMTimebaseGetTime(sync.timebase).seconds
                    if abs(after - pts) > 1.0 {
                        let first = withState { () -> Bool in
                            guard let slot = streamParsers[streamKey],
                                  !slot.reportedUnmovedClock else { return false }
                            slot.reportedUnmovedClock = true
                            return true
                        }
                        if first {
                            Self.log("stream \(streamKey) the "
                                     + "synchronizer's clock did NOT move - "
                                     + "asked for \(pts), it reads "
                                     + "\(after). "
                                     + "AVSampleBufferRenderSynchronizer."
                                     + "setRate did not do what it was "
                                     + "asked, and the audio clock needs a "
                                     + "different mechanism.")
                        }
                    }
                }
                if count % 100 == 0 {
                    Self.log("stream \(streamKey) audio at \(count) - clock "
                             + "\(now) vs sample pts \(pts), drift "
                             + "\(now - pts)")
                }
            }
        }
    }

    /// Register the audio renderer with the stream's content key session.
    ///
    /// The same shape as the display layer's registration, and for the
    /// same reason: HBO's audio is qaac, protected AAC whose decrypt is
    /// deferred to the decoder. A renderer that is not a recipient is
    /// handed ciphertext with no key.
    ///
    /// Conformance tested at runtime rather than declared, matching
    /// joinKeySession(_:streamKey:) above. If a future OS stops vending
    /// it, this says so in the log instead of failing a build.
    private func joinKeySession(audio renderer: AVSampleBufferAudioRenderer,
                                streamKey: String) {
        let sessionId = String(streamKey.split(separator: "|").first ?? "")
        guard !sessionId.isEmpty, let keySession = liveSession(sessionId) else {
            Self.log("stream \(streamKey) has no live key session for the "
                     + "audio renderer - protected audio will not decode")
            return
        }
        guard let recipient = (renderer as AnyObject) as? AVContentKeyRecipient
        else {
            Self.log("stream \(streamKey) AVSampleBufferAudioRenderer is "
                     + "NOT an AVContentKeyRecipient here - protected audio "
                     + "cannot decode in it and the sink has to change")
            return
        }
        keySession.addContentKeyRecipient(recipient)
        Self.log("stream \(streamKey) audio renderer added as a content key "
                 + "recipient - recipients now "
                 + "\(keySession.contentKeyRecipients.count)")
    }

    /// The renderer flushed itself.
    ///
    /// AVFoundation does this on a route change or a format change, and
    /// it is silent otherwise - the sound simply stops and the counters
    /// keep climbing. Worth one line.
    private static func observeAudioFlushes(
        _ renderer: AVSampleBufferAudioRenderer, label: String) {
        let name = NSNotification.Name(
            rawValue:
                "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification")
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: renderer, queue: nil) { note in
            log("stream \(label) audio renderer FLUSHED AUTOMATICALLY: "
                + String(describing: note.userInfo))
        }
        shared.withState {
            shared.streamParsers[label]?.audioFlushObserver = observer
        }
    }

    /// Make sure this process can make a sound at all.
    ///
    /// AVPlayer configures an audio session implicitly, which is why the
    /// HLS route has never needed this. An AVSampleBufferAudioRenderer
    /// does not: on a default .soloAmbient session it runs, reports
    /// status 0 and no error, and is inaudible with the ring switch
    /// silent. That failure looks identical to success in every counter
    /// this file prints, so it is closed here rather than diagnosed
    /// later.
    ///
    /// A session that is ALREADY playback-capable is left completely
    /// alone. If the app has chosen .playback or .playAndRecord it did so
    /// for a reason, and stamping on a working configuration to fix a
    /// hypothetical one is how a media route breaks two things at once.
    private func prepareAudioSession() {
#if canImport(UIKit)
        let first = withState { () -> Bool in
            guard !audioSessionPrepared else { return false }
            audioSessionPrepared = true
            return true
        }
        guard first else { return }
        let session = AVAudioSession.sharedInstance()
        Self.log("audio session on entry - category "
                 + "\(session.category.rawValue) mode "
                 + "\(session.mode.rawValue)")
        guard session.category != .playback,
              session.category != .playAndRecord else {
            Self.log("audio session is already playback-capable - left alone")
            return
        }
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            Self.log("audio session set to playback/moviePlayback and "
                     + "activated")
        } catch {
            Self.log("audio session could NOT be configured: \(error) - the "
                     + "renderer will run and make no sound, which every "
                     + "other line here will report as success")
        }
#endif
    }

    // ==================================================================
    // THE HANDOVER
    // ==================================================================

    /// The compositor built a layer at the element's position, and is
    /// offering it.
    ///
    /// Called from ReynardMSEAttachLayer in dom/media/AVPlayerDecoder.mm,
    /// on the main thread, once NativeLayerCA has seen a DRM surface
    /// carrying this route's tag. Until now that layer was an
    /// AVPlayerLayer and went to AVPlayerHost, which correctly reported
    /// that no player owns it - because on this route none does.
    ///
    /// A class entry point, because the compositor has no way to name a
    /// session or a stream: it knows one bit about the frame and nothing
    /// about who produced it.
    @objc public static func adoptCompositorLayer(_ layer: CALayer) {
        guard let sink = layer as? AVSampleBufferDisplayLayer else {
            log("the compositor offered a \(type(of: layer)) - not an "
                + "AVSampleBufferDisplayLayer, so it is not ours to take")
            return
        }
        shared.adopt(sink)
    }

    /// Move the feed onto the offered layer.
    ///
    /// This is a migration, not a construction, and it happens more than
    /// once: the last capture built three compositor layers because an
    /// ABR resize from 768x322 to 1024x428 rebuilds them. Everything here
    /// has to be safe to do again.
    private func adopt(_ sink: AVSampleBufferDisplayLayer) {
        // Which stream? The one with a picture. There is normally exactly
        // one - a page plays one video at a time - and where there are
        // more, the busiest is the best guess available, since the
        // compositor cannot say which element its layer belongs to.
        // Busiest LIVE stream, falling back to busiest overall.
        //
        // "Busiest" on its own favours a corpse: a stream that played for
        // two minutes before the page reloaded has a far higher sample
        // count than the one that just started, and it is still in the
        // table because a reload inside one content process does not
        // destroy the session.
        //
        // The fallback is kept deliberately. A layer offered during a
        // momentary gap in the feed would otherwise land nowhere, and
        // landing on the busiest stream is what this did before.
        // MOST RECENTLY FED WINS, and the sample count is only a
        // tie-break.
        //
        // This used to take the busiest stream that had a display layer,
        // over the whole table, with no session filter - and a stream
        // that has played a film has a sample count in the thousands
        // while one that started a second ago has fifty. So on the second
        // HBO visit in the last capture, four compositor layers built for
        // HBO's element were handed to child-17|sb-4746391072 - the Apple
        // TV session, silent for nine and a half thousand log lines - and
        // fed The Martian's frames from eleven seconds in, while HBO's
        // own stream sat beside it with a layer nobody adopted.
        //
        // "Which stream is playing right now" is the question the
        // compositor's layer is actually asking, and the last sample's
        // arrival time answers it. Live streams are preferred; the
        // fallback is the most recently fed overall rather than the
        // busiest, because the busiest is precisely what chose a corpse.
        let cutoff = Self.hostNow() - Self.livenessWindow
        let chosen = withState { () -> (key: String, fedAt: Double)? in
            var best: (key: String, fedAt: Double, seen: Int)?
            var any: (key: String, fedAt: Double, seen: Int)?
            for (key, slot) in streamParsers where slot.displayLayer != nil {
                let candidate = (key: key, fedAt: slot.lastSampleAt,
                                 seen: slot.videoSeen)
                if any == nil || candidate.fedAt > any!.fedAt
                    || (candidate.fedAt == any!.fedAt
                        && candidate.seen > any!.seen) {
                    any = candidate
                }
                guard slot.lastSampleAt > cutoff else { continue }
                if best == nil || candidate.fedAt > best!.fedAt
                    || (candidate.fedAt == best!.fedAt
                        && candidate.seen > best!.seen) {
                    best = candidate
                }
            }
            guard let picked = best ?? any else { return nil }
            return (picked.key, picked.fedAt)
        }
        guard let chosen else {
            Self.log("the compositor offered a layer before any stream had "
                     + "a picture - ignored. A resize offers another one.")
            return
        }
        let streamKey = chosen.key
        // The evidence for the choice, because the choice is a guess -
        // the compositor hands over a bare layer and knows only that the
        // frame was DRM. A staleness above a second or two on a page that
        // is playing means the guess is wrong.
        Self.log("the compositor's layer goes to \(streamKey), last fed "
                 + "\(Self.hostNow() - chosen.fedAt)s ago")
        if withState({ streamParsers[streamKey]?.displayLayer === sink }) {
            Self.log("stream \(streamKey) is already using this layer")
            return
        }

        // Seeded from the clock that is already running, so the handover
        // does not move the timeline. Fix 41's audio renderer is anchored
        // to that same clock and would have to be re-anchored otherwise.
        let previous = withState { streamParsers[streamKey]?.displayLayer }
        var anchor = CMTime(seconds: 0, preferredTimescale: 90_000)
        if let old = previous?.controlTimebase,
           CMTimebaseGetRate(old) != 0 {
            anchor = CMTimebaseGetTime(old)
        } else {
            let last = withState {
                streamParsers[streamKey]?.lastIntakePTS ?? 0 }
            anchor = CMTime(seconds: last.isFinite ? last : 0,
                            preferredTimescale: 90_000)
        }
        // The old clock can already be ahead of the media it was meant
        // to be showing: if the page pauses, ours keeps running. At the
        // fourth adoption in the last capture it read 3783.117 while the
        // samples about to be fed were at 3772.560 - ten and a half
        // seconds late, so every one of them was decoded and discarded.
        // Copying that reading into the new layer carries the fault
        // across, so the anchor is clamped to the oldest sample this
        // layer is actually going to be given.
        let oldestHeld = withState { () -> Double? in
            guard let slot = streamParsers[streamKey] else { return nil }
            return [slot.currentGOP.first, slot.pending.first]
                .compactMap { $0 }
                .map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
                .filter { $0.isFinite }
                .min()
        }
        if let oldestHeld, anchor.seconds > oldestHeld {
            Self.log("stream \(streamKey) the old clock read "
                     + "\(anchor.seconds) with the media it is handing "
                     + "over at \(oldestHeld) - anchoring to the media")
            anchor = CMTime(seconds: oldestHeld, preferredTimescale: 90_000)
        }

        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
               allocator: kCFAllocatorDefault,
               sourceClock: CMClockGetHostTimeClock(),
               timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: anchor)
            // At rate 1 immediately, unlike fix 26's construction case.
            // There the layer had nowhere to render for another sixty log
            // lines; this one is already placed, on screen and sized by
            // the compositor before it is ever offered.
            CMTimebaseSetRate(timebase, rate: 1.0)
            sink.controlTimebase = timebase
        } else {
            Self.log("stream \(streamKey) could not build a timebase for "
                     + "the compositor's layer - it will present as fast as "
                     + "it decodes")
        }
        sink.videoGravity = .resizeAspect

        let handover = withState {
            () -> (old: AVSampleBufferDisplayLayer?, observer: NSObjectProtocol?,
                   queue: DispatchQueue?, carried: Int, held: Int,
                   waiting: Bool)? in
            guard let slot = streamParsers[streamKey] else { return nil }
            let old = slot.displayLayer
            let observer = slot.failObserver
            slot.displayLayer = sink
            slot.failObserver = nil
            slot.drainArmed = false
            slot.layerAttached = true
            // Only a layer this parser built may be removed from its
            // superlayer. From the second adoption onwards the one being
            // replaced is a layer NativeLayerCA built and owns, sitting
            // in the compositor's own tree, and retiring one would tear
            // it out of it.
            slot.retiringOverlay = slot.ownsDisplayLayer ? old : nil
            slot.ownsDisplayLayer = false

            // A fresh layer has no reference frame - true, and the reason
            // the queue used to be deleted here. It does not follow that
            // the queue has to go: these are compressed samples that
            // have not been fed to anything yet, and the frames the new
            // layer needs to decode the picture currently on screen were
            // handed to the OLD layer moments ago and are still held in
            // currentGOP.
            //
            // So the samples since the last keyframe are put back in
            // front of whatever was still waiting. Their presentation
            // times have passed, which is fine and is what happens after
            // any seek: a display layer decodes them for reference and
            // skips presenting them.
            //
            // currentGOP and pending overlap - pending is the tail of the
            // GOP that has not been drained yet - so only the part
            // already fed to the old layer is prepended.
            let alreadyFed = max(0, slot.currentGOP.count
                                    - slot.pending.count)
            let carried = Array(slot.currentGOP.prefix(alreadyFed))
            let held = slot.pending.count
            if !carried.isEmpty {
                slot.pending = carried + slot.pending
                slot.needsSyncSample = false
            } else if let at = slot.pending.firstIndex(
                          where: { Self.isSyncSample($0) }) {
                // Nothing to carry, but the queue already contains a
                // keyframe: start there rather than waiting for the next
                // one to arrive from the source.
                slot.pending.removeFirst(at)
                slot.needsSyncSample = false
            } else {
                // The one case where the old behaviour was right.
                slot.pending.removeAll()
                slot.needsSyncSample = true
            }
            return (old, observer, slot.drainQueue, carried.count, held,
                    slot.needsSyncSample)
        }
        guard let handover else { return }

        // Before it is fed, in that order: qavc handed to a sink that is
        // not a content key recipient is 360 x "FAILED TO DECODE".
        joinKeySession(sink, streamKey: streamKey)
        if let observer = handover.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        Self.observeDecodeFailures(sink, label: streamKey)

        // The old layer's requestMediaDataWhenReady block outlives the
        // handover and would keep pulling from a queue that is no longer
        // its own. On the drain queue, because that is where its enqueues
        // happen.
        if let queue = handover.queue, let old = handover.old {
            queue.async { old.stopRequestingMediaData() }
        }

        // Deregistered here rather than at retirement, which only ever
        // runs for the overlay - so superseded compositor layers stayed
        // registered and the recipient count climbed with every
        // adoption.
        if let old = handover.old,
           let keySession = liveSession(
               String(streamKey.split(separator: "|").first ?? "")),
           let recipient = (old as AnyObject) as? AVContentKeyRecipient {
            keySession.removeContentKeyRecipient(recipient)
        }

        let resumption = handover.waiting
            ? "waiting for a sync sample"
            : "resuming from the current GOP"
        Self.log("stream \(streamKey) adopted the compositor's layer at "
                 + "\(anchor.seconds) - carrying \(handover.carried) "
                 + "samples in front of \(handover.held) held, "
                 + resumption + ". The overlay stays until this layer "
                 + "takes one.")
        armDrainIfNeeded(streamKey: streamKey)
    }

    /// Can the decoder start here?
    ///
    /// No attachments at all means nothing declared this sample to depend
    /// on another, which is a sync sample. Absence of the NotSync key
    /// means the same thing.
    fileprivate static func isSyncSample(_ sampleBuffer: CMSampleBuffer)
        -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false)
                  as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    /// Put a decoded frame on screen without a display layer.
    ///
    /// The pink rectangle is composited - its border is visible - and it
    /// consumes samples and reports no error and shows nothing. Rather
    /// than keep guessing at why, this takes the pixel buffers the probe
    /// already produces and sets them as a CALayer's contents. That path
    /// has no renderer, no timebase, no queue and no dequeue policy, so it
    /// removes every mechanism the display layer could be failing in.
    ///
    /// Both rectangles are on screen together, same stream, two sinks. If
    /// cyan shows the movie and pink stays black, the samples and the
    /// decode and the compositing are all right and the display layer is
    /// simply the wrong sink here.
    ///
    /// Every sixth frame. A slideshow answers the question; smooth motion
    /// would cost work that answers nothing.
    fileprivate func presentProofFrame(streamKey: String,
                                       image: CVImageBuffer, index: Int) {
        // Guarded like showLayerIfRequested, and for the same reason: this
        // is the only UIKit in the file, and the call site above is not
        // conditional. The function always exists; its body does not.
#if canImport(UIKit)
        guard Self.showLayerMarkerPresent(), index % 6 == 1 else { return }
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(image, options: nil,
                                                      imageOut: &cgImage)
        guard status == noErr, let cgImage else {
            Self.log("stream \(streamKey) proof frame \(index) could not "
                     + "become a CGImage - status \(status)")
            return
        }
        let count = withState { () -> Int in
            guard let slot = streamParsers[streamKey] else { return 0 }
            slot.proofFrames += 1
            return slot.proofFrames
        }
        DispatchQueue.main.async {
            let existing = self.withState {
                self.streamParsers[streamKey]?.proofLayer
            }
            let layer: CALayer
            if let existing {
                layer = existing
            } else {
                guard let window = Self.reynardKeyWindow() else {
                    Self.log("stream \(streamKey) proof frame - no window")
                    return
                }
                let new = CALayer()
                let width = min(window.bounds.width - 32, 360)
                // Directly below the pink one, which fix 22 puts at y=120
                // with the same width and a 16:9 height. Two rectangles,
                // same stream, so the comparison is one glance.
                new.frame = CGRect(x: 16, y: 120 + width * 9.0 / 16.0 + 8,
                                   width: width, height: width * 9.0 / 16.0)
                new.backgroundColor = UIColor.black.cgColor
                new.borderColor = UIColor.systemTeal.cgColor
                new.borderWidth = 2
                new.contentsGravity = .resizeAspect
                window.layer.addSublayer(new)
                self.withState {
                    self.streamParsers[streamKey]?.proofLayer = new
                }
                Self.log("stream \(streamKey) proof layer placed at "
                         + "\(new.frame) - cyan border. Pictures here with "
                         + "the pink one still black means the display "
                         + "layer is the wrong sink, not the samples.")
                layer = new
            }
            layer.contents = cgImage
            if count <= 3 || count % 20 == 0 {
                Self.log("stream \(streamKey) proof frame \(count) painted "
                         + "(\(cgImage.width)x\(cgImage.height))")
            }
        }
#endif
    }

#if canImport(UIKit)
    /// The app's key window, without a compile-time UIApplication.
    ///
    /// This target is built extension-API-only, so UIApplication.shared is
    /// unavailable and the instance is fetched by selector - the same way
    /// showLayerIfRequested does it.
    private static func reynardKeyWindow() -> UIWindow? {
        let selector = NSSelectorFromString("sharedApplication")
        guard let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
              appClass.responds(to: selector),
              let application = appClass.perform(selector)?
                  .takeUnretainedValue() as? UIApplication else {
            return nil
        }
        let scenes = application.connectedScenes
        return scenes.compactMap { $0 as? UIWindowScene }
                     .flatMap { $0.windows }
                     .first { $0.isKeyWindow }
            ?? scenes.compactMap { $0 as? UIWindowScene }
                     .flatMap { $0.windows }.first
    }
#endif

    fileprivate func withStateNoteProbeFrame(streamKey: String) {
        withState { streamParsers[streamKey]?.probeOut += 1 }
    }

    /// Luma range over a coarse grid, so "decoded", "decoded to black"
    /// and "decoded to a real picture" are three different answers.
    ///
    /// The mean alone was not enough: mean 16 is the video-range black
    /// floor, and it reads the same for a legitimate fade-in as it would
    /// for a decoder producing nothing. min and max separate them - a
    /// flat frame has all three equal.
    fileprivate static func lumaStats(_ image: CVImageBuffer)
        -> (min: Int, mean: Int, max: Int) {
        guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess
        else { return (-1, -1, -1) }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let planar = CVPixelBufferGetPlaneCount(image) > 0
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0)
                          : CVPixelBufferGetBaseAddress(image)
        guard let base else { return (-1, -1, -1) }
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0)
                              : CVPixelBufferGetBytesPerRow(image)
        let height = planar ? CVPixelBufferGetHeightOfPlane(image, 0)
                            : CVPixelBufferGetHeight(image)
        let width = planar ? CVPixelBufferGetWidthOfPlane(image, 0)
                           : CVPixelBufferGetWidth(image)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var samples = 0
        var lowest = 255
        var highest = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let value = Int(bytes[y * rowBytes + x])
                total += value
                lowest = min(lowest, value)
                highest = max(highest, value)
                samples += 1
                x += 16
            }
            y += 8
        }
        guard samples > 0 else { return (-1, -1, -1) }
        return (lowest, total / samples, highest)
    }

    fileprivate static func pixelFormatName(_ value: OSType) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.isEmpty ? String(value) : text
    }

    /// Listen for the decoder's own opinion.
    ///
    /// AVSampleBufferDisplayLayer reports a rejected sample through a
    /// notification, not through its error property, and until now
    /// nothing was listening - so "status=1 error=nil" was consistent
    /// with a decoder refusing every frame. Raw strings rather than the
    /// Swift symbols, so the availability of a constant cannot break a
    /// build over a diagnostic.
    private static func observeDecodeFailures(
        _ layer: AVSampleBufferDisplayLayer, label: String) {
        let name = NSNotification.Name(
            rawValue: "AVSampleBufferDisplayLayerFailedToDecodeNotification")
        let observer = NotificationCenter.default.addObserver(
            forName: name, object: layer, queue: nil) { note in
            let error = note.userInfo?[
                "AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey"]
            log("stream \(label) FAILED TO DECODE: "
                + String(describing: error))
        }
        shared.withState {
            shared.streamParsers[label]?.failObserver = observer
        }
    }

    /// Is the measurement switched on?
    private static func showLayerMarkerPresent() -> Bool {
        let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true)
        let marker = (documents.first ?? "") + "/fps-show-layer.on"
        return FileManager.default.fileExists(atPath: marker)
    }

    /// Subtypes whose bytes are still ciphertext at this point.
    ///
    /// encv and enca are Common Encryption's protected boxes. qavc and
    /// qaac are the deferred-decrypt forms - the sample is protected and
    /// the DECODER is expected to hold the key. Neither can be decoded by
    /// anything that is not registered with the content key session.
    fileprivate static let protectedSubtypes: Set<String> =
        ["encv", "enca", "qavc", "qaac"]

    /// Register the display layer with the stream's content key session.
    ///
    /// HBO Max hands back qavc: protected samples that decrypt inside the
    /// decoder rather than in the parser. The parser is a recipient -
    /// createSession does addContentKeyRecipient and logs "recipients 1" -
    /// but the layer never was, so it was given ciphertext with no key
    /// and returned -11821 "Cannot Decode" 360 times, over a
    /// kVTVideoDecoderMalfunctionErr.
    ///
    /// Conformance is tested at runtime through AnyObject rather than
    /// declared, matching what createSession already does for the parser
    /// at "guard let recipient = parser as? AVContentKeyRecipient". An OS
    /// that will not take a display layer then says so in the log instead
    /// of failing a build, which a diagnostic on this route has already
    /// managed once.
    private func joinKeySession(_ layer: AVSampleBufferDisplayLayer,
                                streamKey: String) {
        // "<sessionId>|<stream>" - see append(_:stream:).
        let sessionId = String(streamKey.split(separator: "|").first ?? "")
        guard !sessionId.isEmpty, let keySession = liveSession(sessionId) else {
            Self.log("stream \(streamKey) has no live key session to join - "
                     + "protected samples will not decode in the layer")
            return
        }
        guard let recipient = (layer as AnyObject) as? AVContentKeyRecipient
        else {
            Self.log("stream \(streamKey) AVSampleBufferDisplayLayer is NOT "
                     + "an AVContentKeyRecipient here - protected samples "
                     + "cannot decode in it and the sink has to change")
            return
        }
        keySession.addContentKeyRecipient(recipient)
        Self.log("stream \(streamKey) display layer added as a content key "
                 + "recipient - recipients now "
                 + "\(keySession.contentKeyRecipients.count)")
    }

    /// Put the layer on screen, if a marker file asks for it.
    ///
    /// Acceptance is not pixels. Fix 21 proved an
    /// AVSampleBufferDisplayLayer takes these samples and reports
    /// rendering with no error - and then stopped asking for more at 55,
    /// which is what a layer with nothing to present to does. Whether
    /// they DECODE and PAINT has never been measured.
    ///
    /// The proper home is the compositor, and that waits on a trigger
    /// this route does not have: NativeLayerCA builds its layer from a
    /// surface Gecko publishes and marks it DRM from Image::SetIsDRM,
    /// both of which come from AVPlayerDecoder::PublishPlaceholderFrame -
    /// which an MSE element never reaches. Building that plumbing before
    /// knowing there are pixels to place would be the expensive order to
    /// do this in.
    ///
    /// So: the app's own window, a fixed rect, once. Marker-gated like
    /// the render probe, because a hardcoded video rectangle over the
    /// page is right for one measurement and wrong for everything else.
    ///
    /// The border is drawn regardless. An empty bordered rectangle means
    /// placed but not painting; no rectangle at all means placement
    /// failed. Those are different problems and the log should not have
    /// to guess between them.
    private static func showLayerIfRequested(_ layer: AVSampleBufferDisplayLayer,
                                             label: String) {
#if canImport(UIKit)
        let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true)
        let marker = (documents.first ?? "") + "/fps-show-layer.on"
        guard FileManager.default.fileExists(atPath: marker) else {
            return
        }
        // Main queue: this is UIKit, and the parser's callbacks arrive on
        // AVFoundation's own queues.
        DispatchQueue.main.async {
            // However this ends - placed, or no window at all - the
            // feeder has to be released. Samples held for a placement
            // that never happens produce no rectangle rather than an
            // empty one, and in a log those look the same.
            defer {
                FairPlayStreamParser.shared.markLayerAttached(
                    streamKey: label)
            }
            // UIApplication.shared is unavailable in this target - it is
            // built extension-API-only - so the instance is fetched
            // dynamically. No compile-time reference, same object.
            let selector = NSSelectorFromString("sharedApplication")
            guard let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
                  appClass.responds(to: selector),
                  let application = appClass.perform(selector)?
                      .takeUnretainedValue() as? UIApplication else {
                log("cannot show \(label) - no UIApplication")
                return
            }
            let scenes = application.connectedScenes
            let window = scenes.compactMap { $0 as? UIWindowScene }
                               .flatMap { $0.windows }
                               .first { $0.isKeyWindow }
                ?? scenes.compactMap { $0 as? UIWindowScene }
                         .flatMap { $0.windows }.first
            guard let window else {
                log("cannot show \(label) - no window")
                return
            }
            let width = min(window.bounds.width - 32, 360)
            layer.frame = CGRect(x: 16, y: 120, width: width,
                                 height: width * 9.0 / 16.0)
            layer.backgroundColor = UIColor.black.cgColor
            layer.borderColor = UIColor.systemPink.cgColor
            layer.borderWidth = 2
            window.layer.addSublayer(layer)
            log("layer for \(label) placed on screen at \(layer.frame) - "
                + "a pink border with nothing in it means placed but not "
                + "painting")
        }
#endif
    }

    /// Does this whole route work in a CONTENT process?
    ///
    /// Everything works today with the parser in the app process, and
    /// what is left is placement: the compositor learns where a video
    /// rectangle belongs from a surface Gecko publishes, and an MSE
    /// element publishes none.
    ///
    /// If the parser can run where the media element lives, that problem
    /// stops existing rather than getting solved. The samples are clear -
    /// their bytes have been read from the CPU - so they can go into
    /// Gecko's ordinary decode path, and placement, sizing, fullscreen,
    /// currentTime and audio all come free because none of it is special
    /// any more.
    ///
    /// The tree does not already answer this. FairPlayCDMProxy goes
    /// remote in a content process because "a proxy in a content process
    /// can never reach the asset" - which is about the AVURLAsset of the
    /// native HLS route. MSE has no asset; its content key recipient is
    /// this parser, an object rather than a URL. So the reason does not
    /// apply and the question is open.
    ///
    /// A class entry point rather than something on the host protocol:
    /// this framework is already linked by content processes - see the
    /// file header - so the class is present and can be reached by name,
    /// with no protocol or IPDL change to ask one question.
    @objc public static func runContentProcessProbe(_ initSegment: Data) {
        let sessionId = "contentProbe"
        log("=== content-process parser probe, \(initSegment.count) bytes ===")
        guard NSClassFromString("AVStreamDataParser") != nil else {
            log("AVStreamDataParser is ABSENT in this process - the route "
                + "cannot move here")
            return
        }
        guard shared.createSession(sessionId) else {
            log("createSession FAILED in this process - the parser loads but "
                + "the key session or the recipient registration is refused")
            return
        }
        // Getting this far is already the architecture answer. The three
        // things that decide whether this route can move to the content
        // process - the class loading, the key session constructing, and
        // addContentKeyRecipient accepting the parser - have all just
        // happened, inside createSession above.
        guard !initSegment.isEmpty else {
            log("=== probe BUILT in this process with no segment to feed. "
                + "The parser class, the key session and the recipient "
                + "registration all work here, which is the sandbox "
                + "question answered. A real key request additionally "
                + "needs an init segment, which arrives only if the page "
                + "appends ===")
            return
        }
        _ = shared.append(sessionId, initSegment: initSegment)
        log("=== probe fed. A 'session contentProbe key request on track N' "
            + "line means the parser and key session both work here, and "
            + "the Gecko-native path is open ===")
    }

    /// The page's FPS application certificate, for one session.
    ///
    /// Reaches here from setServerCertificate by way of the broker,
    /// keyed by child - the per-player fan-out cannot serve a path with
    /// no player.
    @objc public func setCertificate(_ sessionId: String, certificate: Data) {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("certificate for unknown session \(sessionId)")
            return
        }
        Self.log("session \(sessionId) certificate set, "
                 + "\(certificate.count) bytes")
        entry.keyDelegate.setCertificate(certificate)
    }

    // MARK: - SPC out, CKC in

    /// The SPC for this session's pending key request.
    ///
    /// The certificate is the page's, forwarded from setServerCertificate;
    /// the content identifier is the key id the page named. Both come
    /// from EME, and neither is inventable here - which is why this takes
    /// them rather than holding state.
    ///
    /// nil means no SPC, and the log says which of the three reasons.
    @objc public func spc(_ sessionId: String,
                          certificate: Data,
                          contentIdentifier: Data) -> Data? {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("SPC for unknown session \(sessionId)")
            return nil
        }
        guard let trackID = withState({ entry.trackIDs.first }) else {
            Self.log("SPC for session \(sessionId) before any key request - nothing to cover")
            return nil
        }
        return Self.requestSPC(parser: entry.parser, trackID: trackID,
                               certificate: certificate,
                               contentIdentifier: contentIdentifier,
                               label: "session \(sessionId)")
    }

    /// The raw SPC call, with the track id supplied rather than looked up.
    ///
    /// Split out for the deadlock probe: the ordinary path can only name
    /// a track a key request already reported, and the open question is
    /// whether the call needs one at all.
    ///
    /// Typed invocation, not perform(): the selector takes an int32 track
    /// id and an NSError**, and perform() can carry neither. Getting that
    /// wrong is what crashed the first probe - it typed a track id as an
    /// object and sent it isKindOfClass:, for EXC_BAD_ACCESS at 0x2.
    private static func requestSPC(parser: NSObject,
                                   trackID: Int32,
                                   certificate: Data,
                                   contentIdentifier: Data,
                                   label: String) -> Data? {
        let selector = NSSelectorFromString(
            "streamingContentKeyRequestDataForApp:contentIdentifier:trackID:options:error:")
        guard parser.responds(to: selector),
              let implementation = parser.method(for: selector) else {
            log("no streamingContentKeyRequestDataForApp: on the parser")
            return nil
        }
        typealias SPCFunction = @convention(c) (
            AnyObject, Selector, NSData, NSData, Int32, NSDictionary?,
            UnsafeMutablePointer<NSError?>?
        ) -> NSData?
        let call = unsafeBitCast(implementation, to: SPCFunction.self)

        var error: NSError?
        let spc = withUnsafeMutablePointer(to: &error) { errorPointer -> NSData? in
            call(parser, selector, certificate as NSData,
                 contentIdentifier as NSData, trackID, nil, errorPointer)
        }
        guard let spc else {
            log("SPC refused, \(label) track \(trackID): "
                + (error.map { String(describing: $0) } ?? "no error given"))
            return nil
        }
        log("SPC produced, \(label) track \(trackID): \(spc.length) bytes")
        return spc as Data
    }

    /// The CKC the page's licence server returned.
    ///
    /// Two routes, tried in the order they can actually occur. The
    /// session path is the one this file runs on now - the key request
    /// came from processContentKeyRequest, so its licence belongs to
    /// the request object. The parser path below is kept for a request a
    /// real init segment raised, which names a track and takes the
    /// licence through the parser instead.
    @discardableResult
    @objc public func provideResponse(_ sessionId: String,
                                      contentId: String,
                                      ckc: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("CKC for unknown session \(sessionId)")
            return false
        }
        if entry.keyDelegate.provide(response: ckc, contentId: contentId) {
            return true
        }
        guard let trackID = withState({ entry.trackIDs.first }) else {
            Self.log("CKC for session \(sessionId) with neither a pending "
                     + "request nor a track to apply it to")
            return false
        }
        let selector = NSSelectorFromString("processContentKeyResponseData:forTrackID:")
        guard entry.parser.responds(to: selector),
              let implementation = entry.parser.method(for: selector) else {
            Self.log("no processContentKeyResponseData:forTrackID: on the parser")
            return false
        }
        typealias ResponseFunction = @convention(c) (AnyObject, Selector, NSData, Int32) -> Void
        let call = unsafeBitCast(implementation, to: ResponseFunction.self)
        call(entry.parser, selector, ckc as NSData, trackID)
        Self.log("CKC applied to session \(sessionId) track \(trackID): \(ckc.count) bytes")
        return true
    }

    // MARK: - Rendering probe

    /// Can the parser's output reach a layer at all?
    ///
    /// Key origination is settled: a parser fed Apple's encrypted init
    /// segment raises a key request with no AVURLAsset anywhere. What is
    /// not settled is the other half - protected samples cannot be copied
    /// into Gecko (a FairPlay plane base address comes back as 0x200, and
    /// AVSampleBufferAttachContentKey on a self-decoded buffer answers
    /// "this app is not authorized to play this file"), so the only way to
    /// the screen is an AVSampleBufferDisplayLayer that AVFoundation fills
    /// itself. Whether that path exists is worth knowing BEFORE spending a
    /// wide rebuild on IPC that assumes it does.
    ///
    /// What this can answer without a licence server: whether the parser
    /// understands the segment and reports its tracks, whether it accepts
    /// being asked for media data, and whether the sink constructs in this
    /// process. What it cannot: whether a DECRYPTED sample renders, which
    /// needs a CKC and therefore a key server. Said plainly here so the
    /// result is not over-read.
    @objc public func runRenderProbe(initSegment: Data) {
        let sessionId = "renderProbe"
        Self.log("=== rendering probe ===")
        guard createSession(sessionId) else {
            return
        }
        // Deliberately NOT destroyed. The content key request arrives
        // asynchronously, and tearing the session down at the end of this
        // function is what swallowed it the first time. One leaked probe
        // session per launch is the right trade for an answer that can
        // actually arrive.

        guard let entry = withState({ entries[sessionId] }) else {
            return
        }

        // 1. Does the sink even exist in this process? A content
        // extension is refused a playback audio session; if display
        // layers were refused too the whole approach is dead, and this
        // is one line rather than an architecture.
        let layer = AVSampleBufferDisplayLayer()
        Self.log("display layer built: status=\(layer.status.rawValue) "
                 + "error=\(layer.error.map { String(describing: $0) } ?? "nil")")

        // 2. THE DEADLOCK QUESTION, asked before anything is appended.
        //
        // A capture of tv.apple.com and netflix.com with MSE enabled
        // carried 396 emeConfig negotiations and not one appendBuffer:
        // the page raises generateRequest from the manifest's PSSH, waits
        // for a 'message' event we never send, and never commits to the
        // source. So the init segment a tap would forward does not exist
        // yet - it arrives only after the licence exchange the page is
        // stuck in.
        //
        // Which leaves one question. The ordinary SPC path names a track
        // a key request already reported, and no key request can happen
        // without an append. If the call needs that track, MSE FairPlay
        // deadlocks here and Apple TV+ is unreachable. If it will make an
        // SPC from a content id and a guessed track, the cycle breaks and
        // the whole route opens.
        //
        // A dummy certificate is enough to tell them apart: what matters
        // is WHICH refusal comes back. The same error before and after an
        // append means the track was never the obstacle - a certificate
        // complaint in both cases is the answer we want. Different errors
        // mean the track is required and the deadlock is real.
        // A REAL certificate if one was dropped beside the segment.
        //
        // The first run of this probe refused identically before and
        // after an append, which ruled the track out as the obstacle but
        // proved nothing about the cause: both calls returned nil with no
        // NSError at all. 16 zero bytes is not a certificate, and a real
        // FPS application certificate is ~2598 bytes - the size the
        // broker logs on every Apple TV+ load.
        //
        // So the question needs a real one. Apple ships a test
        // certificate in the same FPS Server SDK as the segment; drop it
        // in Documents as fps-certificate.der. Falling back to the dummy
        // keeps the track comparison working when it is absent.
        let certificatePath = documentsPath("fps-certificate.der")
        let realCertificate = FileManager.default.contents(atPath: certificatePath)
        let certificate = realCertificate ?? Data(repeating: 0, count: 16)
        Self.log(realCertificate.map { "using real certificate, \($0.count) bytes" }
                 ?? "no fps-certificate.der - falling back to a dummy, so a "
                 + "refusal below says nothing about the cause")
        let contentIdentifier = Data("probe-content-id".utf8)
        // The key-session delegate needs it too - that is where the real
        // AVContentKeyRequest lands and where the SPC is actually made.
        entry.keyDelegate.certificate = certificate
        Self.log("--- SPC before any append (track guessed) ---")
        for trackID in Int32(1)...Int32(2) {
            _ = Self.requestSPC(parser: entry.parser, trackID: trackID,
                                certificate: certificate,
                                contentIdentifier: contentIdentifier,
                                label: "NO-APPEND")
        }

        // 3. Feed it. The asset callback below reports the tracks.
        append(sessionId, initSegment: initSegment)

        // 4. The same call again, now that a key request has named a real
        // track. Compare the two refusals - that comparison IS the
        // result.
        Self.log("--- SPC after append (real track) ---")
        for trackID in withState({ entry.trackIDs }) {
            _ = Self.requestSPC(parser: entry.parser, trackID: trackID,
                                certificate: certificate,
                                contentIdentifier: contentIdentifier,
                                label: "AFTER-APPEND")
        }

        // 5. The specifier itself - what the parser actually handed us,
        // and the receiver the SPC probably belongs to.
        //
        // Everything above asks the PARSER for an SPC and gets nil with
        // no NSError, under conditions that should have worked. That is
        // the signature of a wrong receiver or a wrong signature rather
        // than a refusal, so stop guessing and read the object: its class
        // and its methods say which selector makes an SPC and what it
        // takes.
        Self.log("--- the content key specifier ---")
        if let specifier = entry.delegate.lastSpecifier {
            Self.log("specifier is \(type(of: specifier)) - \(specifier)")
            var count: UInt32 = 0
            if let methods = class_copyMethodList(object_getClass(specifier), &count) {
                var names: [String] = []
                for i in 0..<Int(count) {
                    names.append(NSStringFromSelector(method_getName(methods[i])))
                }
                free(methods)
                for name in names.sorted(by: { $0.lowercased() < $1.lowercased() }) {
                    Self.log("    \(name)")
                }
            }
            // The standard AVContentKeyRequest spelling, tried directly.
            // Async with a completion handler rather than returning bytes,
            // which is itself why the synchronous parser call may never
            // have been the right one.
            let make = NSSelectorFromString(
                "makeStreamingContentKeyRequestDataForApp:contentIdentifier:options:completionHandler:")
            if specifier.responds(to: make) {
                Self.log("specifier RESPONDS to makeStreamingContentKeyRequestDataForApp: - "
                         + "this is the route")
            } else {
                Self.log("specifier does not respond to "
                         + "makeStreamingContentKeyRequestDataForApp: - see the dump above "
                         + "for what it does offer")
            }
        } else {
            Self.log("no specifier was retained - the callback did not fire")
        }

        // 6. Ask for media data on every track the parser raised a key
        // request for. Without a CKC nothing should decrypt - the point
        // is whether the CALL is accepted and what it says, not whether
        // pixels arrive.
        let shouldProvide = NSSelectorFromString("setShouldProvideMediaData:forTrackID:")
        let provide = NSSelectorFromString("providePendingMediaData")
        let tracks = withState { entry.trackIDs }
        guard !tracks.isEmpty else {
            Self.log("no track raised a key request - nothing to ask for")
            return
        }
        for trackID in tracks {
            guard entry.parser.responds(to: shouldProvide),
                  let implementation = entry.parser.method(for: shouldProvide) else {
                Self.log("no setShouldProvideMediaData:forTrackID: on the parser")
                break
            }
            typealias ProvideFunction = @convention(c) (AnyObject, Selector, Bool, Int32) -> Void
            let call = unsafeBitCast(implementation, to: ProvideFunction.self)
            // Guarded like the live path. The probe names tracks a key
            // request actually reported, so it has never thrown - but
            // this is the same SPI that aborted the app from the live
            // path, and a diagnostic tool taking the process down is the
            // worst possible failure for one.
            if let failure = GeckoRuntimeBridge.catchException(from: {
                call(entry.parser, shouldProvide, true, trackID)
            }) {
                Self.log("probe refused arming track \(trackID): " + failure)
                continue
            }
            Self.log("asked for media data on track \(trackID)")
        }
        if entry.parser.responds(to: provide) {
            if let failure = GeckoRuntimeBridge.catchException(from: {
                entry.parser.perform(provide)
            }) {
                Self.log("probe refused providePendingMediaData: " + failure)
                return
            }
            Self.log("providePendingMediaData sent - any samples are logged above as they land")
        } else {
            Self.log("no providePendingMediaData on the parser")
        }
    }

    fileprivate func noteKeyRequest(sessionId: String, trackID: Int32) {
        withState {
            guard let entry = entries[sessionId], !entry.trackIDs.contains(trackID) else {
                return
            }
            entry.trackIDs.append(trackID)
        }
    }
}

// MARK: - Delegate

/// Where the real AVContentKeyRequest arrives.
///
/// The piece that was missing. The parser's delegate reports an
/// AVContentKeySpecifier - a description of what needs a key, with no
/// ability to make an SPC. Feeding that to
/// processContentKeyRequest(withIdentifier:initializationData:options:)
/// makes the session raise a genuine AVContentKeyRequest, and THAT is the
/// object with makeStreamingContentKeyRequestData(forApp:...).
///
/// The certificate is set by whoever drives the session, because it comes
/// from the page's setServerCertificate and cannot be invented here.
final class KeySessionDelegate: NSObject, AVContentKeySessionDelegate {
    let sessionId: String

    /// Everything per-request, under one lock.
    ///
    /// One lock rather than several, because "is there a certificate"
    /// and "hold this request" have to be decided together: the request
    /// arrives on the session's dedicated queue while the certificate
    /// arrives from Gecko's main thread, and a certificate landing
    /// between those two decisions would leave a request parked with
    /// nothing left to wake it.
    private let lock = NSLock()
    private var storedCertificate: Data?
    private var heldRequests: [AVContentKeyRequest] = []
    /// The origination each live request answers.
    ///
    /// Keyed by the request OBJECT. One AVContentKeySession serves a
    /// whole content process, so "the current content id" is not a thing
    /// that exists once two exchanges are in flight - every read has to
    /// name which request it means.
    private var originations: [ObjectIdentifier: FairPlayOrigination] = [:]
    /// Requests whose SPC has gone out, by EME content id, waiting for a
    /// licence addressed to that id.
    private var outstanding: [String: AVContentKeyRequest] = [:]
    /// Whether any key request has ever arrived for this session.
    private var requestArrived = false
    /// How many have. The watchdog needs the COUNT, not the flag: a
    /// second playback in the same content process reuses this delegate,
    /// so the flag was already true and the silence that mattered went
    /// unreported.
    private var requestCount = 0

    var sawRequest: Bool { withLock { requestArrived } }
    var requestsSeen: Int { withLock { requestCount } }

    init(sessionId: String) {
        self.sessionId = sessionId
        super.init()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The FPS application certificate. Assigning one releases every
    /// request that arrived before it.
    var certificate: Data? {
        get { withLock { storedCertificate } }
        set { setCertificate(newValue) }
    }

    /// Held rather than dropped.
    ///
    /// The certificate cannot arrive first: the page calls
    /// setServerCertificate while handling an 'encrypted' event, and
    /// that event is produced by the very key request that needs it - so
    /// returning early on a missing certificate discarded the request in
    /// the ORDINARY case, and nothing ever re-raised it.
    func setCertificate(_ data: Data?) {
        let waiting = withLock { () -> [AVContentKeyRequest] in
            storedCertificate = data
            guard data != nil else { return [] }
            let held = heldRequests
            heldRequests = []
            return held
        }
        guard !waiting.isEmpty else { return }
        FairPlayStreamParser.log(
            "session \(sessionId) certificate arrived - replaying "
            + "\(waiting.count) held key request(s)")
        for request in waiting {
            makeSPC(for: request)
        }
    }

    func contentKeySession(_ session: AVContentKeySession,
                           didProvide keyRequest: AVContentKeyRequest) {
        // Pin this request to the origination it answers, BEFORE
        // anything reads an identity off it.
        //
        // FIFO, and that is an assumption worth naming: AVFoundation is
        // not documented to raise requests in the order they were asked
        // for. It is forced by raising requests with a nil identifier,
        // which is the shape MSE needs and which removes the per-request
        // handle AVFoundation would otherwise hand back. Where the
        // request DOES carry an identifier the queue order is checked
        // against it below, so a mismatch shows up in the log instead of
        // silently addressing the wrong key.
        let claimed = FairPlayStreamParser.shared.claimOrigination(for: sessionId)
        FairPlayStreamParser.log(
            "session \(sessionId) REAL AVContentKeyRequest arrived - "
            + "identifier \(String(describing: keyRequest.identifier)), "
            + "claimed "
            + (claimed.map { "id \($0.contentId)" } ?? "NOTHING - no "
               + "origination was waiting, so this request was not asked "
               + "for by this process")
            + ", \(FairPlayStreamParser.shared.pendingOriginationCount(for: sessionId))"
            + " still queued")
        // No origination is not an error - it is the render probe.
        //
        // The probe's requests come from the parser's specifier callback
        // and it never calls requestKey, so it queues nothing and this
        // guard turned it away. That disabled the one path proven to
        // work end to end: the last capture has no "SPC PRODUCED" line
        // at all, where the run before it had 8816 bytes. Every
        // comparison this route is measured against depends on that path
        // still running.
        //
        // The request carries its own identifier, which is all makeSPC
        // needs. An empty origination simply contributes no fallback
        // bytes, and report(spc:) still declines to route a session that
        // has no content process behind it.
        let origination = claimed
            ?? FairPlayOrigination(contentId: "", initData: Data())
        if claimed == nil {
            FairPlayStreamParser.log(
                "session \(sessionId) has no origination to claim - "
                + "proceeding on the request's own identifier")
        }
        if let identifier = keyRequest.identifier as? Data,
           let expected = FairPlayStreamParser.keyIdentifier(inPSSH: origination.initData),
           identifier != expected {
            FairPlayStreamParser.log(
                "session \(sessionId) WARNING request identifier does not "
                + "match the origination claimed for it - FIFO order may be "
                + "wrong, and this SPC may address the wrong key")
        }
        let ready = withLock { () -> Bool in
            requestArrived = true
            requestCount += 1
            originations[ObjectIdentifier(keyRequest)] = origination
            if storedCertificate == nil {
                heldRequests.append(keyRequest)
                return false
            }
            return true
        }
        guard ready else {
            FairPlayStreamParser.log(
                "session \(sessionId) has no application certificate yet - "
                + "holding the request for setServerCertificate")
            return
        }
        makeSPC(for: keyRequest)
    }

    /// The SPC, once there is a certificate to make one with.
    private func makeSPC(for keyRequest: AVContentKeyRequest) {
        let state = withLock { () -> (Data, FairPlayOrigination)? in
            guard let certificate = storedCertificate,
                  let origination = originations[ObjectIdentifier(keyRequest)] else {
                return nil
            }
            return (certificate, origination)
        }
        guard let (certificate, origination) = state else {
            return
        }
        guard let contentId = contentIdentifier(for: keyRequest,
                                                origination: origination) else {
            FairPlayStreamParser.log(
                "session \(sessionId) has nothing to address an SPC with "
                + "for id \(origination.contentId)")
            return
        }
        keyRequest.makeStreamingContentKeyRequestData(
            forApp: certificate, contentIdentifier: contentId, options: nil
        ) { [weak self] spc, error in
            guard let self else { return }
            guard let spc else {
                FairPlayStreamParser.log(
                    "SPC failed for session \(self.sessionId) id "
                    + "\(origination.contentId): "
                    + (error.map { String(describing: $0) } ?? "no error given"))
                // Nothing outstanding: a request with no SPC can never
                // be answered by a licence, and leaving it armed would
                // let an unrelated CKC be applied to it.
                self.withLock { _ = self.originations.removeValue(
                    forKey: ObjectIdentifier(keyRequest)) }
                return
            }
            FairPlayStreamParser.log(
                "SPC PRODUCED for session \(self.sessionId) id "
                + "\(origination.contentId): \(spc.count) bytes")
            // Armed only now, and under the id the licence will name.
            // Arming before the SPC existed meant a failed SPC left a
            // request waiting for a licence that was never requested.
            self.withLock {
                self.outstanding[origination.contentId] = keyRequest
            }
            self.report(spc: spc, contentId: origination.contentId)
        }
    }

    /// What the SPC covers.
    ///
    /// A request raised with a nil identifier has none of its own, so
    /// the key id is read back out of the initialisation data that
    /// raised THIS request - not out of whatever the session last saw.
    private func contentIdentifier(for keyRequest: AVContentKeyRequest,
                                   origination: FairPlayOrigination) -> Data? {
        if let data = keyRequest.identifier as? Data {
            FairPlayStreamParser.log("addressing the SPC by the request's identifier")
            return data
        }
        if let string = keyRequest.identifier as? String {
            let assetId = string.hasPrefix("skd://")
                ? String(string.dropFirst("skd://".count))
                : string
            FairPlayStreamParser.log("addressing the SPC by the request's URI identifier")
            return Data(assetId.utf8)
        }
        if let keyId = FairPlayStreamParser.keyIdentifier(inPSSH: origination.initData) {
            FairPlayStreamParser.log("addressing the SPC by the PSSH's key id")
            return keyId
        }
        guard !origination.initData.isEmpty else {
            return nil
        }
        FairPlayStreamParser.log("addressing the SPC by the whole init data")
        return origination.initData
    }

    /// The CKC, applied to the request the content id names.
    ///
    /// Named rather than assumed. One session serves the whole content
    /// process, so "the request awaiting a licence" is ambiguous the
    /// moment two exchanges are in flight - and the content id that
    /// disambiguates it has been crossing both IPC legs all along.
    func provide(response ckc: Data, contentId: String) -> Bool {
        let request = withLock { () -> AVContentKeyRequest? in
            guard let found = outstanding.removeValue(forKey: contentId) else {
                return nil
            }
            _ = originations.removeValue(forKey: ObjectIdentifier(found))
            return found
        }
        guard let request else {
            FairPlayStreamParser.log(
                "session \(sessionId) has no key request outstanding for id "
                + "\(contentId) - licence not applied")
            return false
        }
        request.processContentKeyResponse(
            AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
        FairPlayStreamParser.log(
            "session \(sessionId) licence applied to the request for id "
            + "\(contentId), \(ckc.count) bytes")
        // THE RENDER QUESTION, asked for the first time with a real key.
        //
        // Everything up to here is settled: the page's licence is inside
        // an AVContentKeySession whose content key recipient is the
        // parser. What has never been asked is whether that parser will
        // hand back a DECRYPTED sample - the probe could not ask it,
        // having no key server, and said so.
        //
        // Asked here rather than on a timer because this is the exact
        // moment the answer changes.
        FairPlayStreamParser.shared.requestMediaData(sessionId)
        return true
    }

    /// The SPC's way back to the content process that asked for it.
    ///
    /// Main thread, because ReynardFairPlayNotifyParserKeyMessage
    /// asserts it and everything it touches on the Gecko side is
    /// main-thread-only; this delegate runs on its own queue.
    ///
    /// Reported under the id the request ARRIVED with, which is now the
    /// id of the origination this particular request answers rather than
    /// whatever the session last recorded.
    private func report(spc: Data, contentId: String) {
        guard let childId = Self.childId(ofSession: sessionId) else {
            FairPlayStreamParser.log(
                "session \(sessionId) is not a child session - "
                + "SPC produced but not routed")
            return
        }
        FairPlayStreamParser.log(
            "session \(sessionId) SPC on its way to child \(childId), "
            + "\(spc.count) bytes under id \(contentId)")
        DispatchQueue.main.async {
            spc.withUnsafeBytes { raw in
                ReynardFairPlayNotifyParserKeyMessage(
                    childId, contentId,
                    raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
            }
        }
    }

    /// "child-9" -> 9. Nothing else has a content process to go back to.
    private static func childId(ofSession sessionId: String) -> UInt? {
        let prefix = "child-"
        guard sessionId.hasPrefix(prefix) else {
            return nil
        }
        return UInt(sessionId.dropFirst(prefix.count))
    }
}

/// The parser's output delegate.
///
/// Only the callbacks that matter are declared, and they are declared with
/// their REAL types. The retired probe answered them by counting colons in
/// the selector and typing every argument as an object, which crashed the
/// app on the first callback: forTrackID: is a CMPersistentTrackID, and an
/// Int32 sent isKindOfClass: is EXC_BAD_ACCESS at the track id itself.
///
/// Unknown callbacks are simply not answered. AVFoundation checks
/// respondsToSelector: before sending an optional delegate method, so
/// declining one is a no-op rather than an error - and far safer than
/// answering a signature nobody has verified.
private final class ParserDelegate: NSObject {
    let sessionId: String
    /// "<sessionId>|<stream>" for a per-stream parser, nil for the render
    /// probe's, which has no SourceBuffer behind it.
    let streamKey: String?

    init(sessionId: String, streamKey: String? = nil) {
        self.sessionId = sessionId
        self.streamKey = streamKey
        super.init()
    }

    /// The key request. This is the callback the probe proved fires from
    /// a plain MSE init segment with no asset in the process.
    /// The specifier the parser hands over, kept rather than discarded.
    ///
    /// Discarding it is why the SPC question is still open. Three probe
    /// runs called
    /// streamingContentKeyRequestDataForApp:contentIdentifier:trackID:options:error:
    /// on the PARSER - with a real Apple certificate and a real track id
    /// from a real key request - and every one returned nil with no
    /// NSError at all. A method that reached real logic and disliked its
    /// inputs would populate that error; nil with none is what a wrong
    /// signature or a wrong receiver looks like.
    ///
    /// In AVFoundation's ordinary flow the SPC comes from the REQUEST
    /// object, not from whatever produced it. This is that object.
    private(set) var lastSpecifier: AnyObject?

    @objc(streamDataParser:didProvideContentKeySpecifier:forTrackID:)
    func streamDataParser(_ parser: Any,
                          didProvideContentKeySpecifier specifier: Any,
                          forTrackID trackID: Int32) {
        fputs("fpsParser: session \(sessionId) key request on track \(trackID)\n", stderr)
        lastSpecifier = specifier as AnyObject
        FairPlayStreamParser.shared.noteKeyRequest(sessionId: sessionId, trackID: trackID)
        FairPlayStreamParser.shared.processSpecifier(sessionId: sessionId,
                                                     specifier: specifier as AnyObject)
    }

    /// The older spelling, kept because the SDK samples and WebKit both
    /// still reference it and the device that answers one may not answer
    /// the other.
    @objc(streamDataParser:didProvideContentKeyRequestInitializationData:forTrackID:)
    func streamDataParser(_ parser: Any,
                          didProvideContentKeyRequestInitializationData initData: Data,
                          forTrackID trackID: Int32) {
        fputs("fpsParser: session \(sessionId) key request on track \(trackID), "
              + "\(initData.count) bytes of init data\n", stderr)
        FairPlayStreamParser.shared.noteKeyRequest(sessionId: sessionId, trackID: trackID)
    }

    @objc(streamDataParser:didFailToParseStreamDataWithError:)
    func streamDataParser(_ parser: Any, didFailToParseStreamDataWithError error: Error) {
        fputs("fpsParser: session \(sessionId) parse FAILED: \(error)\n", stderr)
        // Marked for replacement, not just logged. AVFoundation is
        // explicit that this is terminal - "Ignoring appendStreamData:
        // because we're failed or expired, create a new
        // AVStreamDataParser to try again" - so every later append went
        // into a dead object, silently.
        FairPlayStreamParser.shared.noteStreamParseFailure(sessionId: sessionId)
    }

    /// The parser understood the segment and built an asset for it.
    ///
    /// This is what says the init segment parsed at all, and its tracks
    /// are what the media-data calls address. AVAsset here is a parsed
    /// description, NOT an AVURLAsset - nothing about it makes the
    /// AVContentKeyRecipient refusal go away, and it must not be read as
    /// a way back onto the player path.
    @objc(streamDataParser:didParseStreamDataAsAsset:)
    func streamDataParser(_ parser: Any, didParseStreamDataAsAsset asset: AVAsset) {
        fputs("fpsParser: session \(sessionId) parsed asset \(asset)\n", stderr)
        for track in asset.tracks {
            fputs("fpsParser:   track id=\(track.trackID) type=\(track.mediaType.rawValue) "
                  + "enabled=\(track.isEnabled) formats=\(track.formatDescriptions.count)\n",
                  stderr)
        }
        // Kept, because media data is asked for per track and these are
        // the tracks that carry it. trackIDs holds only tracks a KEY
        // REQUEST named, and on this route the request arrives through
        // the session rather than the parser, so it is usually empty.
        let reported = asset.tracks.map { $0.trackID }
        FairPlayStreamParser.shared.noteAssetTracks(
            sessionId: sessionId, tracks: reported)
        // And against THIS parser, which is what the drain arms from.
        // This is the moment the tracks become known, so it is also the
        // moment anything can safely be asked for.
        if let streamKey {
            FairPlayStreamParser.shared.noteStreamTracks(streamKey: streamKey,
                                                         tracks: reported)
        }
    }

    /// A sample the parser vended - the answer to the render question.
    ///
    /// Declaring this commits to a signature, and this file records what
    /// that costs when it is wrong: a previous probe answered callbacks
    /// by counting colons, sent isKindOfClass: to a track id, and
    /// crashed the app on every launch. These are the types WebKit uses.
    ///
    /// The ENTRY is logged before any argument is touched, so a wrong
    /// signature names itself in the log instead of leaving another
    /// silent launch crash to bisect.
    @objc(streamDataParser:didProvideMediaData:forTrackID:mediaType:flags:)
    func streamDataParser(_ parser: Any,
                          didProvideMediaData sampleBuffer: CMSampleBuffer,
                          forTrackID trackID: Int32,
                          mediaType: String,
                          flags: UInt) {
        fputs("fpsParser: session \(sessionId) didProvideMediaData ENTERED\n",
              stderr)
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        let ready = CMSampleBufferDataIsReady(sampleBuffer)
        let hasData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil
        // Whether the sample still carries an encryption attachment is
        // the whole answer: present means the parser handed back
        // something still encrypted, absent means it decrypted it.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false)
        let attachmentCount = attachments.map { CFArrayGetCount($0) } ?? 0
        // THE VERDICT, and it is this rather than the attachments.
        //
        // Attachment dictionaries exist on ordinary samples for
        // ordinary reasons - sync flags, dependency info - so a
        // non-zero count says nothing about encryption on its own.
        // The format subtype does: under Common Encryption a
        // protected track reads 'encv' or 'enca', and once the sample
        // is decrypted it reads the real codec, 'avc1' or 'mp4a'.
        //
        // The count is kept beside it as supporting detail. If the
        // two ever disagree, that is worth knowing before anything
        // is built on top of either.
        let subtype = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map { CMFormatDescriptionGetMediaSubType($0) }
        let subtypeFourCC = subtype.map { code -> String in
            String([24, 16, 8, 0].map { shift -> Character in
                let byte = UInt8((code >> UInt32(shift)) & 0xff)
                return (byte >= 0x20 && byte <= 0x7e)
                    ? Character(UnicodeScalar(byte)) : "."
            })
        } ?? "none"
        // THREE states, because there are three and collapsing two of
        // them cost several rounds of this.
        //
        //   encv / enca   Common Encryption's protected boxes. The
        //                 parser did not decrypt, full stop.
        //   qavc / qaac   Decrypt is deferred to the DECODER. The bytes
        //                 are still ciphertext here, and only a decoder
        //                 registered with the content key session can
        //                 turn them into pictures.
        //   anything else Clear. Apple TV's avc1 was genuinely clear -
        //                 a VTDecompressionSession decoded eight of
        //                 eight.
        //
        // The old test named only the first pair, so HBO Max's 385 qavc
        // samples were all reported "DECRYPTED - the route has an end"
        // while every one of them failed to decode with -12911. The
        // payload bytes did not contradict it either: cbcs leaves the
        // NAL length prefix and the NAL header in the clear and encrypts
        // the slice body, so a protected sample has an exact length
        // prefix and a valid NAL header and looks, to a hex dump of its
        // first sixteen bytes, precisely like a decrypted one.
        let stillEncrypted = subtypeFourCC == "encv"
            || subtypeFourCC == "enca"
        // Built with if/else rather than a nested ternary of concatenated
        // literals. Swift type-checks those badly and this file is
        // already full of long string sums; "expression too complex" is
        // not a failure worth risking for a log line.
        let verdict: String
        if stillEncrypted {
            verdict = "STILL ENCRYPTED - the parser did not decrypt it"
        } else if FairPlayStreamParser.protectedSubtypes.contains(subtypeFourCC) {
            verdict = "PROTECTED - decrypt is deferred to the decoder, so "
                + "the sink has to be a content key recipient"
        } else {
            verdict = "DECRYPTED - the route has an end"
        }

        // THE PAYLOAD, because the description and the bytes are
        // separate things and only one of them has been looked at.
        //
        // A parser could report a track's ORIGINAL format while handing
        // back data it has not decrypted, and subtype=avc1 would look
        // exactly the same. That distinction decides the architecture:
        // genuinely clear samples belong in Gecko's own decode path and
        // the whole protected-surface problem disappears, while
        // ciphertext leaves an AVFoundation-filled display layer as the
        // only sink.
        //
        // Decrypted H.264 in an MP4 sample is length-prefixed NAL units:
        // four big-endian length bytes, then a header whose top bit is
        // zero and whose low five bits are a type in 1...23, with the
        // length fitting the buffer. Ciphertext passes that by accident
        // essentially never.
        // FairPlayStreamParser, not Self: these helpers live on the parser
        // while this callback is on KeySessionDelegate. Self resolves to
        // the wrong type and does not compile - swiftc -parse passes it
        // because it checks syntax and never resolves names.
        let (head, totalBytes) = FairPlayStreamParser.samplePrefix(
            sampleBuffer, count: 16)
        // Both framings, because the first capture disproved the
        // assumption behind testing only one. A 6-byte sample came back
        // as 21 00 03 40 68 1c and was reported "NOT H.264" - but 0x21
        // read as a RAW NAL header is forbidden_zero 0, nal_ref_idc 1,
        // type 1, a perfectly ordinary non-IDR slice. The test was
        // looking for a length prefix that this parser does not add.
        let framing = FairPlayStreamParser.h264Framing(head,
                                                      total: totalBytes)
        let looksLikeH264 = framing != "neither"
        // And the extension a protected track carries to name the codec
        // underneath its encryption. Absent beside subtype=avc1 is what
        // a real decryption looks like; present would mean the
        // description was unwrapped while the bytes were not.
        // Availability-guarded: the deployment target here is iOS 13.0 and
        // this key is 14.0+. Unguarded it does not compile at all, which is
        // a build error swiftc -parse cannot see either.
        var protectedOriginal = "absent"
        if #available(iOS 14.0, *),
           let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           CMFormatDescriptionGetExtension(
               formatDescription,
               extensionKey: kCMFormatDescriptionExtension_ProtectedContentOriginalFormat)
               != nil {
            protectedOriginal = "PRESENT"
        }
        fputs("fpsParser: session \(sessionId)   payload \(totalBytes) bytes, "
              + "head \(head.map { String(format: "%02x", $0) }.joined()) "
              + "-> \(looksLikeH264 ? "H.264 (\(framing))" : "NOT H.264") "
              + "| ProtectedContentOriginalFormat \(protectedOriginal) "
              + "| pts \(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))) "
              + "dts \(CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sampleBuffer)))\n",
              stderr)
        // Into the sink, before the log line below, so a layer that
        // takes the process down does it with the sample's own details
        // already on the record.
        if let streamKey {
            FairPlayStreamParser.shared.enqueueForDisplay(
                streamKey: streamKey, sampleBuffer: sampleBuffer,
                mediaType: mediaType)
        }
        fputs("fpsParser: session \(sessionId) MEDIA DATA track \(trackID) "
              + "(\(mediaType)) samples=\(samples) ready=\(ready) "
              + "dataBuffer=\(hasData) attachments=\(attachmentCount) "
              + "flags=\(flags) subtype=\(subtypeFourCC) -> "
              + verdict
              + "\n", stderr)
    }

    /// Only the arity-2 spelling is declared, and only because its types
    /// are certain. Everything else the parser might send is deliberately
    /// left unanswered: AVFoundation checks respondsToSelector: before an
    /// optional delegate call, so declining is free, whereas declaring a
    /// selector whose signature nobody has verified is how the last probe
    /// crashed the app on every launch.
    @objc(streamDataParser:didReachEndOfTrackWithTrackID:mediaType:)
    func streamDataParser(_ parser: Any,
                          didReachEndOfTrackWithTrackID trackID: Int32,
                          mediaType: String) {
        fputs("fpsParser: session \(sessionId) end of track \(trackID) (\(mediaType))\n", stderr)
    }
}
