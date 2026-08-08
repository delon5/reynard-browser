//
//  AVPlayerHost.swift
//  Reynard
//
//  The embedder side of AVPlayerDecoder.
//
//  Lives in the GeckoView framework, not the app: MediaDecoder runs
//  in whichever Gecko process owns the media element - content
//  processes included - and every such process links this framework
//  and reaches this object through its own GeckoRuntimeImpl
//  .avPlayerHost. App-target placement would leave content
//  processes with no host at all.
//
//  stderr rather than the app's logger(): logger's implementation
//  (JITUtils.m) is app-target-only and does not link into this
//  framework - the exact linker failure GeckoRuntime.swift already
//  documents.
//
//  And stderr rather than NSLog, which is what this used to be.
//  Everything here runs in the CONTENT process, and the device capture
//  only picks up stderr from those - every NSLog-format line in a
//  capture carries the parent's pid, never a content pid. So none of
//  this file's output ever reached a log, and "did createPlayer even
//  run?" could not be answered from one: the C++ side would print
//  "avPlayer: Create()" and then nothing followed it, whether the
//  player was built or not. printf_stderr on that side lands fine, so
//  avLog matches its channel.
//
//  FairPlay forces this split: only AVURLAsset conforms to
//  AVContentKeyRecipient, so an AVContentKeySession can never be attached
//  to samples Gecko demuxed. AVFoundation has to own the URL from the
//  network down, and Gecko drives it from a distance.
//
//  Reached from C++ through GetSwiftRuntime(), the same way every other
//  Gecko-to-app call works here. Raw C symbols would not link, since
//  libxul is a framework and cannot leave undefined symbols pointing at
//  the app.
//

import AVFoundation
import Foundation

/// Unbuffered stderr, matching the C++ side's printf_stderr - see the
/// file comment for why this is not NSLog. Flushed every time: a
/// content process that is about to be killed still gets its last line
/// out, which is the case this logging exists to catch.
private func avLog(_ message: String) {
    fputs("avPlayer: \(message)\n", stderr)
    fflush(stderr)
}

@objc(ReynardAVPlayerHost)
public final class AVPlayerHost: NSObject {
    public static let shared = AVPlayerHost()

    /// Players by opaque id. The decoder holds only the id, so a player
    /// outliving its decoder - or the reverse - cannot dereference
    /// anything freed.
    private var players: [UInt: Player] = [:]
    private var nextID: UInt = 1

    /// The AVContentKeySession the EME licence exchange is bound to,
    /// published by FairPlayCDMProxy the moment it creates one.
    ///
    /// Held weakly: the proxy owns it and tears it down with the page's
    /// MediaKeys, and a strong reference here would keep a dead session
    /// - and its delegate, which retains the proxy - alive for the
    /// process lifetime.
    ///
    /// LIMITATION, deliberately not hidden: this is the most RECENT
    /// session, not one bound per decoder, because
    /// MediaDecoder::SetCDMProxy is not virtual and AVPlayerDecoder has
    /// no hook to reach its own proxy through. With a single protected
    /// element playing - all this pipeline supports today - that is the
    /// same pairing. Two protected elements at once would attach the
    /// second one's asset to the first one's session; fixing that
    /// properly needs SetCDMProxy made virtual.
    private weak var emeContentKeySession: AVContentKeySession?

    // MARK: - Called from FairPlayCDMProxy

    /// Publishes the session the EME key exchange runs on, so assets
    /// created here can be registered as recipients of it.
    @objc public func useContentKeySession(_ session: AVContentKeySession) {
        emeContentKeySession = session
        avLog("EME published a content key session")
    }

    private final class Player {
        let player: AVPlayer
        let item: AVPlayerItem
        let asset: AVURLAsset
        let keySession: AVContentKeySession
        let delegate: ContentKeyDelegate?
        var observers: [NSKeyValueObservation] = []

        init(player: AVPlayer, item: AVPlayerItem, asset: AVURLAsset,
             keySession: AVContentKeySession, delegate: ContentKeyDelegate?) {
            self.player = player
            self.item = item
            self.asset = asset
            self.keySession = keySession
            self.delegate = delegate
        }
    }

    // MARK: - Called from AVPlayerDecoder

