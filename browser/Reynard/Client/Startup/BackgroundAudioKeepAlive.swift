//
//  BackgroundAudioKeepAlive.swift
//  Reynard
//
//  Added by fix_background_audio_keepalive.py.
//

import AVFoundation

/// Plays inaudible audio so iOS does not suspend the app, keeping the
/// JIT debug tunnel and its sessions alive while backgrounded.
///
/// Every suspension problem shares one cause: iOS suspends the app, the
/// tunnel drops with Socket(BrokenPipe), and every debug loop dies. A
/// content process is then either left stopped - unable to answer the
/// synchronous XPC iOS sends every extension, killing the app with
/// 0x8BADF00D - or needs a new JIT region and traps into nothing.
///
/// This prevents the suspension rather than handling its consequences,
/// which is the approach StikDebug takes.
///
/// Off by default: an app that never suspends keeps its threads, tunnel
/// and every debug loop running in the background, which is real
/// battery drain.
final class BackgroundAudioKeepAlive {
    static let shared = BackgroundAudioKeepAlive()
    
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var isRunning = false
    private var healthCheckTimer: Timer?
    
    private init() {
        // A call or Siri will stop the engine, and the session can be
        // torn down entirely if media services reset - both need
        // recovering from rather than silently staying dead.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }
    
    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        startEngine()
        startHealthCheck()
    }
    
    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    /// Applies the current preference. Call at startup and whenever the
    /// toggle changes.
    func applyPreference() {
        if Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled {
            start()
        } else {
            stop()
        }
    }
    
    private func startEngine() {
        do {
            // Rebuilt rather than reused: AVAudioEngine does not
            // reliably restart after certain failures, and recreating it
            // is cheaper than diagnosing which.
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            
            let session = AVAudioSession.sharedInstance()
            
            // .mixWithOthers matters - without it, enabling this would
            // silence whatever the user is already listening to.
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            
            scheduleSilence()
            try engine.start()
            player.play()
        } catch {
            logger("BackgroundAudioKeepAlive: failed to start - \(error.localizedDescription)")
        }
    }
    
    private func scheduleSilence() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        
        // A PCM buffer is zero-initialised, so this is already silence -
        // nothing needs generating or shipping. One second, looped.
        player.scheduleBuffer(buffer, at: nil, options: .loops)
    }
    
    /// Something else can take the audio session without the
    /// interruption-ended notification ever arriving - a video playing
    /// in a tab, for instance. This reclaims it.
    private func startHealthCheck() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.recoverIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }
    
    private func recoverIfNeeded() {
        guard isRunning, !engine.isRunning || !player.isPlaying else {
            return
        }
        
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            player.play()
        } catch {
            // Still held by whatever took it - retried on the next tick.
        }
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard isRunning,
              let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }
        
        if type == .ended {
            recoverIfNeeded()
        }
    }
    
    @objc private func handleMediaServicesReset(_ notification: Notification) {
        guard isRunning else {
            return
        }
        
        // The session is gone entirely after a reset, so the engine has
        // to be rebuilt rather than merely restarted.
        startEngine()
    }
}
