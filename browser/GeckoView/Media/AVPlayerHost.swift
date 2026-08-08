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
//  NSLog rather than the app's logger(): logger's implementation
//  (JITUtils.m) is app-target-only and does not link into this
//  framework - the exact linker failure GeckoRuntime.swift already
//  documents.
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

@objc(ReynardAVPlayerHost)
public final class AVPlayerHost: NSObject {
    public static let shared = AVPlayerHost()

    /// Players by opaque id. The decoder holds only the id, so a player
    /// outliving its decoder - or the reverse - cannot dereference
    /// anything freed.
    private var players: [UInt: Player] = [:]
    private var nextID: UInt = 1

    private final class Player {
        let player: AVPlayer
        let item: AVPlayerItem
        let asset: AVURLAsset
        let keySession: AVContentKeySession
        let delegate: ContentKeyDelegate
        var observers: [NSKeyValueObservation] = []

        init(player: AVPlayer, item: AVPlayerItem, asset: AVURLAsset,
             keySession: AVContentKeySession, delegate: ContentKeyDelegate) {
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
            NSLog("%@", "avPlayer: could not parse \(url)")
            return 0
        }

        let asset = AVURLAsset(url: parsed)

        // The whole reason this pipeline exists. addContentKeyRecipient
        // accepts AVURLAsset and nothing else, which is why Gecko's own
        // decoders can never be given FairPlay keys.
        let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        let delegate = ContentKeyDelegate()
        keySession.setDelegate(delegate, queue: .main)
        keySession.addContentKeyRecipient(asset)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true

        let id = nextID
        nextID += 1
        players[id] = Player(player: player, item: item, asset: asset,
                             keySession: keySession, delegate: delegate)

        NSLog("%@", "avPlayer: created \(id) for \(parsed.absoluteString)")
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
        NSLog("%@", "avPlayer: destroyed \(id)")
    }

    /// The layer the compositor will hand us once NativeLayerCA builds an
    /// AVPlayerLayer for the DRM-marked surface. Until that lands the
    /// player renders nowhere, which is expected.
    @objc public func attachLayer(_ layer: AVPlayerLayer, to id: UInt) {
        guard let entry = players[id] else {
            return
        }
        layer.player = entry.player
        NSLog("%@", "avPlayer: attached layer to \(id)")
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
        NSLog("%@", "avPlayer: content key requested for \(identifier)")

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
        NSLog("%@", "avPlayer: content key request failed - \(err)")
    }
}
