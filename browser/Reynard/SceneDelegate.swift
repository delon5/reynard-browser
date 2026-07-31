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
        
        // Release any thread parked in a debug proxy read before
        // ExtensionFoundation starts synchronously messaging extensions
        // - a debugger-stopped extension cannot answer that, and the
        // app is killed with 0x8BADF00D waiting for a reply. This fires
        // before that cascade begins.
        //
        // Cancellation only, not the full teardown: this also fires for
        // Control Centre and notification pulls, where tearing sessions
        // down would cost a re-attach per process for a moment's
        // interruption. The deliberate teardown stays in
        // sceneDidEnterBackground. See fix_split_cancel_from_detach.py.
        //
        // Safe to do here - unlike presenting a view controller, which
        // the comment below rightly warns against, this touches no
        // UIKit state at all.
        JITEnabler.cancelAllDebugSessionCalls()
        
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
