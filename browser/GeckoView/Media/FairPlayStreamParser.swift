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
        /// The content id FairPlayCDMProxy keys this exchange by, kept
        /// from the generateRequest that opened it.
        ///
        /// The proxy files a session under base64 of the whole init data
        /// blob and matches the SPC coming back by exactly that string.
        /// Deriving an id here from AVContentKeyRequest.identifier would
        /// produce a different encoding and strand every message, so the
        /// one the request arrived with is the one it goes back with.
        var contentId: String = ""
        /// The initialisation data the request was raised from.
        ///
        /// Kept because the SPC still needs a content identifier and a
        /// request raised with a nil identifier has none to offer - the
        /// key id has to be read back out of these bytes. See
        /// KeySessionDelegate's ladder.
        var initData: Data = Data()

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
        Self.log("handing the specifier to the key session - id "
                 + "\(identifier.map { String(describing: $0) } ?? "nil"), "
                 + "\(initializationData?.count ?? 0) bytes of init data")
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
            entry.contentId = contentId
            entry.initData = initData
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
        entry.keySession.processContentKeyRequest(withIdentifier: nil,
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
        Self.keyDelegateQueue.asyncAfter(deadline: .now() + 5) {
            guard !delegate.sawRequest else {
                return
            }
            Self.log("session \(sessionId) raised NO key request from "
                     + "\(sentCount) bytes sent as \(sentShape) - "
                     + "AVFoundation did not recognise the shape, and "
                     + "said nothing about it")
        }
        return true
    }

    /// The content id this session reports its SPC under, or nil.
    func contentId(for sessionId: String) -> String? {
        return withState { entries[sessionId]?.contentId }
    }

    /// The initialisation data this session's request was raised from.
    func initData(for sessionId: String) -> Data? {
        return withState { entries[sessionId]?.initData }
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
    static func keyIdentifier(inPSSH data: Data) -> Data? {
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
            let count = be32(cursor)
            cursor += 4
            guard count > 0, bytes.count >= cursor + 16 else { return nil }
            return Data(bytes[cursor..<(cursor + 16)])
        }
        guard bytes.count >= cursor + 4 else { return nil }
        let payload = be32(cursor)
        cursor += 4
        guard payload >= 16, bytes.count >= cursor + 16 else { return nil }
        // CHANGED - see fix_key_request_unwraps_pssh.py's docstring.
        // A version 0 box names no key ids, and this branch assumed
        // Apple's opens its payload with one. The box the page actually
        // sends opens with a nested fpsd box, so what came back was
        // four bytes of length and four of ASCII reported as a key id.
        // A payload that is box-shaped is not one.
        if Self.looksLikeBox(bytes, at: cursor, within: payload) {
            return nil
        }
        return Data(bytes[cursor..<(cursor + 16)])
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
    @objc public func provideResponse(_ sessionId: String, ckc: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("CKC for unknown session \(sessionId)")
            return false
        }
        if entry.keyDelegate.provide(response: ckc) {
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

    /// The certificate and the requests waiting for it, under one lock.
    ///
    /// One lock rather than two, because "is there a certificate" and
    /// "hold this request" have to be decided together. The request
    /// arrives on the session's dedicated queue while the certificate
    /// arrives from Gecko's main thread, so a certificate landing
    /// between those two decisions would leave a request parked with
    /// nothing left to wake it - the exact race this file already
    /// learned about the hard way on the delegate queue.
    private let lock = NSLock()
    private var storedCertificate: Data?
    private var heldRequests: [AVContentKeyRequest] = []
    /// The request an outstanding SPC belongs to.
    ///
    /// The licence is addressed to the REQUEST on this path, not to a
    /// track: nothing was ever parsed, so there is no track to name.
    private var awaitingResponse: AVContentKeyRequest?
    /// Whether any key request has ever arrived for this session.
    ///
    /// ADDED - see fix_key_request_watchdog.py's docstring.
    /// processContentKeyRequest returns void and reports nothing when
    /// it declines, so "no request came back" is a fact nothing in
    /// this file could previously state. This is what lets the
    /// watchdog state it.
    private var requestArrived = false

    /// Read from the watchdog block, through the same lock as the
    /// rest of this class's state.
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

    /// Held rather than dropped, which is the correction here.
    ///
    /// The certificate cannot arrive first. The page calls
    /// setServerCertificate while handling an 'encrypted' event, and
    /// that event is produced by the very key request that needs it - so
    /// a delegate that returned early on a missing certificate discarded
    /// the request in the ORDINARY case, and nothing ever re-raised it.
    /// The native path has always held these; see AVPlayerHost's
    /// awaitingCertificate.
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

    /// The CKC, applied to the request that asked for it.
    ///
    /// processContentKeyResponseData:forTrackID: - the parser's call -
    /// names a track a key request was raised for, and this route has
    /// none: the request came from the session, from initialisation data
    /// alone. AVContentKeyResponse into the request is the matching
    /// half of processContentKeyRequest, and the only one that can work
    /// here.
    func provide(response ckc: Data) -> Bool {
        guard let request = withLock({ awaitingResponse }) else {
            FairPlayStreamParser.log(
                "session \(sessionId) has no key request awaiting a licence")
            return false
        }
        request.processContentKeyResponse(
            AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
        withLock { awaitingResponse = nil }
        FairPlayStreamParser.log(
            "session \(sessionId) licence applied to the key request, "
            + "\(ckc.count) bytes")
        return true
    }

    func contentKeySession(_ session: AVContentKeySession,
                           didProvide keyRequest: AVContentKeyRequest) {
        FairPlayStreamParser.log(
            "session \(sessionId) REAL AVContentKeyRequest arrived - "
            + "identifier \(String(describing: keyRequest.identifier))")
        let ready = withLock { () -> Bool in
            // Before the certificate test, deliberately: a request
            // that arrives and is HELD has still arrived, and the
            // watchdog is asking about AVFoundation, not about us.
            requestArrived = true
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

    /// The SPC itself, once there is a certificate to make one with.
    private func makeSPC(for keyRequest: AVContentKeyRequest) {
        guard let certificate = withLock({ storedCertificate }) else {
            return
        }
        // Kept so the licence has something to be applied to when it
        // comes back - see provide(response:).
        withLock { awaitingResponse = keyRequest }
        guard let contentId = contentIdentifier(for: keyRequest) else {
            FairPlayStreamParser.log(
                "session \(sessionId) has nothing to address an SPC with")
            return
        }
        keyRequest.makeStreamingContentKeyRequestData(
            forApp: certificate, contentIdentifier: contentId, options: nil
        ) { spc, error in
            guard let spc else {
                FairPlayStreamParser.log(
                    "SPC failed for session \(self.sessionId): "
                    + (error.map { String(describing: $0) } ?? "no error given"))
                return
            }
            FairPlayStreamParser.log(
                "SPC PRODUCED for session \(self.sessionId): \(spc.count) bytes")
            self.report(spc: spc)
        }
    }

    /// What the SPC covers.
    ///
    /// A request raised by processContentKeyRequest(withIdentifier: nil,
    /// ...) carries no identifier of its own - that is the shape this
    /// path deliberately uses, since on MSE the initialisation data is
    /// the identity - so the key id is read back out of those bytes
    /// instead.
    ///
    /// A ladder rather than a single answer, ordered most specific
    /// first, and it logs which rung it landed on: whether AVFoundation
    /// accepts a PSSH's key id here is the next unknown, and the capture
    /// has to be able to say which one produced the SPC.
    private func contentIdentifier(for keyRequest: AVContentKeyRequest) -> Data? {
        if let data = keyRequest.identifier as? Data {
            FairPlayStreamParser.log("addressing the SPC by the request's identifier")
            return data
        }
        if let string = keyRequest.identifier as? String {
            // Scheme stripped, like the native path and Apple's HLS
            // Catalog sample: what a key server is told is the asset id,
            // not the URI that named it.
            let assetId = string.hasPrefix("skd://")
                ? String(string.dropFirst("skd://".count))
                : string
            FairPlayStreamParser.log("addressing the SPC by the request's URI identifier")
            return Data(assetId.utf8)
        }
        let initData = FairPlayStreamParser.shared.initData(for: sessionId) ?? Data()
        if let keyId = FairPlayStreamParser.keyIdentifier(inPSSH: initData) {
            FairPlayStreamParser.log("addressing the SPC by the PSSH's key id")
            return keyId
        }
        guard !initData.isEmpty else {
            return nil
        }
        FairPlayStreamParser.log("addressing the SPC by the whole init data")
        return initData
    }

    /// The SPC's way back to the content process that asked for it.
    ///
    /// Main thread, because ReynardFairPlayNotifyParserKeyMessage
    /// asserts it and everything it touches on the Gecko side is
    /// main-thread-only. This delegate deliberately runs on its own
    /// queue - see createSession - so the hop is required rather than
    /// incidental.
    ///
    /// Reported under the content id the request ARRIVED with, never one
    /// derived from AVContentKeyRequest.identifier. FairPlayCDMProxy
    /// files the session under base64 of the whole init data and matches
    /// the message coming back by exactly that string; any other
    /// encoding parks the SPC in mRemotePendingSpc for ever.
    private func report(spc: Data) {
        guard let childId = Self.childId(ofSession: sessionId) else {
            FairPlayStreamParser.log(
                "session \(sessionId) is not a child session - "
                + "SPC produced but not routed")
            return
        }
        let contentId =
            FairPlayStreamParser.shared.contentId(for: sessionId) ?? ""
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

    /// "child-9" -> 9. Nothing else has a content process to go back to;
    /// the render probe's session deliberately does not.
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
