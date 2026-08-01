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
        JITController.shared.reattachOrphanedProcesses()
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
        JITEnabler.requestDetachForAllDebugSessions()
        
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
        
        sleepBackgroundedTabsWithTimeBudget(for: browserViewController)
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
