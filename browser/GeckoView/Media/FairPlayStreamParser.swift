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
        /// The content ids of one batched key exchange, in fkri order.
        ///
        /// ADDED - see mse_fix_84_every_key_the_pssh_names.py's
        /// docstring. A FairPlay pssh may name several keys, and Safari
        /// answers it with ONE message carrying one challenge per key.
        /// Empty, or holding a single id, means this session is not
        /// batched and every SPC is sent the moment it is made.
        var batchContentIds: [String] = []
        /// The key ids those content ids stand for, same order.
        var batchKeyIds: [Data] = []
        /// SPCs collected so far, by content id.
        var batchSPCs: [String: Data] = [:]
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
        /// Whether that direct-route request was built from an INVENTED
        /// sinf.
        ///
        /// canonicalSinf fabricates a tenc when no real init segment has
        /// been seen yet, and a key minted against it cannot serve the
        /// samples - tv.apple.com's sinks refuse every one of them with
        /// -11800 "no content key present" while four such licences sit
        /// applied. So this decides whether the parser's own specifier,
        /// which IS derived from the real init segment, is still worth
        /// raising.
        ///
        /// Captured at the request rather than read later: fix 63's
        /// harvest can fill templateSinf after the fact, and the
        /// question is what the request that already went out was built
        /// from.
        var directRouteSynthesised = false
        /// Specifiers already let through, by their initialisation
        /// data.
        ///
        /// The callback fires per append, not once - eight times in the
        /// capture this was written against - and eight key requests for
        /// one track is a storm, not a fix. Keyed by the bytes rather
        /// than by a track id because processSpecifier is not given one:
        /// two tracks carry two different specifiers, and one track
        /// re-appended carries the same one.
        var specifierRaisedFor: Set<Data> = []
        /// A sinf box lifted from an init segment the page appended.
        ///
        /// Used as the TEMPLATE for the JSON handed to
        /// processContentKeyRequest: it carries the true frma and the
        /// true constant IV, and a PSSH carries neither. Only its key id
        /// is swapped for the one being asked about, so one template
        /// serves every key in the presentation.
        var templateSinf: Data?
        /// The parser's own specifier for each key, by the tenc KID its
        /// sinf names.
        ///
        /// A template is a reconstruction and templateSinf holds only
        /// one of them, harvested from whichever stream appended first.
        /// Each track has its own constant IV, so reusing one track's
        /// sinf for another track's key asks for the wrong thing - the
        /// video key went out carrying the audio track's IV, and both
        /// sinks refused every sample with -11800 "no content key
        /// present".
        ///
        /// These are not reconstructions. They are the bytes
        /// AVStreamDataParser produced from the real init segment, in
        /// the document shape processContentKeyRequest takes, one per
        /// key - the same thing HBO Max's page hands over directly and
        /// the reason that site works.
        var specifierByKeyId: [String: Data] = [:]
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
    /// Is the element behind this session playing, and how loud?
    ///
    /// Held per SESSION and OUTSIDE Entry, because the order is not
    /// ours to choose: a page can call play() before it sets media
    /// keys, and a state dropped because no Entry existed yet is the
    /// state that decides whether anything plays at all.
    ///
    /// Absent means NOT PLAYING. That is the only safe default for a
    /// setting whose purpose is to withhold playback, and it is the
    /// direction that fails visibly - see the HELD line in
    /// markLayerAttached.
    private var sessionPlaying: [String: Bool] = [:]
    private var sessionVolume: [String: Double] = [:]
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

    /// Guards the once-a-second wall-clock note below.
    ///
    /// ADDED - see mse_fix_119's docstring. log() is called from the
    /// main queue, the drain queues, the audio queues and the key
    /// session's delegate queue, so the note's bookkeeping needs a lock
    /// of its own. Not the state lock: log() is called from inside
    /// withState in several places and that lock is not recursive.
    private static let stampLock = NSLock()
    private static var lastClockNote: Double = 0
    private static let wallClockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return f
    }()

    fileprivate static func log(_ message: String) {
        // WHEN, ON EVERY LINE - see mse_fix_119's docstring. One percent
        // of the lines in the last capture carried a time, and three of
        // the conclusions drawn from it were wrong because durations had
        // to be inferred from how many lines apart things were.
        let now = hostNow()
        // And once a second, what that host reading is in wall clock, so
        // this file can be lined up against the system's own timestamped
        // lines without interpolating between them.
        var note: String?
        stampLock.lock()
        if now - lastClockNote > 1.0 {
            lastClockNote = now
            note = wallClockFormat.string(from: Date())
        }
        stampLock.unlock()
        if let note {
            fputs("fpsParser: CLOCK host "
                  + String(format: "%.3f", now) + " = " + note + "\n",
                  stderr)
        }
        fputs("fpsParser: [" + String(format: "%.3f", now) + "] "
              + message + "\n", stderr)
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
        // File this specifier under the key its own sinf names.
        //
        // Whatever else happens to it below - it may be stood down as a
        // second request for a key already asked about - these bytes are
        // worth keeping. They carry the KID and the constant IV
        // together, for THIS track, already serialised the way
        // processContentKeyRequest wants them.
        if let initializationData,
           let sinf = Self.sinfFromSpecifierJSON(initializationData),
           let named = Self.keyIdentifier(inTenc: sinf) {
            let hex = Self.hexBytes(named)
            let isNew = withState { () -> Bool in
                guard entry.specifierByKeyId[hex] == nil else {
                    return false
                }
                entry.specifierByKeyId[hex] = initializationData
                return true
            }
            if isNew {
                Self.log("session \(sessionId) filed the parser's specifier "
                         + "for key \(hex), \(initializationData.count) bytes")
            }
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
        //
        // NARROWED. Standing down is right when the direct route's
        // request was a good one. It is wrong when that request was
        // built from an invented sinf: such a key cannot serve these
        // samples however well the licence exchange goes, so suppressing
        // the only request that could is pure loss. tv.apple.com spent a
        // whole capture that way - four licences applied, eight
        // specifiers discarded, and both sinks refusing every protected
        // sample with -11800 "no content key present".
        //
        // Once per specifier, because this callback fires per append -
        // eight times in one capture - and eight key requests for one
        // track is a storm, not a fix.
        let standDown = withState { () -> Bool in
            entry.directRouteOwnsSession && !entry.directRouteSynthesised
        }
        if standDown {
            Self.log("session \(sessionId) parser raised a specifier, but the "
                     + "direct route already asked for this key - not raising "
                     + "a second request")
            return
        }
        if withState({ entry.directRouteOwnsSession }) {
            let alreadyRaised = withState { () -> Bool in
                guard let initializationData else {
                    return false
                }
                guard !entry.specifierRaisedFor.contains(initializationData)
                else {
                    return true
                }
                entry.specifierRaisedFor.insert(initializationData)
                return false
            }
            if alreadyRaised {
                Self.log("session \(sessionId) this specifier has already "
                         + "been raised - not asking again")
                return
            }
            Self.log("session \(sessionId) the direct route asked with a "
                     + "SYNTHESISED sinf, so its key cannot serve these "
                     + "samples - letting the parser's own specifier through, "
                     + "\(initializationData?.count ?? 0) bytes")
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
        Self.addRecipient(keySession, recipient: recipient,
                          label: "session \(sessionId) parser")

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
        // CHANGED - see mse_fix_95's docstring. This block was the only
        // place that knew how to take a stream apart, and it could only
        // do it for a whole session at once. A page that rebuilds its
        // player abandons two streams without going anywhere near
        // destroySession, so the same work is now a helper.
        for (key, slot) in orphans {
            tearDownStream(key: key, slot: slot,
                           keySession: entry.keySession,
                           why: "its session was destroyed")
        }
        // AND THE STATE KEYED ON THEM.
        //
        // ADDED - see fix 13's docstring. These dictionaries live
        // outside Entry deliberately - a page can call play() before it
        // sets media keys - and nothing ever removed from them. A
        // `sessionPlaying[sessionId] = true` left behind pre-seeds the
        // next stream of a recycled session id as PLAYING, which is
        // the one direction that field's own comment forbids.
        //
        // Owner-keyed state goes only when no surviving stream still
        // names that element: tv.apple.com runs a pre-roll element and
        // a feature element in one content process, and destroying one
        // session is not a reason to forget where the other one is.
        withState {
            sessionPlaying.removeValue(forKey: sessionId)
            sessionVolume.removeValue(forKey: sessionId)
            let prefix = sessionId + "|"
            // Snapshotted before anything is removed, for the reason
            // the doomed list above is.
            for key in Array(pendingOwners.keys) where key.hasPrefix(prefix) {
                pendingOwners.removeValue(forKey: key)
            }
            if let chosen = lastVideoClockKey, chosen.hasPrefix(prefix) {
                lastVideoClockKey = nil
            }
            let living = Set(streamParsers.values.map { $0.owner })
            for (_, slot) in orphans
            where slot.owner != 0 && !living.contains(slot.owner) {
                ownerPlaying.removeValue(forKey: slot.owner)
                ownerVolume.removeValue(forKey: slot.owner)
                ownerPosition.removeValue(forKey: slot.owner)
                ownerPositionAt.removeValue(forKey: slot.owner)
            }
        }
        Self.log("session \(sessionId) destroyed")
    }

    /// The page removed this SourceBuffer, or dropped the MediaSource it
    /// lived on. Nothing more will ever be appended to it.
    ///
    /// ADDED - see mse_fix_99's docstring. This is the signal fix 95
    /// did not have. Fix 95 parks a stream when a NEWER sink of the same
    /// half appears, which is a good guess and arrives late: on
    /// tv.apple.com the page removed both SourceBuffers five hundred log
    /// lines before the replacement renderer was built, and the
    /// abandoned one was singing for all of them.
    ///
    /// Torn down rather than parked. Parking is reversible because it
    /// answers a guess; this is the page itself saying it is finished,
    /// and there is nothing to be careful about.
    ///
    /// A retire for a stream that does not exist is ordinary - most
    /// SourceBuffers on a page are never appended to at all - so it is
    /// silent.
    @objc public func retireStream(_ sessionId: String, stream: String) {
        let key = sessionId + "|" + stream
        guard let slot = withState({
            streamParsers.removeValue(forKey: key)
        }) else {
            return
        }
        tearDownStream(key: key, slot: slot,
                       keySession: liveSession(sessionId),
                       why: "the page removed its SourceBuffer")
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
        // THE STREAMS SURVIVE THE REBUILD.
        //
        // CHANGED - see mse_fix_96's docstring. This went straight
        // through destroySession, which tears down every stream parser
        // in the session - and a stream parser holds the INIT SEGMENT.
        // The page appended that once, at the start of playback, and
        // will never append it again, so every fragment after a rebuild
        // went into a virgin AVStreamDataParser with no idea what it was
        // looking at. On Netflix the same SourceBuffer went from
        //
        //     stream child-11|sb-4942676128 standing down ... a VIDEO
        //       sink here would be a second copy
        //
        // to, four lines after the rebuild,
        //
        //     payload 93075 bytes, head fff7d3d8... -> NOT H.264
        //     MEDIA DATA track 100 (soun) ... subtype=.mp1
        //
        // - an H.264 video track reported as MPEG-1 Layer 1 audio,
        // because a parser with no initialisation scans for anything
        // frame-shaped and finds ADTS syncwords in ciphertext.
        //
        // Only the KEY SESSION is deaf. The parsers are fine, so they
        // come off the dying session's books before it goes and go onto
        // the new one's afterwards. Everything that is genuinely about
        // the key session - the pending originations, the batch, the
        // specifiers already raised - is still thrown away, which is the
        // whole point of the rebuild.
        let carried = withState { () -> [(String, StreamParser)] in
            var out: [(String, StreamParser)] = []
            // Keys snapshotted before anything is removed - see
            // destroySession for why.
            for key in Array(streamParsers.keys).sorted()
            where key.hasPrefix(sessionId + "|") {
                if let slot = streamParsers.removeValue(forKey: key) {
                    out.append((key, slot))
                }
            }
            return out
        }
        // And the media facts the entry had learned. These describe the
        // CONTENT, not the key session, and cannot be re-derived once
        // the page has stopped sending init segments - the log said
        //
        //     using the page's own sinf as the template, 72 bytes
        //
        // before the rebuild and
        //
        //     no sinf template yet - synthesising 72 bytes
        //
        // after it, and a synthesised template is what fix 63 exists to
        // avoid: it carries a fabricated tenc rather than the track's
        // real constant IV.
        let carriedTemplate = withState { entries[sessionId]?.templateSinf }
        let carriedSpecifiers = withState {
            entries[sessionId]?.specifierByKeyId ?? [:] }
        if let old = liveSession(sessionId) {
            for (_, slot) in carried {
                old.removeContentKeyRecipient(slot.recipient)
                if let layer = slot.displayLayer,
                   let recipient = (layer as AnyObject)
                    as? AVContentKeyRecipient {
                    old.removeContentKeyRecipient(recipient)
                }
                if let renderer = slot.audioRenderer,
                   let recipient = (renderer as AnyObject)
                    as? AVContentKeyRecipient {
                    old.removeContentKeyRecipient(recipient)
                }
            }
        }
        destroySession(sessionId)
        guard createSession(sessionId) else {
            Self.log("session \(sessionId) could not be rebuilt - this "
                     + "playback has no route")
            return
        }
        withState {
            for (key, slot) in carried {
                streamParsers[key] = slot
            }
            if let fresh = entries[sessionId] {
                fresh.templateSinf = carriedTemplate
                fresh.specifierByKeyId = carriedSpecifiers
            }
        }
        if let fresh = liveSession(sessionId) {
            for (key, slot) in carried {
                // GUARDED - see mse_fix_97's docstring. Every one of
                // these three raised NSInvalidArgumentException on
                // tv.apple.com and took the app with it: a recipient
                // that has already established its own content
                // protection cannot be moved to another key session.
                // The refusal is the answer to the question fix 96
                // asked, and it is survivable - what the parser holds
                // is the init segment, which is what the rebuild was
                // losing.
                Self.addRecipient(fresh, recipient: slot.recipient,
                                  label: "stream \(key) parser")
                if let layer = slot.displayLayer,
                   let recipient = (layer as AnyObject)
                    as? AVContentKeyRecipient {
                    Self.addRecipient(fresh, recipient: recipient,
                                      label: "stream \(key) display layer")
                }
                if let renderer = slot.audioRenderer,
                   let recipient = (renderer as AnyObject)
                    as? AVContentKeyRecipient {
                    Self.addRecipient(fresh, recipient: recipient,
                                      label: "stream \(key) audio renderer")
                }
                // The recipient count is the test. If it does not climb,
                // an AVStreamDataParser cannot be re-registered once its
                // session has gone and the init segment has to be
                // replayed instead - which is a different fix.
                Self.log("stream \(key) carried across the rebuild with "
                         + "its parser - the init segment the page sent "
                         + "once is still in it. Recipients now "
                         + "\(fresh.contentKeyRecipients.count).")
            }
        }
        if let carriedTemplate {
            Self.log("session \(sessionId) kept its "
                     + "\(carriedTemplate.count)-byte sinf template and "
                     + "\(carriedSpecifiers.count) parser specifiers "
                     + "across the rebuild")
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
        // Recorded here, where the answer is knowable: with no template
        // this request is about to be built from a fabricated tenc, and
        // the parser's own specifier is then the only one that can name
        // the key these samples actually use.
        // The parser's own specifier for THIS key, if one has been seen.
        //
        // Preferred over everything below, because it is not a
        // reconstruction: it names this track's KID and this track's
        // constant IV, which no template shared between two tracks can
        // do. HBO Max's page hands over exactly this shape and that site
        // renders; Apple TV hands over a pssh, and every sinf built from
        // one has been refused.
        let exactSpecifier: Data? = keyId.flatMap { id -> Data? in
            let hex = Self.hexBytes(id)
            return withState { () -> Data? in entry.specifierByKeyId[hex] }
        }
        withState {
            entry.directRouteSynthesised = (exactSpecifier == nil
                                            && template == nil)
        }
        let forSession: Data
        if let exactSpecifier {
            Self.log("session \(sessionId) asking with the parser's own "
                     + "specifier for key "
                     + (keyId.map { Self.hexBytes($0) } ?? "?")
                     + ", \(exactSpecifier.count) bytes")
            forSession = exactSpecifier
        } else {
            // The scheme the page declares, not the one that happened
            // to work for the first site on this route.
            let scheme = Self.schemeType(inPSSH: initData) ?? "cbcs"
            forSession = Self.sinfInitialisationJSON(
                keyId: keyId, template: template, scheme: scheme,
                sessionId: sessionId)
                ?? (payload ?? initData)
        }
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

        // ADDED - see mse_fix_84's docstring. A pssh may name several
        // keys and the picture is often not keyed to the first: Netflix
        // licences 09e2052f above while its video track's tenc names
        // 09e20534, and the display layer answers "no content key
        // present" for every frame.
        //
        // One request per remaining key, each with a sinf naming it and
        // an origination of its own, so each produces its own SPC. The
        // originations are queued in the same order the requests are
        // made, which is the order the delegate's FIFO claims them in.
        //
        // reynard-keyid: is the existing convention for a request this
        // side raised. Nothing is held for these keys yet, so the replay
        // branch that convention also drives cannot fire on a fresh
        // batch.
        let everyKey = Self.keyIdentifiers(inPSSH: initData)
        if everyKey.count > 1, let primary = keyId {
            // CORRECTED while applying fix 84. The script's fan-out read
            // `scheme` from the binding above, which is declared inside
            // the else branch that builds the first request's sinf and
            // is not in scope here - the emitted Swift did not compile.
            // schemeType is a pure function of initData, so asking it
            // again is the same answer that branch would have had.
            let scheme = Self.schemeType(inPSSH: initData) ?? "cbcs"
            var ids = [contentId]
            var keys = [primary]
            for extra in everyKey where Self.hexBytes(extra)
                    != Self.hexBytes(primary) {
                let extraId = "reynard-keyid:" + Self.hexBytes(extra)
                guard let extraSinf = Self.sinfInitialisationJSON(
                        keyId: extra, template: template, scheme: scheme,
                        sessionId: sessionId) else {
                    Self.log("session \(sessionId) could not build a sinf "
                             + "for key \(Self.hexBytes(extra)) - that key "
                             + "is not in this batch")
                    continue
                }
                withState {
                    entry.pendingOriginations.append(
                        FairPlayOrigination(contentId: extraId,
                                            initData: initData))
                }
                ids.append(extraId)
                keys.append(extra)
                Self.log("session \(sessionId) also asking for key "
                         + Self.hexBytes(extra) + " - the pssh names "
                         + "\(everyKey.count) and the picture may be on "
                         + "any of them")
                entry.keySession.processContentKeyRequest(
                    withIdentifier: extra, initializationData: extraSinf,
                    options: nil)
            }
            if ids.count > 1 {
                withState {
                    entry.batchContentIds = ids
                    entry.batchKeyIds = keys
                    entry.batchSPCs = [:]
                }
                Self.log("session \(sessionId) batching \(ids.count) "
                         + "challenges into one key message")
            }
        }

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

    /// addContentKeyRecipient, which THROWS.
    ///
    /// ADDED - see mse_fix_97's docstring. This is not a theoretical
    /// hazard. Fix 96 carried stream parsers across a session rebuild
    /// and re-registered them, and the device answered:
    ///
    ///     *** Terminating app due to uncaught exception
    ///         'NSInvalidArgumentException', reason:
    ///         '*** -[AVContentKeySession addContentKeyRecipient:] Can't
    ///          add object as an AVContentKeyRecipient after it has
    ///          established its own content protection'
    ///
    /// Swift cannot catch an Objective-C exception, so that is the
    /// process gone - SIGABRT, with the .ips naming
    /// objc_exception_throw under addContentKeyRecipient:.
    ///
    /// Guarded exactly as drainPending guards layer.enqueue, and for the
    /// same reason: these APIs raise instead of returning an error, and
    /// this route has now had two of them do it.
    ///
    /// A refusal is not fatal and is not silent. A recipient that has
    /// established its own content protection keeps it - that state is
    /// precisely what it is refusing to leave - so the sensible thing is
    /// to say so and carry on.
    @discardableResult
    fileprivate static func addRecipient(_ session: AVContentKeySession,
                                         recipient: AVContentKeyRecipient,
                                         label: String) -> Bool {
        if let failure = GeckoRuntimeBridge.catchException(from: {
            session.addContentKeyRecipient(recipient)
        }) {
            log("\(label) was REFUSED as a content key recipient: \(failure)"
                + " - it keeps whatever content protection it has already "
                + "established. This is not fatal; it was, before it was "
                + "guarded.")
            return false
        }
        return true
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
    ///
    /// `scheme` is what the page's own PSSH declares in fpsi, and is
    /// used only when there is no template to copy - a real template
    /// carries its own schm and is never rewritten.
    static func sinfInitialisationJSON(keyId: Data?, template: Data?,
                                       scheme: String,
                                       sessionId: String) -> Data? {
        guard let keyId, keyId.count == 16 else {
            log("session \(sessionId) has no key id - cannot build a sinf")
            return nil
        }
        let sinf: Data
        // A real template names the media's own key. Do not overwrite it.
        //
        // Rekeying is right when the key id came from the page - HBO
        // Max's init data IS a sinf, so its keyId and its template's
        // tenc agree and the rewrite is a no-op. It is wrong when the
        // key id came from a cenc pssh's fkri box, which counts 0, 1,
        // 2, 3 across sessions: that is an index, and writing it over
        // the media's default_KID is what left AVFoundation holding a
        // key no sample ever asks for.
        let templateKeyId = template.flatMap { keyIdentifier(inTenc: $0) }
        let templateNamesItsOwn = templateKeyId.map { candidate in
            candidate.count == 16
                && candidate.contains(where: { $0 != 0 })
                && candidate != keyId
        } ?? false
        if let template, templateNamesItsOwn {
            sinf = template
            log("session \(sessionId) template names KID "
                + hexBytes(templateKeyId ?? Data()) + ", the pssh names "
                + hexBytes(keyId) + " - the media's own KID wins")
        } else if let template,
                  let rekeyed = replacingKeyId(in: template, with: keyId) {
            sinf = rekeyed
            log("session \(sessionId) using the page's own sinf as the "
                + "template, \(sinf.count) bytes")
        } else {
            sinf = canonicalSinf(keyId: keyId, scheme: scheme)
            log("session \(sessionId) no sinf template yet - synthesising "
                + "\(sinf.count) bytes for scheme \(scheme) "
                + "(the page's own fpsi)")
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
    ///
    /// CHANGED - see mse_fix_77_the_scheme_the_page_declares.py's
    /// docstring. The scheme was hardcoded cbcs, which is what
    /// tv.apple.com's fpsi declares and is NOT what netflix.com's
    /// declares. A cenc track described as cbcs is described wrongly in
    /// the two fields that only pattern encryption has - the pattern
    /// byte and the constant IV - and that description is what the SPC
    /// is built from.
    static func canonicalSinf(keyId: Data, scheme: String) -> Data {
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
        // Anything that is not four characters is not a scheme type,
        // and cbcs is the form every site on this route used before
        // fpsi was read at all.
        let name = scheme.utf8.count == 4 ? scheme : "cbcs"
        let frma = box("frma", Array("avc1".utf8))
        // version+flags 0, the scheme, scheme version 0x00010000
        let schm = box("schm", [0, 0, 0, 0] + Array(name.utf8)
                               + [0x00, 0x01, 0x00, 0x00])
        var tencBody: [UInt8]
        if name == "cenc" || name == "cens" {
            // Full-sample AES-CTR. Version 0, because the pattern byte
            // and the constant IV are version 1's and neither exists
            // here: the IV is per sample and eight bytes is the size
            // every cenc packager in practice writes.
            tencBody = [0x00, 0x00, 0x00, 0x00]   // version 0
            tencBody.append(0x00)    // reserved
            tencBody.append(0x00)    // reserved - no pattern in v0
            tencBody.append(0x01)    // default_isProtected
            tencBody.append(0x08)    // per-sample IV size
            tencBody.append(contentsOf: [UInt8](keyId))
        } else {
            // Pattern encryption, exactly the bytes this built before.
            tencBody = [0x01, 0x00, 0x00, 0x00]   // version 1
            tencBody.append(0x00)    // reserved
            tencBody.append(0x19)    // crypt 1, skip 9 - cbcs
            tencBody.append(0x01)    // default_isProtected
            tencBody.append(0x00)    // per-sample IV size: none
            tencBody.append(contentsOf: [UInt8](keyId))
            tencBody.append(0x10)    // constant IV size
            tencBody.append(contentsOf: [UInt8](repeating: 0, count: 16))
        }
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

    /// The default_KID a sinf's tenc names, if it has one.
    ///
    /// The read half of replacingKeyId below, walked the same way and
    /// with the same layout assumption: past the type, the version and
    /// flags, and the four bytes before the KID.
    static func keyIdentifier(inTenc sinf: Data) -> Data? {
        let bytes = [UInt8](sinf)
        let marker: [UInt8] = [0x74, 0x65, 0x6e, 0x63]  // "tenc"
        var typeAt = 0
        while typeAt + 4 <= bytes.count {
            if Array(bytes[typeAt..<(typeAt + 4)]) == marker {
                let kidAt = typeAt + 12
                guard kidAt + 16 <= bytes.count else {
                    return nil
                }
                return Data(bytes[kidAt..<(kidAt + 16)])
            }
            typeAt += 1
        }
        return nil
    }

    /// The sinf inside a specifier's initialisation data.
    ///
    /// The parser hands back {"sinf":["<base64>"]} - the same document
    /// sinfInitialisationJSON builds - so this is the read half of it.
    static func sinfFromSpecifierJSON(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let list = object["sinf"] as? [Any],
              let first = list.first as? String else {
            return nil
        }
        return Data(base64Encoded: first)
    }

    /// Bytes as hex, the way every other log line in this file spells
    /// them.
    static func hexBytes(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
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

    /// Hold a batched SPC, or hand back what should be sent now.
    ///
    /// ADDED - see mse_fix_84's docstring. Returns nil while a batch is
    /// still incomplete, the batched JSON under the page's own content
    /// id once the last challenge arrives, and the SPC unchanged for a
    /// session that is not batched at all.
    fileprivate func batchedMessage(sessionId: String, contentId: String,
                                    spc: Data) -> (String, Data)? {
        let staged = withState { () -> ([String], [Data], [String: Data])? in
            guard let entry = entries[sessionId],
                  entry.batchContentIds.count > 1 else {
                return nil
            }
            entry.batchSPCs[contentId] = spc
            return (entry.batchContentIds, entry.batchKeyIds, entry.batchSPCs)
        }
        guard let (ids, keys, held) = staged else {
            return (contentId, spc)
        }
        let missing = ids.filter { held[$0] == nil }
        guard missing.isEmpty else {
            Self.log("session \(sessionId) batch holding "
                     + "\(held.count) of \(ids.count) challenges - "
                     + "still waiting for \(missing.count)")
            return nil
        }
        var entriesJSON: [[String: String]] = []
        for (index, id) in ids.enumerated() {
            guard let payload = held[id], index < keys.count else {
                continue
            }
            entriesJSON.append([
                "keyID": keys[index].base64EncodedString(),
                "payload": payload.base64EncodedString(),
            ])
        }
        guard let document = try? JSONSerialization.data(
                withJSONObject: entriesJSON, options: []) else {
            Self.log("session \(sessionId) could not serialise the batched "
                     + "key message - sending the first challenge alone")
            return (ids[0], held[ids[0]] ?? spc)
        }
        withState { entries[sessionId]?.batchSPCs = [:] }
        Self.log("session \(sessionId) batched \(entriesJSON.count) "
                 + "challenges into \(document.count) bytes of JSON")
        return (ids[0], document)
    }

    /// The licences inside a batched response, in challenge order.
    ///
    /// ADDED - see mse_fix_84's docstring. Netflix labels each challenge
    /// with an index and sorts its RESPONSES by that label, so the label
    /// is the authority and array order is only the fallback. Nil when
    /// these bytes are not a batch at all, which is every response this
    /// path saw before now.
    fileprivate static func splitLicenceBatch(_ response: Data,
                                              expecting keyIds: [Data])
        -> [Data]? {
        guard let first = response.first,
              first == UInt8(ascii: "["), let parsed = try? JSONSerialization
                .jsonObject(with: response, options: []) else {
            // An object, which is the shape a server that wraps its
            // batch uses.
            guard let first = response.first, first == UInt8(ascii: "{"),
                  let object = try? JSONSerialization.jsonObject(
                    with: response, options: []) as? [String: Any] else {
                return nil
            }
            for name in ["RESPONSES", "responses", "CHALLENGES"] {
                if let list = object[name] as? [[String: Any]] {
                    return decodeLicenceEntries(list, expecting: keyIds)
                }
            }
            return nil
        }
        guard let list = parsed as? [[String: Any]] else {
            return nil
        }
        return decodeLicenceEntries(list, expecting: keyIds)
    }

    /// One base64 payload per entry, put back in challenge order.
    ///
    /// CHANGED - see mse_fix_86_match_the_licence_to_its_key.py's
    /// docstring. Array order was wrong and both licences were applied
    /// to each other's requests, which FairPlay reported as -11835
    /// "This content is not authorised" on BOTH keys at once.
    ///
    /// DHB is the authority. Netflix's own getDrmKeyMapping pairs
    /// responses to keys with
    ///
    ///     base64.decode(t.DHB).subarray(4, 12)
    ///     base64.decode(keyIds[n]).subarray(0, 8)
    ///
    /// so bytes 4..12 of DHB are the first eight bytes of the key id -
    /// and these ids are eight significant bytes followed by eight
    /// zeroes, so that is all of them. Exact, and immune to whatever
    /// order the server answers in.
    private static func decodeLicenceEntries(_ list: [[String: Any]],
                                             expecting keyIds: [Data])
        -> [Data]? {
        // What the entries look like, once, because nothing has ever
        // printed one and the ID labels are still unknown.
        if let first = list.first {
            let names = first.keys.sorted().joined(separator: " ")
            let label = (first["ID"] as? String) ?? (first["id"] as? String)
            log("licence batch entry 0 keys: " + names
                + ", ID=" + (label.map { "\"" + $0 + "\"" } ?? "absent"))
        }
        var payloads: [Data] = []
        var positions: [Int] = []
        var howMatched = "array order"
        // Which field did the matching, so a capture never has to guess
        // whether keyID or DHB was the one present.
        var matchedField = "keyID"
        var allByKey = !keyIds.isEmpty
        var allById = true
        for (index, item) in list.enumerated() {
            var payload: Data?
            for name in ["PAYLOAD", "payload", "CKC", "ckc", "DATA", "data"] {
                if let text = item[name] as? String,
                   let bytes = Data(base64Encoded: text), !bytes.isEmpty {
                    payload = bytes
                    break
                }
            }
            guard let payload else {
                return nil
            }
            payloads.append(payload)

            // 1. the key this entry answers.
            //
            // CHANGED - see mse_fix_88_the_answer_names_its_own_key.py's
            // docstring. The capture settled what the response looks
            // like:
            //
            //   licence batch entry 0 keys: keyID payload, ID=absent
            //
            // Netflix answers a batch by MIRRORING it - the same keyID
            // and payload the challenge carried - so the key each
            // licence belongs to is named outright and needs no
            // inference at all. Compared as sixteen bytes rather than as
            // text, because base64 of the same bytes is not guaranteed
            // to be the same string.
            var byKey: Int?
            for name in ["keyID", "keyId", "keyid", "KEYID"] {
                guard let text = item[name] as? String,
                      let raw = Data(base64Encoded: text), !raw.isEmpty else {
                    continue
                }
                for (slot, keyId) in keyIds.enumerated()
                where Array(keyId) == Array(raw) {
                    byKey = slot
                    matchedField = "keyID"
                    break
                }
                break
            }
            // DHB, for a packaging that names the key that way instead -
            // which is what getDrmKeyMapping in the same player reads,
            // bytes 4 through 12 being the key id's first eight.
            if byKey == nil {
                for name in ["DHB", "dhb"] {
                    guard let text = item[name] as? String,
                          let raw = Data(base64Encoded: text),
                          raw.count >= 12 else {
                        continue
                    }
                    let stamp = Array(raw)[4..<12]
                    for (slot, keyId) in keyIds.enumerated()
                    where keyId.count >= 8
                            && Array(keyId.prefix(8)) == Array(stamp) {
                        byKey = slot
                        matchedField = "DHB"
                        break
                    }
                    break
                }
            }
            if byKey == nil {
                allByKey = false
            }

            // 2. an ID that is a number.
            var byId: Int?
            if let text = (item["ID"] as? String) ?? (item["id"] as? String),
               let parsed = Int(text) {
                byId = parsed
            } else {
                allById = false
            }

            positions.append(byKey ?? byId ?? index)
        }
        guard !payloads.isEmpty else {
            return nil
        }
        if allByKey {
            howMatched = matchedField
        } else if allById {
            howMatched = "ID"
        } else {
            // A partial match orders nothing reliably - fall all the way
            // back rather than half-sort.
            positions = Array(0..<payloads.count)
        }
        log("licence batch: \(payloads.count) entries, matched by "
            + howMatched)
        let paired = zip(positions, payloads).sorted { $0.0 < $1.0 }
        return paired.map { $0.1 }
    }

    /// EVERY key the FairPlay pssh names, in the order it names them.
    ///
    /// ADDED - see mse_fix_84's docstring. Netflix's 200-byte box holds
    /// two fpsk boxes and its 344-byte box holds four; the picture is
    /// keyed to one of the ones this file used to skip. The single-key
    /// reader below is untouched and still answers with the first,
    /// which is what everything that names one key still wants.
    ///
    /// Deduplicated, because a packager repeating a key id would
    /// otherwise cost an extra request that can never be answered
    /// separately.
    static func keyIdentifiers(inPSSH data: Data) -> [Data] {
        let bytes = [UInt8](data)
        func be32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return -1 }
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        let pssh = Array("pssh".utf8)
        let fkri = Array("fkri".utf8)
        var found: [Data] = []
        var seen = Set<String>()
        var boxAt = 0
        while boxAt + 8 <= bytes.count {
            let size = be32(boxAt)
            guard size >= 8, boxAt + size <= bytes.count else { break }
            guard boxAt + 32 <= bytes.count,
                  Array(bytes[(boxAt + 4)..<(boxAt + 8)]) == pssh,
                  Array(bytes[(boxAt + 12)..<(boxAt + 28)])
                      == Self.fairPlaySystemId else {
                boxAt += size
                continue
            }
            var cursor = boxAt + 28
            if bytes[boxAt + 8] >= 1 {
                cursor += 4 + 16 * max(be32(cursor), 0)
            }
            // Past the payload's own length field.
            cursor += 4
            let end = boxAt + size
            // The same scan fkriKeyIdentifier does, continued past the
            // first hit instead of stopping at it. Layout from the type:
            // type 4, reserved 4, then the key id for 16.
            var typeAt = max(cursor, 0)
            while typeAt >= 0, typeAt + 4 <= end {
                if Array(bytes[typeAt..<(typeAt + 4)]) == fkri {
                    let kidAt = typeAt + 8
                    if kidAt + 16 <= end {
                        let kid = Data(bytes[kidAt..<(kidAt + 16)])
                        let hex = Self.hexBytes(kid)
                        if !seen.contains(hex) {
                            seen.insert(hex)
                            found.append(kid)
                        }
                    }
                    typeAt += 4
                    continue
                }
                typeAt += 1
            }
            boxAt += size
        }
        return found
    }

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

        // Every byte, once per distinct value, with the box tree
        // inside it.
        //
        // CHANGED - see mse_fix_76_show_the_whole_pssh.py's docstring.
        // The forty-byte head this replaces covers Apple's 104-byte box
        // and none of Netflix's 344-byte payload, which is where the
        // parse goes wrong and where nothing could be read.
        Self.log("init data \(bytes.count) bytes, box \(fourCC(4))")
        Self.dumpInitData(bytes)

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
                        Self.log("  v1 header key id "
                                 + kid.map { String(format: "%02x", $0) }
                                      .joined())
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
                    let guess = Data(bytes[cursor..<(cursor + 16)])
                    let hex = guess.map { String(format: "%02x", $0) }
                                   .joined()
                    // REVERTED - fix 76 refused a candidate with fewer
                    // than eight non-zero bytes, on the reading that
                    // Netflix's 0000000004c37d40... was a length field
                    // rather than an identifier. The box tree settled
                    // it the other way: the sibling fkai box holds
                    // those same sixteen bytes, and tv.apple.com's ids
                    // are literally 0, 1, 2 and 3. Sparse is what these
                    // ids look like, so the guard would have refused
                    // real ones.
                    Self.log("  no fkri - taking the payload's first "
                             + "16 bytes, " + hex)
                    return guess
                }
            }
            boxAt += size
        }

        if fallback != nil {
            Self.log("no FairPlay key id - falling back to another system's, "
                     + "which may not be the right key")
        } else {
            Self.log("no key id in this init data")
        }
        return fallback
    }

    /// The protection scheme the page's own PSSH declares, or nil.
    ///
    /// ADDED - see mse_fix_77_the_scheme_the_page_declares.py's
    /// docstring. fpsi's body is four reserved bytes and a
    /// four-character scheme type, and it is the one field that differs
    /// structurally between the two sites on this route:
    ///
    ///     tv.apple.com   fpsi = 00000000 63626373   "cbcs"
    ///     netflix.com    fpsi = 00000000 63656e63   "cenc"
    ///
    /// Scanned for within the FairPlay box's payload rather than walked
    /// through fpsd, for the same reason fkriKeyIdentifier scans: one
    /// field is wanted and the nesting has already varied between
    /// packagers.
    static func schemeType(inPSSH data: Data) -> String? {
        let bytes = [UInt8](data)
        func be32(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= bytes.count else { return -1 }
            return (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                 | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
        }
        let pssh = Array("pssh".utf8)
        let fpsi = Array("fpsi".utf8)
        var boxAt = 0
        while boxAt + 8 <= bytes.count {
            let size = be32(boxAt)
            guard size >= 8, boxAt + size <= bytes.count else { return nil }
            guard boxAt + 32 <= bytes.count,
                  Array(bytes[(boxAt + 4)..<(boxAt + 8)]) == pssh,
                  Array(bytes[(boxAt + 12)..<(boxAt + 28)])
                      == Self.fairPlaySystemId else {
                boxAt += size
                continue
            }
            var cursor = boxAt + 28
            if bytes[boxAt + 8] >= 1 {
                cursor += 4 + 16 * max(be32(cursor), 0)
            }
            // Past the payload's own length field.
            cursor += 4
            let end = boxAt + size
            var typeAt = max(cursor, 0)
            while typeAt >= 0, typeAt + 12 <= end {
                if Array(bytes[typeAt..<(typeAt + 4)]) == fpsi {
                    let scheme = String(bytes[(typeAt + 8)..<(typeAt + 12)]
                        .map { byte -> Character in
                            (byte >= 0x20 && byte <= 0x7e)
                                ? Character(UnicodeScalar(byte)) : "."
                        })
                    Self.log("  fpsi scheme " + scheme)
                    return scheme
                }
                typeAt += 1
            }
            return nil
        }
        return nil
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

    // MARK: - Init data, in full

    /// So one page's repeated init data does not print the same dump
    /// forty times, and a page that mints a fresh one per key still gets
    /// each of them.
    private static let dumpLock = NSLock()
    private static var dumpedInitData = Set<String>()

    /// Every byte of the initialisation data, once per distinct value.
    ///
    /// ADDED - see mse_fix_76_show_the_whole_pssh.py's docstring. The
    /// forty-byte head this replaces is enough for Apple's 104-byte box
    /// and not for Netflix's 344-byte one, where the scan comes back
    /// with 0000000004c37d40... - and from a head there is no telling
    /// whether it found the wrong box, the right box at the wrong
    /// offset, or no box at all. Those want three different fixes, so
    /// this prints the whole thing and the tree inside it.
    static func dumpInitData(_ bytes: [UInt8]) {
        let head = bytes.prefix(16).map { String(format: "%02x", $0) }
                        .joined()
        let tail = bytes.suffix(8).map { String(format: "%02x", $0) }
                        .joined()
        let key = "\(bytes.count):\(head):\(tail)"
        let isNew: Bool = {
            Self.dumpLock.lock()
            defer { Self.dumpLock.unlock() }
            // Bounded, because a page that mints init data per segment
            // must not become the capture.
            guard Self.dumpedInitData.count < 12,
                  !Self.dumpedInitData.contains(key) else {
                return false
            }
            Self.dumpedInitData.insert(key)
            return true
        }()
        guard isNew else { return }

        let shown = min(bytes.count, 1024)
        var at = 0
        while at < shown {
            let end = min(at + 16, shown)
            let hex = bytes[at..<end].map { String(format: "%02x", $0) }
                                     .joined(separator: " ")
            let text = String(bytes[at..<end].map { byte -> Character in
                (byte >= 0x20 && byte <= 0x7e)
                    ? Character(UnicodeScalar(byte)) : "."
            })
            // %lx, not %x: `at` is an Int and CVarArg passes it as
            // sixty-four bits.
            Self.log(String(format: "  %04lx  ", at)
                     + hex.padding(toLength: 47, withPad: " ", startingAt: 0)
                     + "  " + text)
            at = end
        }
        if bytes.count > shown {
            Self.log("  ... \(bytes.count - shown) more bytes")
        }
        Self.log("  box tree:")
        Self.dumpBoxTree(bytes, from: 0, to: bytes.count, depth: 1)
    }

    /// The MP4 box tree in [from, to), as far as it parses.
    ///
    /// Descends only where the children parse as a clean run, so it
    /// cannot invent structure inside a leaf that happens to begin with
    /// four printable bytes. pssh is special-cased: its children sit
    /// behind a header this has to step over, and the header is the part
    /// that says which DRM the box is for.
    static func dumpBoxTree(_ bytes: [UInt8], from: Int, to: Int,
                            depth: Int) {
        guard depth <= 6, from >= 0, to <= bytes.count else { return }
        let indent = String(repeating: "  ", count: depth + 1)
        var at = from
        while at + 8 <= to {
            let size = (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                     | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
            guard size >= 8, at + size <= to else { return }
            let type = String(bytes[(at + 4)..<(at + 8)]
                .map { byte -> Character in
                    (byte >= 0x20 && byte <= 0x7e)
                        ? Character(UnicodeScalar(byte)) : "."
                })
            let end = at + size
            var bodyAt = at + 8
            var note = ""
            if type == "pssh", at + 32 <= to {
                let version = bytes[at + 8]
                let systemId = Array(bytes[(at + 12)..<(at + 28)])
                note = " v\(version) system "
                     + systemId.map { String(format: "%02x", $0) }.joined()
                if systemId == Self.fairPlaySystemId {
                    note += " (FairPlay)"
                }
                bodyAt = at + 28
                if version >= 1, bodyAt + 4 <= to {
                    let count = (Int(bytes[bodyAt]) << 24)
                              | (Int(bytes[bodyAt + 1]) << 16)
                              | (Int(bytes[bodyAt + 2]) << 8)
                              | Int(bytes[bodyAt + 3])
                    // The key ids a v1 box names in its own header,
                    // which under Common Encryption is where the KID
                    // lives and is the one thing a foreign system's box
                    // can still tell us.
                    var kidAt = bodyAt + 4
                    var listed: [String] = []
                    var left = max(count, 0)
                    while left > 0, kidAt + 16 <= to {
                        listed.append(bytes[kidAt..<(kidAt + 16)]
                            .map { String(format: "%02x", $0) }.joined())
                        kidAt += 16
                        left -= 1
                    }
                    if !listed.isEmpty {
                        note += " kids " + listed.joined(separator: ",")
                    }
                    bodyAt += 4 + 16 * max(count, 0)
                }
                // The payload's own length field, which is not part of
                // the payload.
                bodyAt += 4
            }
            Self.log(indent + String(format: "+%04lx ", at)
                     + "\(size) '\(type)'" + note)
            guard bodyAt < end, bodyAt >= 0 else {
                at = end
                continue
            }
            if Self.parsesAsBoxes(bytes, from: bodyAt, to: end) {
                Self.dumpBoxTree(bytes, from: bodyAt, to: end,
                                 depth: depth + 1)
            } else {
                let stop = min(bodyAt + 48, end)
                Self.log(indent + "  = "
                         + bytes[bodyAt..<stop]
                             .map { String(format: "%02x", $0) }.joined()
                         + (stop < end ? " ..." : ""))
            }
            at = end
        }
    }

    /// Whether [from, to) is a clean run of MP4 boxes ending exactly on
    /// `to`.
    ///
    /// Stricter than looksLikeBox below on the type - alphanumeric
    /// rather than any printable byte - because this decides whether to
    /// RECURSE, and a wrong yes here prints a tree that is not there.
    static func parsesAsBoxes(_ bytes: [UInt8], from: Int,
                              to: Int) -> Bool {
        guard from >= 0, to <= bytes.count, to - from >= 8 else {
            return false
        }
        var at = from
        var seen = 0
        while at + 8 <= to {
            let size = (Int(bytes[at]) << 24) | (Int(bytes[at + 1]) << 16)
                     | (Int(bytes[at + 2]) << 8) | Int(bytes[at + 3])
            guard size >= 8, at + size <= to else { return false }
            let named = bytes[(at + 4)..<(at + 8)].allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x41 && $0 <= 0x5a)
                    || ($0 >= 0x30 && $0 <= 0x39)
            }
            guard named else { return false }
            at += size
            seen += 1
        }
        return at == to && seen > 0
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
        /// The media element this SourceBuffer belongs to.
        ///
        /// ADDED - see mse_fix_101's docstring. Zero until the owner
        /// message arrives, which reads as "unknown" and falls back to
        /// the session-wide state - the behaviour this had before there
        /// was an owner at all.
        var owner: UInt64 = 0
        /// What the page adds to this buffer's stamps to place it on the
        /// element's timeline.
        ///
        /// ADDED - see mse_fix_103's docstring. tv.apple.com splices the
        /// feature onto the end of its own pre-roll by walking this from
        /// -1.99 to 32.08 on the SAME SourceBuffer, and without it this
        /// route played the film's soundtrack at element time ten -
        /// under the trailer.
        var timestampOffset: Double = 0
        let parser: NSObject
        let recipient: AVContentKeyRecipient
        let delegate: ParserDelegate
        /// AVFoundation says a failed parser cannot recover - "create a
        /// new AVStreamDataParser to try again" - so this marks one for
        /// replacement rather than pretending it still works.
        var failed = false
        /// The last initialisation segment this stream was given.
        ///
        /// ADDED - see mse_fix_159's docstring. A replacement parser
        /// has never seen a moov, and media without one cannot be
        /// parsed - so the rebuild that already existed here could not
        /// work until there was something to bring the new parser up to
        /// state with.
        var initSegment: Data?
        /// The last sign of life from this stream's parser, and how
        /// many media segments have gone in since.
        ///
        /// ADDED - see mse_fix_159's docstring. Stamped when the parser
        /// is built and again on every didProvideMediaData, so silence
        /// is measurable without a delegate that never fires.
        var lastMediaDataAt = 0.0
        var appendsSinceMediaData = 0
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
        /// Fragments withheld from the parser because the display queue
        /// is already full enough.
        ///
        /// ADDED - see mse_fix_100's docstring. Fix 98 tried to throttle
        /// the parser with setShouldProvideMediaData:forTrackID:, which
        /// needs a track id, and trackIDs is empty in every capture
        /// there has ever been - didParseStreamDataAsAsset has never
        /// fired. So the hold printed a line and did nothing, and the
        /// queue went on overflowing twenty-three times in one capture.
        ///
        /// These are OUR bytes, held on OUR side. Nothing can decline
        /// them, discard them or ignore them, which is the whole reason
        /// the back pressure moved here.
        ///
        /// STAMPED - see mse_fix_133's docstring. A fragment is bytes
        /// and nothing else until the parser reads it, so on its own it
        /// cannot say whether it belongs to the media the element is
        /// playing now. In capture d655146f thirty-two fragments of a
        /// 4481-second timeline sat here across a swap to a 2494-second
        /// one and were appended eighty-six seconds later, and every
        /// sample fed after that was 1944 seconds ahead of the clock.
        struct HeldFragment {
            let bytes: Data
            /// Where the media was when the back pressure took these.
            let at: Double
        }
        var heldSegments: [HeldFragment] = []
        var heldFragments = 0
        /// Has the parser been told to stop providing media data?
        ///
        /// ADDED - see mse_fix_98's docstring. The parser hands over a
        /// whole appended segment at once and the page buffers as far
        /// ahead as it likes, so the producer is faster than the sink
        /// by whatever factor it feels like - fifty-seven seconds of
        /// lookahead against a thirty-seven second queue, in the
        /// capture this came from. A bigger bin does not fix that; not
        /// asking for the data does.
        var mediaDataHeld = false
        /// Whether a held fragment is already on its way to the parser.
        ///
        /// ADDED - see mse_fix_132's docstring. releaseMediaDataIfDrained
        /// decides on the drain queue and appends on the main queue, and
        /// it is called once per sample the layer takes. In capture
        /// ee663d06 sixteen of those decisions were taken before the
        /// first of them landed: the live-depth column fix 105 added
        /// reads 120, 234, 336, 458, 522, 617, 740, 862 and then 900
        /// eight times, against a captured depth of 115-120 on every
        /// one. Forty-eight seconds of media went into a queue that
        /// holds thirty-seven and the rest was destroyed.
        ///
        /// One in flight at a time, which is what the "one fragment per
        /// call rather than the lot" comment beside the dispatch has
        /// always claimed to do.
        var releaseInFlight = false
        /// Samples thrown away since the needsSyncSample gate closed.
        ///
        /// The overflow counter could not see these: the gate returns
        /// before it is touched, so one overflow was reported and eight
        /// more in the same window were silent.
        var droppedSinceSync = 0
        /// Segments refused because the bin was already twice its cap.
        ///
        /// ADDED - see mse_fix_134's docstring. Never a reorder: the
        /// page's bytes go into the parser in order or not at all.
        var binRefused = 0
        /// Samples refused for being unreachably ahead of the media.
        ///
        /// ADDED - see mse_fix_133's docstring.
        var aheadDropped = 0
        /// The first and last PTS thrown away since the gate closed.
        ///
        /// ADDED - see mse_fix_132's docstring. A count says nothing
        /// about a hole. Capture ee663d06 reports "63 samples lost
        /// waiting for it" sixteen times running and never once says
        /// that between them they are forty-eight seconds of the film,
        /// which is the only number that identifies the fault.
        var droppedSinceSyncFrom = Double.nan
        var droppedSinceSyncTo = Double.nan
        /// Which call installed the timebase this stream's layer is on.
        ///
        /// ADDED - see mse_fix_105's docstring. On tv.apple.com a layer
        /// pointer that did not change read 2328.149 and then, with no
        /// write from this file in between, 2359.051 - and that step is
        /// 80.3% of the site's measured A/V error. Either the layer is
        /// on a different timebase from the one that was installed, or
        /// something outside this file is writing it. The drift line
        /// could not tell those apart because it named neither.
        var timebaseFrom = "unset"
        /// requestMediaDataWhenReady calls its block in a loop while the
        /// layer is hungry, so it is stopped when the queue empties and
        /// re-armed when something arrives. Otherwise it spins.
        var drainArmed = false
        /// When drainPending last actually ran for this stream.
        ///
        /// ADDED - see mse_fix_178's docstring. drainArmed says a
        /// callback is BELIEVED to be installed; this says whether one
        /// ever arrived. The difference between those two is the
        /// deadlock in capture ccce0736.
        var lastDrainAt: Double = 0
        /// When the stall was last reported, so it is said once and then
        /// rarely rather than at the page's append rate.
        var stallSaidAt: Double = 0
        /// How many times the feed has been held off for this stream.
        ///
        /// ADDED - see mse_fix_114's docstring. Said on the first and
        /// then rarely: pacing is the normal state of a healthy stream
        /// and a line per stop would be a line per second.
        var pacedStops = 0
        /// Host time until which the feed is deliberately held off.
        ///
        /// ADDED - see mse_fix_117's docstring. Without it every append
        /// re-arms the drain, which walks straight back into the hold it
        /// just took: capture e10b8c17 has six hundred holds in thirty
        /// seconds, each one a stopRequestingMediaData and a
        /// requestMediaDataWhenReady on a layer that is presenting.
        var holdUntil: Double = 0
        /// When the current hold began and how long it meant to last.
        ///
        /// ADDED - see mse_fix_129's docstring. A hold at a lead of
        /// 8.29s, whose sleep is capped at two seconds, produced a
        /// twenty-three second stall in capture c7528ff8 - and nothing
        /// in the log says a hold ever ended, only that one began.
        var holdStartedAt: Double = 0
        var holdIntended: Double = 0
        var failObserver: NSObjectProtocol?
        var drainQueue: DispatchQueue?
        /// The independent decode probe - see runDecodeProbe.
        var probeSession: VTDecompressionSession?
        var probeIn = 0
        var probeOut = 0
        /// So the "these are protected, the probe cannot help" note is
        /// made once rather than 360 times.
        var probeSkippedLogged = false
        /// Has this stream already said its samples could not be shifted?
        ///
        /// ADDED while applying fix 103. It reused probeSkippedLogged,
        /// which the decode-probe message already owns - and unlike the
        /// stand-down flags those two are NOT mutually exclusive: a
        /// protected stream can both fail to shift and skip the probe,
        /// and whichever spoke first would silence the other.
        var shiftFailedLogged = false
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
        /// Has this stream already said it is not ours to render? See
        /// standDown.
        var standDownLogged = false
        /// Did an initialisation segment for this stream carry a sinf?
        ///
        /// ADDED - see mse_fix_82_a_decrypted_sample_is_still_ours.py's
        /// docstring. This is the question the stand-down rule actually
        /// needs answered. isProtectedSample asks whether the bytes are
        /// ciphertext NOW, which under cenc they are not - the parser
        /// decrypts a cenc track completely and hands back plain avc1.
        /// Whether GECKO can render them is decided by whether the track
        /// was encrypted when the page appended it, and a protected
        /// track says so in its init segment.
        var trackIsProtected = false
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
        /// Samples refused because the media had moved on without them.
        ///
        /// ADDED - see mse_fix_106's docstring. In capture 8ec30c6a the
        /// queue held media at 954, 2015, 2370 and 3461 at the same
        /// time while the timebase sat correctly at 3428.
        var strandedDropped = 0
        /// Samples already queued when the media moved, dropped with it.
        var strandedPruned = 0
        /// Has this stream already said its queue went stale?
        var strandedReported = false
        /// Has this stream already refused a correction onto stale media?
        var reportedStaleQueue = false
        /// The samples taken in since the last sync sample.
        ///
        /// Kept so that a new sink can be started without waiting for
        /// the next keyframe: these are exactly the samples it needs to
        /// decode the picture that is on screen right now, and they have
        /// already been handed to the layer being replaced. Cleared on
        /// every sync sample, so it holds one GOP and no more.
        var currentGOP: [CMSampleBuffer] = []
        /// The last frame counts read from the layer.
        ///
        /// ADDED - see mse_fix_120's docstring. Totals answer nothing on
        /// their own; the deltas between two readings are what say
        /// whether the picture moved.
        var lastShown: Int = -1
        var lastDropped: Int = -1
        /// Which layer those counts belong to, and how much has been
        /// enqueued into it.
        ///
        /// ADDED - see mse_fix_125's docstring. The metrics belong to
        /// the layer and the enqueue counter belongs to the stream, and
        /// reading one against the other while the layer is replaced
        /// several times a minute produced a line that looked like a
        /// dead picture and was not.
        var metricsLayer: ObjectIdentifier?
        var enqueuedIntoLayer = 0
        /// The GOP before that one.
        ///
        /// ADDED - see mse_fix_110's docstring. One GOP only covers a
        /// handover that happens while the display queue is nearly
        /// empty. In capture 7a522e97 seven of eleven adoptions carried
        /// NOTHING, every one of them with a queue deeper than a GOP -
        /// held 183, 220, 241, 285, 342, 372 - and each left its new
        /// layer with one to five seconds between its clock and the
        /// first frame it was given, which is one to five seconds of
        /// black.
        ///
        /// Two GOPs, not a window of seconds: the bound stays the same
        /// shape as currentGOP's and the memory stays compressed
        /// samples this file was holding anyway a moment earlier.
        var previousGOP: [CMSampleBuffer] = []
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
        /// Consecutive drift lines with the sound behind the picture,
        /// and when it was last put back.
        ///
        /// ADDED - see mse_fix_148's docstring. Two in a row, because
        /// the av column spikes for one line after a handover while the
        /// drain still reads the old timebase.
        var audioLagSeen = 0
        var audioLagFixedAt = Double.nan
        /// Forward steps in intake PTS big enough to be missing media.
        ///
        /// ADDED - see mse_fix_137's docstring.
        var intakeHoles = 0
        /// After a flush or a drop, nothing is fed until a sync sample: a
        /// display layer handed a mid-GOP frame has no reference to
        /// decode from.
        var needsSyncSample = false
        var flushes = 0
        /// When this stream last flushed a FAILED display layer, and how
        /// many times it has had to.
        ///
        /// ADDED - see mse_fix_157's docstring. Zero rather than a
        /// sentinel: hostNow is a mach uptime in the tens of thousands,
        /// so the first check is always outside the gap.
        var lastFailRecoveryAt = 0.0
        var failRecoveries = 0
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
        /// Host time of the last sample the renderer actually took.
        ///
        /// ADDED - see mse_fix_135's docstring. The difference between
        /// "armed" and "working": in capture 6db1f5c7 audioDrainArmed
        /// was true for the last forty-two seconds of the stream while
        /// the renderer sat ready with ninety-four samples queued
        /// behind it and took none of them.
        var audioFedAt = Double.nan
        var audioEnqueued = 0
        var audioSeen = 0
        var audioFlushes = 0
        /// Said once - see mse_fix_136's docstring. The audio twin of
        /// standDownLogged.
        var audioStandDownLogged = false
        /// Said once - see mse_fix_136's docstring.
        var audioHorizonLogged = false
        var audioLastReport = ""
        /// When the audio renderer was last flushed out of .failed.
        ///
        /// ADDED - see mse_fix_180's docstring. Its own counters rather
        /// than the video ones: "the picture recovered" and "the sound
        /// recovered" are different facts and reading one as the other
        /// is how a8bc28b1 would have been misread.
        var audioLastFailRecoveryAt = 0.0
        /// How many times that has been needed.
        var audioFailRecoveries = 0
        /// Has the synchronizer been given a rate? Nothing is fed before
        /// it has, for fix 26's reason: a renderer clocked at a time the
        /// samples have already passed discards all of them and reports
        /// no error.
        var audioStarted = false
        var lastAudioIntakePTS = Double.nan
        var audioFlushObserver: NSObjectProtocol?
        /// Host time of the last APPEND from the page.
        ///
        /// ADDED - see mse_fix_95's docstring. lastSampleAt is when the
        /// PARSER last handed something over, which is a different
        /// question: AVStreamDataParser holds what it has been given and
        /// delivers it as the sink asks, so a stream the page abandoned
        /// keeps producing samples for as long as its buffer lasts. In
        /// the capture that produced this fix, tv.apple.com destroyed
        /// its hls.js player - both SourceBuffers removed, both key
        /// sessions closed - and the display layer belonging to it was
        /// still being fed seventeen thousand log lines later, from
        /// eighteen fragments appended before the teardown.
        ///
        /// The page's own last word is the only thing that says whether
        /// a stream is still wanted.
        var lastAppendAt: Double = 0
        /// The stream that took this one's place, if any.
        ///
        /// A superseded stream is PARKED rather than destroyed: clocks
        /// stopped, renderer muted, queue dropped, nothing more fed -
        /// and an append revives it. Destroying it outright would be a
        /// guess about a page that legitimately holds two audio
        /// SourceBuffers at once; parking one that is still wanted
        /// costs a segment of latency and nothing else.
        var supersededBy: String?

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
        // AND STARVED COUNTS AS FAILED - see mse_fix_159's docstring.
        //
        // The didFailToParseStreamDataWithError: delegate has never
        // fired: capture 50625b25 has 244 "Ignoring appendStreamData:
        // because we're failed or expired" from AVFoundation and zero
        // "parse FAILED" from this file. The parser dies without
        // telling anyone, so the only way to know is that it stopped
        // answering.
        var carriedInit: Data?
        if let existing = slot,
           existing.failed || Self.parserHasStopped(existing) {
            let why = existing.failed
                ? "reported a parse failure"
                : "stopped answering - \(existing.appendsSinceMediaData) "
                    + "segments in and nothing back for "
                    + "\(Self.hostNow() - existing.lastMediaDataAt)s"
            Self.log("stream \(stream) parser \(why) - building a new one")
            carriedInit = withState { existing.initSegment }
            entry.keySession.removeContentKeyRecipient(existing.recipient)
            withState { streamParsers[key] = nil }
            slot = nil
        }
        if slot == nil {
            guard let built = Self.buildParser(sessionId: sessionId,
                                               stream: stream) else {
                return false
            }
            Self.addRecipient(entry.keySession, recipient: built.recipient,
                              label: "stream \(stream) parser")
            withState { streamParsers[key] = built }
            // Any owner that arrived before this moment - see
            // mse_fix_104's docstring.
            adoptPendingOwner(key)
            Self.log("stream \(stream) parser built and added to the key "
                     + "session - recipients "
                     + "\(entry.keySession.contentKeyRecipients.count)")
            // UP TO STATE BEFORE ANYTHING ELSE - see mse_fix_159's
            // docstring. A fresh parser has never seen a moov, and the
            // segment that provoked this rebuild is media. Without this
            // the replacement fails on its first append exactly as the
            // one it replaced did.
            if let carriedInit {
                let replay = NSSelectorFromString("appendStreamData:")
                if built.parser.responds(to: replay) {
                    built.parser.perform(replay, with: carriedInit)
                    withState { built.initSegment = carriedInit }
                    Self.log("stream \(stream) replayed its "
                             + "\(carriedInit.count)-byte init segment into "
                             + "the new parser")
                } else {
                    Self.log("stream \(stream) has an init segment to "
                             + "replay and no appendStreamData: to replay it "
                             + "with - the new parser starts blind")
                }
            }
            // Sign of life starts now, so a parser that dies before it
            // ever produces is still caught.
            withState { built.lastMediaDataAt = Self.hostNow() }
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
        // BACK PRESSURE, ON THE BYTES.
        //
        // ADDED - see mse_fix_100's docstring. The parser delivers what
        // it parses, immediately, and no switch this file can reach
        // stops it: fix 98's setShouldProvideMediaData: needs a track id
        // and trackIDs has been empty in every capture. So the throttle
        // is here, on data we still own.
        //
        // An INIT SEGMENT is never held. ftyp and moov have to reach the
        // parser before any media does, they are small, and holding one
        // would fail the stream rather than pace it.
        // WHAT ACTUALLY GOES TO THE PARSER - see mse_fix_134's
        // docstring. Not always the segment that just arrived: when the
        // bin has older bytes in it, the oldest of those goes instead
        // and this one takes its place at the back.
        // KEPT FOR THE REPLACEMENT - see mse_fix_159's docstring.
        if Self.isInitSegment(segment) {
            withState { streamParsers[key]?.initSegment = segment }
        }
        var outgoing = segment
        var sentFromTheBin = false
        if !Self.isInitSegment(segment) {
            // BEFORE the lock, because mediaAuthority takes it - see
            // mse_fix_133's docstring. NaN when the element has not
            // said where it is, which a sweep reads as "cannot tell"
            // and keeps.
            let heldAt = mediaAuthority(key) ?? Double.nan
            let verdict = withState { () -> (hold: Bool, depth: Int,
                                             held: Int, forced: Bool,
                                             instead: Data?,
                                             refused: Bool) in
                let depth = slot.pending.count
                // IN THE ORDER THE PAGE WROTE THEM - see mse_fix_134's
                // docstring. The depth test on its own let a segment
                // walk past everything already waiting whenever the
                // queue happened to be shallow when it arrived. In
                // capture e19d2555 twelve segments sat in the bin from
                // 59971.5 while 7228242 - the one AFTER the newest of
                // them - went straight in at 59986.633, and the queue
                // head stepped from 2599.26 to 2646.14 with forty-five
                // seconds of the film unreachable behind it.
                //
                // appendStreamData: is a stream. A stream has an order.
                //
                // AND NOT WHILE ONE IS IN THE AIR - fix 132's flag,
                // which the turnover below already respects. The bin
                // reads empty from the moment
                // releaseMediaDataIfDrained pops the last fragment on
                // the drain queue until its main-queue block appends
                // it, and an append taken during that window would go
                // in front of bytes the page wrote first.
                if depth < Self.mediaDataHighWater,
                   slot.heldSegments.isEmpty, !slot.releaseInFlight {
                    return (hold: false, depth: depth, held: 0,
                            forced: false, instead: nil, refused: false)
                }
                // A HARD CEILING regardless. `forced` below cannot fire
                // while a release from the drain queue is in flight,
                // and a run of appends on the main queue can outrun that
                // flag being cleared - these fragments are five to nine
                // megabytes each, so a bin that grows unchecked is an
                // out-of-memory rather than a stall. Past twice the cap
                // the NEWEST bytes are refused: an ordered hole that the
                // next sync sample closes, and never an out-of-order
                // stream.
                //
                // EITHER ceiling. A fragment's size is the page's
                // choice, so sixty-four of them is not a number of
                // bytes; heldByteRefuse is.
                let heldBytes = Self.heldByteTotal(slot.heldSegments)
                if slot.heldSegments.count >= Self.heldFragmentCap * 2
                    || heldBytes + segment.count > Self.heldByteRefuse {
                    slot.needsSyncSample = true
                    slot.binRefused += 1
                    return (hold: true, depth: depth,
                            held: slot.heldSegments.count, forced: false,
                            instead: nil, refused: true)
                }
                slot.heldSegments.append(
                    StreamParser.HeldFragment(bytes: segment, at: heldAt))
                slot.heldFragments += 1
                // Bounded, and the cap no longer reorders either: it
                // used to put the NEWEST segment in, which is the same
                // overtake with a log line in front of it.
                //
                // heldBytes was read before this fragment went in, so
                // the bin's total now is that plus its size.
                let forced = slot.heldSegments.count > Self.heldFragmentCap
                    || heldBytes + segment.count > Self.heldByteCap
                // Not while one is already on its way from the drain
                // queue - fix 132's flag. That fragment came off the
                // front and lands on the main queue after this call, so
                // sending another now would put them in backwards.
                if !slot.releaseInFlight,
                   forced || depth < Self.mediaDataHighWater {
                    let next = slot.heldSegments.removeFirst().bytes
                    return (hold: false, depth: depth,
                            held: slot.heldSegments.count, forced: forced,
                            instead: next, refused: false)
                }
                return (hold: true, depth: depth,
                        held: slot.heldSegments.count, forced: false,
                        instead: nil, refused: false)
            }
            // One in, one out - see mse_fix_134's docstring. The bin
            // turns over at the page's own append rate rather than
            // waiting on the drain queue to reach its low water.
            if let instead = verdict.instead {
                outgoing = instead
                sentFromTheBin = true
            }
            if verdict.refused {
                let nth = withState { slot.binRefused }
                if nth == 1 || nth % 50 == 0 {
                    Self.log("stream \(stream) REFUSED the page's bytes - "
                             + "\(verdict.held) fragments already held with "
                             + "\(verdict.depth) samples queued, past the "
                             + "cap. Refused \(nth) so far. The layer has "
                             + "stopped draining; this is a hole, not a "
                             + "reorder.")
                }
                withState { slot.lastAppendAt = Self.hostNow() }
                reapSuperseded(sessionId: sessionId)
                // ADDED - see mse_fix_178's docstring. Both of the
                // bin's non-appending exits reach this - the hold and
                // the refusal - and both mean the same thing: the queue
                // this is waiting on is not moving. In capture ccce0736
                // nothing moved it, and this return was taken for every
                // video segment for the rest of the session.
                nudgeStalledDrain(streamKey: key)
                return true
            }
            if verdict.forced {
                Self.log("stream \(stream) held bin cap reached "
                         + "(\(Self.heldFragmentCap) fragments or "
                         + "\(Self.heldByteCap >> 20)MB) with "
                         + "\(verdict.depth) "
                         + "samples still queued - sending the OLDEST held "
                         + "fragment anyway. The layer is not draining and "
                         + "the cap is the only thing between that and "
                         + "unbounded memory. \(verdict.held) still held.")
            } else if verdict.hold {
                if verdict.held == 1 {
                    Self.log("stream \(stream) HOLDING the parser - "
                             + "\(verdict.depth) samples already queued, "
                             + "\(verdict.held) fragments held. The bytes "
                             + "wait here until the layer drains to "
                             + "\(Self.mediaDataLowWater).")
                }
                // The PAGE appended, even though the parser has not been
                // given it yet - ADDED while applying fix 100. Holding is
                // our decision, not the page going quiet, and
                // lastAppendAt is fix 95's liveness signal: the stamp and
                // the reap below this early return would otherwise be
                // skipped for every held fragment.
                withState { slot.lastAppendAt = Self.hostNow() }
                reapSuperseded(sessionId: sessionId)
                // ADDED - see mse_fix_178's docstring. Both of the
                // bin's non-appending exits reach this - the hold and
                // the refusal - and both mean the same thing: the queue
                // this is waiting on is not moving. In capture ccce0736
                // nothing moved it, and this return was taken for every
                // video segment for the rest of the session.
                nudgeStalledDrain(streamKey: key)
                return true
            }
        }
        slot.parser.perform(append, with: outgoing)
        // COUNTED, SO SILENCE IS MEASURABLE - see mse_fix_159's
        // docstring. Init segments are not counted: they produce an
        // asset, not media data, so counting them would make every
        // period boundary look like a stall.
        if !Self.isInitSegment(outgoing) {
            withState { slot.appendsSinceMediaData += 1 }
        }
        // Keep the sinf the page's OWN init segment carries.
        //
        // The other harvest, in append(_:initSegment:), is on the
        // SESSION entry point, and that one only ever receives EME
        // initialisation data. For tv.apple.com that is a cenc pssh,
        // which has no sinf in it, so every key request went out
        // against canonicalSinf's fabricated tenc carrying the fkri
        // index - and the qavc samples, which name the media's real
        // default_KID, were then refused at both sinks with -11800
        // "no content key present". Real init segments arrive here.
        //
        // Bounded twice over: only while no template is held, and only
        // for segments small enough to BE an init segment. The media
        // segments on this route run to 8 MB and a byte scan of every
        // one of them would cost more than this is worth.
        // CHANGED - see mse_fix_82's docstring. The scan is no longer
        // gated on the session having no template: that gate meant the
        // SECOND stream of a session never scanned at all, and each
        // stream has to know about its own track. The template half is
        // still session-wide and still taken only once.
        if segment.count <= 65536, let sinf = Self.sinfBox(in: segment) {
            let firstForStream = withState { () -> Bool in
                guard !slot.trackIsProtected else { return false }
                slot.trackIsProtected = true
                return true
            }
            if firstForStream {
                Self.log("stream \(stream) is a PROTECTED track - a sinf in "
                         + "its init segment, so this route renders it even "
                         + "when the parser hands back clear bytes")
            }
            if withState({ entry.templateSinf == nil }) {
                let harvested = Self.keyIdentifier(inTenc: sinf)
                withState { entry.templateSinf = sinf }
                Self.log("stream \(stream) kept a \(sinf.count)-byte sinf "
                         + "as the key request template - tenc KID "
                         + (harvested.map { Self.hexBytes($0) } ?? "absent"))
            }
        }
        // ADDED - see mse_fix_95's docstring. This is the liveness
        // signal the file did not have. Everything else it knows about
        // a stream comes from the parser, and the parser goes on
        // talking about a stream the page has finished with.
        let revivedBy = withState { () -> String? in
            slot.lastAppendAt = Self.hostNow()
            guard let who = slot.supersededBy else { return nil }
            slot.supersededBy = nil
            return who
        }
        if let revivedBy {
            Self.log("stream \(key) was appended to again - it is NOT the "
                     + "abandoned half of \(revivedBy) after all, so it is "
                     + "unparked. If this line appears on a site that "
                     + "plays one video at a time, the supersede rule is "
                     + "wrong for it.")
            unpark(streamKey: key)
        }
        reapSuperseded(sessionId: sessionId)
        // OUTGOING, not segment - see mse_fix_134's docstring. This
        // line is the only record of what appendStreamData: was given,
        // and comparing it against the content process's forwarding log
        // is what found the reordering. It has to describe the bytes
        // that actually went in.
        var whichBytes = ""
        if sentFromTheBin {
            whichBytes = " from the bin, in place of the "
                + "\(segment.count) just in"
        }
        Self.log("stream \(stream) appended \(outgoing.count) bytes"
                 + whichBytes)
        // Asked for again after EVERY append, not once when the licence
        // landed. setShouldProvideMediaData is armed per track and
        // providePendingMediaData drains what is pending NOW - fragments
        // that arrive later were simply never asked for, which is why
        // eight forwarded fragments produced one sample.
        // CHANGED - see mse_fix_98's docstring. This armed the tracks and
        // drained on every append unconditionally, which is what let a
        // parser fifty-seven seconds ahead of the picture keep pushing
        // into a queue that could hold thirty-seven.
        pumpMediaData(slot: slot, label: stream)
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

    // ==================================================================
    // BACK PRESSURE
    //
    // ADDED - see mse_fix_98's docstring. AVStreamDataParser delivers a
    // whole appended segment the moment it has parsed it, and the page
    // decides how far ahead it appends. In the capture this came from
    // the parser was handing over pts 5544 while the display layer's
    // timebase was at 5487 - fifty-seven seconds of lookahead against a
    // nine-hundred sample queue, which is thirty-seven. The excess went
    // in the bin, each drop closed the needsSyncSample gate, and the
    // next two seconds went with it. Nine times in ninety seconds.
    //
    // No queue size fixes that, because how far the page buffers is not
    // ours to choose. setShouldProvideMediaData:forTrackID: is the
    // parser's own back-pressure switch and this file has only ever
    // called it with YES.
    // ==================================================================

    /// How deep the display queue may get before the parser is told to
    /// stop, and how far it must drain before it is asked again.
    ///
    /// 300 is roughly twelve seconds at 24fps, which is more than one
    /// appended segment, so an ordinary append never trips it. 120 is
    /// five seconds - enough that the release has time to arrive before
    /// the layer runs dry.
    /// How many already-fed samples to keep for the next handover.
    ///
    /// ADDED - see mse_fix_111's docstring. The compositor replaces the
    /// video layer every six to thirteen seconds on these sites, and
    /// the replacement can only paint if it is given a keyframe at or
    /// before the clock it inherits. In capture 5f8a8ea2 the furthest
    /// back that was needed was 11.2 seconds; 400 samples is about
    /// sixteen at 24fps.
    fileprivate static let keepBackSamples = 400

    /// How far past the layer's clock the queue may be fed.
    ///
    /// ADDED - see mse_fix_114's docstring. drainPending has always run
    /// `while layer.isReadyForMoreMediaData`, and that layer stays ready
    /// long enough to swallow the whole queue: capture 16467831 has it
    /// taking thirty-seven seconds of media in five seconds of wall
    /// time, at up to 140,000 frames per second. Five seconds after
    /// that the compositor replaced the layer and all of it went with
    /// it, which is why the picture lasted five to seven seconds.
    ///
    /// Three seconds. The one healthy window in that capture ran at a
    /// lead of 1.1 to 1.9s, so three is comfortably above what playback
    /// needs and an order of magnitude below what it was doing.
    fileprivate static let feedAhead: Double = 3.0

    fileprivate static let mediaDataHighWater = 300
    fileprivate static let mediaDataLowWater = 120

    /// Turn the parser's push on or off for every track of one stream.
    ///
    /// Same shape as drainMediaData's arming loop, guarded the same way
    /// and for the same reason: this is SPI that raises rather than
    /// returning an error, and it has already aborted the app once from
    /// a track that did not exist yet.
    private static func setProvideMediaData(_ parser: NSObject,
                                            tracks: [Int32], on: Bool,
                                            label: String) {
        guard !tracks.isEmpty else { return }
        let shouldProvide =
            NSSelectorFromString("setShouldProvideMediaData:forTrackID:")
        guard parser.responds(to: shouldProvide),
              let implementation = parser.method(for: shouldProvide) else {
            return
        }
        typealias ProvideFunction =
            @convention(c) (AnyObject, Selector, Bool, Int32) -> Void
        let call = unsafeBitCast(implementation, to: ProvideFunction.self)
        for trackID in tracks {
            if let failure = GeckoRuntimeBridge.catchException(from: {
                call(parser, shouldProvide, on, trackID)
            }) {
                log("stream \(label) refused "
                    + (on ? "arming" : "holding") + " track \(trackID): "
                    + failure)
            }
        }
    }

    /// Ask for more, or ask for nothing, depending on how deep the queue
    /// already is. Called from append, which is where new data enters.
    fileprivate func pumpMediaData(slot: StreamParser, label: String) {
        // ONE BACK PRESSURE, NOT TWO - see mse_fix_137's docstring.
        //
        // This used to answer a deep queue with
        // setShouldProvideMediaData:NO, and the comment beside this
        // file's own re-arm says what that costs: "providePendingMediaData
        // drains what is pending NOW - fragments that arrive later were
        // simply never asked for, which is why eight forwarded fragments
        // produced one sample". Media goes into the parser and does not
        // come out.
        //
        // The back pressure moved to the bytes in fix 100 and was
        // finished in 132 and 134. It never moved AWAY from here, so
        // both were live, and in capture 42d770ba this one fired six
        // times - 314 samples queued, 360, 361, 357, 380, 325 - beside a
        // picture that stopped for four to six seconds every eight, with
        // the page's own buffered range contiguous across every one of
        // them and 134's append order exact.
        //
        // Removing it cannot unbound the queue. A segment only reaches
        // the parser when the queue is under this high water or the bin
        // turns one over for it, so the worst case is one fragment on
        // top of 299 - about a hundred samples against a cap of 900.
        //
        // mediaDataHeld is left in place and simply never set: it still
        // gates releaseMediaDataIfDrained's own arm, which is harmless
        // and keeps that path's shape.
        withState { slot.mediaDataHeld = false }
        Self.drainMediaData(slot.parser, tracks: slot.trackIDs,
                            label: label)
    }

    /// The layer has taken enough. Ask the parser for the rest.
    ///
    /// Called from the drain, which is the only place that knows the
    /// queue is going down. Cheap when there is nothing to do: one lock
    /// and two comparisons.
    fileprivate func releaseMediaDataIfDrained(streamKey: String) {
        // THE HELD BYTES FIRST - see mse_fix_100's docstring. This is
        // the half that actually does anything; everything below it
        // depends on a track id this route has never had.
        //
        // One fragment per call rather than the lot. Each is two to six
        // seconds of media and the parser hands over the whole of it at
        // once, so releasing four would put the queue straight back over
        // the mark it just came under. This runs on every sample the
        // layer takes, so the next one is never far away.
        let fragment = withState { () -> (bytes: Data, at: Double,
                                          parser: NSObject,
                                          left: Int, depth: Int)? in
            guard let slot = streamParsers[streamKey],
                  !slot.heldSegments.isEmpty,
                  // ONE AT A TIME - see mse_fix_132's docstring. This
                  // runs on every sample the layer takes, and the
                  // append it asks for happens on another queue an
                  // unknown time later, so without this the drain
                  // dispatches a release per drained sample and the
                  // whole backlog lands at once.
                  !slot.releaseInFlight,
                  slot.pending.count <= Self.mediaDataLowWater else {
                return nil
            }
            slot.releaseInFlight = true
            let next = slot.heldSegments.removeFirst()
            // WITH ITS STAMP - see mse_fix_133's docstring, so a
            // fragment put back by fix 132 goes back as what it was.
            return (bytes: next.bytes, at: next.at, parser: slot.parser,
                    left: slot.heldSegments.count,
                    depth: slot.pending.count)
        }
        if let fragment {
            // ON THE MAIN QUEUE, because that is where every other
            // appendStreamData: on this parser happens - the IPC
            // handler that calls parserAppendMediaSegment runs there.
            // This release is reached from the DRAIN queue, and two
            // threads appending to one AVStreamDataParser is a race
            // this file has no way to win. It also keeps the delivery
            // the append triggers out of the drain loop that asked
            // for it.
            DispatchQueue.main.async {
                let append = NSSelectorFromString("appendStreamData:")
                guard fragment.parser.responds(to: append) else {
                    FairPlayStreamParser.shared.finishRelease(
                        fragment.bytes, at: fragment.at,
                        streamKey: streamKey, appended: false)
                    return
                }
                // CAPTURED AND LIVE - see mse_fix_105's docstring. The
                // depth above was read on the drain queue; this block
                // runs on the main queue an unknown time later, and in
                // the capture that produced this eight of these lines
                // reported 116-119 while the queue actually stood at its
                // 900 cap and was overflowing.
                let live = FairPlayStreamParser.shared.pendingDepth(streamKey)
                // AND ACTED ON - see mse_fix_132's docstring. The
                // column above has reported the queue at its cap while
                // the guard that let this through read 116 since fix
                // 105 added it, and nothing ever looked. The check that
                // counts is the one taken beside the thing it guards.
                guard live <= Self.mediaDataLowWater else {
                    FairPlayStreamParser.shared.finishRelease(
                        fragment.bytes, at: fragment.at,
                        streamKey: streamKey, appended: false)
                    Self.log("stream \(streamKey) held a fragment BACK - "
                             + "the queue was \(fragment.depth) when this "
                             + "was decided and \(live) by the time it "
                             + "ran. \(fragment.left + 1) still held.")
                    return
                }
                Self.log("stream \(streamKey) releasing a held fragment "
                         + "- captured \(fragment.depth), live \(live), "
                         + "\(fragment.left) still held")
                // GUARDED, because the flag above must be cleared on
                // every exit and appendStreamData: is SPI that raises
                // rather than returning an error - see mse_fix_132's
                // docstring. An exception unwinding past the clear
                // would strand every fragment behind it forever.
                let failure = GeckoRuntimeBridge.catchException(from: {
                    _ = fragment.parser.perform(append,
                                                with: fragment.bytes)
                })
                FairPlayStreamParser.shared.finishRelease(
                    fragment.bytes, at: fragment.at,
                    streamKey: streamKey, appended: true)
                if let failure {
                    Self.log("stream \(streamKey) the parser REFUSED a "
                             + "held fragment: \(failure)")
                }
            }
        }
        let work = withState { () -> (parser: NSObject, tracks: [Int32],
                                      left: Int)? in
            guard let slot = streamParsers[streamKey], slot.mediaDataHeld,
                  slot.pending.count <= Self.mediaDataLowWater else {
                return nil
            }
            slot.mediaDataHeld = false
            return (slot.parser, slot.trackIDs, slot.pending.count)
        }
        guard let work else { return }
        Self.log("stream \(streamKey) releasing the parser - the layer has "
                 + "drained to \(work.left)")
        Self.drainMediaData(work.parser, tracks: work.tracks,
                            label: streamKey)
    }

    /// The main queue is done with a held fragment.
    ///
    /// ADDED - see mse_fix_132's docstring. Clears the in-flight flag
    /// on every exit, and puts the bytes back at the FRONT of the held
    /// list when they were not appended, so the order the page produced
    /// them in survives the deferral. The next sample the layer takes
    /// calls releaseMediaDataIfDrained again, so a fragment put back
    /// here is never far from another try.
    fileprivate func finishRelease(_ bytes: Data, at: Double,
                                   streamKey: String, appended: Bool) {
        withState {
            guard let slot = streamParsers[streamKey] else { return }
            slot.releaseInFlight = false
            if !appended {
                // With the position it was held at - see mse_fix_133's
                // docstring. A fragment that goes back into the bin has
                // to be as sweepable as it was before it came out.
                slot.heldSegments.insert(
                    StreamParser.HeldFragment(bytes: bytes, at: at),
                    at: 0)
            }
        }
    }

    /// How deep the display queue is right now.
    ///
    /// ADDED - see mse_fix_105's docstring. Read at the moment of use
    /// rather than at the moment of capture.
    fileprivate func pendingDepth(_ streamKey: String) -> Int {
        return withState { streamParsers[streamKey]?.pending.count ?? -1 }
    }

    /// ftyp or moov at the top, which is what an fMP4 initialisation
    /// segment looks like and what a media fragment (moof) does not.
    ///
    /// The same test SourceBuffer::AppendData already makes before it
    /// forwards anything - four bytes after a big-endian length.
    fileprivate static func isInitSegment(_ segment: Data) -> Bool {
        guard segment.count >= 8 else { return false }
        let box = segment.subdata(in: 4..<8)
        return box == Data("ftyp".utf8) || box == Data("moov".utf8)
    }

    /// How many fragments may wait on our side before one is appended
    /// regardless.
    ///
    /// 32 fragments is a minute or two of media. Reaching it means the
    /// layer has stopped draining entirely, which is a different fault.
    /// The SECONDARY bound, though: a fragment's size is the page's
    /// choice, so a count is not a memory bound - see heldByteCap.
    fileprivate static let heldFragmentCap = 32

    /// The same ceiling in bytes, which is the one that binds memory.
    ///
    /// The hard refuse in append() records these fragments at five to
    /// nine megabytes each, so 32 of them is 160 to 288MB in ONE bin,
    /// and a stream has one for audio and one for video. 96MB is more
    /// lookahead than any stall this has been asked to ride out, and it
    /// is a number the device has.
    fileprivate static let heldByteCap = 96 * 1024 * 1024

    /// Past this the page's newest bytes are refused outright.
    ///
    /// heldFragmentCap * 2's counterpart. The headroom above
    /// heldByteCap is what a run of appends on the main queue can add
    /// while the forced release ahead of them is still in flight.
    fileprivate static let heldByteRefuse = 128 * 1024 * 1024

    /// How many bytes the bin is carrying.
    ///
    /// Summed rather than kept as a running total. The bin is bounded
    /// at twice heldFragmentCap, so this is at most sixty-four reads of
    /// Data.count, and every site that adds to or takes from
    /// heldSegments would otherwise have to keep a second number in
    /// step with it.
    fileprivate static func heldByteTotal(
        _ fragments: [StreamParser.HeldFragment]) -> Int {
        return fragments.reduce(0) { $0 + $1.bytes.count }
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

    /// This parser is alive - it just handed something back.
    ///
    /// ADDED - see mse_fix_159's docstring. Matched by the parser
    /// object rather than by session, because a session has one parser
    /// per SourceBuffer and only the one that produced this sample has
    /// proved anything.
    fileprivate func noteMediaData(from parser: AnyObject) {
        let now = Self.hostNow()
        withState {
            for (_, slot) in streamParsers where slot.parser === parser {
                slot.lastMediaDataAt = now
                slot.appendsSinceMediaData = 0
            }
        }
    }

    /// Has this stream's parser stopped answering?
    ///
    /// ADDED - see mse_fix_159's docstring. Read without the lock, the
    /// same way the `failed` flag beside it has always been read: two
    /// scalars on a class the caller is holding, and a torn read costs
    /// one late or early rebuild rather than a wrong one.
    fileprivate static func parserHasStopped(_ slot: StreamParser) -> Bool {
        guard slot.appendsSinceMediaData >= starvedAppends,
              slot.lastMediaDataAt > 0 else { return false }
        return hostNow() - slot.lastMediaDataAt > starvedSeconds
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
    /// Put a sample on the element's timeline.
    ///
    /// ADDED - see mse_fix_103's docstring. Everything downstream of
    /// this - the clocks, the drift line, the discontinuity test, fix
    /// 102's position feedback - compares against numbers the PAGE
    /// produced, and until now it was comparing them with numbers from a
    /// different coordinate system.
    ///
    /// Done once, at the door, so nothing below has to know. A copy with
    /// new timing shares the data buffer; only the timing is rewritten.
    fileprivate func shiftIntoElementTime(_ streamKey: String,
                                          _ sampleBuffer: CMSampleBuffer)
        -> CMSampleBuffer {
        let offset = withState {
            streamParsers[streamKey]?.timestampOffset ?? 0
        }
        guard offset != 0, offset.isFinite else { return sampleBuffer }
        let shift = CMTime(seconds: offset, preferredTimescale: 90_000)
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
                  sampleBuffer, entryCount: 0, arrayToFill: nil,
                  entriesNeededOut: &count) == noErr, count > 0 else {
            return sampleBuffer
        }
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(), count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(
                  sampleBuffer, entryCount: count, arrayToFill: &timings,
                  entriesNeededOut: nil) == noErr else {
            return sampleBuffer
        }
        for i in 0..<timings.count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp =
                    CMTimeAdd(timings[i].presentationTimeStamp, shift)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp =
                    CMTimeAdd(timings[i].decodeTimeStamp, shift)
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
                  allocator: kCFAllocatorDefault,
                  sampleBuffer: sampleBuffer,
                  sampleTimingEntryCount: count,
                  sampleTimingArray: &timings,
                  sampleBufferOut: &shifted) == noErr,
              let shifted else {
            // Said once per stream rather than per sample: a stream that
            // cannot be shifted is one whose picture will be in the
            // wrong place, and that is worth knowing without 10,000
            // lines of it.
            let first = withState { () -> Bool in
                guard let slot = streamParsers[streamKey],
                      !slot.shiftFailedLogged else { return false }
                slot.shiftFailedLogged = true
                return true
            }
            if first {
                Self.log("stream \(streamKey) could NOT be shifted by "
                         + "\(offset) - CMSampleBufferCreateCopyWithNewTiming "
                         + "refused, so this stream stays in its own "
                         + "coordinates and will not line up with the page")
            }
            return sampleBuffer
        }
        return shifted
    }

    fileprivate func enqueueForDisplay(streamKey: String,
                                       sampleBuffer rawSampleBuffer: CMSampleBuffer,
                                       mediaType: String) {
        let sampleBuffer = shiftIntoElementTime(streamKey, rawSampleBuffer)
        // ADDED - see mse_fix_95's docstring. A parked stream is half of
        // a player the page threw away, and its parser goes on
        // delivering for as long as the fragments it was already given
        // last - eighteen of them, thirty seconds of media, in the
        // capture this came from.
        //
        // Dropped here rather than queued. Queuing would fill the bound
        // and report an overflow for every sample of a stream nobody is
        // listening to, and - worse - would keep lastSampleAt fresh,
        // which is the liveness signal adopt() and videoClock() read to
        // decide which stream is playing.
        if withState({ streamParsers[streamKey]?.supersededBy != nil }) {
            return
        }
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

        // ONLY SAMPLES NOTHING ELSE CAN RENDER.
        //
        // If the parser hands back a CLEAR sample then Gecko has the
        // same bytes and is already decoding them - DoCreateDecoder
        // reports encrypted=0 for exactly these tracks - so putting them
        // in a display layer paints a second picture over the first.
        // tv.apple.com does this, and 242 video samples went into a
        // layer for a video that was already on screen.
        //
        // It was bounded before and therefore invisible: AppendData
        // forwarded eight fragments per process and stopped. Fix 45
        // removed that budget because it was starving HBO, and the
        // duplicate became the whole film. This is that fix's other
        // half.
        // CHANGED - see mse_fix_82's docstring. A cenc track is
        // decrypted COMPLETELY by the parser and comes back as plain
        // avc1, so the subtype test alone stood Netflix's video down
        // and dropped 2626 decrypted frames - while Gecko sat on the
        // ciphertext the page appended, which it cannot decrypt. The
        // track being protected is the fact that decides this.
        guard Self.isProtectedSample(sampleBuffer)
                || withState({ slot.trackIsProtected }) else {
            standDown(streamKey: streamKey, half: "video")
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
                slot.timebaseFrom = "build"
                slot.displayLayer = layer
                slot.drainQueue = DispatchQueue(
                    label: "org.reynard.fps.display")
            }
            joinKeySession(layer, streamKey: streamKey)
            Self.observeDecodeFailures(layer, label: streamKey)
            Self.log("stream \(streamKey) built a display layer - "
                     + "status \(layer.status.rawValue) "
                     + "timebase \(timebase != nil) - paused until attached")
            // ADDED - see mse_fix_95's docstring. A second display layer
            // in one session is a second picture, and a session is one
            // content process playing one element. Whatever held the
            // picture until now belongs to a player the page threw away.
            supersede(winner: streamKey, half: "video")
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
        // Filled by the block below and reported once the lock is
        // released - see mse_fix_137's docstring.
        var holeFrom = Double.nan
        var holeTo = Double.nan
        var holeNth = 0
        let jump = withState { () -> Double? in
            slot.videoSeen += 1
            slot.lastSampleAt = arrivedAt
            // LIVENESS - see mse_fix_177's docstring. The compositor
            // asks, once a frame, whether a picture is still being
            // produced, and this is the moment that is true of.
            Self.noteLivePicture(arrivedAt)
            // WHAT CAME IN, AND WHAT DID NOT - see mse_fix_137's
            // docstring. Measured here because this is the last point
            // where the sequence means what it says: after a handover
            // 111 re-feeds a carried run, so the PTS on the drift line
            // steps backwards by design and a hole cannot be told from
            // a carry.
            //
            // Against the running maximum, so B-frame reordering - which
            // moves PTS backwards in decode order - cannot register.
            // Only a forward step larger than intakeGap counts, and at
            // 24fps that is twelve frames.
            if slot.lastIntakePTS.isFinite, intakePTS.isFinite,
               intakePTS - slot.lastIntakePTS > Self.intakeGap {
                slot.intakeHoles += 1
                holeFrom = slot.lastIntakePTS
                holeTo = intakePTS
                holeNth = slot.intakeHoles
            }
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
        if holeNth > 0, holeFrom.isFinite, holeTo.isFinite {
            Self.log("stream \(streamKey) A HOLE IN THE INTAKE - the "
                     + "parser went from \(holeFrom) to \(holeTo), "
                     + "\(holeTo - holeFrom)s of media that the page "
                     + "appended and this process never saw. Hole "
                     + "\(holeNth).")
        }
        if let jump {
            // INTAKE ORDER IS NOT TIMELINE ORDER.
            //
            // CHANGED - see mse_fix_102's docstring. lastIntakeDTS is one
            // number and a page may hold as many buffered ranges as it
            // likes: Netflix appends a range ahead of the one it is
            // playing and then fills in behind it, and this read the two
            // as a discontinuity each way round. Seven events in one
            // playback, 1188 frames flushed out of 1864 taken in, 946
            // ever shown - more picture discarded than presented, and
            // 1026 of the loss to FORWARD jumps, which strand nothing at
            // all.
            //
            // With the element's own position known there is nothing to
            // infer. A display layer holds a sample that is not due yet
            // and skips one whose time has passed; that is what its
            // control timebase is for, and it does not need this file to
            // second-guess it.
            //
            // A stream with no position - an older content process, or a
            // page this never reaches - keeps the old behaviour exactly.
            if elementPosition(streamKey) != nil {
                let first = withState { () -> Bool in
                    guard let slot = streamParsers[streamKey],
                          !slot.standDownLogged else { return false }
                    slot.standDownLogged = true
                    return true
                }
                if first {
                    Self.log("stream \(streamKey) standing down from the "
                             + "discontinuity test - the element says "
                             + "where it is, so intake order proves "
                             + "nothing. Jump \(jump)s ignored.")
                }
            } else {
                resynchronise(streamKey: streamKey, to: intakePTS,
                              jump: jump)
            }
        }

        // MEDIA THE ELEMENT HAS ALREADY PASSED.
        //
        // ADDED - see mse_fix_106's docstring. Fix 102 stood the
        // discontinuity test down - correctly, intake order proves
        // nothing - and left nothing in its place, so since then
        // NOTHING has flushed the video queue on a page that reports a
        // position, which is all three sites under test. The queue then
        // carries pre-seek media across the seek and the drift line
        // reads 1408 to 2474 seconds for hundreds of samples, which is
        // a frozen picture. The audio path has done this correctly all
        // along; this is the same thing, against a better reference
        // than intake order.
        //
        // Refused rather than queued, and what is already queued behind
        // the media goes with it. needsSyncSample because a pruned
        // queue has a hole in it exactly like a flushed one.
        if let authority = mediaAuthority(streamKey), authority.isFinite,
           intakePTS.isFinite, intakePTS < authority - Self.strandedBehind {
            let oldest = authority - Self.strandedBehind
            let tally = withState {
                () -> (dropped: Int, pruned: Int, first: Bool) in
                guard let slot = streamParsers[streamKey] else {
                    return (0, 0, false)
                }
                slot.strandedDropped += 1
                let live: (CMSampleBuffer) -> Bool = { sample in
                    let at = CMSampleBufferGetPresentationTimeStamp(sample)
                        .seconds
                    return !at.isFinite || at >= oldest
                }
                let keptGOP = slot.currentGOP.filter(live)
                let keptPending = slot.pending.filter(live)
                // ADDED - see mse_fix_110's docstring. Reference frames
                // go stale exactly as queued ones do.
                let keptPrevious = slot.previousGOP.filter(live)
                let pruned = (slot.currentGOP.count - keptGOP.count)
                    + (slot.pending.count - keptPending.count)
                    + (slot.previousGOP.count - keptPrevious.count)
                if pruned > 0 {
                    slot.previousGOP = keptPrevious
                    slot.currentGOP = keptGOP
                    slot.pending = keptPending
                    slot.needsSyncSample = true
                    slot.strandedPruned += pruned
                }
                let first = !slot.strandedReported
                slot.strandedReported = true
                return (slot.strandedDropped, pruned, first)
            }
            if tally.first || tally.pruned > 0 || tally.dropped % 100 == 0 {
                Self.log("stream \(streamKey) sample at \(intakePTS) is "
                         + "\(authority - intakePTS)s behind the media at "
                         + "\(authority) - refused. \(tally.dropped) "
                         + "stranded so far, \(tally.pruned) pruned "
                         + "from the queue here")
            }
            return
        }

        // MEDIA THE ELEMENT CANNOT REACH.
        //
        // ADDED - see mse_fix_133's docstring. The mirror of the block
        // above, which has caught nothing in two captures while this
        // direction ran a stream to teardown at drift -1944.59.
        //
        // Refused only, with no pruning: a queue holding media this far
        // ahead has nothing in it that these samples belong with, and
        // the sweep above is what empties it when the element moves.
        if let authority = mediaAuthority(streamKey), authority.isFinite,
           intakePTS.isFinite, intakePTS > authority + Self.strandedAhead {
            let tally = withState { () -> (n: Int, first: Bool) in
                guard let slot = streamParsers[streamKey] else {
                    return (0, false)
                }
                slot.aheadDropped += 1
                let first = slot.aheadDropped == 1
                return (slot.aheadDropped, first)
            }
            if tally.first || tally.n % 100 == 0 {
                Self.log("stream \(streamKey) sample at \(intakePTS) is "
                         + "\(intakePTS - authority)s AHEAD of the media "
                         + "at \(authority) - refused. \(tally.n) so far. "
                         + "No page buffers this far; these bytes belong "
                         + "to media the element has left.")
            }
            return
        }

        // Nothing is fed mid-GOP. After a flush the layer has no
        // reference frame, and after a drop there is a hole where one
        // used to be - either way the next usable sample is a keyframe
        // and everything before it decodes to garbage.
        if withState({ slot.needsSyncSample }) {
            // AND ROOM FOR IT - see mse_fix_132's docstring. A keyframe
            // arriving into a full queue clears this gate, the append
            // sixty lines below then overflows and closes it again, and
            // the GOP behind that keyframe is thrown away for nothing.
            // Capture ee663d06 ran that sixteen times in thirty-one
            // milliseconds - overflow 4 through 19, resyncs at 4203.7,
            // 4206.4, 4208.7, 4211.0, 4213.7, 4216.4, 4219.6, 4222.5,
            // 4225.1, 4227.8, 4230.8, 4240.9, 4243.8, 4246.7, 4249.5,
            // 4251.6 - and lost the forty-eight seconds between them.
            //
            // One closure per burst instead: with no room the gate
            // stays shut, and the next keyframe is two or three seconds
            // of media away rather than one sample.
            guard Self.isSyncSample(sampleBuffer),
                  withState({ slot.pending.count < 900 }) else {
                // COUNTED - see mse_fix_98's docstring. Everything
                // between the drop and the next keyframe goes, and until
                // now nothing said how much. Nine of these in one window
                // is the whole of the missing picture.
                // WHAT, not just how many - see mse_fix_132's
                // docstring.
                withState {
                    slot.droppedSinceSync += 1
                    guard intakePTS.isFinite else { return }
                    if slot.droppedSinceSyncFrom.isNaN {
                        slot.droppedSinceSyncFrom = intakePTS
                    }
                    slot.droppedSinceSyncTo = intakePTS
                }
                return
            }
            let lost = withState { () -> (n: Int, from: Double,
                                          to: Double) in
                slot.needsSyncSample = false
                let n = slot.droppedSinceSync
                let from = slot.droppedSinceSyncFrom
                let to = slot.droppedSinceSyncTo
                slot.droppedSinceSync = 0
                slot.droppedSinceSyncFrom = Double.nan
                slot.droppedSinceSyncTo = Double.nan
                return (n, from, to)
            }
            // AS MEDIA - see mse_fix_132's docstring. Sixteen of these
            // in capture ee663d06 said "63 samples lost" and not one of
            // them said the sixteen together were forty-eight seconds
            // of the film, which is the number that names the fault.
            // Built as a statement, not a ternary: this file's own
            // note about long concatenations applies, and the operands
            // here are two interpolations and a subtraction.
            var hole = ""
            if lost.from.isFinite, lost.to.isFinite {
                hole = " - lost \(lost.from) to \(lost.to), "
                    + "\(lost.to - lost.from)s of media"
            }
            Self.log("stream \(streamKey) resync complete - first sync "
                     + "sample at pts \(intakePTS), \(lost.n) samples "
                     + "lost waiting for it" + hole)
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
                // A ROLLING WINDOW, not one GOP - see mse_fix_111's
                // docstring. Two GOPs carried nothing at every handover
                // where the display queue was deeper than they were,
                // which in capture 5f8a8ea2 was four of six, held 347
                // to 400, and each left its new layer one and a half to
                // eleven seconds short of a frame it could paint.
                //
                // Trimmed by count rather than by span: the span of a
                // queue is a property of the content, the memory is a
                // property of this process, and it is the memory that
                // has to be bounded. 400 compressed samples is fewer
                // than the 900 pending is already allowed.
                slot.previousGOP += slot.currentGOP
                // AGAINST THE CLOCK - see mse_fix_131's docstring.
                // Trimming to the newest four hundred keeps the wrong
                // end: after the queue is emptied into the layer in one
                // second, which capture 0c6b8550 has it doing, the
                // newest samples are thirty seconds past the clock and
                // the frames a handover would anchor at are gone. The
                // new layer then carries nothing and the picture stops
                // for forty seconds.
                //
                // What a handover needs is what is AROUND the clock, so
                // that is what is kept: everything from staleBehind
                // before the clock forwards.
                // Two steps on purpose: displayLayer? and
                // controlTimebase are both optional, and chaining map
                // over them gives a Double?? that will not compile
                // against isFinite.
                var clockNow: Double?
                if let running = slot.displayLayer?.controlTimebase {
                    clockNow = CMTimebaseGetTime(running).seconds
                }
                if let clockNow, clockNow.isFinite {
                    let floor = clockNow - Self.staleBehind
                    slot.previousGOP.removeAll { sample in
                        let at = CMSampleBufferGetPresentationTimeStamp(
                            sample).seconds
                        return at.isFinite && at < floor
                    }
                }
                // And a hard cap regardless, so a stream with no clock
                // - or one whose clock has stopped - cannot grow this
                // without bound.
                if slot.previousGOP.count > Self.keepBackSamples * 3 {
                    slot.previousGOP.removeFirst(
                        slot.previousGOP.count - Self.keepBackSamples * 3)
                }
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
            // PER EPISODE, not per hundredth sample.
            //
            // CHANGED - see mse_fix_98's docstring. The old throttle was
            // `dropped == 1 || dropped % 100 == 0`, and the counter never
            // reached 100 because the needsSyncSample gate returns before
            // it is incremented. So the first overflow was reported and
            // the eight after it, in the same ninety seconds, were not.
            // An episode is one closing of the gate, which is the thing
            // that costs a picture.
            let dropped = withState { slot.overflowed }
            Self.log("stream \(streamKey) pending queue FULL at 900 - "
                     + "overflow \(dropped), restarting at the next sync "
                     + "sample. Back pressure should have stopped this "
                     + "before it got here.")
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
            // The element decides, not this file. An element that is
            // paused - or that autoplay never let start - gets a layer
            // that is attached, fed and held at rate 0.
            let rate = gatedRate(streamKey)
            CMTimebaseSetRate(timebase, rate: Float64(rate))
            Self.log("stream \(streamKey) released the timebase at "
                     + "\(CMTimebaseGetTime(timebase).seconds) - layer "
                     + "attached, "
                     + (rate > 0
                        ? "feeding starts now"
                        : "HELD at rate 0 - no play state for this "
                          + "session yet, or the element is paused"))
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
    /// Release a deliberate hold, so the wake that scheduled it is not
    /// turned away by its own guard.
    ///
    /// ADDED - see mse_fix_117's docstring.
    fileprivate func withStateClearHold(streamKey: String) {
        withState { streamParsers[streamKey]?.holdUntil = 0 }
    }

    /// Is a hold still standing well past the time it meant to?
    ///
    /// ADDED - see mse_fix_129's docstring. Clears it if so, and says
    /// so to the caller, which is the only place that reports it.
    fileprivate func withStateHoldOverran(streamKey: String) -> Bool {
        return withState { () -> Bool in
            guard let slot = streamParsers[streamKey],
                  slot.holdStartedAt > 0 else { return false }
            slot.holdUntil = 0
            slot.holdStartedAt = 0
            return true
        }
    }

    /// How long the hold that has just ended really lasted.
    ///
    /// ADDED - see mse_fix_129's docstring. Reported only when it
    /// overran, so a healthy stream says nothing.
    fileprivate func withStateHoldEnded(streamKey: String) -> (Double, Double)? {
        return withState { () -> (Double, Double)? in
            guard let slot = streamParsers[streamKey],
                  slot.holdStartedAt > 0 else { return nil }
            let lasted = Self.hostNow() - slot.holdStartedAt
            let meant = slot.holdIntended
            slot.holdStartedAt = 0
            guard lasted > meant * 2 + 0.5 else { return nil }
            return (lasted, meant)
        }
    }

    /// The bin is holding and the queue is not moving. Why?
    ///
    /// ADDED - see mse_fix_178's docstring. After the seek in capture
    /// ccce0736 the video queue stood at 337 with the bin refusing to
    /// append until it fell to 120, and it never fell: no drain ran, the
    /// layer went unfed for eleven seconds, and eight video segments -
    /// about 55 MB - were held and never given to the parser while audio
    /// played on. The stream said nothing at all for the rest of the
    /// session.
    ///
    /// armDrainIfNeeded declines silently on six conditions and prints
    /// none of them. This prints the three that can still be true here -
    /// pending is 337, holdUntil is only ever assigned zero in this file,
    /// and the layer is present - so one line names the latch.
    ///
    /// And it clears the ONE that is safe to clear. drainArmed is not a
    /// state, it is a belief: "a requestMediaDataWhenReady block is
    /// installed and will call us". It is cleared in exactly one place,
    /// inside that callback - so if the belief is wrong, nothing can ever
    /// correct it. Clearing it and re-arming is right under every cause
    /// and costs one redundant requestMediaDataWhenReady if the belief
    /// was true after all.
    ///
    /// layerAttached and supersededBy are reported and NOT touched. They
    /// say something about which stream this is, and forcing them would
    /// be guessing at the very point this exists to stop guessing.
    /// Where a display layer's control timebase is, and how fast.
    ///
    /// ADDED - see mse_fix_181's docstring. A layer whose timebase sits
    /// somewhere its queued samples are not will never ask for them, and
    /// that reads identically from this side to a layer that is simply
    /// full. One string, so the stall line can carry both and the
    /// subtraction can be done by eye.
    fileprivate func layerClock(_ layer: AVSampleBufferDisplayLayer)
        -> String {
        guard let timebase = layer.controlTimebase else { return "none" }
        let at = CMTimebaseGetTime(timebase).seconds
        let rate = CMTimebaseGetRate(timebase)
        guard at.isFinite else { return "unreadable" }
        return String(format: "%.3f@%.2fx", at, rate)
    }

    fileprivate func nudgeStalledDrain(streamKey: String) {
        // PAUSED IS NOT STALLED - see mse_fix_179's docstring. In
        // capture 666e86e3 this reported "no drain for 135.9s" of which
        // 132 were a deliberate pause with the app in the background. A
        // paused layer does not ask for data and is right not to.
        guard gatedRate(streamKey) != 0 else {
            // AND THE PAUSED SECONDS DO NOT COUNT. Returning alone only
            // silences the report while the pause LASTS: lastDrainAt goes
            // on ageing, so the first tick after the resume prints the
            // whole pause as a stall. That is literally what 666e86e3
            // did - "no drain for 135.9s" was logged at 195449.313, 3.3s
            // AFTER the rate went back to 1.0, with this guard open. So
            // hold the clock here and the window starts at the resume.
            //
            // Only once it has drained at all: lastDrainAt of 0 is what
            // makes the report say "ever", and a stream that has never
            // fed the layer should keep saying so.
            withState {
                guard let slot = streamParsers[streamKey],
                      slot.lastDrainAt > 0 else { return }
                slot.lastDrainAt = Self.hostNow()
            }
            return
        }
        let now = Self.hostNow()
        let look = withState { () -> (attached: Bool, armed: Bool,
                                      superseded: Bool, depth: Int,
                                      held: Int, since: Double,
                                      say: Bool,
                                      layer: AVSampleBufferDisplayLayer,
                                      head: Double)? in
            guard let slot = streamParsers[streamKey],
                  let layer = slot.displayLayer else { return nil }
            let since = slot.lastDrainAt > 0
                ? now - slot.lastDrainAt : Double.infinity
            guard since > Self.drainStallSeconds else { return nil }
            let say = now - slot.stallSaidAt > 5.0
            if say { slot.stallSaidAt = now }
            // THE FRONT OF THE QUEUE - see mse_fix_181's docstring. The
            // sample the layer would take next, so clock-versus-head is
            // arithmetic on the line rather than a guess about it.
            let head = slot.pending.first.map {
                CMSampleBufferGetPresentationTimeStamp($0).seconds
            } ?? Double.nan
            return (slot.layerAttached, slot.drainArmed,
                    slot.supersededBy != nil, slot.pending.count,
                    slot.heldSegments.count, since, say, layer, head)
        }
        guard let look else { return }
        if look.say {
            let waited = look.since.isFinite
                ? String(format: "%.1f", look.since) : "ever"
            // AND WHAT THE LAYER THINKS - see mse_fix_181's docstring.
            // Everything above this is what THIS FILE believes about the
            // stream. In capture 1059b024 all of it read healthy through
            // a stall that re-arming could not fix, twice, with the
            // protected layer in the compositor's list the whole time.
            //
            // ready=false means the layer is full and not presenting,
            // and the question becomes why. ready=true means it is
            // asking and we are not feeding it, which is a bug on this
            // side of the boundary. Those want completely different
            // fixes and nothing has ever told them apart.
            let clockAt = layerClock(look.layer)
            let headAt = look.head.isFinite
                ? String(format: "%.3f", look.head) : "none"
            Self.log("stream \(streamKey) THE DRAIN HAS STOPPED - no drain "
                     + "for \(waited)s with \(look.depth) samples queued "
                     + "and \(look.held) fragment(s) held. attached="
                     + "\(look.attached) armed=\(look.armed) superseded="
                     + "\(look.superseded) | the layer says ready="
                     + "\(look.layer.isReadyForMoreMediaData) status="
                     + "\(look.layer.status.rawValue) error="
                     + (look.layer.error.map { String(describing: $0) }
                        ?? "nil")
                     + " clock=\(clockAt) head=\(headAt)")
        }
        // Only the belief, and only when nothing else explains it.
        guard look.attached, !look.superseded, look.armed else { return }
        // AND FLUSH IT IF THAT IS WHAT IT IS WAITING FOR - see
        // mse_fix_179's docstring. A layer that has been through app
        // backgrounding loses its decode session and will not dequeue
        // until it is flushed. This file has printed
        // requiresFlushToResumeDecoding since fix 113 and never acted on
        // it, and the only place it reads it is inside drainPending -
        // which runs when the layer asks for data, which it will not do
        // until it is flushed. In capture 666e86e3 that left the layer
        // attached, submitted, timebase running and 300 samples deep,
        // waiting on code that could not run.
        //
        // KVC with a responds(to:) guard, the same way drainPending
        // reads it: the property is newer than this deployment target.
        // ONCE PER REPORT, NOT ONCE PER APPEND. This runs from the
        // bin's hold and refusal exits, which on a stalled stream is
        // every segment the page appends - several a second. say is
        // already the 5s rate limiter above and starts open, so the
        // first flush is immediate and the next is five seconds later,
        // which is time enough to know whether it worked.
        //
        // AND THE LAYER IS ASKED OUTSIDE THE LOCK. The first version of
        // this read requiresFlushToResumeDecoding by KVC from inside
        // withState, which is the opposite of what the rest of this file
        // does - armAudioDrainIfNeeded reads the renderer "OUTSIDE the
        // lock, because both read the renderer or its clock", and
        // livePictureLock exists because the state lock is already held
        // across real work. An AVFoundation getter that blocks inside
        // the framework would have stretched that hold for the append
        // thread, every drain queue and the compositor's adopt() alike.
        // So: snapshot under the lock, ask the layer outside it, and
        // re-enter only to record what was decided.
        let candidate = withState { () -> (layer: AVSampleBufferDisplayLayer,
                                           queue: DispatchQueue)? in
            guard look.say,
                  let slot = streamParsers[streamKey],
                  let layer = slot.displayLayer,
                  let queue = slot.drainQueue else { return nil }
            return (layer, queue)
        }
        var flushed: (layer: AVSampleBufferDisplayLayer,
                      queue: DispatchQueue, dropped: Int)?
        if let candidate {
            let key = "requiresFlushToResumeDecoding"
            let needsFlush =
                candidate.layer.responds(to: NSSelectorFromString(key))
                && (candidate.layer.value(forKey: key) as? Bool) == true
            if needsFlush {
                // AND THE QUEUE GOES WITH IT, AS FAR AS THE NEXT
                // KEYFRAME. needsSyncSample gates what comes IN and does
                // not touch what is already pending, so on its own it
                // would leave a flushed decoder being fed samples with
                // no reference frame - resynchronise clears the whole
                // queue for exactly this reason. Here the media is still
                // wanted, so drop only the mid-GOP head: those samples
                // decode to nothing either way.
                //
                // Identity re-checked: the lock was let go to ask the
                // layer, and an adopt() in that window would mean this
                // is no longer the stream's sink.
                let dropped = withState { () -> Int? in
                    guard let slot = streamParsers[streamKey],
                          slot.displayLayer === candidate.layer else {
                        return nil
                    }
                    slot.needsSyncSample = true
                    let before = slot.pending.count
                    while let head = slot.pending.first,
                          !Self.isSyncSample(head) {
                        slot.pending.removeFirst()
                    }
                    return before - slot.pending.count
                }
                if let dropped {
                    flushed = (candidate.layer, candidate.queue, dropped)
                }
            }
        }
        if let flushed {
            Self.log("stream \(streamKey) the layer needs a flush to "
                     + "resume decoding - it has been through app "
                     + "backgrounding and will not take a sample until "
                     + "it gets one. Flushing, and dropping "
                     + "\(flushed.dropped) queued sample(s) to reach the "
                     + "next keyframe.")
            // On the drain queue, because that is where enqueue happens
            // and flush() racing an enqueue is the one collision these
            // two calls can have - the same rule resynchronise follows.
            flushed.queue.async { flushed.layer.flush() }
        }
        // AT THE CADENCE IT REPORTS. Only the log line used to be behind
        // say; the recovery itself ran on every nudge, which is every
        // segment the page appends while stalled - several a second -
        // each one a cross-thread requestMediaDataWhenReady against a
        // layer whose drain queue may be executing the previous block.
        // Replacing the handler is defined behaviour, so this was churn
        // rather than breakage, but there is no reason to re-arm faster
        // than the evidence that it is needed arrives.
        guard look.say else { return }
        withState { streamParsers[streamKey]?.drainArmed = false }
        Self.log("stream \(streamKey) clearing drainArmed and asking "
                 + "the layer again - the callback that clears it is "
                 + "the one that never came.")
        armDrainIfNeeded(streamKey: streamKey)
    }

    /// How long the drain may be silent before that is a fault.
    ///
    /// Three seconds. A paced feed goes quiet for a frame interval at a
    /// time and a held queue for as long as the layer takes to eat 217
    /// samples, which at 25fps is under nine; three seconds with the bin
    /// holding is not pacing, it is a stop.
    fileprivate static let drainStallSeconds: Double = 3.0

    fileprivate func armDrainIfNeeded(streamKey: String) {
        let work = withState { () -> (layer: AVSampleBufferDisplayLayer,
                                      queue: DispatchQueue)? in
            guard let slot = streamParsers[streamKey],
                  slot.layerAttached, !slot.drainArmed,
                  slot.supersededBy == nil,
                  !slot.pending.isEmpty,
                  // ADDED - see mse_fix_117's docstring. A hold that an
                  // append can re-arm through is not a hold. The wake
                  // this hold scheduled clears holdUntil before it calls
                  // here, so the timer is never blocked by its own
                  // guard.
                  Self.hostNow() >= slot.holdUntil,
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
        // ADDED - see mse_fix_178's docstring. Stamped on entry rather
        // than on a successful enqueue: the question this answers is
        // whether the callback is arriving at all.
        withState { streamParsers[streamKey]?.lastDrainAt = Self.hostNow() }
        while layer.isReadyForMoreMediaData {
            // NO LONGER A HOLD - see mse_fix_130's docstring. 114
            // paced the feed by calling stopRequestingMediaData and
            // re-arming from a timer, and capture 328fcc2f proves that
            // re-arm never happens: 167 backstop releases, 15 holds,
            // and 'the feed came back after' - the line that fires when
            // the DRAIN QUEUE brings it back - not once. Every hold in
            // the capture was released by 129's main-queue backstop
            // two seconds late.
            //
            // The reason 114 existed was that everything inside a layer
            // is lost when the compositor replaces it. That is no
            // longer true: 110 and 111 carry a bounded reference run
            // across a handover, and in this same capture the two
            // handovers started at -0.38s and -2.15s, which is seamless.
            //
            // So the layer's own readiness is the pacing again, as it
            // was before 114. isReadyForMoreMediaData going false is
            // the layer saying it has enough, and it is the only signal
            // here that has never failed.
            //
            // Kept: the measurement. A queue running a long way ahead
            // of the clock is worth knowing about, because it is what
            // 114 was written for, and if it comes back this line says
            // so without stopping anything.
            if let timebase = layer.controlTimebase,
               CMTimebaseGetRate(timebase) != 0 {
                let now = CMTimebaseGetTime(timebase).seconds
                let head = withState { () -> Double? in
                    guard let slot = streamParsers[streamKey],
                          let first = slot.pending.first else { return nil }
                    let at = CMSampleBufferGetPresentationTimeStamp(first)
                        .seconds
                    return at.isFinite ? at : nil
                }
                if now.isFinite, let head, head - now > Self.feedAhead * 10 {
                    let nth = withState { () -> Int in
                        guard let slot = streamParsers[streamKey] else {
                            return 0
                        }
                        slot.pacedStops += 1
                        return slot.pacedStops
                    }
                    if nth == 1 || nth % 200 == 0 {
                        Self.log("stream \(streamKey) the queue is "
                                 + "\(head - now)s ahead of the layer's "
                                 + "clock and being fed anyway - the layer "
                                 + "decides. Seen \(nth).")
                    }
                }
            }
            let next = withState { () -> CMSampleBuffer? in
                guard let slot = streamParsers[streamKey],
                      !slot.pending.isEmpty else { return nil }
                return slot.pending.removeFirst()
            }
            guard let sample = next else {
                // Nothing left. Stop, or the block spins on an empty
                // queue for as long as the layer stays ready.
                //
                // And ask the parser first - see mse_fix_98's docstring.
                // An empty queue under a hold is the worst case there
                // is: the samples exist, the parser is holding them, and
                // the picture has stopped.
                releaseMediaDataIfDrained(streamKey: streamKey)
                layer.stopRequestingMediaData()
                withState { streamParsers[streamKey]?.drainArmed = false }
                return
            }
            // Guarded: enqueue RAISES on a sample it dislikes rather than
            // returning an error, and this route has already had one
            // AVFoundation SPI take the process down.
            // THE PICTURE IS MOVING - see mse_fix_179's docstring.
            // Fix 177 stamped liveness where samples ARRIVE FROM THE
            // PARSER, which is bursty and stops completely once the page
            // has buffered ahead: in capture 813b4835 the last append
            // was at 195308.952 and frames went on displaying to
            // 195313.414, so 177 declared the picture dead twice while
            // it ran at a steady 25fps. A sample being handed to the
            // layer happens once a frame and cannot say that.
            Self.noteLivePicture(Self.hostNow())
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
            // ADDED - see mse_fix_98's docstring. The other half of the
            // back pressure: a hold that is never released is a stall,
            // and the append that would have released it may be seconds
            // away or may never come if the page has finished buffering.
            releaseMediaDataIfDrained(streamKey: streamKey)

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

            // A FAILED LAYER NEVER UN-FAILS ITSELF - see mse_fix_157's
            // docstring.
            //
            // status .failed is terminal. The layer goes on accepting
            // samples and discarding all of them until flush() resets
            // it, and the comment above has been describing that state
            // for several rounds without anything acting on it.
            //
            // Netflix in capture 94b3e7b8 failed on its FIRST sample -
            // "no content key present", 291ms before the licence
            // arrived - and stayed failed for 18.865 seconds and 3,548
            // enqueues. It came back only because entering fullscreen
            // made the compositor build a new layer.
            //
            // The gate is re-opened with the flush because a flushed
            // layer cannot decode until it is given a keyframe, which
            // is the same pair resynchronise uses for a discontinuity.
            if layer.status == .failed {
                let recovery = withState { () -> Int? in
                    guard let slot = streamParsers[streamKey] else {
                        return nil
                    }
                    let now = Self.hostNow()
                    guard now - slot.lastFailRecoveryAt
                            > Self.failRecoveryGap else { return nil }
                    slot.lastFailRecoveryAt = now
                    slot.failRecoveries += 1
                    slot.needsSyncSample = true
                    return slot.failRecoveries
                }
                if let recovery {
                    Self.log("stream \(streamKey) the display layer has "
                             + "FAILED - "
                             + (layer.error.map { String(describing: $0) }
                                ?? "no error reported")
                             + " - flushing and re-feeding from the next "
                             + "keyframe. Recovery \(recovery).")
                    // Already on the drain queue, which is where enqueue
                    // happens - the one collision flush() can have.
                    layer.flush()
                }
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
                // CHANGED - see mse_fix_106's docstring. Every one of
                // the six corrections in capture 8ec30c6a was wrong, by
                // 31s to 1454s, and each dragged the audio after it:
                //
                //   CLOCK RAN AHEAD by 1453.67s - put back on the media
                //   at 616.32
                //
                // three lines after the element said 2070.28 and the
                // write landed. The clock was right and the QUEUE was
                // stale, and this read the queue.
                var mediaAt: Double?
                if ranAhead != nil { mediaAt = mediaAuthority(streamKey) }
                if let ranAhead, let mediaAt, mediaAt.isFinite,
                   abs(pts - mediaAt) > Self.strandedBehind {
                    let first = withState { () -> Bool in
                        guard let slot = streamParsers[streamKey],
                              !slot.reportedStaleQueue else { return false }
                        slot.reportedStaleQueue = true
                        return true
                    }
                    if first {
                        Self.log("stream \(streamKey) the clock reads "
                                 + "\(now) and this sample is at \(pts), "
                                 + "\(ranAhead.late)s behind it - but the "
                                 + "media is at \(mediaAt), so the QUEUE "
                                 + "is stale and the clock is not moving")
                    }
                } else if let ranAhead {
                    let to = CMTime(seconds: pts, preferredTimescale: 90_000)
                    CMTimebaseSetTime(timebase, time: to)
                    // READ IT BACK - see mse_fix_100's docstring. This is
                    // the last CMTimebaseSetTime in this file that
                    // reported what it ASKED FOR and never what it got,
                    // and the capture that produced this fix has it
                    // asking for 5514.874 and reading 5537.048 thirty
                    // samples later. Fix 93 was written on exactly that
                    // mistake and had to be withdrawn.
                    let landed = CMTimebaseGetTime(timebase).seconds
                    if abs(landed - to.seconds) > 0.25 {
                        Self.log("stream \(streamKey) THE CORRECTION DID "
                                 + "NOT TAKE - asked for \(to.seconds), it "
                                 + "reads \(landed) rate "
                                 + "\(CMTimebaseGetRate(timebase))")
                    }
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
                // DID A FRAME REACH THE SCREEN - see mse_fix_120's
                // docstring. Ten times less often than the drift line:
                // the counts move slowly and the deltas are what matter.
                // PER LAYER - see mse_fix_125's docstring. The counts
                // belong to the layer, so the enqueues they are read
                // against have to as well, and a layer change has to be
                // said rather than shown as a negative delta.
                let here = ObjectIdentifier(layer)
                let changed = withState { () -> Bool in
                    guard let slot = streamParsers[streamKey] else {
                        return false
                    }
                    slot.enqueuedIntoLayer += 1
                    guard slot.metricsLayer != here else { return false }
                    slot.metricsLayer = here
                    slot.enqueuedIntoLayer = 1
                    slot.lastShown = -1
                    slot.lastDropped = -1
                    return true
                }
                if changed || count % 300 == 0 {
                    if let metrics = Self.pictureMetrics(layer) {
                        let tail = withState { () -> String in
                            guard let slot = streamParsers[streamKey] else {
                                return ""
                            }
                            var out = ""
                            if !changed, slot.lastShown >= 0,
                               metrics.shown >= 0 {
                                out += " (+\(metrics.shown - slot.lastShown)"
                                    + " shown, +"
                                    + "\(metrics.dropped - slot.lastDropped)"
                                    + " dropped)"
                            }
                            slot.lastShown = metrics.shown
                            slot.lastDropped = metrics.dropped
                            out += changed
                                ? " - NEW LAYER, \(slot.enqueuedIntoLayer) "
                                    + "enqueued into it so far"
                                : " - \(slot.enqueuedIntoLayer) enqueued "
                                    + "into this layer"
                            return out
                        }
                        Self.log("stream \(streamKey) PICTURE "
                                 + metrics.text + tail
                                 + " (stream total \(count))")
                    } else {
                        let first = withState { () -> Bool in
                            guard let slot = streamParsers[streamKey],
                                  slot.lastShown == -1 else { return false }
                            slot.lastShown = -2
                            return true
                        }
                        if first {
                            Self.log("stream \(streamKey) PICTURE metrics "
                                     + "unavailable on this OS - fall back "
                                     + "to enqueued against drift")
                        }
                    }
                }
                if count % 30 == 0 {
                    // With the offset between the two clocks, so "out of
                    // sync" is a column rather than a judgement. Anything
                    // beyond a few milliseconds is a bug in this file,
                    // and the sign says which half moved.
                    let session =
                        String(streamKey.split(separator: "|").first ?? "")
                    let av = audioClock(sessionId: session).map { now - $0 }
                    // ADDED - see mse_fix_105's docstring. Read here and
                    // not concatenated into the line below: that chain
                    // is already long enough that adding a generic call
                    // to it is a fight with the type checker for no
                    // gain.
                    let clockFrom = withState {
                        streamParsers[streamKey]?.timebaseFrom ?? "unknown"
                    }
                    // Hoisted for the reason clockFrom above is hoisted:
                    // this concatenation is already long enough that
                    // adding calls into it is a fight with the type
                    // checker for no gain.
                    let effectiveRate = CMTimebaseGetEffectiveRate(timebase)
                    let readingAt = Self.hostNow()
                    // AND ACT ON IT - see mse_fix_135's docstring. The
                    // sound columns below reported `ready true held 94
                    // fed 23` on every one of these lines for
                    // forty-two seconds in capture 6db1f5c7. A line
                    // that can see a stall can end one.
                    nudgeAudio(sessionId: session)
                    // AND WATCHES THE LAG - see mse_fix_148's
                    // docstring. This column has been printed since fix
                    // 100 and never acted on, and in capture d8bae8d7
                    // it read three and a half seconds on thirty-eight
                    // lines in a row while the answer sat in it.
                    //
                    // Positive av is the sound BEHIND the picture. 146
                    // is what makes the write stick: the renderer holds
                    // the media the clock is being moved past, and a
                    // refused write now flushes it and asks again.
                    if let av, av > Self.audioLagLimit, now.isFinite {
                        let due = withState { () -> Bool in
                            guard let slot = streamParsers[streamKey] else {
                                return false
                            }
                            slot.audioLagSeen += 1
                            guard slot.audioLagSeen >= 2 else { return false }
                            let last = slot.audioLagFixedAt
                            if last.isFinite,
                               readingAt - last < Self.audioLagGrace {
                                return false
                            }
                            slot.audioLagSeen = 0
                            slot.audioLagFixedAt = readingAt
                            return true
                        }
                        if due {
                            Self.log("stream \(streamKey) the sound is "
                                     + "\(av)s behind the picture and has "
                                     + "been for two readings - putting it "
                                     + "back on the video clock at \(now)")
                            realignAudioClock(
                                sessionId: session,
                                to: CMTime(seconds: now,
                                           preferredTimescale: 90_000))
                        }
                    } else {
                        withState { streamParsers[streamKey]?.audioLagSeen = 0 }
                    }
                    Self.log("stream \(streamKey) at \(count) - timebase "
                             + "\(now) vs sample pts \(pts), drift "
                             + "\(now - pts), av "
                             + (av.map { String($0) } ?? "no audio clock")
                             // ADDED - see mse_fix_100's docstring. The
                             // video counterpart of fix 97's sound
                             // columns. A timebase on the host clock at
                             // rate 1.0 cannot advance 0.67s in twelve
                             // seconds, and cannot jump twenty-two
                             // forward, so either the rate is not what
                             // this file thinks or the clock being read
                             // is not the one being written.
                             + " | clock rate \(CMTimebaseGetRate(timebase))"
                             // ADDED - see mse_fix_113's docstring.
                             // Through the snapshot: this line is built
                             // on the drain queue and the walk is only
                             // safe on the main one.
                             + Self.layerShapeCached(
                                 layer, streamKey: streamKey)
                             // ADDED - see mse_fix_108's docstring.
                             // CMTimebaseGetRate is the rate relative
                             // to the IMMEDIATE source; this is the one
                             // relative to the master clock, and in
                             // capture 80deceef a clock reporting 1.0
                             // advanced 0.154s in 9.08s of wall time.
                             + " effective \(effectiveRate)"
                             // WHEN the reading was taken, so that
                             // clock-versus-real is arithmetic on two
                             // adjacent lines rather than an
                             // interpolation between unrelated
                             // timestamped ones nine seconds apart.
                             + " host \(readingAt)"
                             // ADDED - see mse_fix_105's docstring. WHICH
                             // timebase, and who installed it.
                             + " timebase "
                             + "\(Unmanaged.passUnretained(timebase).toOpaque())"
                             + " from \(clockFrom)"
                             + " layer "
                             + "\(Unmanaged.passUnretained(layer).toOpaque())"
                             + audioHealth(sessionId: session))
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
        let onto = CMTime(seconds: pts, preferredTimescale: 90_000)
        work.queue.async {
            work.layer.flush()
            if let timebase = work.layer.controlTimebase {
                CMTimebaseSetTime(timebase, time: onto)
            }
        }
        // AND THE SOUND WITH IT.
        //
        // Fix 41 declined this, on the grounds that fix 27's
        // discontinuity was a video-only ABR re-append and dragging
        // audio back eight seconds would repeat it audibly. That is
        // still the cost, and it is still real. But the case in the
        // capture that prompted this is a seek - both halves jumped
        // within thirty-one lines - and letting each re-anchor to its
        // own first sample is what produced a permanent 0.767s offset.
        // A repeated second of sound is recoverable; an offset that
        // lasts the rest of the film is not.
        realignAudioClock(
            sessionId: String(streamKey.split(separator: "|").first ?? ""),
            to: onto)
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

        // The same rule, and the audible half of it - see
        // enqueueForDisplay. A clear sample is already going through
        // Gecko's own audio sink, and a second copy through an
        // AVSampleBufferAudioRenderer is the doubled sound on
        // tv.apple.com.
        // The same correction - see enqueueForDisplay. A clear track
        // still stands down, which is what keeps tv.apple.com's
        // pre-roll from being played twice.
        guard Self.isProtectedSample(sampleBuffer)
                || withState({ slot.trackIsProtected }) else {
            standDown(streamKey: streamKey, half: "audio")
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
            // The element's volume, applied at construction. A renderer
            // built after the volume arrived would otherwise start at
            // 1.0 and stay there until the page next touched the
            // control, which for a muted trailer is never.
            let startingVolume = volumeFor(streamKey)
            renderer.volume = Float(startingVolume)
            renderer.isMuted = startingVolume <= 0.0
            // ADDED - see mse_fix_87's docstring. Four renderers were
            // built on tv.apple.com in one capture and none was ever
            // recorded stopping. A renderer that is still being fed
            // after its track was replaced is the old audio language,
            // still playing, which is exactly what "the switch is not
            // acknowledged" sounds like.
            let already = withState { () -> [String] in
                streamParsers.compactMap { key, other -> String? in
                    guard key != streamKey,
                          key.hasPrefix(sessionOf(streamKey) + "|"),
                          other.audioRenderer != nil else {
                        return nil
                    }
                    return "\(key) fed \(other.audioEnqueued)"
                }.sorted()
            }
            Self.log("stream \(streamKey) built an audio renderer - "
                     + "status \(renderer.status.rawValue) "
                     + "volume \(renderer.volume) "
                     + "muted \(renderer.isMuted)"
                     + (already.isEmpty
                        ? " - the session has no other"
                        : " - session already has \(already.count): ["
                          + already.joined(separator: ", ") + "]"))
            // ADDED - see mse_fix_95's docstring. Fix 87 added the line
            // above to find out whether this ever happened. It happens
            // on tv.apple.com and on Netflix, every player rebuild, and
            // both renderers went on singing. This is what that
            // diagnostic was for.
            supersede(winner: streamKey, half: "audio")
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
            // INTAKE ORDER IS NOT TIMELINE ORDER, ON THIS HALF EITHER.
            //
            // CHANGED - see mse_fix_136's docstring. This is fix 27's
            // test, which fix 102 stood down on the video half three
            // years of captures ago and left running here. In capture
            // 94cc3a44 it fired four times in seventy seconds, threw
            // away 208 queued samples against the 118 that ever reached
            // the renderer, left the renderer holding media forty-six
            // seconds in its own future - thirty seconds of silence,
            // `ready false held 80 fed 24` - and swept the video queue
            // twice on the way past.
            //
            // Its first firing there is false on its own terms:
            // `+32.129s at sample 14` is `belongs to element ... offset
            // 32.083208` being applied partway through intake, the same
            // false positive the video half logs as `Jump 29.12s
            // ignored`.
            //
            // With the element's own position known there is nothing to
            // infer. A renderer holds a sample that is not due and
            // discards one whose time has passed; that is what the
            // synchronizer is for.
            //
            // A stream with no position - the HBO case
            // resynchroniseAudio's own comment is about - keeps the old
            // behaviour exactly.
            if elementPosition(streamKey) != nil {
                let first = withState { () -> Bool in
                    guard let slot = streamParsers[streamKey],
                          !slot.audioStandDownLogged else { return false }
                    slot.audioStandDownLogged = true
                    return true
                }
                if first {
                    Self.log("stream \(streamKey) standing down from the "
                             + "AUDIO discontinuity test - the element "
                             + "says where it is, so intake order proves "
                             + "nothing. Jump \(jump)s ignored.")
                }
            } else {
                resynchroniseAudio(streamKey: streamKey, to: intakePTS,
                                   jump: jump)
            }
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
        writeAudioClock(synchronizer, to: anchor,
                        rate: gatedRate(streamKey), label: streamKey,
                        reason: "startAudioClock")
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

    /// How long a PARKED stream may go without an append before it is
    /// torn down for good.
    ///
    /// ADDED - see mse_fix_95's docstring. Parking is instant, because
    /// the sound has to stop instantly. Teardown waits, because a page
    /// that really does hold two of one half would append to the parked
    /// one again within a segment - and a segment on these sites is two
    /// to six seconds.
    fileprivate static let supersedeWindow: Double = 8.0

    /// The stream videoClock last chose, so a change of mind is visible.
    ///
    /// ADDED - see mse_fix_94's docstring.
    private var lastVideoClockKey: String?

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
                      slot.supersededBy == nil,
                      let found = slot.displayLayer else { continue }
                if newest == nil || slot.lastSampleAt > newest!.fedAt {
                    newest = (found, slot.lastSampleAt)
                }
            }
            return newest?.layer
        }
        // ADDED - see mse_fix_94's docstring. av is an exact, stable
        // offset, and this file's own note says both clocks run on the
        // same host clock and cannot drift - so an offset is an
        // ANCHORING difference. This picks the most recently fed
        // stream's timebase while the drift line reads the reporting
        // stream's own, and in a session with more than one video
        // stream those are different objects. Said when the choice
        // changes, which is when an av step would appear.
        if let layer {
            let chosen = withState { () -> String? in
                for (key, slot) in streamParsers
                where key.hasPrefix(sessionId + "|")
                        && slot.displayLayer === layer {
                    return key
                }
                return nil
            }
            let changed = withState { () -> Bool in
                guard lastVideoClockKey != chosen else { return false }
                lastVideoClockKey = chosen
                return true
            }
            if changed {
                Self.log("video clock for \(sessionId) now follows "
                         + (chosen ?? "an unnamed stream"))
            }
        }
        // NO RATE TEST. It used to require CMTimebaseGetRate != 0, which
        // was right when a stopped clock meant a dead one and wrong the
        // moment fix 48 started holding the video timebase at rate 0
        // until Gecko says the element is playing. That hold is exactly
        // the window the first audio sample arrives in, so audio asked
        // for an anchor, was told there was none, and started 0.767s
        // away from the picture - which is a fixed offset for the rest
        // of the film, because both clocks run on the same host clock
        // and cannot drift.
        //
        // A held clock is not a dead one: its TIME is the anchor audio
        // needs and only its rate is zero. Corpses are excluded by the
        // liveness test above, which asks when the stream was last fed
        // rather than whether someone happened to have started it.
        guard let layer, let timebase = layer.controlTimebase else {
            return nil
        }
        return CMTimebaseGetTime(timebase)
    }

    /// Where the sound's clock is now, for the same session.
    ///
    /// Only used to report the offset between the two. Nothing anchors
    /// to it - the video timebase is the timeline, and audio follows.
    fileprivate func audioClock(sessionId: String) -> Double? {
        // THE MOST RECENTLY FED, and never a parked one.
        //
        // CHANGED - see mse_fix_95's docstring. This took the FIRST
        // started synchronizer in dictionary order, with no liveness
        // test of any kind, and dictionary order is not ordered by
        // anything. In a session holding two renderers - which is every
        // player rebuild on tv.apple.com and on Netflix - the av figure
        // was measured against whichever one the hash landed on, which
        // is where
        //
        //     av -4759.470286519
        //
        // came from: the dead stream's own drift line, reading the live
        // stream's clock. videoClock has picked the most recently fed
        // live stream since fix 94; this is the same choice, for the
        // same reason.
        let sync = withState { () -> AVSampleBufferRenderSynchronizer? in
            var newest: (sync: AVSampleBufferRenderSynchronizer,
                         fedAt: Double)?
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") {
                guard slot.audioStarted, slot.supersededBy == nil,
                      let found = slot.audioSynchronizer else { continue }
                if newest == nil || slot.lastSampleAt > newest!.fedAt {
                    newest = (found, slot.lastSampleAt)
                }
            }
            return newest?.sync
        }
        guard let sync else { return nil }
        return CMTimebaseGetTime(sync.timebase).seconds
    }

    /// The sound's own health, for the drift line.
    ///
    /// ADDED - see mse_fix_97's docstring. av does not hold at the
    /// adoption step, it grows: 2.336, 2.618, 12.750, 14.876 across one
    /// playback, while the video timebase advanced 33.1s and the audio
    /// clock advanced 18.2.
    ///
    /// The two are different KINDS of clock. The video timebase is a
    /// plain CMTimebase on the host clock and runs whatever happens; an
    /// AVSampleBufferRenderSynchronizer's timebase is driven by the
    /// renderer's actual rendering and holds when it is not rendering.
    /// A stalling synchronizer produces exactly this shape - and so
    /// would a rate that quietly went to zero.
    ///
    /// Four columns on a line that already prints, rather than a new
    /// line: this is a measurement, and the drift line is where the
    /// other half of the comparison already lives.
    fileprivate func audioHealth(sessionId: String) -> String {
        let found = withState {
            () -> (key: String, sync: AVSampleBufferRenderSynchronizer,
                   renderer: AVSampleBufferAudioRenderer?,
                   held: Int, fed: Int)? in
            var best: (key: String, sync: AVSampleBufferRenderSynchronizer,
                       renderer: AVSampleBufferAudioRenderer?,
                       held: Int, fed: Int)?
            var fedAt = -Double.infinity
            // The most recently fed, matching audioClock's choice - a
            // session with two renderers must not report one clock and
            // the other's health.
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") {
                guard slot.audioStarted,
                      let sync = slot.audioSynchronizer else { continue }
                guard slot.lastSampleAt > fedAt else { continue }
                fedAt = slot.lastSampleAt
                best = (key: key, sync: sync, renderer: slot.audioRenderer,
                        held: slot.audioPending.count,
                        fed: slot.audioEnqueued)
            }
            return best
        }
        guard let found else { return "" }
        return " | sound \(found.key) rate \(found.sync.rate)"
            + " ready \(found.renderer?.isReadyForMoreMediaData ?? false)"
            + " status \(found.renderer?.status.rawValue ?? -1)"
            + " held \(found.held) fed \(found.fed)"
            + (found.renderer?.error.map { " ERROR \($0)" } ?? "")
    }

    /// A queue used only to READ a clock back a moment later.
    ///
    /// ADDED - see mse_fix_105's docstring. Deliberately not a write
    /// queue: the serial clock queue the redesign needs belongs with the
    /// redesign, and introducing it in a measurement patch would change
    /// the ordering of the very writes being measured.
    fileprivate static let clockProbeQueue =
        DispatchQueue(label: "org.reynard.fps.clockprobe")

    /// Every audio clock write in this file goes through here.
    ///
    /// ADDED - see mse_fix_105's docstring. The five call sites each
    /// wrote and then logged the value they ASKED FOR. On child-19 six
    /// of eight of those writes did not land - two by more than three
    /// hundred seconds - and nothing said so, because there was nothing
    /// to say it. Four separate fixes in this series have been sent
    /// down the wrong path by a line that reports a request as though
    /// it were a result; this is the last place in the file that still
    /// does it.
    ///
    /// The write itself is unchanged: same object, same value, same
    /// thread, same order. Only the reporting is new.
    ///
    /// Read back TWICE. AVSampleBufferRenderSynchronizer schedules a
    /// rate change rather than performing one, so an immediate read can
    /// legitimately show the old value while a later read shows the new
    /// one - and the two cases have opposite implications for the
    /// redesign.
    @discardableResult
    fileprivate func writeAudioClock(
        _ synchronizer: AVSampleBufferRenderSynchronizer,
        to time: CMTime, rate: Float, label: String, reason: String
    ) -> Double {
        synchronizer.setRate(rate, time: time)
        let asked = time.seconds
        let reads = CMTimebaseGetTime(synchronizer.timebase).seconds
        let missed = asked.isFinite && reads.isFinite
            && abs(reads - asked) > 0.05
        Self.log("stream \(label) CLOCK WRITE \(reason) asked \(asked) "
                 + "rate \(rate) - reads \(reads)"
                 + (missed ? " - DID NOT TAKE" : ""))
        Self.clockProbeQueue.asyncAfter(deadline: .now() + 0.05) {
            let later = CMTimebaseGetTime(synchronizer.timebase).seconds
            guard later.isFinite else { return }
            let settled = asked.isFinite && abs(later - asked) <= 0.05
            // Only when it says something the line above did not: a
            // write that landed immediately and stayed put needs no
            // second line.
            guard missed || !settled else { return }
            Self.log("stream \(label) CLOCK WRITE \(reason) reads "
                     + "\(later) after 50ms"
                     + (settled ? " - it settled" : " - still adrift"))
        }
        return reads
    }

    /// Move every started audio clock in this session onto the picture's.
    /// Move every started audio clock in this session onto the
    /// picture's, optionally emptying the renderer first.
    ///
    /// CHANGED - see mse_fix_143's docstring. `flushing` is for a move
    /// the queued sound cannot serve. A synchronizer will not put its
    /// clock past media its renderer already holds, so after a seek
    /// every write here is refused - nine of them in capture 37d82f28,
    /// leaving the sound five thousand seconds from the picture - and
    /// the only thing that makes the write take is emptying the
    /// renderer before it.
    ///
    /// Off by default, because the ordinary caller is setPosition's
    /// half-second correction several times a second. That sweeps
    /// nothing and must flush nothing.
    fileprivate func realignAudioClock(sessionId: String, to time: CMTime,
                                       flushing: Bool = false) {
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
                   slot.supersededBy == nil,
                   let sync = slot.audioSynchronizer {
                    out.append((key, sync))
                }
            }
            return out
        }
        for (key, synchronizer) in started {
            // BOTH ON THE AUDIO QUEUE, IN THIS ORDER - see
            // mse_fix_143's docstring, and resynchroniseAudio, which
            // has done it this way since it was written. flush() and
            // enqueue() must not race, and a write that runs before the
            // flush is the refusal this exists to stop.
            // Two steps rather than a ternary: this file's own note
            // about not fighting the type checker applies, and a
            // multi-statement closure against a bare nil is exactly
            // that fight.
            var emptying: (renderer: AVSampleBufferAudioRenderer,
                           queue: DispatchQueue, dropped: Int)?
            if flushing {
                emptying = withState {
                    () -> (renderer: AVSampleBufferAudioRenderer,
                           queue: DispatchQueue, dropped: Int)? in
                    guard let slot = streamParsers[key],
                          let renderer = slot.audioRenderer,
                          let queue = slot.audioQueue else { return nil }
                    let dropped = slot.audioPending.count
                    slot.audioPending.removeAll()
                    return (renderer, queue, dropped)
                }
            }
            if let emptying {
                Self.log("stream \(key) the element moved somewhere the "
                         + "queued sound cannot serve - dropping "
                         + "\(emptying.dropped) samples and flushing the "
                         + "renderer before the clock is written, or the "
                         + "write is refused")
                let rate = gatedRate(key)
                emptying.queue.async {
                    emptying.renderer.flush()
                    FairPlayStreamParser.shared.writeAudioClock(
                        synchronizer, to: time, rate: rate, label: key,
                        reason: "realignAudioClock after a seek")
                }
            } else {
                let reads = writeAudioClock(synchronizer, to: time,
                                            rate: gatedRate(key),
                                            label: key,
                                            reason: "realignAudioClock")
                // AND IF IT WAS REFUSED, FLUSH AND ASK AGAIN - see
                // mse_fix_146's docstring.
                //
                // 143 predicts the refusal from the video queue having
                // been swept, and in capture dd24aee2 both failures are
                // moves where nothing was swept: Netflix sits three and
                // a half seconds out for a whole playback because the
                // renderer holds the samples the clock is being moved
                // past, and a scrub in the same session is refused five
                // hundred and forty seconds out. queueStrays answers a
                // question about the VIDEO queue; this is a fact about
                // the audio renderer.
                //
                // The read-back is not a prediction. It has said DID
                // NOT TAKE on every one of these and on nothing else,
                // so acting on it cannot flush a write that would have
                // worked.
                // clockRefused, NOT clockLanded - see mse_fix_149's
                // docstring. The read-back is taken after the clock has
                // started running, so it is never exact, and flushing a
                // renderer for that costs a minute of queued sound.
                if reads.isFinite, time.seconds.isFinite,
                   abs(reads - time.seconds) > Self.clockRefused {
                    let refused = withState {
                        () -> (renderer: AVSampleBufferAudioRenderer,
                               queue: DispatchQueue, dropped: Int)? in
                        guard let slot = streamParsers[key],
                              let renderer = slot.audioRenderer,
                              let queue = slot.audioQueue else {
                            return nil
                        }
                        let dropped = slot.audioPending.count
                        slot.audioPending.removeAll()
                        return (renderer, queue, dropped)
                    }
                    if let refused {
                        Self.log("stream \(key) the clock would not move "
                                 + "to \(time.seconds) - it reads "
                                 + "\(reads), so the renderer is holding "
                                 + "media in the way. Dropping "
                                 + "\(refused.dropped) queued samples, "
                                 + "flushing it and asking again.")
                        let rate = gatedRate(key)
                        refused.queue.async {
                            refused.renderer.flush()
                            FairPlayStreamParser.shared.writeAudioClock(
                                synchronizer, to: time, rate: rate,
                                label: key,
                                reason: "realignAudioClock after a refusal")
                        }
                    }
                }
            }
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
        // AND THE PICTURE'S QUEUE WITH IT - see mse_fix_107's docstring.
        //
        // This detector has been right every time it has fired - nine
        // firings in capture c49b7746, five in 8ec30c6a, no false ones
        // - and the video half has never been told. HBO needs it: it
        // reported ONE element position in each of the last two
        // captures, so setPosition's sweep will not reach it, and its
        // audio path caught every seek in both.
        let session = String(streamKey.split(separator: "|").first ?? "")
        let owner = withState { streamParsers[streamKey]?.owner ?? 0 }
        // AGAINST THE ELEMENT, not against the sound's intake - see
        // mse_fix_136's docstring. `pts` is where the AUDIO PARSER has
        // reached, which on a page that buffers ahead is not where
        // anything is being played. In capture 94cc3a44 that was 2733
        // while the picture was at 2687, and this line swept all 460
        // samples out of a healthy video queue: `the sound jumped to
        // 2733.644533333333 - swept 460 samples that were not near it,
        // 0 left in the queue`.
        //
        // Sweeping the picture to where the sound's buffer has reached
        // is never right. Where the element is, is.
        let authority = mediaAuthority(streamKey) ?? pts
        sweepOwnedVideo(sessionId: session, owner: owner,
                        authority: authority,
                        why: "the sound jumped to")
        // On the drain queue, for the same collision flush() and
        // enqueue() can have on the video side.
        work.queue.async {
            work.renderer.flush()
            // ONTO THE VIDEO CLOCK, not onto this stream's own PTS.
            //
            // Audio and video segments legitimately start at different
            // times - 0.767s apart in the stream that produced this fix
            // - so anchoring each half to its own first sample after an
            // event bakes that difference into a permanent A/V offset.
            // The video timebase is the timeline; audio follows it, and
            // uses its own PTS only when there is no video clock at all.
            let parser = FairPlayStreamParser.shared
            let session = String(streamKey.split(separator: "|").first ?? "")
            let onto = parser.videoClock(sessionId: session)
                ?? CMTime(seconds: pts, preferredTimescale: 90_000)
            parser.writeAudioClock(work.sync, to: onto,
                                   rate: parser.gatedRate(streamKey),
                                   label: streamKey,
                                   reason: "resynchroniseAudio")
        }
    }

    /// How long an armed drain may sit on a ready renderer with a
    /// queue behind it before the arm is presumed dead.
    ///
    /// ADDED - see mse_fix_135's docstring. A renderer that is ready
    /// with samples waiting is fed within a millisecond when the
    /// callback is alive; a second is three orders of magnitude of
    /// slack and still catches the forty-two second silence in capture
    /// 6db1f5c7 on the first check.
    fileprivate static let audioArmGrace: Double = 1.0

    /// How far past the synchronizer's clock the head of the audio
    /// queue is, when that is further than the drain should go.
    ///
    /// ADDED - see mse_fix_136's docstring. nil means "feed it": the
    /// queue is empty, the clock cannot be read, or the head is due.
    /// An AVSampleBufferAudioRenderer handed media a long way into its
    /// own future schedules it, reports itself not ready, and stops
    /// asking - which in capture 94cc3a44 was thirty seconds of
    /// silence with `ready false held 80 fed 24`.
    ///
    /// The same three seconds the video half paces to, for the same
    /// reason: it is comfortably more than playback needs and an order
    /// of magnitude below a page's lookahead.
    fileprivate func audioHeadIsAhead(_ streamKey: String) -> Double? {
        let found = withState {
            () -> (sync: AVSampleBufferRenderSynchronizer, at: Double)? in
            guard let slot = streamParsers[streamKey],
                  let sync = slot.audioSynchronizer,
                  let first = slot.audioPending.first else { return nil }
            let at = CMSampleBufferGetPresentationTimeStamp(first).seconds
            guard at.isFinite else { return nil }
            return (sync, at)
        }
        guard let found else { return nil }
        let now = CMTimebaseGetTime(found.sync.timebase).seconds
        guard now.isFinite, found.at - now > Self.feedAhead else {
            return nil
        }
        return found.at - now
    }

    /// Is this stream's arm set but doing nothing?
    ///
    /// ADDED - see mse_fix_135's docstring. Read as two steps because
    /// isReadyForMoreMediaData belongs to the renderer and everything
    /// else belongs to the lock, and this file does not call out of
    /// withState.
    private func audioArmIsStalled(_ streamKey: String) -> Bool {
        let found = withState {
            () -> (renderer: AVSampleBufferAudioRenderer, since: Double)? in
            guard let slot = streamParsers[streamKey],
                  slot.audioDrainArmed, !slot.audioPending.isEmpty,
                  let renderer = slot.audioRenderer else { return nil }
            return (renderer, slot.audioFedAt)
        }
        guard let found, found.since.isFinite,
              Self.hostNow() - found.since > Self.audioArmGrace
        else { return false }
        // A HOLD IS NOT A STALL - see mse_fix_136's docstring. With the
        // horizon in place the drain deliberately leaves a ready
        // renderer unfed while the head is not due, and 135's detector
        // would read that as a dead callback and raise the arm again
        // every second for as long as it lasted.
        guard audioHeadIsAhead(streamKey) == nil else { return false }
        return found.renderer.isReadyForMoreMediaData
    }

    /// Ask the renderer to come and get them, if it is not already
    /// asking - or if it is asking and nothing is coming.
    private func armAudioDrainIfNeeded(streamKey: String) {
        // OUTSIDE the lock, because both read the renderer or its
        // clock.
        let stalled = audioArmIsStalled(streamKey)
        let headIsAhead = audioHeadIsAhead(streamKey) != nil
        let work = withState { () -> (renderer: AVSampleBufferAudioRenderer,
                                      queue: DispatchQueue,
                                      again: Bool, held: Int)? in
            guard let slot = streamParsers[streamKey],
                  slot.audioStarted,
                  // RAISED AGAIN - see mse_fix_135's docstring. This
                  // guard used to be `!slot.audioDrainArmed` alone, and
                  // in capture 6db1f5c7 it turned away every call for
                  // the last forty-two seconds of the stream while the
                  // renderer sat ready and the queue grew from 3 to 94.
                  !slot.audioDrainArmed || stalled,
                  slot.supersededBy == nil,
                  !slot.audioPending.isEmpty,
                  // AND DUE - see mse_fix_136's docstring. Arming on a
                  // head the drain will refuse puts the block straight
                  // back into the loop it just left.
                  !headIsAhead,
                  let renderer = slot.audioRenderer,
                  let queue = slot.audioQueue else { return nil }
            let again = slot.audioDrainArmed
            slot.audioDrainArmed = true
            // Started now, so a fresh arm gets a full grace period
            // before it can be judged stalled.
            slot.audioFedAt = Self.hostNow()
            return (renderer, queue, again, slot.audioPending.count)
        }
        guard let work else { return }
        if work.again {
            Self.log("stream \(streamKey) the audio arm was set and "
                     + "nothing was coming - renderer ready with "
                     + "\(work.held) samples waiting. Raised again.")
        }
        // ON THE AUDIO QUEUE, both halves - see mse_fix_135's docstring.
        // stopRequestingMediaData already ran there, from inside the
        // block; the request that pairs with it was raised from
        // whichever thread the parser called us on, and those two have
        // to be ordered against each other.
        work.queue.async {
            if work.again {
                work.renderer.stopRequestingMediaData()
            }
            work.renderer.requestMediaDataWhenReady(on: work.queue) {
                [weak renderer = work.renderer] in
                guard let renderer else { return }
                FairPlayStreamParser.shared.drainAudioPending(
                    streamKey: streamKey, renderer: renderer)
            }
        }
    }

    /// Give every audio renderer in a session a chance to be re-armed.
    ///
    /// ADDED - see mse_fix_135's docstring. Called from the video
    /// drain's periodic block, which is the line that watched this
    /// stall for forty-two seconds and only reported it. Intake covers
    /// the ordinary case; this covers a page that has buffered ahead
    /// and gone quiet, where there is no intake left to re-arm on.
    fileprivate func nudgeAudio(sessionId: String) {
        let keys = withState { () -> [String] in
            streamParsers.compactMap { key, slot -> String? in
                guard key.hasPrefix(sessionId + "|"), slot.audioStarted,
                      slot.supersededBy == nil,
                      !slot.audioPending.isEmpty else { return nil }
                return key
            }
        }
        for key in keys {
            armAudioDrainIfNeeded(streamKey: key)
        }
    }

    /// Feed the renderer while it is hungry, and stop asking when it is
    /// not.
    fileprivate func drainAudioPending(
        streamKey: String, renderer: AVSampleBufferAudioRenderer) {
        while renderer.isReadyForMoreMediaData {
            // NOT ITS OWN FUTURE - see mse_fix_136's docstring.
            //
            // Stopped rather than simply returned: this block is being
            // called in a loop for as long as the renderer is ready, so
            // returning without enqueueing would spin. The re-arm comes
            // from audio intake, which runs on every append, and from
            // 135's nudge on the video drain every thirty samples - so
            // feeding resumes within about a second of the head coming
            // due, against a three second horizon.
            if let ahead = audioHeadIsAhead(streamKey) {
                let first = withState { () -> Bool in
                    guard let slot = streamParsers[streamKey],
                          !slot.audioHorizonLogged else { return false }
                    slot.audioHorizonLogged = true
                    return true
                }
                if first {
                    Self.log("stream \(streamKey) holding the sound at the "
                             + "horizon - the head of the queue is "
                             + "\(ahead)s past the synchronizer's clock, "
                             + "and a renderer handed that stops asking. "
                             + "Fed again as the clock reaches it.")
                }
                renderer.stopRequestingMediaData()
                withState { streamParsers[streamKey]?.audioDrainArmed = false }
                return
            }
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
                // WHEN - see mse_fix_135's docstring. This is what tells
                // a working arm from a dead one.
                slot.audioFedAt = Self.hostNow()
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
            // AND RECOVER IT - see mse_fix_180's docstring. This is the
            // audio half of fix 157, which was never written.
            //
            // status .failed is terminal for a renderer exactly as it is
            // for a layer: it goes on accepting samples and discarding
            // all of them until flush() resets it. In capture a8bc28b1
            // the renderer failed on its FIRST sample with -11800 - no
            // content key present, one millisecond after being made a
            // key recipient - and then took 234 more audio samples
            // without playing one of them, while video ran.
            //
            // Rate-limited by the same gap the video recovery uses, so a
            // renderer that fails on every sample costs one flush a
            // second rather than one per sample.
            if renderer.status == .failed {
                let recovery = withState { () -> Int? in
                    guard let slot = streamParsers[streamKey] else {
                        return nil
                    }
                    let now = Self.hostNow()
                    guard now - slot.audioLastFailRecoveryAt
                            > Self.failRecoveryGap else { return nil }
                    slot.audioLastFailRecoveryAt = now
                    slot.audioFailRecoveries += 1
                    return slot.audioFailRecoveries
                }
                if let recovery {
                    Self.log("stream \(streamKey) the audio renderer has "
                             + "FAILED - "
                             + (renderer.error.map { String(describing: $0) }
                                ?? "no error given")
                             + " - flushing it. Recovery \(recovery). "
                             + "Without this it accepts every sample and "
                             + "plays none of them.")
                    // On this queue, which is where enqueue happens -
                    // flush() racing an enqueue is the one collision
                    // these two calls can have.
                    renderer.flush()
                }
            }
            // ADDED - see mse_fix_87's docstring. One line naming every
            // renderer in this session and how much each has taken. Two
            // of them climbing together is the old audio language still
            // being fed; one climbing and one frozen is a leak but not
            // the cause of anything audible.
            //
            // Every two hundred samples, which is a few seconds of
            // audio, so a long playback costs a handful of lines.
            if count % 200 == 0 {
                let session = sessionOf(streamKey)
                let census = withState { () -> [String] in
                    streamParsers.compactMap { key, other -> String? in
                        guard key.hasPrefix(session + "|"),
                              let renderer = other.audioRenderer else {
                            return nil
                        }
                        return "\(key) fed \(other.audioEnqueued) muted "
                             + "\(renderer.isMuted)"
                    }.sorted()
                }
                if census.count > 1 {
                    Self.log("session \(session) audio census: "
                             + census.joined(separator: ", "))
                }
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
                    // Onto the video clock where there is one - see
                    // resynchroniseAudio for why the audio PTS is the
                    // wrong reference.
                    let session =
                        String(streamKey.split(separator: "|").first ?? "")
                    let onto = videoClock(sessionId: session)
                        ?? CMTime(seconds: pts, preferredTimescale: 90_000)
                    writeAudioClock(sync, to: onto,
                                    rate: gatedRate(streamKey),
                                    label: streamKey,
                                    reason: "audioCorrector")
                    Self.log("stream \(streamKey) AUDIO CLOCK RAN AHEAD by "
                             + "\(ranAhead.late)s - put back on the media "
                             + "at \(pts). Correction \(ranAhead.nth).")
                    // READ IT BACK. The last capture corrected
                    // thirty-two times and the clock reported 35.3555 on
                    // every one of them - so either setRate did nothing
                    // or something moved it back, and arithmetic on a log
                    // is a poor way to find out which. Said once.
                    // CHANGED - see
                    // mse_fix_94_the_refusal_was_a_false_alarm.py's
                    // docstring. This compared against pts while the
                    // write above targets onto, and those differ by
                    // exactly the gap the correction exists to close -
                    // so it reported a refusal on every SUCCESSFUL
                    // correction. The capture reads 480.261 against an
                    // onto of 480.261: the clock went precisely where it
                    // was sent.
                    let after = CMTimebaseGetTime(sync.timebase).seconds
                    if abs(after - onto.seconds) > 1.0 {
                        let first = withState { () -> Bool in
                            guard let slot = streamParsers[streamKey],
                                  !slot.reportedUnmovedClock else { return false }
                            slot.reportedUnmovedClock = true
                            return true
                        }
                        if first {
                            Self.log("stream \(streamKey) the "
                                     + "synchronizer's clock did NOT move - "
                                     + "asked for \(onto.seconds), it "
                                     + "reads "
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
        guard Self.addRecipient(keySession, recipient: recipient,
                                label: "stream \(streamKey) audio renderer")
        else { return }
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
            for (key, slot) in streamParsers
            where slot.displayLayer != nil && slot.supersededBy == nil {
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
        } else if let mediaAt = mediaAuthority(streamKey), mediaAt.isFinite {
            // WHERE THE MEDIA IS - see mse_fix_128's docstring. There is
            // no running clock to copy at launch, and the fallback below
            // is lastIntakePTS: the last sample taken in, which after a
            // seek is media the sweep has just thrown away. In capture
            // b6d4f046 that anchored the first layer at 852.76 when the
            // element had said 883.0 one line earlier, so nothing the
            // layer was given could be presented and the picture did not
            // appear until the fourth layer.
            //
            // This is the same authority 106, 107, 109 and 124 use for
            // every other question about where the media is. Adopt was
            // the last place still guessing from intake.
            anchor = CMTime(seconds: mediaAt, preferredTimescale: 90_000)
        } else {
            // Neither a clock nor an authority - an older content
            // process, or a stream that has not been claimed by an
            // element. Unchanged.
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
        // CHANGED - see mse_fix_106's docstring. Unbounded, this moved
        // the anchor back 1429.05s on tv.apple.com and 369.62s on HBO,
        // onto pre-seek media the queue had never dropped - and it
        // printed the correct reading on the same line before throwing
        // it away:
        //
        //   the old clock read 2070.356609875 with the media it is
        //   handing over at 641.3070805555556 - anchoring to the media
        //
        // realignAudioClock then took every audio clock in the session
        // to 641.31 as well. The clamp is for a clock that ran ahead of
        // its own media during a pause - fix 41's ten and a half
        // seconds - not a licence to go back to another part of the
        // film.
        let mediaAt = mediaAuthority(streamKey)
        var clampable = true
        if let mediaAt, let oldestHeld, mediaAt.isFinite {
            clampable = oldestHeld >= mediaAt - Self.strandedBehind
        }
        // AND NOT WHEN THE ANCHOR IS ALREADY WHERE THE ELEMENT IS - see
        // mse_fix_148's docstring.
        //
        // This clamp is for a clock that ran ahead of its own media
        // while the page was paused - fix 41's ten and a half seconds -
        // and the test for that is whether the anchor is ahead of where
        // the MEDIA is, not ahead of whatever the queue still holds.
        //
        // HBO resumes at 1023.697 into a buffered range of
        // [1020.16-1024.12], so the queue legitimately starts three and
        // a half seconds before the element. The guard above asked
        // `1020.12 >= 963.697` and clamped, the realign at the end of
        // adopt copied 1020.12 onto the audio clock, and the sound sat
        // three and a half seconds behind the picture for the rest of
        // the playback.
        //
        // An anchor at or behind the element is already correct.
        // Nothing is gained by moving it and this is what was lost.
        if let mediaAt, mediaAt.isFinite, anchor.seconds.isFinite,
           anchor.seconds <= mediaAt + Self.positionSlack {
            clampable = false
        }
        if let oldestHeld, anchor.seconds > oldestHeld, clampable {
            Self.log("stream \(streamKey) the old clock read "
                     + "\(anchor.seconds) with the media it is handing "
                     + "over at \(oldestHeld) - anchoring to the media")
            anchor = CMTime(seconds: oldestHeld, preferredTimescale: 90_000)
        } else if let oldestHeld, anchor.seconds > oldestHeld {
            Self.log("stream \(streamKey) the old clock read "
                     + "\(anchor.seconds) and the queue starts at "
                     + "\(oldestHeld), but the media is at "
                     + "\(mediaAt ?? Double.nan) - that queue is stale, so the "
                     + "clock keeps its reading")
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
            CMTimebaseSetRate(timebase, rate: Float64(gatedRate(streamKey)))
            sink.controlTimebase = timebase
            // ADDED - see mse_fix_94's docstring. The Netflix capture
            // has this reporting an anchor of 121.281 and the drift line
            // three lines later reading 99.003 off the same stream. A
            // control timebase cannot always be replaced on a layer that
            // has already had buffers enqueued, and the compositor pools
            // its layers - so the assignment above may be silently
            // ignored. Read it back and say so.
            if let installed = sink.controlTimebase {
                let reads = CMTimebaseGetTime(installed).seconds
                let took = installed === timebase
                    && abs(reads - anchor.seconds) <= 0.05
                Self.log("stream \(streamKey) adopt timebase reads "
                         + "\(reads) rate \(CMTimebaseGetRate(installed)) "
                         + "layer \(Unmanaged.passUnretained(sink).toOpaque())"
                         + (took ? "" : " - THE SET DID NOT TAKE"))
            } else {
                Self.log("stream \(streamKey) adopt left the layer with NO "
                         + "control timebase")
            }
        } else {
            Self.log("stream \(streamKey) could not build a timebase for "
                     + "the compositor's layer - it will present as fast as "
                     + "it decodes")
        }
        sink.videoGravity = .resizeAspect

        // ADDED - see mse_fix_105's docstring. Two of Netflix's three
        // silent discard sinks are in the block below, and between them
        // they account for frames this file has never reported at all.
        // Captured rather than logged in place: nothing should log while
        // it holds the lock.
        var adoptTrimmed = 0
        var adoptDumped = 0
        var adoptGateHeld = 0
        let handover = withState {
            () -> (old: AVSampleBufferDisplayLayer?, observer: NSObjectProtocol?,
                   queue: DispatchQueue?, carried: Int, held: Int,
                   waiting: Bool)? in
            guard let slot = streamParsers[streamKey] else { return nil }
            let old = slot.displayLayer
            let observer = slot.failObserver
            slot.timebaseFrom = "adopt"
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
            // TWO GOPS - see mse_fix_110's docstring. With one, this
            // was zero by arithmetic whenever the display queue was
            // deeper than a GOP, which is most of the time: seven of
            // eleven adoptions in capture 7a522e97 carried nothing and
            // every one of those had a queue of 183 samples or more.
            //
            // The run still starts on a keyframe, because previousGOP
            // starts on one by construction, so the new layer can
            // decode from the first sample it is handed.
            // BY TIME, not by counting - see mse_fix_111's docstring.
            // What the new layer needs is the run from the last
            // KEYFRAME at or before the clock it is inheriting, forward
            // to the first sample still queued. The old arithmetic -
            // window size minus queue depth - answered a different
            // question, and answered zero whenever the queue was deeper
            // than the window.
            let fed = slot.previousGOP + slot.currentGOP
            let target = anchor.seconds
            let queuedFrom = slot.pending.first.map {
                CMSampleBufferGetPresentationTimeStamp($0).seconds
            } ?? Double.infinity
            let usable = fed.filter { sample in
                let at = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                return at.isFinite && at < queuedFrom
            }
            // AND NOT FROM ANOTHER PART OF THE FILM - see
            // mse_fix_129's docstring. The window is four hundred
            // samples, and when it spans a gap the last keyframe at or
            // before the clock can be thirty-nine seconds back, as it
            // was in capture c7528ff8. Those frames decode and are
            // thrown away. staleBehind is what 124 already decided
            // "too far behind" means, and a reference run is no
            // different.
            var carried: [CMSampleBuffer] = []
            if let start = usable.lastIndex(where: { sample in
                let at = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                return Self.isSyncSample(sample) && at <= target
                    && at >= target - Self.staleBehind
            }) {
                carried = Array(usable[start...])
            }
            let held = slot.pending.count
            if !carried.isEmpty {
                slot.pending = carried + slot.pending
                slot.needsSyncSample = false
            } else if let at = slot.pending.firstIndex(
                          where: { Self.isSyncSample($0) }) {
                // Nothing to carry, but the queue already contains a
                // keyframe: start there rather than waiting for the next
                // one to arrive from the source.
                adoptTrimmed = at
                adoptGateHeld = slot.droppedSinceSync
                slot.droppedSinceSync = 0
                // With the span it was accumulating - see
                // mse_fix_132's docstring.
                slot.droppedSinceSyncFrom = Double.nan
                slot.droppedSinceSyncTo = Double.nan
                slot.pending.removeFirst(at)
                slot.needsSyncSample = false
            } else {
                // The one case where the old behaviour was right.
                adoptDumped = slot.pending.count
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
        // HOW LONG THE BLACK IS - see mse_fix_110's docstring. The
        // clock is anchored where the picture was; this is the first
        // frame the new layer will actually be given, and the distance
        // between them is time with nothing to show. Reconstructing it
        // from separate lines took eleven adoptions and a script.
        let firstUp = withState { () -> Double? in
            guard let head = streamParsers[streamKey]?.pending.first
            else { return nil }
            let at = CMSampleBufferGetPresentationTimeStamp(head).seconds
            return at.isFinite ? at : nil
        }
        if let firstUp {
            Self.log("stream \(streamKey) the new layer starts "
                     + "\(firstUp - anchor.seconds)s after its clock - "
                     + "first frame at \(firstUp), clock at "
                     + "\(anchor.seconds) - " + Self.layerShape(sink))
        } else {
            Self.log("stream \(streamKey) the new layer has NO frame to "
                     + "start from - its clock is at \(anchor.seconds) "
                     + "and the queue is empty")
        }
        // ADDED - see mse_fix_105's docstring. Said only when there is
        // something to say, so a clean handover stays a single line.
        if adoptTrimmed > 0 || adoptDumped > 0 || adoptGateHeld > 0 {
            Self.log("stream \(streamKey) adopt trimmed \(adoptTrimmed) "
                     + "samples ahead of the first sync sample, dumped "
                     + "\(adoptDumped), and reopened the resync gate with "
                     + "\(adoptGateHeld) already dropped and never "
                     + "reported")
        }
        // AND THE SOUND FOLLOWS THE PICTURE, HERE TOO.
        //
        // ADDED - see mse_fix_97's docstring. markLayerAttached
        // re-anchors the audio when it starts the video timebase, and
        // says why - "the master clock just started ... so it is
        // re-anchored here, to the one clock that matters". This path
        // moves that clock as well: it builds a NEW timebase and anchors
        // it to the oldest sample being handed over. It never told the
        // audio, so every adoption left a fixed offset:
        //
        //     released the timebase at 5476.586125
        //     audio clock re-anchored to 5476.586125
        //     at 30 - ... av 0.0
        //     adopted the compositor's layer at 5478.921788888889
        //     at 60 - ... av 2.33566388888903
        //
        // 5478.921789 - 5476.586125 = 2.335664, to the microsecond.
        //
        // The timebase is READ BACK rather than assumed. Fix 94 added
        // that read-back because the set does not always take, and
        // anchoring the sound to a time the picture is not at would
        // trade one offset for another.
        if let landed = sink.controlTimebase {
            realignAudioClock(sessionId: sessionOf(streamKey),
                              to: CMTimebaseGetTime(landed))
        }
        armDrainIfNeeded(streamKey: streamKey)
    }

    /// Can the decoder start here?
    ///
    /// No attachments at all means nothing declared this sample to depend
    /// on another, which is a sync sample. Absence of the NotSync key
    /// means the same thing.
    /// What the layer we are feeding actually looks like.
    ///
    /// ADDED - see mse_fix_113's docstring. A layer with no area, or
    /// one that is not in a tree, or a hidden one, accepts every sample
    /// and reports status 1 and ready true while showing nothing. This
    /// file has had no way to tell that apart from working, and
    /// "landscape controls show on screen, no video" is exactly what it
    /// looks like from the outside.
    ///
    /// Read where the rest of the layer's properties are read. Rounded,
    /// because the question is whether there is a picture-sized box,
    /// not what its subpixel geometry is.
    ///
    /// MAIN THREAD. This and the two walks below read the live layer
    /// tree - superlayer, sublayers, frame, opacity, contents - and the
    /// main thread and the compositor rebuild that tree while playback
    /// runs. A caller that is not on the main thread reads it through
    /// layerShapeCached instead.
    fileprivate static func layerShape(_ layer: CALayer) -> String {
        let box = layer.bounds.size
        return "box \(Int(box.width.rounded()))x"
            + "\(Int(box.height.rounded()))"
            + " super \(layer.superlayer != nil)"
            + " hidden \(layer.isHidden)"
            // AND THE SINK'S OWN - see mse_fix_174's docstring.
            + Self.layerPlane(layer)
            // WHERE IT LANDS - see mse_fix_171's docstring. Everything
            // above this line has reported healthy through 48 samples
            // of a black screen; none of it is geometry.
            + Self.layerWhere(layer)
            // WHO IS ABOVE IT - see mse_fix_138's docstring.
            + Self.layerChain(layer)
            // AND WHAT IS OVER IT - see mse_fix_154's docstring.
            + Self.layersOver(layer)
    }

    /// WHERE the layer lands, and what takes it away.
    ///
    /// ADDED - see mse_fix_171's docstring. layerShape prints
    /// `layer.bounds` and nothing else about geometry: a size, with no
    /// origin, no transform, and no answer to whether the box it
    /// describes is anywhere a person could see it. Every landscape
    /// sample in captures 47fe9153 and 542f7cb6 reads `super true
    /// hidden false` with a correct 640x267 box while the screen is
    /// black, and layerChain and layersOver both come back clean.
    ///
    /// A layer moved off the window, scaled to nothing, clipped away by
    /// an ancestor's bounds, or animated somewhere else by Core
    /// Animation reads EXACTLY like that.
    ///
    /// So this walks the path layerChain walks and carries the
    /// rectangle with it, in two copies: one that every clipping
    /// ancestor is allowed to cut, and one that nothing cuts. Where
    /// they disagree is the whole question, and reporting both is what
    /// makes "clipped away" and "positioned somewhere else" different
    /// words rather than the same silence.
    ///
    /// The model tree is not what the render server draws while an
    /// animation is in flight, so the presentation layer is read too,
    /// and reported only when it disagrees.
    ///
    /// MAIN THREAD, for the reason layerShape is: this reads the live
    /// tree. Bounded at twelve, like the other two walks, so a cycle
    /// cannot turn a log line into a hang.
    fileprivate static func layerWhere(_ layer: CALayer) -> String {
        var out = ""
        // Never printed before. A sink at zero opacity accepts every
        // sample and reports status 1 exactly like a visible one.
        if layer.opacity < 0.999 { out += " OPACITY \(layer.opacity)" }
        let transform = layer.transform
        if !CATransform3DIsIdentity(transform) {
            out += " scale \(Self.twoPlaces(transform.m11))"
                + "x\(Self.twoPlaces(transform.m22))"
        }

        // `clipped` is cut by every ancestor that masks; `free` is not
        // cut by anything. Both start as the sink's own bounds and end
        // in root - window - coordinates.
        var clipped = layer.bounds
        var free = layer.bounds
        var takenBy: String? = nil
        var current: CALayer = layer
        var root: CALayer = layer
        var depth = 0
        while let parent = current.superlayer, depth < 12 {
            free = current.convert(free, to: parent)
            // Once something has taken the rectangle, stop cutting it:
            // converting an empty rect up the rest of the tree yields a
            // travelling zero-sized box and says nothing.
            if takenBy == nil {
                clipped = current.convert(clipped, to: parent)
                if parent.masksToBounds {
                    let kept = clipped.intersection(parent.bounds)
                    if kept.isNull || kept.width < 1 || kept.height < 1 {
                        takenBy = "<\(type(of: parent))"
                            + " \(Int(parent.bounds.width.rounded()))x"
                            + "\(Int(parent.bounds.height.rounded()))"
                            + " at depth \(depth + 1)>"
                    } else {
                        clipped = kept
                    }
                }
            }
            root = parent
            current = parent
            depth += 1
        }

        out += " at " + Self.rectText(free)
        // No parent at all: layerChain already says `<none>`, and there
        // is no root to be inside of.
        if depth == 0 { return out + " of nothing" }
        out += " of root \(Int(root.bounds.width.rounded()))x"
            + "\(Int(root.bounds.height.rounded()))"

        if let takenBy = takenBy {
            out += " CLIPPED AWAY by " + takenBy
        } else {
            let onScreen = free.intersection(root.bounds)
            if onScreen.isNull || onScreen.width < 1
                || onScreen.height < 1 {
                out += " OFF SCREEN"
            } else if clipped.width < free.width - 1
                || clipped.height < free.height - 1 {
                out += " visible " + Self.rectText(clipped)
            } else {
                out += " visible whole"
            }
        }

        // What the render server is drawing, when that is not what the
        // model tree says. An animation that carries the sink off the
        // window leaves every model-tree property correct.
        if let live = layer.presentation() {
            let model = layer.frame
            let shown = live.frame
            if shown.isNull || model.isNull || shown.isInfinite {
                // Nothing to compare, and rectText would say so anyway.
            } else if abs(shown.origin.x - model.origin.x) > 1
                || abs(shown.origin.y - model.origin.y) > 1
                || abs(shown.width - model.width) > 1
                || abs(shown.height - model.height) > 1 {
                out += " ANIMATING to " + Self.rectText(shown)
            }
            if abs(live.opacity - layer.opacity) > 0.01 {
                out += " live opacity \(live.opacity)"
            }
        }
        return out
    }

    /// A rectangle, rounded, for layerWhere.
    ///
    /// Rounded for the reason layerShape rounds: the question is where
    /// a picture-sized box is, not what its subpixel geometry is.
    ///
    /// Guarded, for a reason specific to this probe. A layer scaled to
    /// zero is one of the four faults layerWhere exists to catch, and
    /// converting a rectangle up through a zero-scale transform is
    /// exactly how CGRect acquires an infinity. `Int(Double.infinity)`
    /// is a trap in Swift, not a large number - so the diagnostic that
    /// went looking for the collapsed layer would be the thing that
    /// took playback down with it.
    fileprivate static func rectText(_ rect: CGRect) -> String {
        if rect.isNull { return "nowhere" }
        if rect.isInfinite { return "infinite" }
        let parts = [rect.origin.x, rect.origin.y,
                     rect.width, rect.height]
        for part in parts where !part.isFinite || abs(part) > 1e7 {
            return "unreadable"
        }
        return "\(Int(rect.origin.x.rounded())),"
            + "\(Int(rect.origin.y.rounded())) "
            + "\(Int(rect.width.rounded()))x"
            + "\(Int(rect.height.rounded()))"
    }

    /// Two decimal places, without dragging in a formatter.
    fileprivate static func twoPlaces(_ value: CGFloat) -> String {
        return "\((value * 100).rounded() / 100)"
    }

    /// Whether this layer can be composited at all, and on what.
    ///
    /// ADDED - see mse_fix_174's docstring. Capture 508bf50e excluded
    /// the whole CALayer tree: with the report cap raised and
    /// backgroundColor read, not one covering layer paints, not one
    /// ancestor hides or fades, and the sink is `visible whole` at
    /// correct geometry and scale with `status 1 ready true` - while
    /// the screen is black.
    ///
    /// What has never been read is the one property this project sets
    /// on this layer for this content: preventsCapture. A layer that
    /// carries it holds its pixels on a protected plane, which the
    /// render server can scan out to the display and cannot copy into
    /// an intermediate buffer. Anything that forces the subtree through
    /// such a buffer therefore renders black with every property this
    /// file prints still perfectly correct.
    ///
    /// Read by KVC rather than by casting: preventsCapture is declared
    /// on AVSampleBufferDisplayLayer behind an availability annotation,
    /// and a diagnostic should not be the reason a build stops
    /// compiling on a different SDK. responds(to:) makes the absence
    /// silent rather than fatal.
    ///
    /// MAIN THREAD, for the reason layerShape is.
    fileprivate static func layerPlane(_ layer: CALayer) -> String {
        var out = ""
        if layer.responds(to: NSSelectorFromString("preventsCapture")),
           let flag = layer.value(forKey: "preventsCapture") as? Bool {
            out += " preventsCapture \(flag ? 1 : 0)"
        }
        // IS THE PICTURE BEING WITHHELD - see mse_fix_176's docstring.
        // preventsCapture above is the flag this project SETS; it says
        // the request was made and nothing about whether AVFoundation
        // is acting on it. This is the one AVFoundation raises when it
        // will not put protected pixels on the current output, and it
        // produces exactly the reported symptom: the video plane blank,
        // audio running, subtitles and controls compositing normally on
        // top, and every layer property correct - because the layer is
        // correct and the picture is being withheld from it.
        let obscuredKey = "outputObscuredDueToInsufficientExternalProtection"
        if layer.responds(to: NSSelectorFromString(obscuredKey)),
           let withheld = layer.value(forKey: obscuredKey) as? Bool {
            out += " obscured \(withheld ? 1 : 0)"
        }
        // AND WHAT THE OUTPUT LOOKS LIKE. Protected content is withheld
        // when the picture would reach somewhere that cannot hold it: a
        // second screen, or a recording or mirroring session. This
        // device has had CarPlay in the picture before, and mirroring
        // is precisely the condition a preventsCapture layer goes black
        // under.
        let screens = UIScreen.screens.count
        if screens != 1 { out += " screens \(screens)" }
        if UIScreen.main.isCaptured { out += " CAPTURED" }
        // The same offscreen-forcing set layerChain reads on ancestors.
        // On the sink itself these are rarer, and rarer still to be
        // right, which is exactly why they are worth one line.
        if layer.shouldRasterize { out += " RASTERIZES" }
        if layer.mask != nil { out += " MASK" }
        if layer.compositingFilter != nil { out += " FILTER" }
        if let effects = layer.filters, !effects.isEmpty {
            out += " FILTERS \(effects.count)"
        }
        if let backdrop = layer.backgroundFilters, !backdrop.isEmpty {
            out += " BACKDROP \(backdrop.count)"
        }
        return out
    }

    /// Every ancestor of this layer, from its parent to the root.
    ///
    /// ADDED - see mse_fix_138's docstring. layerShape has described
    /// one layer since fix 113, and four captures of "landscape with
    /// the controls up shows no picture" have all reported that one
    /// layer as attached, unhidden, correctly sized and still taking
    /// frames. Whatever removes the picture is not that layer, and
    /// nothing in this log has ever described anything else.
    ///
    /// An ancestor that goes hidden, drops to zero opacity, collapses
    /// to zero height or starts clipping does all of that while leaving
    /// `super true hidden false` reading exactly as it does today.
    ///
    /// The root's box is the window, so this also says which way up the
    /// device is without asking UIKit - which matters, because this
    /// runs on the drain queue and every orientation API wants the main
    /// thread.
    ///
    /// Bounded at twelve, which is deeper than this tree has ever been,
    /// so a cycle or a surprise cannot turn a log line into a hang.
    fileprivate static func layerChain(_ layer: CALayer) -> String {
        var out = " chain"
        var current = layer.superlayer
        var depth = 0
        while let here = current, depth < 12 {
            let box = here.bounds.size
            out += " <\(type(of: here))"
                + " \(Int(box.width.rounded()))x"
                + "\(Int(box.height.rounded()))"
            if here.isHidden { out += " HIDDEN" }
            if here.opacity < 0.999 { out += " opacity \(here.opacity)" }
            if here.masksToBounds { out += " clips" }
            // ADDED - see mse_fix_171's docstring. Whether the
            // compositor's placeholder surface is being painted at all.
            if here.contents != nil { out += " drawn" }
            // WHAT FORCES AN OFFSCREEN PASS - see mse_fix_174's
            // docstring. The sink carries preventsCapture, so its
            // pixels can be scanned out to the display and cannot be
            // copied into a buffer. Any ancestor that makes Core
            // Animation render this subtree into one turns the picture
            // black while leaving every property above correct.
            if here.shouldRasterize { out += " RASTERIZES" }
            if here.mask != nil { out += " MASK" }
            if here.compositingFilter != nil { out += " FILTER" }
            if let effects = here.filters, !effects.isEmpty {
                out += " FILTERS \(effects.count)"
            }
            if let backdrop = here.backgroundFilters, !backdrop.isEmpty {
                out += " BACKDROP \(backdrop.count)"
            }
            if here.cornerRadius > 0.01 && here.masksToBounds {
                out += " ROUNDED"
            }
            if here.shadowOpacity > 0.01 { out += " SHADOW" }
            if here.superlayer == nil { out += " ROOT" }
            out += ">"
            current = here.superlayer
            depth += 1
        }
        if depth == 0 { out += " <none>" }
        return out
    }

    /// What is drawn ON TOP of this layer, at every level of the tree.
    ///
    /// ADDED - see mse_fix_154's docstring. layerChain walks ancestors
    /// and has answered its question - nothing above the sink is hidden
    /// or transparent in any of the 262 landscape samples this log has
    /// taken. This walks the same path and looks sideways instead: at
    /// each level, the siblings ordered AFTER the child on the path are
    /// the ones the render server composites over it.
    ///
    /// Only siblings that are visible and whose frame actually
    /// intersects the sink's are reported, so a controls bar that sits
    /// beside the picture is silent and one that sits on it is not.
    ///
    /// Six at most and twelve levels deep, for the reason layerChain is
    /// bounded: a diagnostic must not be able to turn one log line into
    /// a hang or a page of text.
    fileprivate static func layersOver(_ layer: CALayer) -> String {
        var out = ""
        var child: CALayer = layer
        var current = layer.superlayer
        var depth = 0
        var found = 0
        while let here = current, depth < 12 {
            guard let siblings = here.sublayers,
                  let index = siblings.firstIndex(where: { $0 === child })
            else {
                break
            }
            let mine = layer.convert(layer.bounds, to: here)
            for above in siblings.dropFirst(index + 1) {
                guard !above.isHidden, above.opacity > 0.01 else { continue }
                let box = above.frame
                guard box.intersects(mine) else { continue }
                let hit = box.intersection(mine)
                found += 1
                // RAISED from 6 - see mse_fix_173's docstring. The
                // header has been saying `over 11:` while printing six,
                // so five covering layers a sample have never been
                // looked at, and the one that paints could be any.
                guard found <= 12 else { continue }
                out += " <\(type(of: above))"
                    + " \(Int(box.width.rounded()))x"
                    + "\(Int(box.height.rounded()))"
                    + " covering \(Int(hit.width.rounded()))x"
                    + "\(Int(hit.height.rounded()))"
                if above.opacity < 0.999 { out += " opacity \(above.opacity)" }
                if above.isOpaque { out += " opaque" }
                // WHAT IT PAINTS - see mse_fix_173's docstring. The
                // word below has only ever meant `contents == nil`, and
                // a layer with no contents and an opaque background
                // paints solid colour while reporting exactly that. 168
                // of 168 covering layers in capture dc1664e0 said
                // `empty` while the screen was black.
                if let paint = above.backgroundColor, paint.alpha > 0.004 {
                    out += " BG a\(Self.twoPlaces(paint.alpha))"
                    if let parts = paint.components {
                        if parts.count >= 4 {
                            out += " rgb \(Self.twoPlaces(parts[0]))"
                                + "/\(Self.twoPlaces(parts[1]))"
                                + "/\(Self.twoPlaces(parts[2]))"
                        } else if parts.count >= 2 {
                            out += " grey \(Self.twoPlaces(parts[0]))"
                        }
                    }
                }
                // WHICH LAYER. NativeLayerCA names the ones it builds -
                // the MSE sink is "org.reynard.mse.sink" - so a name
                // here is the difference between "something paints" and
                // a place to go and change it.
                if let named = above.name, !named.isEmpty {
                    out += " \"\(named)\""
                }
                out += (above.contents != nil) ? " drawn" : " empty"
                out += ">"
            }
            child = here
            current = here.superlayer
            depth += 1
        }
        if found == 0 { return " over nothing" }
        return " over \(found):" + out
    }

    /// Guards the layer snapshots below.
    ///
    /// A lock of its own, not the state lock: this is written from the
    /// main queue and read from the drain queues, and neither of those
    /// holds the state lock at the point it asks.
    /// Guards livePictureAt, and nothing else.
    ///
    /// ADDED - see mse_fix_177's docstring. Its own lock rather than the
    /// state lock, because the reader is the COMPOSITOR THREAD once a
    /// frame and the state lock is held across real work. One write site
    /// is inside withState and the other - 179's, at the enqueue - holds
    /// nothing, so the order is state then this or this alone, and never
    /// the reverse.
    private static let livePictureLock = NSLock()
    /// When a protected video sample last reached a display layer.
    private static var livePictureAt: Double = 0
    /// How stale that may be and still count as a live picture.
    ///
    /// Three seconds - CHANGED from two, see mse_fix_179's docstring.
    /// Now that the stamp is taken where a sample is handed to the layer
    /// rather than where bytes arrive from the parser, it moves once a
    /// frame while the picture runs, so the window is margin rather than
    /// the thing doing the work. It still separates the case this exists
    /// to exclude: the dead page in 7a010c1d was silent for 7.8s.
    private static let livePictureWindow: Double = 3.0

    /// Record that the protected route just produced a picture.
    fileprivate static func noteLivePicture(_ at: Double) {
        livePictureLock.lock()
        livePictureAt = at
        livePictureLock.unlock()
    }

    /// Is the protected route producing a picture RIGHT NOW?
    ///
    /// ADDED - see mse_fix_177's docstring. Called from the compositor
    /// thread through ReynardMSEHasLivePicture, once per commit, to
    /// decide whether a protected layer missing from WebRender's list is
    /// a gap to bridge or a teardown to accept. Capture f84dd12e has the
    /// media controls removing that layer for 1.2s, 2.1s, 3.4s and 2.2s
    /// while the parser is fed throughout; capture 7a010c1d has it gone
    /// for good with the parser silent for 7.8s. No frame count tells
    /// those apart. This does.
    ///
    /// An uncontended NSLock, which is what layerShapeLock below already
    /// does for the same reason, and cheap enough at 60Hz.
    @objc public static func hasLivePicture() -> Bool {
        livePictureLock.lock()
        let at = livePictureAt
        livePictureLock.unlock()
        guard at > 0 else { return false }
        return Self.hostNow() - at < Self.livePictureWindow
    }

    private static let layerShapeLock = NSLock()
    /// layerShape's last answer for a stream, taken on the main queue.
    private static var layerShapeText: [String: String] = [:]
    /// Streams whose refresh is already on its way to the main queue.
    private static var layerShapeRefreshing: Set<String> = []

    /// layerShape, for a caller that is not on the main thread.
    ///
    /// The walk is a race everywhere else - see layerShape - and a
    /// diagnostic must not be the thing that takes playback down. So it
    /// runs on the main queue and this hands back whatever it last
    /// produced: stale by at most one drift line, and never torn.
    ///
    /// One refresh in flight per stream. The drift line is periodic and
    /// a queue of walks would describe the same tree several times over
    /// on a thread that has a picture to composite.
    ///
    /// The leading space belongs to the answer. Before the first
    /// snapshot lands the line carries no shape field at all, rather
    /// than an empty one, so every shape a reader sees is layerShape's
    /// own text in layerShape's own format.
    fileprivate static func layerShapeCached(_ layer: CALayer,
                                             streamKey: String) -> String {
        layerShapeLock.lock()
        let cached = layerShapeText[streamKey]
        let refreshing = layerShapeRefreshing.contains(streamKey)
        if !refreshing { layerShapeRefreshing.insert(streamKey) }
        layerShapeLock.unlock()
        if !refreshing {
            DispatchQueue.main.async {
                let text = Self.layerShape(layer)
                layerShapeLock.lock()
                // Bounded. Stream keys are minted per source buffer, so
                // a long-lived content process mints more of them than
                // it ever has live streams, and only the live one is
                // ever asked about.
                if layerShapeText.count >= 16 { layerShapeText.removeAll() }
                layerShapeText[streamKey] = text
                layerShapeRefreshing.remove(streamKey)
                layerShapeLock.unlock()
            }
        }
        guard let cached else { return "" }
        return " " + cached
    }

    /// What the layer says it has actually put on the screen.
    ///
    /// ADDED - see mse_fix_120's docstring. Reached by name rather than
    /// by call: videoPerformanceMetrics is not on every OS this runs
    /// on, and a KVC read of a key an object does not have RAISES. Both
    /// of those are handled here rather than at the call site.
    fileprivate static func pictureMetrics(
        _ layer: AVSampleBufferDisplayLayer
    ) -> (text: String, shown: Int, dropped: Int)? {
        var found: (String, Int, Int)?
        let failure = GeckoRuntimeBridge.catchException(from: {
            let key = "videoPerformanceMetrics"
            guard layer.responds(to: NSSelectorFromString(key)),
                  let m = layer.value(forKey: key) as? NSObject else {
                return
            }
            func read(_ name: String) -> Int? {
                guard m.responds(to: NSSelectorFromString(name)),
                      let v = m.value(forKey: name) as? NSNumber else {
                    return nil
                }
                return v.intValue
            }
            func readDouble(_ name: String) -> Double? {
                guard m.responds(to: NSSelectorFromString(name)),
                      let v = m.value(forKey: name) as? NSNumber else {
                    return nil
                }
                return v.doubleValue
            }
            let shown = read("numberOfDisplayedVideoFrames")
                ?? read("totalNumberOfVideoFrames") ?? -1
            let dropped = read("numberOfDroppedVideoFrames") ?? -1
            let corrupt = read("numberOfCorruptedVideoFrames") ?? -1
            let delay = readDouble("totalFrameDelay") ?? Double.nan
            found = ("shown \(shown) dropped \(dropped) corrupt "
                     + "\(corrupt) delay \(delay)", shown, dropped)
        })
        if let failure {
            return ("metrics REFUSED - " + failure, -1, -1)
        }
        guard let found else { return nil }
        return (found.0, found.1, found.2)
    }

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

    /// Is this sample one only this route can render?
    ///
    /// encv and enca were not decrypted at all; qavc and qaac were
    /// decrypted only in name, their bytes still ciphertext until a
    /// decoder registered with the content key session touches them.
    /// Anything else is clear, and clear samples are Gecko's - it has
    /// the same bytes, it reports the track as encrypted=0, and it is
    /// already decoding them.
    ///
    /// A sample with no format description at all counts as NOT
    /// protected. It cannot be identified, and the failure that matters
    /// is playing something twice rather than not playing a sample this
    /// route was never going to be able to decode anyway.
    fileprivate static func isProtectedSample(_ sampleBuffer: CMSampleBuffer)
        -> Bool {
        guard let description =
                CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return false
        }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let fourCC = String([24, 16, 8, 0].map { shift -> Character in
            let byte = UInt8((code >> UInt32(shift)) & 0xff)
            return (byte >= 0x20 && byte <= 0x7e)
                ? Character(UnicodeScalar(byte)) : "."
        })
        return protectedSubtypes.contains(fourCC)
    }

    /// "child-12|sb-4630" -> "child-12".
    ///
    /// ADDED - see mse_fix_87's docstring. Stream keys are the session
    /// and the source buffer joined by a pipe, and the censuses need the
    /// session half to group by.
    fileprivate func sessionOf(_ streamKey: String) -> String {
        return String(streamKey.split(separator: "|").first ?? "")
    }

    // ==================================================================
    // A PLAYER THE PAGE THREW AWAY
    //
    // ADDED - see mse_fix_95's docstring. tv.apple.com destroys its
    // whole hls.js player between the trailer and the feature: both
    // SourceBuffers removed, both MediaKeySessions closed, a new player
    // built five hundred log lines later. Netflix does the same on a
    // profile change. Nothing here noticed, so the abandoned player's
    // display layer and audio renderer went on running at rate 1.0,
    // draining thirty seconds of fragments that had already been
    // forwarded, while the new one played somewhere else entirely.
    //
    // A session is one content process, and it plays one element. Two
    // display layers in a session is two pictures; two audio renderers
    // is the two soundtracks the user heard.
    // ==================================================================

    /// This stream just built a sink. Park whatever else in its session
    /// already had that half.
    ///
    /// Parked, not destroyed, and the difference matters: a page MAY
    /// legitimately hold two SourceBuffers of one kind, and this cannot
    /// tell that case from an abandoned player at the moment the second
    /// sink appears. Parking is silent, instant and reversible - the
    /// next append to a parked stream revives it - and only a stream
    /// that then stays silent is torn down.
    private func supersede(winner: String, half: String) {
        let session = sessionOf(winner)
        let losers = withState { () -> [String] in
            var out: [String] = []
            for (key, slot) in streamParsers
            where key != winner && key.hasPrefix(session + "|")
                    && slot.supersededBy == nil {
                let holdsSameHalf = half == "audio"
                    ? slot.audioRenderer != nil
                    : slot.displayLayer != nil
                guard holdsSameHalf else { continue }
                slot.supersededBy = winner
                out.append(key)
            }
            return out.sorted()
        }
        for key in losers {
            Self.log("stream \(key) is PARKED - \(winner) built this "
                     + "session's \(half) sink and a session plays one "
                     + "element, so this is the half of a player the "
                     + "page threw away. Clocks stopped, queue dropped. "
                     + "An append revives it; \(Self.supersedeWindow)s "
                     + "without one retires it.")
            park(streamKey: key)
        }
    }

    /// Stop a superseded stream making any sound or any picture.
    ///
    /// Everything here is reversible. Nothing is released, no observer
    /// is removed and the parser keeps its tracks - this is the pause
    /// button, not the teardown.
    private func park(streamKey: String) {
        let work = withState {
            () -> (timebase: CMTimebase?,
                   sync: AVSampleBufferRenderSynchronizer?,
                   renderer: AVSampleBufferAudioRenderer?,
                   audioQueue: DispatchQueue?,
                   layer: AVSampleBufferDisplayLayer?,
                   drainQueue: DispatchQueue?,
                   held: Int, audioHeld: Int) in
            guard let slot = streamParsers[streamKey] else {
                return (timebase: nil, sync: nil, renderer: nil,
                        audioQueue: nil, layer: nil, drainQueue: nil,
                        held: 0, audioHeld: 0)
            }
            let held = slot.pending.count
            let audioHeld = slot.audioPending.count
            slot.pending.removeAll()
            slot.audioPending.removeAll()
            slot.currentGOP.removeAll()
            // ADDED - see mse_fix_110's docstring.
            slot.previousGOP.removeAll()
            slot.drainArmed = false
            slot.audioDrainArmed = false
            return (timebase: slot.displayLayer?.controlTimebase,
                    sync: slot.audioSynchronizer,
                    renderer: slot.audioRenderer,
                    audioQueue: slot.audioQueue,
                    layer: slot.displayLayer,
                    drainQueue: slot.drainQueue,
                    held: held, audioHeld: audioHeld)
        }
        // The clocks first, so nothing already inside a sink is
        // presented while the rest of this runs.
        if let timebase = work.timebase {
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
        work.sync?.rate = 0
        // Muted as well as stopped. A synchronizer at rate 0 should be
        // silent, and belt-and-braces on the half the user can hear
        // costs one property write.
        work.renderer?.isMuted = true
        // On their own queues, because drainPending and
        // drainAudioPending run there and flush() must not race an
        // enqueue() - the same rule resynchroniseAudio follows.
        if let renderer = work.renderer {
            if let queue = work.audioQueue {
                queue.async {
                    renderer.stopRequestingMediaData()
                    renderer.flush()
                }
            } else {
                renderer.stopRequestingMediaData()
                renderer.flush()
            }
        }
        if let layer = work.layer {
            if let queue = work.drainQueue {
                queue.async { layer.stopRequestingMediaData() }
            } else {
                layer.stopRequestingMediaData()
            }
        }
        Self.log("stream \(streamKey) parked - \(work.held) video and "
                 + "\(work.audioHeld) audio samples dropped, clocks at "
                 + "rate 0")
    }

    /// The page appended to a parked stream, so it was never abandoned.
    private func unpark(streamKey: String) {
        // Read outside the lock: both of these take it.
        let volume = volumeFor(streamKey)
        let rate = gatedRate(streamKey)
        let work = withState {
            () -> (renderer: AVSampleBufferAudioRenderer?,
                   sync: AVSampleBufferRenderSynchronizer?,
                   timebase: CMTimebase?) in
            guard let slot = streamParsers[streamKey] else {
                return (renderer: nil, sync: nil, timebase: nil)
            }
            return (renderer: slot.audioRenderer,
                    sync: slot.audioSynchronizer,
                    timebase: slot.layerAttached
                        ? slot.displayLayer?.controlTimebase : nil)
        }
        if let renderer = work.renderer {
            renderer.volume = Float(volume)
            renderer.isMuted = volume <= 0.0
        }
        work.sync?.rate = rate
        if let timebase = work.timebase {
            CMTimebaseSetRate(timebase, rate: Float64(rate))
        }
        armDrainIfNeeded(streamKey: streamKey)
        armAudioDrainIfNeeded(streamKey: streamKey)
    }

    /// Retire parked streams the page has stayed silent about.
    ///
    /// Called from append, which is the only place that learns anything
    /// new about what the page still wants. A session with nothing being
    /// appended to it is a session where nothing is playing, and a
    /// parked stream there is already silent - so there is no need for a
    /// timer.
    private func reapSuperseded(sessionId: String) {
        let cutoff = Self.hostNow() - Self.supersedeWindow
        let doomed = withState { () -> [(String, StreamParser)] in
            var out: [(String, StreamParser)] = []
            // Keys snapshotted before anything is removed - see
            // destroySession for why.
            for key in Array(streamParsers.keys).sorted()
            where key.hasPrefix(sessionId + "|") {
                guard let slot = streamParsers[key],
                      slot.supersededBy != nil,
                      slot.lastAppendAt < cutoff else { continue }
                streamParsers.removeValue(forKey: key)
                out.append((key, slot))
            }
            return out
        }
        guard !doomed.isEmpty else { return }
        let keySession = liveSession(sessionId)
        for (key, slot) in doomed {
            tearDownStream(
                key: key, slot: slot, keySession: keySession,
                why: "parked for more than \(Self.supersedeWindow)s with "
                     + "no append - the page is finished with it")
        }
    }

    /// Take one stream apart: sinks, clocks, key-session registrations,
    /// observers and any layer this parser owns.
    ///
    /// The slot must already have been removed from streamParsers by the
    /// caller, so that nothing can find it half-dismantled.
    private func tearDownStream(key: String, slot: StreamParser,
                                keySession: AVContentKeySession?,
                                why: String) {
        keySession?.removeContentKeyRecipient(slot.recipient)
        if let layer = slot.displayLayer,
           let recipient = (layer as AnyObject) as? AVContentKeyRecipient {
            keySession?.removeContentKeyRecipient(recipient)
        }
        if let renderer = slot.audioRenderer {
            if let recipient = (renderer as AnyObject)
                as? AVContentKeyRecipient {
                keySession?.removeContentKeyRecipient(recipient)
            }
            // On the audio queue, for the reason park() gives:
            // drainAudioPending runs there and flush() must not race an
            // enqueue(). A stream being torn down is no safer - the
            // drain block can be mid-enqueue on that queue while this
            // runs, and the caller here is whichever thread the append
            // or the proxy came in on.
            if let queue = slot.audioQueue {
                queue.async {
                    renderer.stopRequestingMediaData()
                    renderer.flush()
                }
            } else {
                renderer.stopRequestingMediaData()
                renderer.flush()
            }
        }
        slot.audioSynchronizer?.rate = 0
        slot.displayLayer?.stopRequestingMediaData()
        // The timebase too. destroySession never stopped it, so a torn
        // down layer's clock carried on running - and adopt() and
        // videoClock() both read timebases.
        if let timebase = slot.displayLayer?.controlTimebase {
            CMTimebaseSetRate(timebase, rate: 0.0)
        }
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
        // ADDED - see mse_fix_105's docstring. A torn-down slot takes
        // its queues with it, and until now that was the largest of
        // Netflix's unreported losses.
        Self.log("stream \(key) torn down - \(why)"
                 + " - \(slot.pending.count) video and "
                 + "\(slot.audioPending.count) audio samples went with it, "
                 + "\(slot.enqueued) video and \(slot.audioEnqueued) audio "
                 + "ever reached a sink")
    }

    /// Say once that this stream is not ours to render.
    ///
    /// Once, because it is true for every sample of a clear stream and
    /// four hundred identical lines would bury the one that matters. It
    /// is worth saying at all because the alternative reading of silence
    /// - that no samples arrived - is a completely different problem.
    private func standDown(streamKey: String, half: String) {
        let first = withState { () -> Bool in
            guard let slot = streamParsers[streamKey],
                  !slot.standDownLogged else { return false }
            slot.standDownLogged = true
            return true
        }
        guard first else { return }
        Self.log("stream \(streamKey) standing down - these samples are "
                 + "CLEAR, so Gecko is already decoding and playing them "
                 + "and a \(half) sink here would be a second copy")
    }

    // ==================================================================
    // THE ELEMENT'S STATE
    //
    // Everything below exists so this route obeys the same rules the
    // element does: the autoplay setting, the per-site override, and
    // the user's own pause button. It follows the ELEMENT and never
    // reads the setting, which is what keeps CarPlay working unchanged
    // - that display plays by giving the document sticky user
    // activation, so Gecko plays the element and this simply follows.
    // ==================================================================

    /// What rate a clock for this stream may run at.
    ///
    /// Asked at every site that starts a clock rather than assumed,
    /// because there are six of them and one that assumed 1.0 would be
    /// a route that quietly un-pauses itself.
    /// May a message from `sender` act on a stream owned by `held`?
    ///
    /// ADDED - see mse_fix_104's docstring. This was written inline as
    ///
    ///     owner == 0 || slot.owner == 0 || slot.owner == owner
    ///
    /// and the middle clause is the bug. It was meant as "do not regress
    /// a stream whose owner has not arrived"; it reads as "a stream with
    /// no owner accepts anybody", and with fix 103 inert every stream had
    /// no owner - so an element that owned nothing at all was yanking
    /// the film's clock back to zero four times a second, 254 times in
    /// one capture.
    ///
    /// An unknown sender still reaches everything: that is the genuine
    /// legacy case, a content process too old to name its elements. An
    /// unknown STREAM now waits, which costs it nothing - a stream with
    /// no owner has no clock worth setting yet.
    fileprivate static func ownerMatches(_ held: UInt64,
                                         _ sender: UInt64) -> Bool {
        return sender == 0 || held == sender
    }

    fileprivate func gatedRate(_ streamKey: String) -> Float {
        let sessionId = String(streamKey.split(separator: "|").first ?? "")
        // THIS STREAM'S ELEMENT FIRST - see mse_fix_101's docstring.
        // sessionPlaying is per CONTENT PROCESS, and on tv.apple.com
        // that meant the feature element's play() started the film's
        // soundtrack under a pre-roll trailer playing in a different
        // element. The session-wide answer is still the fallback, for a
        // stream whose owner never arrived.
        return withState { () -> Bool in
            if let owner = streamParsers[streamKey]?.owner, owner != 0,
               let playing = ownerPlaying[owner] {
                return playing
            }
            return sessionPlaying[sessionId] ?? false
        } ? 1.0 : 0.0
    }

    /// Which element a SourceBuffer belongs to, and what that element is
    /// doing. Keyed on the MediaDecoder both sides can see.
    private var ownerPlaying: [UInt64: Bool] = [:]
    private var ownerVolume: [UInt64: Double] = [:]
    /// Where each element is playing, as Gecko settles it.
    ///
    /// ADDED - see mse_fix_102's docstring. The number this file has
    /// been inferring from intake order since it was written, and
    /// inferring wrongly: on Netflix that inference discarded 1188 of
    /// 1864 frames in one playback.
    private var ownerPosition: [UInt64: Double] = [:]

    /// When each of those positions arrived.
    ///
    /// ADDED - see mse_fix_106's docstring. A position that stopped
    /// arriving is not an authority, and there is no way to tell one
    /// from a current reading without the stamp.
    private var ownerPositionAt: [UInt64: Double] = [:]

    /// How far our timebase may be from the element's before it is put
    /// back on it.
    ///
    /// Half a second is comfortably more than the gap a host clock can
    /// open in the quarter second between positions, and comfortably
    /// less than anything a viewer would call out of sync. Correcting
    /// smaller differences would move the picture four times a second
    /// for no reason.
    fileprivate static let positionSlack: Double = 0.5

    /// How much silence from a stream's parser counts as death.
    ///
    /// ADDED - see mse_fix_159's docstring. Both have to be true. Across
    /// every stream in capture 50625b25 the 95th percentile gap between
    /// a segment going in and media data coming back is one to five
    /// segments, answered in milliseconds. Six segments over four
    /// seconds with nothing back is not a working parser, and the cost
    /// of being wrong is a re-parse from the kept init segment rather
    /// than a broken stream.
    fileprivate static let starvedAppends = 6
    fileprivate static let starvedSeconds: Double = 4.0

    /// The least time between two recoveries of a failed layer.
    ///
    /// ADDED - see mse_fix_157's docstring. A flush that does not fix
    /// the failure would otherwise be attempted on every sample, which
    /// on this route is a hundred and eighty a second.
    fileprivate static let failRecoveryGap: Double = 1.0

    /// The element moved. Put this session's picture on its clock.
    @objc public func setPosition(_ sessionId: String, owner: UInt64,
                                  seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        withState {
            if owner != 0 {
                ownerPosition[owner] = seconds
                // ADDED - see mse_fix_106's docstring.
                ownerPositionAt[owner] = Self.hostNow()
            }
        }
        let clocks = withState { () -> [(String, CMTimebase)] in
            var out: [(String, CMTimebase)] = []
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") && slot.supersededBy == nil
                    && Self.ownerMatches(slot.owner, owner) {
                guard slot.layerAttached,
                      let timebase = slot.displayLayer?.controlTimebase
                else { continue }
                out.append((key, timebase))
            }
            return out
        }
        let onto = CMTime(seconds: seconds, preferredTimescale: 90_000)
        var moved = false
        // Set by the sweep below - see mse_fix_143's docstring.
        var swept = false
        for (key, timebase) in clocks {
            let before = CMTimebaseGetTime(timebase).seconds
            guard before.isFinite,
                  abs(before - seconds) > Self.positionSlack else {
                continue
            }
            CMTimebaseSetTime(timebase, time: onto)
            // Read back, for the reason fix 100 gives: this file has
            // been misled three times by a line that reported a write
            // as though it were a result.
            let after = CMTimebaseGetTime(timebase).seconds
            moved = true
            // AND THE QUEUE GOES WITH IT - see mse_fix_107's docstring.
            //
            // Every catastrophic drift run in capture c49b7746 begins
            // on the line after one of these. The clock lands here,
            // sixteen times out of sixteen; the queue is left holding
            // the media the page has just seeked away from, and drains
            // it against the new clock for hundreds of samples.
            //
            // Only for a move the element could not have made by
            // playing. The 0.5s positionSlack corrections this makes
            // several times a second sweep nothing and walk no queue.
            // CHANGED - see mse_fix_109's docstring. This was gated on
            // how far the ELEMENT moved, which says nothing. In capture
            // 2231f247 tv.apple.com swapped a pre-roll for a feature in
            // one SourceBuffer: the element moved 45.15s and then
            // 55.51s, both under strandedBehind, so neither swept -
            // while the queue was 45s away in the first case and 6242s
            // in the second, and three hundred and thirty samples went
            // out late in a row.
            //
            // What matters is how far the QUEUE is from where the
            // element now is. A small move can leave a queue a long way
            // off, and a large move need not.
            if queueStrays(key, from: seconds) {
                // REMEMBERED - see mse_fix_143's docstring. A sweep
                // means the queue could not serve where the element has
                // gone, and the sound's queue and renderer are in the
                // same position.
                if sweepMediaAwayFrom(key, authority: seconds,
                                      why: "the element moved to") > 0 {
                    swept = true
                }
            }
            // WHICH CLOCK - see mse_fix_112's docstring. In capture
            // e179d626 this read 3407.1 four times running while the
            // drain read the same stream's timebase advancing from
            // 3413 to 3421 at 1.000x, with no adoption between them and
            // every write here reading back what it asked for. Two
            // readings that cannot both be of one object, starting
            // sixteen lines after 'pipLife: willStart'. The drift line
            // has named its timebase since 108; this one never has.
            let onTimebase = Unmanaged.passUnretained(timebase).toOpaque()
            let onLayer = withState {
                streamParsers[key]?.displayLayer
            }.map { Unmanaged.passUnretained($0).toOpaque() }
            Self.log("stream \(key) clock put on the ELEMENT at "
                     + "\(seconds) - it read \(before), it now reads "
                     + "\(after) - timebase \(onTimebase) layer "
                     + (onLayer.map { "\($0)" } ?? "none"))
        }
        if moved {
            realignAudioClock(sessionId: sessionId, to: onto,
                              flushing: swept)
        }
    }

    /// How far behind the media a sample may be and still be shown.
    ///
    /// ADDED - see mse_fix_106's docstring. Not a tuning knob: the
    /// display queue's high-water is 300 samples and its cap 900, which
    /// at 24fps is 12.5 and 37.5 seconds, so a sample a full minute
    /// behind the media did not come from the media being played. In
    /// capture 8ec30c6a every legitimate backlog was under 14s and
    /// every stranded queue was over 360s.
    fileprivate static let strandedBehind: Double = 60.0

    /// How close a clock read-back has to be to count as landed.
    ///
    /// ADDED - see mse_fix_146's docstring. The same 0.05 writeAudioClock
    /// has used to decide whether to print DID NOT TAKE since it was
    /// written.
    fileprivate static let clockLanded: Double = 0.05

    /// And how far out it has to be before the renderer is flushed for
    /// it.
    ///
    /// ADDED - see mse_fix_149's docstring. 146 acted on clockLanded,
    /// which is right for a report and wrong for an action:
    /// writeAudioClock writes at rate 1.0 and then reads back, so the
    /// clock has been running for however long the call took, and a
    /// tenth of a second is that and nothing else. In capture 5e206fda
    /// it flushed four times for gaps of 0.565, 0.113, 0.118 and 0.087
    /// seconds, throwing away 12, 135, 0 and 124 queued samples.
    ///
    /// Every genuine refusal this file has caught is seconds or worse -
    /// 3.577 on HBO Max, 33.00 and 540.16 on Netflix - so 1.5 sits
    /// between the widest read-back lag and the narrowest real refusal
    /// with room on both sides.
    fileprivate static let clockRefused: Double = 1.5

    /// How far the sound may fall behind the picture before it is put
    /// back.
    ///
    /// ADDED - see mse_fix_148's docstring. tv.apple.com's median |av|
    /// is 0.000 across 133 drift lines in capture d8bae8d7 and HBO's is
    /// 3.401 across 38, so there is no honest reading anywhere near
    /// half a second.
    fileprivate static let audioLagLimit: Double = 0.5

    /// And how often that may be done.
    ///
    /// ADDED - see mse_fix_148's docstring. A realign that lands fixes
    /// it; this is so a realign that does not cannot become a loop.
    fileprivate static let audioLagGrace: Double = 3.0

    /// A forward step in intake PTS large enough to be a hole.
    ///
    /// ADDED - see mse_fix_137's docstring. Half a second is twelve
    /// frames at 24fps - far beyond any reordering, far below the four
    /// to six second gaps capture 42d770ba stalls on - and it is
    /// measured against the running maximum, so decode-order
    /// reordering cannot reach it at all.
    fileprivate static let intakeGap: Double = 0.5

    /// How far AHEAD of the element a sample may be and still be taken.
    ///
    /// ADDED - see mse_fix_133's docstring. The behind arm of this gate
    /// has fired zero times in the last two captures, because the fault
    /// has never been in that direction: in d655146f tv.apple.com left
    /// a 4481-second timeline for a 2494-second one and held bytes from
    /// the first were appended afterwards, so every sample was 1944
    /// seconds AHEAD of the element and every gate in this file waved
    /// it through.
    ///
    /// Ten minutes. The pages under test buffer up to 195 seconds - the
    /// widest `MSE sb#2 buffered` range in these captures is
    /// [4077.45-4272.02] - so this is three times the widest
    /// legitimate lookahead and still catches a 1944 second miss on the
    /// first sample rather than the thousandth.
    fileprivate static let strandedAhead: Double = 600.0

    /// How far BEHIND the media a queued sample may be before the queue
    /// holding it is stale.
    ///
    /// ADDED - see mse_fix_124's docstring. Ahead of the element is
    /// buffer and a page may hand over a lot of it. Behind the element
    /// is nothing at all: the clock has passed those frames and no
    /// layer can present them. The only frames legitimately behind are
    /// the reference run 111 carries at a handover, which starts at the
    /// last keyframe at or before the clock - one GOP, two to four
    /// seconds.
    ///
    /// Eight seconds is two GOPs, comfortably above that and far below
    /// the fifty-four that slipped under strandedBehind in capture
    /// 84425dde and cost five hundred unpresentable frames.
    fileprivate static let staleBehind: Double = 8.0

    /// How old an element position may be before it stops being an
    /// authority.
    ///
    /// Positions arrive as Gecko settles them, several times a second
    /// on a playing element. One that has not arrived for two seconds
    /// is a reading, not a report - HBO sent exactly one in the whole
    /// of capture 8ec30c6a and it was 384s out by the end of it.
    fileprivate static let authorityFreshness: Double = 2.0

    /// Is this stream holding media a long way from where the element
    /// now is?
    ///
    /// ADDED - see mse_fix_109's docstring. Three timestamp reads, not
    /// nine hundred: positions arrive several times a second and the
    /// answer only has to be good enough to decide whether a full sweep
    /// is worth walking. The ends of the queue and the head of the
    /// current GOP are where a strayed queue shows itself - a queue
    /// spanning a discontinuity has one end on each side of it.
    fileprivate func queueStrays(_ streamKey: String,
                                 from authority: Double) -> Bool {
        guard authority.isFinite else { return false }
        return withState { () -> Bool in
            guard let slot = streamParsers[streamKey] else { return false }
            let ends = [slot.pending.first, slot.pending.last,
                        slot.currentGOP.first].compactMap { $0 }
            for sample in ends {
                let at = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                // ASYMMETRIC - see mse_fix_124's docstring. Behind the
                // element cannot be shown; ahead of it is buffer.
                if at.isFinite,
                   at < authority - Self.staleBehind
                    || at > authority + Self.strandedBehind {
                    return true
                }
            }
            return false
        }
    }

    /// Drop queued media that is nowhere near where the media now is.
    ///
    /// ADDED - see mse_fix_107's docstring. Fix 106 refuses stranded
    /// samples as they arrive, which stops the queue REFILLING with
    /// media the page has left behind but does nothing about what it is
    /// already holding: a seek stops the old range being appended, so
    /// no further stranded sample arrives to trigger the prune, and the
    /// three hundred already queued drain out one at a time against a
    /// clock twenty minutes away from them.
    ///
    /// Symmetric, unlike the intake test. tv.apple.com seeked backwards
    /// in capture c49b7746 - remove(1984.5, Infinity), buffered
    /// [1927.26-1977.89] - and left the queue holding 3475, which is
    /// 1546s in the FUTURE. A layer holds those and shows nothing,
    /// which is the same frozen picture from the other side.
    ///
    /// needsSyncSample because a pruned queue has a hole in it exactly
    /// like a flushed one, and everything before the next keyframe
    /// decodes to garbage.
    @discardableResult
    fileprivate func sweepMediaAwayFrom(_ streamKey: String,
                                        authority: Double,
                                        why: String) -> Int {
        guard authority.isFinite else { return 0 }
        // ASYMMETRIC, for the reason queueStrays is - see
        // mse_fix_124's docstring. What is kept behind the element is
        // only what a handover needs to decode from.
        let near = { (sample: CMSampleBuffer) -> Bool in
            let at = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            return !at.isFinite
                || (at >= authority - Self.staleBehind
                    && at <= authority + Self.strandedBehind)
        }
        // AND THE BYTES BEHIND THEM - see mse_fix_133's docstring.
        // Emptying the queue of a timeline the element has left, while
        // leaving thirty-two fragments of that same timeline in the bin
        // to be appended eighty-six seconds later, is how capture
        // d655146f ends with every sample 1944s ahead of the clock.
        //
        // Judged by the stamp, not by the fact of being held: a sweep
        // that follows the sound FORWARD leaves held bytes that are the
        // continuation of the media it kept, and those must survive.
        // A fragment with no stamp - the element never said where it
        // was - is kept, because "cannot tell" is not "stale".
        let heldNear = { (fragment: StreamParser.HeldFragment) -> Bool in
            return !fragment.at.isFinite
                || (fragment.at >= authority - Self.strandedBehind
                    && fragment.at <= authority + Self.strandedBehind)
        }
        let swept = withState { () -> (gone: Int, left: Int, bins: Int) in
            guard let slot = streamParsers[streamKey] else {
                return (0, 0, 0)
            }
            let keptGOP = slot.currentGOP.filter(near)
            let keptPending = slot.pending.filter(near)
            // ADDED - see mse_fix_110's docstring.
            let keptPrevious = slot.previousGOP.filter(near)
            let keptHeld = slot.heldSegments.filter(heldNear)
            let bins = slot.heldSegments.count - keptHeld.count
            let gone = (slot.currentGOP.count - keptGOP.count)
                + (slot.pending.count - keptPending.count)
                + (slot.previousGOP.count - keptPrevious.count)
            if gone > 0 || bins > 0 {
                slot.previousGOP = keptPrevious
                slot.currentGOP = keptGOP
                slot.pending = keptPending
                slot.heldSegments = keptHeld
                slot.needsSyncSample = true
                slot.strandedPruned += gone
            }
            return (gone, slot.pending.count, bins)
        }
        if swept.gone > 0 || swept.bins > 0 {
            var bin = ""
            if swept.bins > 0 {
                bin = ", and \(swept.bins) held fragment(s) of the media "
                    + "it left"
            }
            Self.log("stream \(streamKey) \(why) \(authority) - swept "
                     + "\(swept.gone) samples that were not near it, "
                     + "\(swept.left) left in the queue" + bin)
        }
        return swept.gone
    }

    /// The same, for every video stream the element owns.
    ///
    /// ADDED - see mse_fix_107's docstring. Owner-matched rather than
    /// session-wide: tv.apple.com runs a pre-roll element and a feature
    /// element in one content process, and one of them moving is not
    /// the other one moving. A stream with no owner keeps the old
    /// session-wide behaviour, which is what an older content process
    /// gives us.
    fileprivate func sweepOwnedVideo(sessionId: String, owner: UInt64,
                                     authority: Double, why: String) {
        let keys = withState { () -> [String] in
            var out: [String] = []
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|") && slot.supersededBy == nil
                    && slot.displayLayer != nil
                    && Self.ownerMatches(slot.owner, owner) {
                out.append(key)
            }
            return out
        }
        for key in keys {
            sweepMediaAwayFrom(key, authority: authority, why: why)
        }
    }

    /// WHERE THE MEDIA ACTUALLY IS.
    ///
    /// ADDED - see mse_fix_106's docstring. Two independent answers,
    /// and this file needs both: tv.apple.com and Netflix report
    /// element positions and Netflix has no audio renderer at all,
    /// while HBO reported one position and then went quiet but kept an
    /// audio clock that tracked every seek. Neither alone covers the
    /// three sites.
    ///
    /// The queue is deliberately not consulted. Reading the queue is
    /// what every one of the faults this fix addresses did.
    fileprivate func mediaAuthority(_ streamKey: String) -> Double? {
        let fresh = withState { () -> Double? in
            guard let owner = streamParsers[streamKey]?.owner, owner != 0,
                  let stamped = ownerPositionAt[owner],
                  Self.hostNow() - stamped <= Self.authorityFreshness,
                  let told = ownerPosition[owner], told.isFinite
            else { return nil }
            return told
        }
        if let fresh { return fresh }
        let session = String(streamKey.split(separator: "|").first ?? "")
        guard let heard = audioClock(sessionId: session), heard.isFinite
        else { return nil }
        return heard
    }

    /// Does this stream know where its element is?
    fileprivate func elementPosition(_ streamKey: String) -> Double? {
        return withState { () -> Double? in
            guard let owner = streamParsers[streamKey]?.owner,
                  owner != 0 else { return nil }
            return ownerPosition[owner]
        }
    }

    /// Owners that arrived before the stream they name.
    ///
    /// ADDED - see mse_fix_104's docstring. AppendData sends the owner
    /// before the segment, so the first one reaches this process before
    /// the stream exists - and the sender dedups, so unless the offset
    /// later moves it is never sent again. Dropping it left slot.owner
    /// at zero for the life of the stream, which is what let every
    /// element's clock reach every stream.
    private var pendingOwners: [String: (owner: UInt64, offset: Double)] = [:]

    /// Apply an owner that was waiting for this stream to exist.
    fileprivate func adoptPendingOwner(_ key: String) {
        let waiting = withState { () -> (owner: UInt64, offset: Double)? in
            guard let held = pendingOwners[key],
                  let slot = streamParsers[key] else { return nil }
            pendingOwners.removeValue(forKey: key)
            slot.owner = held.owner
            slot.timestampOffset = held.offset
            return held
        }
        guard let waiting else { return }
        Self.log("stream \(key) belongs to element \(waiting.owner), offset "
                 + "\(waiting.offset) - held until the stream existed")
    }

    @objc public func setStreamOwner(_ sessionId: String, stream: String,
                                     owner: UInt64, offset: Double) {
        let key = sessionId + "|" + stream
        let shift = offset.isFinite ? offset : 0
        // Filled under the lock and acted on once it is released - see
        // mse_fix_141's docstring.
        var shifted = false
        var wasAt = Double.nan
        let sounded = withState { streamParsers[key]?.audioEnqueued ?? 0 }
        let changed = withState { () -> Bool in
            guard let slot = streamParsers[key] else {
                pendingOwners[key] = (owner: owner, offset: shift)
                return false
            }
            let moved = slot.owner != owner
                || abs(slot.timestampOffset - shift) > 0.0005
            // WHAT WAS ALREADY FED AT THE OLD ONE - see mse_fix_141's
            // docstring. Only a real move, and only once something has
            // gone into the renderer: an offset that arrives before the
            // first sample is the ordinary case and needs nothing.
            shifted = slot.audioEnqueued > 0
                && slot.timestampOffset.isFinite
                && abs(slot.timestampOffset - shift) > 0.05
            wasAt = slot.timestampOffset
            slot.owner = owner
            slot.timestampOffset = shift
            return moved
        }
        if shifted {
            // Through resynchroniseAudio because the ORDER is what
            // matters and it already has it right: flush the renderer,
            // then write the clock. An AVSampleBufferRenderSynchronizer
            // will not skip past media its renderer already holds, so a
            // write before the flush is refused - which is what capture
            // 56fcf67c has it doing three times in a row, `asked 2811.0
            // - reads 2771.687066666667 - DID NOT TAKE`, and then
            // thirty-seven seconds of silence while the clock walked up
            // to media it should never have been anchored behind.
            let session = String(key.split(separator: "|").first ?? "")
            let target = videoClock(sessionId: session)?.seconds
                ?? elementPosition(key)
            if let target, target.isFinite {
                Self.log("stream \(key) the element's offset moved from "
                         + "\(wasAt) to \(shift) after \(sounded) audio "
                         + "samples had been fed - flushing what was timed "
                         + "against the old one and re-anchoring to "
                         + "\(target).")
                resynchroniseAudio(streamKey: key, to: target,
                                   jump: shift - wasAt)
            }
        }
        guard changed else { return }
        Self.log("stream \(key) belongs to element \(owner), offset "
                 + "\(shift) - its samples are shifted into the element's "
                 + "timeline, and its clock and volume follow THAT "
                 + "element rather than whatever else is playing in this "
                 + "content process")
        // The element may already have said what it is doing, before
        // this stream existed to hear it.
        let rate = gatedRate(key)
        let volume = volumeFor(key)
        let work = withState {
            () -> (AVSampleBufferAudioRenderer?,
                   AVSampleBufferRenderSynchronizer?, CMTimebase?)? in
            guard let slot = streamParsers[key] else { return nil }
            return (slot.audioRenderer,
                    slot.audioStarted ? slot.audioSynchronizer : nil,
                    slot.layerAttached
                        ? slot.displayLayer?.controlTimebase : nil)
        }
        guard let work else { return }
        if let renderer = work.0 {
            renderer.volume = Float(volume)
            renderer.isMuted = volume <= 0.0
        }
        work.1?.rate = rate
        if let timebase = work.2 {
            CMTimebaseSetRate(timebase, rate: Float64(rate))
        }
    }

    /// The element started or stopped.
    @objc public func setSessionPlaying(_ sessionId: String, owner: UInt64,
                                        playing: Bool) {
        // CHANGED - see mse_fix_101's docstring. The session-wide value
        // is still kept, because it is the fallback for a stream whose
        // owner never arrived, but what gates a clock is the element's.
        let changed = withState { () -> Bool in
            var moved = false
            if owner != 0 {
                moved = ownerPlaying[owner] != playing
                ownerPlaying[owner] = playing
            }
            let was = sessionPlaying[sessionId]
            sessionPlaying[sessionId] = playing
            return moved || was != playing
        }
        guard changed else { return }
        let mine = withState {
            streamParsers.filter {
                $0.key.hasPrefix(sessionId + "|")
                    && Self.ownerMatches($0.value.owner, owner)
            }.count
        }
        Self.log("session \(sessionId) element \(owner) is now "
                 + (playing ? "PLAYING" : "PAUSED")
                 + " - applying it to the \(mine) stream(s) that element "
                 + "owns")
        let rate: Float = playing ? 1.0 : 0.0
        // The clocks are read out UNDER the lock and set outside it.
        // Only a layer that has somewhere to render: starting a clock
        // for one that has not been attached would undo fix 26, whose
        // whole point is that a queue must not go stale against a clock
        // with nothing to present to.
        let clocks = withState {
            () -> [(String, CMTimebase?, AVSampleBufferRenderSynchronizer?)] in
            var out: [(String, CMTimebase?,
                       AVSampleBufferRenderSynchronizer?)] = []
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|")
                    && slot.supersededBy == nil
                    && Self.ownerMatches(slot.owner, owner) {
                let timebase = slot.layerAttached
                    ? slot.displayLayer?.controlTimebase : nil
                let sync = slot.audioStarted ? slot.audioSynchronizer : nil
                if timebase != nil || sync != nil {
                    out.append((key, timebase, sync))
                }
            }
            return out
        }
        // Released together AND aligned together. Setting two rates
        // leaves any gap between the two clocks exactly as it was, so a
        // pause and resume preserved a desync rather than healing it.
        //
        // Done here rather than through realignAudioClock because that
        // one filters by liveness, and a stream the page stopped feeding
        // while it was paused is exactly the stream being resumed.
        //
        // Only on resume: moving a stopped clock achieves nothing, and
        // its renderer will be told a time again the moment it starts.
        let onto = playing ? videoClock(sessionId: sessionId) : nil
        for (key, timebase, sync) in clocks {
            if let timebase {
                CMTimebaseSetRate(timebase, rate: Float64(rate))
            }
            if let sync {
                if let onto {
                    writeAudioClock(sync, to: onto, rate: rate, label: key,
                                    reason: "setSessionPlaying")
                } else {
                    sync.rate = rate
                }
            }
            Self.log("stream \(key) clocks -> rate \(rate)"
                     + (onto.map { " aligned to \($0.seconds)" } ?? ""))
        }
    }

    /// The element's volume changed.
    ///
    /// Muting collapses into this: Gecko passes the effective volume,
    /// zero when the element is muted, which is also how
    /// AVPlayerHost.setVolume treats it.
    @objc public func setSessionVolume(_ sessionId: String, owner: UInt64,
                                       volume: Double) {
        let clamped = max(0.0, min(1.0, volume.isFinite ? volume : 1.0))
        withState {
            sessionVolume[sessionId] = clamped
            if owner != 0 {
                ownerVolume[owner] = clamped
            }
        }
        let renderers = withState { () -> [(String, AVSampleBufferAudioRenderer)] in
            var out: [(String, AVSampleBufferAudioRenderer)] = []
            for (key, slot) in streamParsers
            where key.hasPrefix(sessionId + "|")
                    && slot.supersededBy == nil
                    && Self.ownerMatches(slot.owner, owner) {
                if let renderer = slot.audioRenderer {
                    out.append((key, renderer))
                }
            }
            return out
        }
        for (key, renderer) in renderers {
            renderer.volume = Float(clamped)
            renderer.isMuted = clamped <= 0.0
            Self.log("stream \(key) volume -> \(clamped)")
        }
    }

    /// The volume a renderer should be built with.
    ///
    /// A renderer built after the volume arrived would otherwise start
    /// at 1.0 and stay there until the page next touched the control -
    /// which for a muted autoplaying trailer is never.
    fileprivate func volumeFor(_ streamKey: String) -> Double {
        let sessionId = String(streamKey.split(separator: "|").first ?? "")
        // THIS STREAM'S ELEMENT FIRST, for the reason in gatedRate.
        return withState { () -> Double in
            if let owner = streamParsers[streamKey]?.owner, owner != 0,
               let volume = ownerVolume[owner] {
                return volume
            }
            return sessionVolume[sessionId] ?? 1.0
        }
    }

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
        guard Self.addRecipient(keySession, recipient: recipient,
                                label: "stream \(streamKey) display layer")
        else { return }
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
        // ADDED - see mse_fix_84's docstring. A batched exchange is
        // answered in kind: one entry per challenge, which the licence
        // server labels and may return in any order. Each is applied to
        // its own request through the same provide() a single exchange
        // uses.
        let expectedKeys = withState { entry.batchKeyIds }
        if let split = Self.splitLicenceBatch(ckc, expecting: expectedKeys),
           split.count > 1 {
            let ids = withState { entry.batchContentIds }
            guard ids.count == split.count else {
                Self.log("session \(sessionId) licence batch has "
                         + "\(split.count) entries for \(ids.count) "
                         + "challenges - not applying any of them")
                return false
            }
            var applied = 0
            for (index, licence) in split.enumerated()
            where entry.keyDelegate.provide(response: licence,
                                            contentId: ids[index]) {
                applied += 1
            }
            Self.log("session \(sessionId) licence batch: \(applied) of "
                     + "\(split.count) applied")
            return applied > 0
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
    /// Licences already applied, by the key id they were applied for.
    ///
    /// The page answers one message per session and no more. When the
    /// parser later raises its own request for a key the direct route
    /// already licensed, there is nobody left to ask - so the licence is
    /// kept and replayed into it. Keyed by the request's own 16-byte
    /// identifier, which both routes carry and which is the only thing
    /// the two have in common.
    private var licenceByKeyId: [String: Data] = [:]
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

    // ---- the callbacks nothing was listening on ------------------------
    //
    // This delegate implemented exactly one method. Every other callback
    // in AVContentKeySessionDelegate is optional and was absent,
    // including the only one that reports a REFUSED licence.
    //
    // processContentKeyResponse does not throw and returns nothing. It
    // hands the CKC over and the verdict arrives here, later. So
    // "licence applied to the request" has never meant "licence
    // accepted" - it means the bytes were passed - and every capture
    // that showed a licence applied and then -11800 "no content key
    // present" was consistent with a rejection nobody heard.
    //
    // All of these print and return. Nothing is routed, retried or
    // answered, so behaviour is exactly what it is today with the
    // methods absent.

    func contentKeySession(_ session: AVContentKeySession,
                           contentKeyRequest keyRequest: AVContentKeyRequest,
                           didFailWithError err: Error) {
        FairPlayStreamParser.log(
            "session \(sessionId) key request FAILED - status="
            + "\(keyRequest.status.rawValue) identifier="
            + "\(String(describing: keyRequest.identifier)) error=\(err)")
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        FairPlayStreamParser.log(
            "session \(sessionId) asked whether to retry a key request - "
            + "reason \(retryReason.rawValue), status "
            + "\(keyRequest.status.rawValue) - declining, which is what "
            + "happens today with this method absent")
        return false
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        // Logged, NOT routed. Sending a renewal through the ordinary
        // path would answer one EME exchange twice; this is here to find
        // out whether renewals happen at all.
        FairPlayStreamParser.log(
            "session \(sessionId) RENEWING key request offered - identifier "
            + "\(String(describing: keyRequest.identifier)) - not routed")
    }

    func contentKeySessionContentProtectionSessionIdentifierDidChange(
        _ session: AVContentKeySession) {
        let identifier = session.contentProtectionSessionIdentifier
        FairPlayStreamParser.log(
            "session \(sessionId) content protection session identifier "
            + "changed to \(identifier?.count ?? -1) bytes")
    }

    @available(iOS 14.5, *)
    func contentKeySession(_ session: AVContentKeySession,
                           externalProtectionStatusDidChangeFor
                           contentKeySpecifier: AVContentKeySpecifier,
                           hasAvailableKey: Bool) {
        // A display-security refusal looks exactly like a missing key
        // from the sink's side, and it is not something a licence can
        // fix. Worth being able to tell the two apart.
        FairPlayStreamParser.log(
            "session \(sessionId) external protection status changed - "
            + "hasAvailableKey=\(hasAvailableKey)")
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
        // An unclaimed request still has an identity, and discarding it
        // is what parks the SPC.
        //
        // The empty content id here travelled all the way to
        // FairPlayCDMProxy's parking branch, which is keyed by content
        // id: "SPC PRODUCED ... id : 8776 bytes" and then "SPC parked
        // for  (8776 bytes)". The bytes were right - they came from the
        // parser's own specifier, the only object that names the real
        // constant IV - and nothing could address them.
        //
        // The request is not anonymous. It arrives carrying the fkri key
        // id out of the page's own pssh, which fix 59 also files per EME
        // session, so naming the SPC by that id is enough for the far
        // side to find the session that asked.
        var unclaimedContentId = ""
        if claimed == nil,
           let identifier = keyRequest.identifier as? Data,
           identifier.count == 16 {
            let hex = identifier.map { String(format: "%02x", $0) }.joined()
            unclaimedContentId = "reynard-keyid:" + hex
            FairPlayStreamParser.log(
                "session \(sessionId) no origination claimed - addressing "
                + "this SPC by the request's own key id \(hex)")
        }
        let origination = claimed
            ?? FairPlayOrigination(contentId: unclaimedContentId,
                                   initData: Data())
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
            // A licence we already hold beats a message nobody answers.
            //
            // Only for the requests fix 66 addressed by key id - the
            // ones the parser raised, which the page did not ask for and
            // will not answer. Everything the page originated still gets
            // the page's own licence; replaying one into a genuine
            // renewal would be a stale key answering a fresh question.
            //
            // The SPC is made either way, because a request has to be
            // loaded before a response can be processed. It simply is
            // not sent.
            let replayed: Bool = { () -> Bool in
                guard origination.contentId.hasPrefix("reynard-keyid:"),
                      let identifier = keyRequest.identifier as? Data,
                      identifier.count == 16 else {
                    return false
                }
                let hex = identifier.map { String(format: "%02x", $0) }.joined()
                let held: Data? = self.withLock { () -> Data? in
                    self.licenceByKeyId[hex]
                }
                guard let held else {
                    FairPlayStreamParser.log(
                        "session \(self.sessionId) no licence held for key "
                        + "\(hex) - asking the page")
                    return false
                }
                FairPlayStreamParser.log(
                    "session \(self.sessionId) replaying the licence already "
                    + "held for key \(hex) (\(held.count) bytes) instead of "
                    + "asking again")
                _ = self.provide(response: held,
                                 contentId: origination.contentId)
                return true
            }()
            if replayed {
                return
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
        // Kept, for a request that has not been raised yet.
        //
        // Apple's player answers one message per session. The parser's
        // own specifier arrives afterwards, asks for the same key, and
        // is met with silence - both of its SPCs reached the page in the
        // last capture and neither was ever answered. This is what the
        // replay below serves.
        if let identifier = request.identifier as? Data,
           identifier.count == 16 {
            let hex = identifier.map { String(format: "%02x", $0) }.joined()
            withLock { () -> Void in licenceByKeyId[hex] = ckc }
        }
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
        // CHANGED - see mse_fix_84's docstring. A batched session sends
        // nothing until every challenge is made, and then sends all of
        // them as one message. An unbatched session is handed straight
        // back its own SPC and behaves exactly as before.
        guard let outgoing = FairPlayStreamParser.shared.batchedMessage(
                sessionId: sessionId, contentId: contentId, spc: spc) else {
            return
        }
        let contentId = outgoing.0
        let spc = outgoing.1
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

    /// The same callback, with the discontinuity flag.
    ///
    /// ADDED - see mse_fix_100's docstring. WebKit's delegate implements
    /// BOTH spellings and this file declared only the first, which has
    /// never fired: "parsed asset" appears zero times in a capture with
    /// sixteen thousand media-data callbacks in it. If this one is the
    /// one the OS calls, trackIDs stops being empty and arming becomes
    /// possible for the first time on this route.
    ///
    /// Straight through to the arity-2 handler. The flag says the asset
    /// follows a timeline break, which this side already detects for
    /// itself from the sample stamps - see the discontinuity test in
    /// enqueueForDisplay - so nothing here needs to act on it.
    @objc(streamDataParser:didParseStreamDataAsAsset:withDiscontinuity:)
    func streamDataParser(_ parser: Any,
                          didParseStreamDataAsAsset asset: AVAsset,
                          withDiscontinuity discontinuity: Bool) {
        fputs("fpsParser: session \(sessionId) parsed asset WITH "
              + "discontinuity=\(discontinuity) - it is this spelling the "
              + "OS calls, not the arity-2 one\n", stderr)
        streamDataParser(parser, didParseStreamDataAsAsset: asset)
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
        // A SIGN OF LIFE - see mse_fix_159's docstring.
        FairPlayStreamParser.shared.noteMediaData(from: parser as AnyObject)
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
