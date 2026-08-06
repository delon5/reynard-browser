//
//  FairPlayLayerProbe.swift
//  Reynard
//
//  A probe, not a feature. It answers the one untested assumption in the
//  FairPlay stage 2 plan: can an AVPlayerLayer live inside Gecko's
//  compositor layer tree, at a video element's position, and survive the
//  compositor's per-frame updates?
//
//  Everything else in that plan reuses machinery that already works.
//  NativeLayerCA already builds a real AVSampleBufferDisplayLayer at the
//  element's exact geometry, tracked through scroll, zoom, clip and
//  transform, and PictureInPictureCoordinator already reaches in and
//  hands that layer to the app. The only thing nobody has tested is
//  whether that slot tolerates a different layer class driven by an
//  AVPlayer - which it has to, because AVPlayer cannot render into an
//  AVSampleBufferDisplayLayer, and AVPlayerItemVideoOutput returns
//  nothing for protected content by design.
//
//  If the compositor discards our layer, or the geometry stops tracking,
//  that needs to be known before any Gecko-side work starts.
//
//  The stream is unprotected on purpose. This tests layer plumbing, not
//  FairPlay.

import AVFoundation
import Foundation
import QuartzCore
import UIKit

/// Flip to false to disable the probe without removing it.
private let kFairPlayLayerProbeEnabled = true

/// Apple's public HLS sample stream.
private let kFairPlayLayerProbeStream =
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"

/// How many one-second reports to make before giving up. Enough to cover
/// a scroll and a rotation without filling the log.
private let kFairPlayLayerProbeTicks = 240

final class FairPlayLayerProbe {
    static var isEnabled: Bool { return kFairPlayLayerProbeEnabled }
    
    private let hostLayer: CALayer
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var timer: Timer?
    private var ticks = 0
    private var attachedTo: CALayer?
    private var insertedAsSibling = false
    
    init(hostLayer: CALayer) {
        self.hostLayer = hostLayer
    }
    
    deinit {
        timer?.invalidate()
    }
    
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard player == nil else {
            return
        }
        guard let url = URL(string: kFairPlayLayerProbeStream) else {
            logger("fairPlayProbe: could not build the stream URL")
            return
        }
        
        // A sibling above the video layer is closer to what the real
        // change would do - NativeLayerCA would create this layer as
        // mContentCALayer instead of the sample buffer layer - so try
        // that first and only fall back to a child.
        let parent: CALayer
        if let superlayer = hostLayer.superlayer {
            parent = superlayer
            insertedAsSibling = true
            playerLayer.frame = hostLayer.frame
        } else {
            parent = hostLayer
            insertedAsSibling = false
            playerLayer.frame = hostLayer.bounds
        }
        
        playerLayer.videoGravity = .resizeAspect
        
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        self.player = player
        playerLayer.player = player
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if insertedAsSibling {
            parent.insertSublayer(playerLayer, above: hostLayer)
        } else {
            parent.addSublayer(playerLayer)
        }
        CATransaction.commit()
        attachedTo = parent
        
        player.play()
        
        logger(String(
            format: "fairPlayProbe: attached as %@ of %@ - host frame %@, player frame %@",
            insertedAsSibling ? "sibling" : "child",
            String(describing: type(of: parent)),
            NSCoder.string(for: hostLayer.frame),
            NSCoder.string(for: playerLayer.frame)
        ))
        
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
    }
    
    /// Whether a layer's superlayer chain still terminates at the
    /// window's own layer. An orphaned subtree keeps every internal link
    /// intact, so this is the only reliable way to tell.
    private func isRootedInWindow(_ layer: CALayer) -> Bool {
        var root: CALayer = layer
        while let parent = root.superlayer {
            root = parent
        }
        
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else {
                continue
            }
            for window in windowScene.windows where window.layer === root {
                return true
            }
        }
        return false
    }
    
    private func tick() {
        ticks += 1
        
        // The question the whole probe exists to answer: is our layer
        // still in the tree, and is it still where the video is?
        //
        // The parent pointer alone is not enough. A subtree removed from
        // the window keeps its internal links, so an orphaned layer
        // reports a healthy parent forever while rendering nothing -
        // which is how this test passed twice through a fullscreen
        // transition that had thrown the layer away.
        let parentUnchanged = playerLayer.superlayer === attachedTo
        let rooted = isRootedInWindow(playerLayer)
        let stillAttached = parentUnchanged && rooted
        let hostMoved = insertedAsSibling && playerLayer.frame != hostLayer.frame
        
        logger(String(
            format: "fairPlayProbe: tick %ld attached=%@ hostFrame=%@ playerFrame=%@ rate=%.2f status=%ld",
            ticks,
            stillAttached ? "YES" : "NO",
            NSCoder.string(for: hostLayer.frame),
            NSCoder.string(for: playerLayer.frame),
            player?.rate ?? 0,
            (player?.currentItem?.status.rawValue).map { Int($0) } ?? -1
        ))
        
        if !stillAttached {
            if parentUnchanged {
                // The subtree came away whole. The layer would have to be
                // created by NativeLayerCA rather than inserted beside
                // its content layer.
                logger("fairPlayProbe: ORPHANED - parent intact but the subtree is no longer in the window")
            } else {
                logger("fairPlayProbe: REPARENTED - the compositor took our layer out of its parent")
            }
            stop()
            return
        }
        
        // Follow the host so a scroll shows whether geometry tracking is
        // usable, rather than only whether the layer survives.
        if hostMoved {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = hostLayer.frame
            CATransaction.commit()
        }
        
        if ticks >= kFairPlayLayerProbeTicks {
            logger("fairPlayProbe: finished - the layer survived the full run")
            stop()
        }
    }
}
