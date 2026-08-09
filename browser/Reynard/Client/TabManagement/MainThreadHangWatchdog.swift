//
//  MainThreadHangWatchdog.swift
//  Reynard
//

import Foundation
import UIKit

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
///
/// Suspension awareness: iOS freezes every thread while the app is
/// suspended, so on resume "time since the main thread last responded"
/// spans the entire suspension — indistinguishable from a hang, and it
/// used to false-fire an emergency flush on every resume longer than
/// `hangThreshold`. The watchdog therefore pauses itself on
/// didEnterBackground and re-arms (with a fresh timestamp) on
/// willEnterForeground. Both notifications are delivered on the main
/// thread, which preserves the property that matters: a main thread
/// that hangs before backgrounding completes never delivers the pause,
/// so the watchdog stays armed for exactly the scenario it was built
/// for.
final class MainThreadHangWatchdog {
    private let hangThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private let onHangDetected: () -> Void

    private let lock = NSLock()
    /// ProcessInfo.systemUptime rather than Date(): monotonic while the
    /// system is awake, so a wall-clock adjustment (NTP correction,
    /// manual change) can never masquerade as a hang, and it stops
    /// during device sleep, which is never a hang either.
    private var lastMainThreadResponseUptime = ProcessInfo.processInfo.systemUptime
    private var hasFiredForCurrentHang = false
    private var isRunning = false
    /// Set only by the didEnterBackground pause, cleared by any stop —
    /// so an explicit stop() is never undone by a later foreground
    /// transition.
    private var resumeOnForeground = false
    /// Incremented by every start(). Each recursive ping chain carries
    /// the generation it was started with and terminates when the
    /// current generation no longer matches. The isRunning check alone
    /// could not guarantee that: a stop() followed by a start() within
    /// one checkInterval (a sub-quarter-second background/foreground
    /// bounce) flipped isRunning back to true before the old chain's
    /// next hop observed it false, so the superseded chain survived
    /// alongside the new one — and each such bounce could add another
    /// permanent chain bouncing between the main and watchdog queues
    /// every checkInterval for the rest of the process lifetime.
    private var pingGeneration = 0

    private var timer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.minh-ton.Reynard.MainThreadHangWatchdog", qos: .utility)
    private var lifecycleObservationTokens: [NSObjectProtocol] = []

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

        let center = NotificationCenter.default
        lifecycleObservationTokens = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.pauseForBackground()
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resumeFromBackgroundIfNeeded()
            },
        ]
    }

    deinit {
        for token in lifecycleObservationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        timer?.cancel()
    }

    func start() {
        lock.lock()
        if isRunning {
            lock.unlock()
            return
        }
        isRunning = true
        lastMainThreadResponseUptime = ProcessInfo.processInfo.systemUptime
        hasFiredForCurrentHang = false
        pingGeneration += 1
        let generation = pingGeneration
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer

        pingMainThread(generation: generation)
    }

    func stop() {
        lock.lock()
        isRunning = false
        resumeOnForeground = false
        lock.unlock()

        timer?.cancel()
        timer = nil
    }

    private func pauseForBackground() {
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else {
            return
        }

        stop()

        lock.lock()
        resumeOnForeground = true
        lock.unlock()
    }

    private func resumeFromBackgroundIfNeeded() {
        lock.lock()
        let shouldResume = resumeOnForeground
        resumeOnForeground = false
        lock.unlock()
        guard shouldResume else {
            return
        }

        // start() re-stamps lastMainThreadResponseUptime, so the frozen
        // stretch the process just spent suspended never counts as a
        // hang.
        start()
    }

    private func pingMainThread(generation: Int) {
        // Bail out of the recursive ping cycle once stopped or
        // superseded — otherwise this keeps bouncing between the main
        // and watchdog queues every checkInterval forever (until self
        // deallocs), even after stop(). The generation comparison is
        // what makes a stop()-then-start() bounce kill the old chain
        // at its next hop; see pingGeneration's own comment.
        lock.lock()
        let current = isRunning && generation == pingGeneration
        lock.unlock()
        guard current else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.recordMainThreadResponse()
            self.watchdogQueue.asyncAfter(deadline: .now() + self.checkInterval) { [weak self] in
                self?.pingMainThread(generation: generation)
            }
        }
    }

    private func recordMainThreadResponse() {
        lock.lock()
        lastMainThreadResponseUptime = ProcessInfo.processInfo.systemUptime
        hasFiredForCurrentHang = false
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - lastMainThreadResponseUptime
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
