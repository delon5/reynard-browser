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
        Self.log("session \(sessionId) destroyed")
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
        let payload = Self.psshPayload(in: initData)
        let forSession = payload ?? initData
        Self.log("session \(sessionId) raising a key request directly from "
                 + "\(forSession.count) bytes of "
                 + (payload == nil ? "init data as it arrived"
                                   : "PSSH payload (unwrapped from "
                                     + "\(initData.count))")
                 + " - key id "
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
        Self.keyDelegateQueue.asyncAfter(deadline: .now() + 5) {
            guard !delegate.sawRequest else {
                return
            }
            Self.log("session \(sessionId) raised NO key request from "
                     + "\(sentCount) bytes sent as \(sentShape) with "
                     + (namedKey ? "a named key id" : "no identifier")
                     + " - AVFoundation did not recognise it, and said "
                     + "nothing about it")

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
            call(entry.parser, shouldProvide, true, trackID)
            Self.log("asked for media data on track \(trackID)")
        }
        if entry.parser.responds(to: provide) {
            entry.parser.perform(provide)
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

    var sawRequest: Bool { withLock { requestArrived } }

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

    init(sessionId: String) {
        self.sessionId = sessionId
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
