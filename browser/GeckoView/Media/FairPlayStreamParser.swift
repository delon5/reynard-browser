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
        /// Track ids the parser has raised a key request for, in arrival
        /// order. The SPC call needs one and the CKC is addressed to one,
        /// and neither EME message carries it - the page has never heard
        /// of a track id.
        var trackIDs: [Int32] = []

        init(parser: NSObject,
             recipient: AVContentKeyRecipient,
             keySession: AVContentKeySession,
             delegate: ParserDelegate) {
            self.parser = parser
            self.recipient = recipient
            self.keySession = keySession
            self.delegate = delegate
        }
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func log(_ message: String) {
        fputs("fpsParser: \(message)\n", stderr)
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

        // A session with no delegate of its own on purpose. The parser is
        // the recipient and the parser's delegate is what reports the key
        // request; AVContentKeySession's own delegate is the AVURLAsset
        // path's mechanism and would be a second, conflicting source of
        // the same event.
        let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        keySession.addContentKeyRecipient(recipient)

        withState {
            entries[sessionId] = Entry(parser: parser, recipient: recipient,
                                       keySession: keySession, delegate: delegate)
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

        // Typed invocation, not perform(): the selector takes an int32
        // track id and an NSError**, and perform() can carry neither.
        // Getting this wrong is what crashed the probe - it typed the
        // track id as an object and sent it isKindOfClass:.
        let selector = NSSelectorFromString(
            "streamingContentKeyRequestDataForApp:contentIdentifier:trackID:options:error:")
        guard entry.parser.responds(to: selector),
              let signature = entry.parser.method(for: selector) else {
            Self.log("no streamingContentKeyRequestDataForApp: on the parser")
            return nil
        }
        typealias SPCFunction = @convention(c) (
            AnyObject, Selector, NSData, NSData, Int32, NSDictionary?,
            UnsafeMutablePointer<NSError?>?
        ) -> NSData?
        let call = unsafeBitCast(signature, to: SPCFunction.self)

        var error: NSError?
        let spc = withUnsafeMutablePointer(to: &error) { errorPointer -> NSData? in
            call(entry.parser, selector, certificate as NSData,
                 contentIdentifier as NSData, trackID, nil, errorPointer)
        }
        guard let spc else {
            Self.log("SPC refused for session \(sessionId) track \(trackID): "
                     + (error.map { String(describing: $0) } ?? "no error given"))
            return nil
        }
        Self.log("SPC for session \(sessionId) track \(trackID): \(spc.length) bytes")
        return spc as Data
    }

    /// The CKC the page's licence server returned.
    @discardableResult
    @objc public func provideResponse(_ sessionId: String, ckc: Data) -> Bool {
        guard let entry = withState({ entries[sessionId] }) else {
            Self.log("CKC for unknown session \(sessionId)")
            return false
        }
        guard let trackID = withState({ entry.trackIDs.first }) else {
            Self.log("CKC for session \(sessionId) with no track to apply it to")
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
    @objc(streamDataParser:didProvideContentKeySpecifier:forTrackID:)
    func streamDataParser(_ parser: Any,
                          didProvideContentKeySpecifier specifier: Any,
                          forTrackID trackID: Int32) {
        fputs("fpsParser: session \(sessionId) key request on track \(trackID)\n", stderr)
        FairPlayStreamParser.shared.noteKeyRequest(sessionId: sessionId, trackID: trackID)
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
}
