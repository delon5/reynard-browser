//
//  SceneDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = .appBackground
        switch ReynardStartupMode.current {
        case .normal:
            let browserViewController = BrowserViewController()
            browserViewController.sessionManager.setApplicationForeground(
                scene.activationState != .background
            )
            window.overrideUserInterfaceStyle = AppAppearanceController.userInterfaceStyle(
                for: Prefs.AppearanceSettings.appAppearance
            )
            window.rootViewController = browserViewController
        case let .dataTransfer(operation):
            window.rootViewController = DataTransferOperationViewController(operation: operation)
        case .recoveryFailure:
            window.rootViewController = DataTransferRecoveryFailureViewController()
        }
        window.makeKeyAndVisible()
        self.window = window
        
        if case .normal = ReynardStartupMode.current {
            handleIncomingURLContexts(connectionOptions.urlContexts)
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleIncomingURLContexts(URLContexts)
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {}
    
    func sceneDidBecomeActive(_ scene: UIScene) {
        // Attach anything that arrived while we were inactive - see
        // fix_defer_attaches_while_inactive.py.
        JITController.shared.applicationDidBecomeActive()
        
        // Clears a now playing entry left behind by a session that died
        // without reporting - see fix_media_session_leak.py. Foreground
        // is when a stale one would be noticed anyway.
        SystemMediaSession.shared.revalidate()
        
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        browserViewController.sessionManager.applicationDidBecomeActive()
        browserViewController.privateBrowsingLockCoordinator.presentLockIfNeeded(animated: true)
    }
    
    func sceneWillResignActive(_ scene: UIScene) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        browserViewController.sessionManager.applicationWillResignActive()
        
        // Stop starting attaches - a process stopped mid-vAttach cannot
        // answer the synchronous XPC iOS is about to send it, and the
        // watchdog kills the app for the hang. See
        // fix_defer_attaches_while_inactive.py.
        JITController.shared.applicationWillResignActive()
        
        // Any attach still in flight has its target stopped, and iOS is
        // about to message every extension synchronously. See
        // fix_interrupt_attaching_sessions.py.
        if Prefs.ExperimentalSettings.interruptsAttachingSessionsOnResign {
            // REMOVED - see fix_delay_cancel_after_detach.py.
            //
            // This logged "0 attach(es) in flight, interrupted 0" on
            // every one of its twenty-odd invocations, so it never had
            // anything to interrupt and has never done anything. The
            // registry and the C function remain, unreferenced, so
            // restoring the experiment is one line.
            _ = ()
        }
        
        // REMOVED the cancelAllDebugSessionCalls() call that used to be
        // here - see fix_cancel_only_on_real_teardown.py.
        //
        // It was described as the cheap half of teardown. It is not:
        // debug_proxy_cancel aborts whatever call is in flight, and for
        // a healthy loop that is the continue it is waiting on. The
        // abort surfaces as a failed command and the loop exits.
        //
        // On device it killed sixteen working sessions at once, at a
        // moment when every one of them was servicing breakpoints
        // normally. This transition fires for a swipe up, Control
        // Centre, or a notification pull - the app need not even leave
        // the foreground - so JIT was being destroyed for every content
        // process on any momentary interruption.
        //
        // Teardown now happens only in sceneDidEnterBackground, where
        // the app is genuinely going away. The XPC hang this was meant
        // to avoid is handled by deferring new attaches instead, which
        // touches no existing session.
        
        // Setting the lock flag here is safe — it's just a boolean.
        // Actually *presenting* a real view controller this early is
        // NOT safe: this moment is an unstable UIKit transition, and
        // presentations attempted here can fail in inconsistent ways
        // depending on exact timing — sometimes silently with no
        // protection shown at all, sometimes leaving UIKit's own state
        // corrupted in ways that show up as the app becoming
        // unresponsive. Confirmed by testing, not just theory. The
        // coordinator's own lockIfNeeded() now handles showing a safe,
        // non-interactive curtain instead of presenting anything here.
        browserViewController.privateBrowsingLockCoordinator.lockIfNeeded()
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        (window?.rootViewController as? BrowserViewController)?
            .sessionManager.setApplicationForeground(true)
        
        // The tunnel dies during suspension and every debug loop with
        // it, but an attach is otherwise only triggered by a process
        // STARTING - so a process that survives runs interpreted
        // forever. This is the first point the device is reachable
        // again. See
        // fix_reattach_orphaned_sessions_on_foreground.py.
        // CHANGED - delayed rather than immediate. See
        // fix_defer_reattach_past_transition.py.
        //
        // This runs inside the foreground lifecycle cascade, during
        // which iOS messages every extension SYNCHRONOUSLY. vAttach
        // stops its target for ~1013ms, and a stopped extension cannot
        // reply - so an attach started here blocks the main thread and
        // the watchdog kills the app. Seen exactly that way: re-attach
        // at 03:38:21.465, attach at .554, hang watchdog at 03:38:23.
        //
        // Two seconds puts the attaches past the cascade. A process
        // that has run interpreted since the last suspension can wait
        // two more seconds for JIT.
        let reattachApplication = UIApplication.shared
        var reattachTask = UIBackgroundTaskIdentifier.invalid
        reattachTask = reattachApplication.beginBackgroundTask(withName: "JITReattachDelay") {
            if reattachTask != .invalid {
                reattachApplication.endBackgroundTask(reattachTask)
                reattachTask = .invalid
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Restored alongside the re-attach, not before it: the
            // sessions it creates are what make trapping safe again.
            // See fix_stop_trapping_on_background.py.
            JITEnabler.setDebuggerListening(true)
            
            JITController.shared.reattachOrphanedProcesses()
            
            if reattachTask != .invalid {
                reattachApplication.endBackgroundTask(reattachTask)
                reattachTask = .invalid
            }
        }
    }
    
    /// Holds the app awake briefly while attaches finish.
    ///
    /// Polled rather than signalled: completion happens on another queue
    /// inside an FFI call, with nothing to hook. 200ms for at most 8
    /// seconds - enough for an attach that is nearly done, and short
    /// enough to leave the rest of the background budget for flushing
    /// tabs.
    ///
    /// See fix_hold_background_for_inflight_attach.py.
    private func waitForInFlightAttachesBeforeSuspending() {
        guard JITController.attachesInFlight > 0 else {
            return
        }
        
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "JITAttachDrain") {
            if task != .invalid {
                application.endBackgroundTask(task)
                task = .invalid
            }
        }
        
        let started = CFAbsoluteTimeGetCurrent()
        logger(String(format: "attachDrain: holding for %d attach(es) still in flight", JITController.attachesInFlight))
        
        func poll() {
            let remaining = JITController.attachesInFlight
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            
            if remaining == 0 || elapsed > 8.0 {
                logger(String(format: "attachDrain: %@ after %.1fs, %d still in flight", remaining == 0 ? "drained" : "GAVE UP", elapsed, remaining))
                if task != .invalid {
                    application.endBackgroundTask(task)
                    task = .invalid
                }
                return
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                poll()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            poll()
        }
    }
    
    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        browserViewController.sessionManager.setApplicationForeground(false)
        browserViewController.privateBrowsingLockCoordinator.lockIfNeeded()
        
        // Release any content process the debugger is holding stopped,
        // before iOS suspends us and the tunnel dies. A Helper left
        // stopped cannot answer the synchronous XPC iOS sends every
        // extension on the next foreground, and the watchdog kills the
        // app for it - 0x8BADF00D, confirmed across three hang reports.
        // See fix_detach_debug_sessions_on_background.py.
        //
        // Only sets flags, so it needs no background-task budget of its
        // own; the debug loops do the actual detaching on their own
        // threads.
        // Tabs are slept FIRST - see fix_sleep_tabs_before_detach.py.
        //
        // Closing a Gecko session waits for its content process to
        // acknowledge, and once the detach flags are set the debug loops
        // stop servicing traps. A process that hits brk #0xf00d during
        // teardown then stays stopped, and closing its session waits for
        // a reply that never comes - nine seconds of blocked main thread
        // in the capture that found this, with nine tabs to close.
        //
        // Doing this before the flags are set means the loops are still
        // live and answer promptly. It also leaves less to detach, since
        // a process whose session has closed is on its way out anyway.
        sleepBackgroundedTabsWithTimeBudget(for: browserViewController)
        
        // Before the detach, so no process can trap during the
        // teardown. See fix_stop_trapping_on_background.py.
        //
        // Clearing this reactively - when a command or detach fails -
        // happens once the transport is already dead, by which time a
        // process may be stopped at a brk with nothing able to continue
        // it. That process then cannot answer the synchronous XPC iOS
        // sends on the next transition, and the watchdog takes the app.
        //
        // The cost is that background JavaScript runs interpreted, which
        // is the same trade already made for the registration-failure
        // fallback and matters little in an app whose tabs are asleep.
        JITEnabler.setDebuggerListening(false)
        
        JITEnabler.requestDetachForAllDebugSessions()
        
        // An attach in flight has left its target STOPPED, and it stays
        // that way until the debug loop starts and sends continue. If
        // iOS suspends us first, that process is stranded - measured at
        // 260 seconds in one capture, ending in a watchdog kill because
        // a stopped extension cannot answer the synchronous XPC iOS
        // sends on the next transition.
        //
        // An attach normally takes about a second, so asking for a
        // little more time is usually enough for it to finish and the
        // target to resume. See
        // fix_hold_background_for_inflight_attach.py.
        waitForInFlightAttachesBeforeSuspending()
        
        // CHANGED - cancellation is delayed rather than immediate. See
        // fix_delay_cancel_after_detach.py.
        //
        // These two used to be adjacent, and the log showed cancellation
        // firing 286 MICROSECONDS after the detach request, followed
        // immediately by twelve "Detach failed" lines and a watchdog
        // kill two seconds later. No loop can notice a flag in that
        // time, so cancellation always won and every detach went out
        // over a connection whose reader had just been aborted.
        //
        // Delaying it inverts that: loops between iterations see the
        // flag, send D, exit and unregister themselves, and only those
        // genuinely stuck inside a blocking read are still registered
        // when cancellation runs - which is the case cancellation
        // exists for.
        //
        // Wrapped in a background task so iOS grants the runtime rather
        // than suspending mid-wait, the same way
        // sleepBackgroundedTabsWithTimeBudget does.
        let application = UIApplication.shared
        var cancelTaskIdentifier = UIBackgroundTaskIdentifier.invalid
        cancelTaskIdentifier = application.beginBackgroundTask(withName: "JITDetachDrain") {
            if cancelTaskIdentifier != .invalid {
                application.endBackgroundTask(cancelTaskIdentifier)
                cancelTaskIdentifier = .invalid
            }
        }
        
        // One second: continue iterations were taking 30-60ms in the
        // captures, so this is ample for a loop between iterations and
        // still well inside the background window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Gated OFF by default - see fix_no_cancel_experiment.py.
            //
            // Cancelling desyncs the connection permanently rather than
            // briefly disturbing it: a retry 50ms later succeeded once
            // in ten. The detach that follows then fails, leaving the
            // process attached with a dead debugger connection - which
            // is the state that hangs the app on the next transition.
            //
            // Loops still parked here have RUNNING targets, and a
            // running extension can answer XPC. Leaving them alone may
            // simply be better.
            if Prefs.ExperimentalSettings.cancelsDebugSessionsOnBackground {
                JITEnabler.cancelAllDebugSessionCalls()
            }
            
            if cancelTaskIdentifier != .invalid {
                application.endBackgroundTask(cancelTaskIdentifier)
                cancelTaskIdentifier = .invalid
            }
        }
        
        flushNavigationHistoryInBackground()
    }
    
    /// sceneDidEnterBackground only gets a few seconds of guaranteed
    /// runtime before iOS can suspend the app outright — closing and
    /// recreating a Gecko session per tab is real, cumulative work that
    /// could plausibly outrun that default window with many tabs open,
    /// especially under the same memory pressure this feature exists to
    /// relieve. Wrapping it in an explicit background task tells iOS to
    /// grant more time (up to its own ~30s budget) rather than assuming
    /// the default window is enough — same reasoning, same pattern, as
    /// flushNavigationHistoryInBackground() just below. This work has to
    /// stay synchronous on the main thread (GeckoSession isn't safe to
    /// touch from a background queue), so unlike that method, there's no
    /// dispatch to a background queue here — just the wider time budget.
    private func sleepBackgroundedTabsWithTimeBudget(for browserViewController: BrowserViewController) {
        let application = UIApplication.shared
        var taskIdentifier = UIBackgroundTaskIdentifier.invalid
        taskIdentifier = application.beginBackgroundTask(withName: "TabSleep") {
            if taskIdentifier != .invalid {
                application.endBackgroundTask(taskIdentifier)
                taskIdentifier = .invalid
            }
        }
        
        browserViewController.tabManager.sleepBackgroundedTabs()
        
        if taskIdentifier != .invalid {
            application.endBackgroundTask(taskIdentifier)
            taskIdentifier = .invalid
        }
    }

    private func flushNavigationHistoryInBackground() {
        let application = UIApplication.shared
        var taskIdentifier = UIBackgroundTaskIdentifier.invalid
        taskIdentifier = application.beginBackgroundTask(withName: "NavigationHistory") {
            if taskIdentifier != .invalid {
                application.endBackgroundTask(taskIdentifier)
                taskIdentifier = .invalid
            }
        }
        DispatchQueue.global(qos: .utility).async {
            NavigationHistoryStore.shared.flushPendingWrites()
            DispatchQueue.main.async {
                if taskIdentifier != .invalid {
                    application.endBackgroundTask(taskIdentifier)
                    taskIdentifier = .invalid
                }
            }
        }
    }
    
    private func handleIncomingURLContexts(_ urlContexts: Set<UIOpenURLContext>) {
        guard let incomingURL = urlContexts.first?.url else {
            return
        }
        handleIncomingURL(incomingURL)
    }
    
    private func handleIncomingURL(_ incomingURL: URL) {
        guard let browserViewController = window?.rootViewController as? BrowserViewController,
              let resolvedURL = resolvedBrowserURL(from: incomingURL) else {
            return
        }
        
        DispatchQueue.main.async {
            browserViewController.loadViewIfNeeded()
            browserViewController.sidebarCoordinator.loadContentIfNeeded()
            browserViewController.sidebarCoordinator.openExternalURL(resolvedURL)
        }
    }
    
    private func resolvedBrowserURL(from incomingURL: URL) -> URL? {
        guard let scheme = incomingURL.scheme?.lowercased() else {
            return nil
        }
        
        if scheme == "http" || scheme == "https" {
            return incomingURL
        }
        
        guard scheme == "reynard",
              let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let encodedURL = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        
        return URL(string: encodedURL)
    }
}