    /// Returns 0 on failure, which the decoder treats as a load error.
    @objc public func createPlayer(url: String) -> UInt {
        guard let parsed = URL(string: url) else {
            avLog("could not parse \(url)")
            return 0
        }

        let asset = AVURLAsset(url: parsed)

        // The whole reason this pipeline exists. addContentKeyRecipient
        // accepts AVURLAsset and nothing else, which is why Gecko's own
        // decoders can never be given FairPlay keys.
        //
        // Prefer the session the EME exchange is bound to, published by
        // FairPlayCDMProxy through useContentKeySession(_:). Its keys
        // only decrypt assets registered on THAT session - a session we
        // made here holds none of them, however correctly configured.
        //
        // The locally-created fallback is for plain HLS reaching this
        // decoder with no EME involved: it never receives a licence, so
        // its delegate just reports the request and fails it, which is
        // the same behaviour as before this pipeline knew about EME.
        let keySession: AVContentKeySession
        let delegate: ContentKeyDelegate?
        if let published = emeContentKeySession {
            keySession = published
            delegate = nil
            avLog("using the EME-published content key session")
        } else {
            let owned = AVContentKeySession(keySystem: .fairPlayStreaming)
            let ownedDelegate = ContentKeyDelegate()
            owned.setDelegate(ownedDelegate, queue: .main)
            keySession = owned
            delegate = ownedDelegate
            avLog("no EME session published - using a local one (no licence)")
        }
        keySession.addContentKeyRecipient(asset)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true

        let id = nextID
        nextID += 1
        players[id] = Player(player: player, item: item, asset: asset,
                             keySession: keySession, delegate: delegate)

        avLog("created \(id) for \(parsed.absoluteString)")
        return id
    }

    @objc public func play(_ id: UInt) {
        players[id]?.player.play()
    }

    @objc public func pause(_ id: UInt) {
        players[id]?.player.pause()
    }

    /// Backgrounding. Playback stops but the item is kept, so resuming
    /// does not re-fetch or re-negotiate keys.
    @objc public func suspend(_ id: UInt) {
        players[id]?.player.pause()
    }

    @objc public func resume(_ id: UInt) {
        players[id]?.player.play()
    }

    @objc public func destroy(_ id: UInt) {
        guard let entry = players.removeValue(forKey: id) else {
            return
        }
        entry.observers.forEach { $0.invalidate() }
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        entry.keySession.removeContentKeyRecipient(entry.asset)
        avLog("destroyed \(id)")
    }

    /// The layer the compositor will hand us once NativeLayerCA builds an
    /// AVPlayerLayer for the DRM-marked surface. Until that lands the
    /// player renders nowhere, which is expected.
    @objc public func attachLayer(_ layer: AVPlayerLayer, to id: UInt) {
        guard let entry = players[id] else {
            return
        }
        layer.player = entry.player
        avLog("attached layer to \(id)")
    }

    /// Seconds, or -1 when not yet known.
    @objc public func currentTime(_ id: UInt) -> Double {
        guard let entry = players[id] else {
            return -1
        }
        let time = entry.player.currentTime()
        return time.isValid && !time.isIndefinite ? time.seconds : -1
    }

    @objc public func duration(_ id: UInt) -> Double {
        guard let entry = players[id] else {
            return -1
        }
        let duration = entry.item.duration
        return duration.isValid && !duration.isIndefinite ? duration.seconds : -1
    }

    @objc public func seek(_ id: UInt, to seconds: Double) {
        guard let entry = players[id] else {
            return
        }
        entry.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
}

/// Handles the key request AVFoundation raises for a protected asset.
///
/// Left deliberately incomplete: the SPC goes to a licence server whose
/// URL and certificate are per-deployment, and inventing one here would
/// be a guess. The request is logged so the negotiation is visible, which
/// is more than the earlier probes ever got - AVContentKeySession never
/// called back at all when the recipient was not an AVURLAsset.
final class ContentKeyDelegate: NSObject, AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession,
                           didProvide keyRequest: AVContentKeyRequest) {
        let identifier = (keyRequest.identifier as? String) ?? "<none>"
        avLog("content key requested for \(identifier)")

        // Without a licence server the request cannot be satisfied.
        // Failing it explicitly is better than leaving it pending, which
        // stalls playback with no diagnosis.
        keyRequest.processContentKeyResponseError(
            NSError(domain: "ReynardAVPlayer", code: -1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No FairPlay licence server configured"
            ])
        )
    }

    func contentKeySession(_ session: AVContentKeySession,
                           contentKeyRequest keyRequest: AVContentKeyRequest,
                           didFailWithError err: Error) {
        avLog("content key request failed - \(err)")
    }
}
