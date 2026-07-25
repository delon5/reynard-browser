//
//  MainThreadHangWatchdog.swift
//  Reynard
//

import Foundation

/// Detects a genuinely unresponsive main thread from a background queue,
/// independent of any UIApplication/UIScene lifecycle hook.
///
/// Why this exists: every flush-on-exit mechanism this app has (background
/// flush, terminate flush) depends on iOS *cooperatively telling us* the
/// app is ending. A real crash showed that assumption can fail completely
/// — a watchdog SIGKILL after the main thread hung inside Gecko's own
/// native networking code gives zero warning and calls neither
/// `sceneDidEnterBackground` nor `applicationWillTerminate`. This
/// watchdog doesn't wait to be told; it notices unresponsiveness on its
/// own, from a background thread that's unaffected by whatever's stuck
/// the main thread, and reacts before the OS's own much harsher
/// watchdog (observed at 5s in that crash) gets a chance to.
///
/// Mechanism: periodically dispatch a lightweight block to the main
/// queue that just records "the main thread is alive, right now." If a
/// tick on the background timer finds that timestamp hasn't moved in
/// longer than `hangThreshold`, the main thread genuinely isn't
/// processing work — including our own ping — and `onHangDetected`
/// fires exactly once per hang.
final class MainThreadHangWatchdog {
    private let hangThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private let onHangDetected: () -> Void
    
    private let lock = NSLock()
    private var lastMainThreadResponseTime = Date()
    private var hasFiredForCurrentHang = false
    private var isRunning = false
    
    private var timer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.minh-ton.Reynard.MainThreadHangWatchdog", qos: .utility)
    
    /// - Parameters:
    ///   - hangThreshold: how long the main thread can go without
    ///     responding before this considers it hung. Chosen well below
    ///     the ~5s watchdog SIGKILL window observed in the real crash
    ///     this was built for, to maximize the time available to react.
    ///   - checkInterval: how often to check.
    ///   - onHangDetected: called once, from the background watchdog
    ///     queue (not the main thread — it's the one that's stuck), the
    ///     moment a hang is first detected.
    init(
        hangThreshold: TimeInterval = 2.0,
        checkInterval: TimeInterval = 0.25,
        onHangDetected: @escaping () -> Void
    ) {
        self.hangThreshold = hangThreshold
        self.checkInterval = checkInterval
        self.onHangDetected = onHangDetected
    }
    
    func start() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lastMainThreadResponseTime = Date()
        hasFiredForCurrentHang = false
        lock.unlock()
        
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
        
        pingMainThread()
    }
    
    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
        
        timer?.cancel()
        timer = nil
    }
    
    private func pingMainThread() {
        // Bail out of the recursive ping cycle once stopped — otherwise
        // this keeps bouncing between the main and watchdog queues every
        // checkInterval forever (until self deallocs), even after stop().
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.recordMainThreadResponse()
            self.watchdogQueue.asyncAfter(deadline: .now() + self.checkInterval) { [weak self] in
                self?.pingMainThread()
            }
        }
    }
    
    private func recordMainThreadResponse() {
        lock.lock()
        lastMainThreadResponseTime = Date()
        hasFiredForCurrentHang = false
        lock.unlock()
    }
    
    private func tick() {
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastMainThreadResponseTime)
        let alreadyFired = hasFiredForCurrentHang
        if elapsed >= hangThreshold, !alreadyFired {
            hasFiredForCurrentHang = true
        }
        lock.unlock()
        
        guard elapsed >= hangThreshold, !alreadyFired else {
            return
        }
        
        NSLog("[HangWatchdog] Main thread unresponsive for %.2fs — triggering emergency flush", elapsed)
        onHangDetected()
    }
}
