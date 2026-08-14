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
        guard let browserViewController = window?.rootViewController as? BrowserViewController else {
            return
        }
        
        browserViewController.startScreenOrientationHandling()
        browserViewController.sessionManager.applicationDidBecomeActive()
        browserViewController.tabManager.applicationDidBecomeActive()
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
        
        browserViewController.stopScreenOrientationHandling()
        browserViewController.tabManager.applicationWillResignActive()
        browserViewController.sessionManager.applicationWillResignActive()
    }
    
    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        (window?.rootViewController as? BrowserViewController)?
            .screenOrientationChanged(to: windowScene.interfaceOrientation)
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
            // ADDED - see
            // fix_reattach_timer_rechecks_foreground.py's docstring.
            //
            // Two seconds is enough time for the scene to background
            // again, and this block had no way to notice. On 2026-08-12
            // the app became active at 19:12:33.085 and backgrounded at
            // 19:12:34.124 - 278ms before this fired. It ran anyway,
            // logged "childCensus at foreground" for an app that was
            // not in the foreground, and started five vAttaches. Three
            // of those targets were still stopped 165 seconds later
            // when FrontBoard killed the app for the unanswered XPC.
            //
            // applicationState rather than our own flag, for the reason
            // in fix_check_real_app_state_before_attach.py: iOS wakes a
            // backgrounded app periodically and the flag goes
            // stale-true across those wakes. This block is already on
            // the main queue, where reading it is legal.
            //
            // The background task is ended on the way out - held across
            // these two seconds, it was asking iOS for runtime in order
            // to do the thing that kills the app.
            guard UIApplication.shared.applicationState == .active else {
                logger("reattachSkip: the +2s timer fired but the app is no longer active - not re-attaching")
                if reattachTask != .invalid {
                    reattachApplication.endBackgroundTask(reattachTask)
                    reattachTask = .invalid
                }
                return
            }

            // Restored alongside the re-attach, not before it: the
            // sessions it creates are what make trapping safe again.
            // See fix_stop_trapping_on_background.py.
            // Before trapping is restored, so the census describes the
            // state the foreground handshake actually saw - an order
            // only the attach queue can hold, since two of the three
            // steps hop to it on their own, and a placement that keeps
            // the attaches off the thread the watchdog is timing.
            // See fix_reattach_off_main_queue.py.
            JITController.shared.performForegroundReattach {
                if reattachTask != .invalid {
                    reattachApplication.endBackgroundTask(reattachTask)
                    reattachTask = .invalid
                }
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

        // If nothing is playing or paused there is nothing the
        // lock screen could control - drop the now playing entry
        // and release the audio session, or iOS keeps offering
        // transport controls for an app with nothing to control.
        SystemMediaSession.shared.applicationDidEnterBackground()

        // Everything below runs AFTER this notification returns, not
        // inside it. See fix_defer_background_teardown.py.
        //
        // ExtensionFoundation observes didEnterBackground too, and its
        // handler synchronously XPCs every extension it hosts
        // (-[EXConcreteExtension _hostDidEnterBackgroundNote:] ->
        // dispatch_sync -> NSXPCConnection sendSelector). Our content
        // processes ARE those extensions. Closing their sessions from
        // inside the same notification leaves that handler messaging
        // processes that are already exiting, and it blocks the main
        // thread until the 10s scene-update budget runs out.
        //
        // Two device captures, identical stack, one with PiP active and
        // one without - so it is the teardown, not PiP:
        //
        //   [TabMemory] Sleeping backgrounded tab sessions
        //   Exiting due to channel error.   x11 and x12
        //   0x8BADF00D  ... _hostDidEnterBackgroundNote: ... mach_msg
        //
        // b7d7ba3's processExitTrace confirms the ordering: every
        // deliberate close logs a BrowserParent/ContentParent pair, and
        // those eleven exits logged NOTHING - the parent never reached
        // them, because it was already blocked.
        //
        // The assertion is taken NOW, synchronously, so iOS grants the
        // runtime for work that no longer happens before this method
        // returns. The block's internal order is untouched: tabs are
        // still slept before the detach flags are set
        // (fix_sleep_tabs_before_detach.py), which is a separate
        // constraint from this one.
        let teardownApplication = UIApplication.shared
        var teardownTask = UIBackgroundTaskIdentifier.invalid
        teardownTask = teardownApplication.beginBackgroundTask(withName: "BackgroundTeardown") {
            if teardownTask != .invalid {
                teardownApplication.endBackgroundTask(teardownTask)
                teardownTask = .invalid
            }
        }

        // CHANGED - delayed and re-checked rather than next-turn. See
        // fix_debounce_background_teardown.py's docstring.
        //
        // async alone only moves this to the next main-queue turn, a few
        // milliseconds, so it cannot notice the app coming straight back.
        // On 2026-08-12 the app backgrounded at 22:30:42.271 and
        // foregrounded at 22:30:42.491 - an app-switcher glance - and the
        // teardown was still interrupting and detaching six sessions at
        // :508, inside the foreground cascade. The synchronous
        // per-extension XPC landed on processes that were mid-teardown
        // and the watchdog took the app.
        //
        // Same reasoning as fix_cancel_only_on_real_teardown.py further
        // up this file: this transition fires for a swipe up, Control
        // Centre or a notification pull, and destroying every content
        // process's session for a momentary interruption is not worth it.
        //
        // 1.5s sits past a returned-from glance and well inside the
        // background grace period, matching the 1s this file already
        // waits before cancelAllDebugSessionCalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            defer {
                if teardownTask != .invalid {
                    teardownApplication.endBackgroundTask(teardownTask)
                    teardownTask = .invalid
                }
            }
            guard let self else {
                return
            }
            // applicationState rather than a cached flag - iOS wakes a
            // backgrounded app periodically and the flag goes stale-true
            // across those wakes. Legal here: this is the main queue.
            guard UIApplication.shared.applicationState != .active else {
                logger("backgroundTeardown: skipped - the app came back before the teardown ran")
                return
            }
            self.performBackgroundTeardown(for: browserViewController)
        }
    }

    /// The backgrounding teardown, deferred off the didEnterBackground
    /// notification - see sceneDidEnterBackground for why. The order
    /// within this method is load-bearing and unchanged.
    private func performBackgroundTeardown(for browserViewController: BrowserViewController) {

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
        
        // Before the detach, while every loop is still running normally -
        // a stopped one stands out against ticks of 30-60ms, where at
        // hang time they are all equally stale after a suspension. See
        // fix_dump_loops_at_background.py.
        JITEnabler.dumpDebugLoopState(labelled: "loopState at background")
        
        // ADDED - see fix_no_teardown_while_system_media_active.py's
        // docstring.
        //
        // requestDetachForAllDebugSessions is not a passive flag-setter -
        // it calls interruptLiveDebugSessions, which sends the GDB
        // interrupt byte to every target and STOPS it. Doing that to the
        // process rendering Picture in Picture contradicts what the
        // coordinator logs one line earlier:
        //
        //   22:42:01.439  pipLife: didStart - PiP is now active, its
        //                 content process must stay alive in the background
        //   22:42:01.906  requestDetachForAllDebugSessions: for 8 session(s)
        //   22:42:01.906  interruptLiveDebugSessions: 8 live, interrupted 8
        //
        // The audio stuttered for the 18 seconds PiP was up, and the
        // census on the way back showed all ten children at session=NO.
        //
        // hasSystemMediaSession rather than hasPictureInPictureSession,
        // deliberately: its own doc comment covers PiP AND the
        // now-playing entry that CarPlay and the lock screen drive their
        // transport controls from, and notes that under CarPlay losing
        // the content process is worse than a paused video - the head
        // unit keeps showing controls for a page that no longer exists.
        // Backgrounded audio has the same requirement as PiP.
        //
        // setDebuggerListening(false) above still runs, so children stop
        // trapping either way and a region needed during playback is
        // simply prepared interpreted - the same trade that fix already
        // makes at every background. Only the interrupt and the detach
        // are skipped. The loops stay alive, parked in their continue,
        // and the next background after media stops tears down normally.
        if browserViewController.sessionManager.hasSystemMediaSession {
            logger("backgroundTeardown: skipping the debug-session detach - PiP or system media is live and its content process must keep running")
        } else {
            JITEnabler.requestDetachForAllDebugSessions()
        }
        
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
            // UNGATED - see fix_foreground_scoped_jit_transport.py.
            //
            // The three reasons this was turned off, and where each
            // stands now:
            //
            //   "cancelling desyncs the connection permanently"
            //       still true, now irrelevant - the adapter is closed
            //       two steps below, so there is nothing left to desync.
            //
            //   "the detach that follows then fails, leaving the process
            //    attached with a dead debugger connection"
            //       that cost is already paid on EVERY background: 52
            //       Detach failed and zero Detach response in the
            //       2026-08-14 capture. Cancelling does not create the
            //       state, it only decides when we enter it.
            //
            //   "loops still parked here have RUNNING targets ... leaving
            //    them alone may simply be better"
            //       that was the hypothesis, and it has been the shipped
            //       behaviour for four builds. It produced the 07:02 and
            //       11:53 watchdog kills. It does not hold.
            //
            // The structural reason to prefer this over the 0x03
            // interrupt we spent four builds compensating for:
            // debug_proxy_cancel aborts OUR OWN in-flight read,
            // client-side. Nothing goes over the wire, so unlike the
            // interrupt it cannot stop the target. It is the only way to
            // get a loop out of a blocking continue without touching the
            // process.
            //
            // dumpDebugLoopState above has just printed WAITING for every
            // session, and WAITING means the target is running. So this
            // runs at a moment we have verified is safe, rather than
            // letting the connection die at an arbitrary point inside a
            // three-minute suspension - possibly while a child is stopped
            // at a fault with nobody left to service it.
            JITEnabler.cancelAllDebugSessionCalls()

            // Then the transport itself, once the loops it was feeding
            // have had a second to notice and exit.
            //
            // This is the half that makes JIT recoverable without a force
            // quit. freeDeviceProvider is the only thing in the app that
            // calls adapter_free, and until now it ran only from dealloc
            // - so a retired tunnel kept its socket to 10.7.0.1:49152
            // open for the life of the process, and every rebuild was
            // refused. Measured: 6 successful tunnel creates against 102
            // failures, and all 6 were the first call of a fresh process.
            //
            // Closing here also sends the FIN before iOS can suspend us,
            // so the peer does not keep a half-open connection that
            // refuses the NEXT launch too - the 96-minute dead window on
            // 2026-08-14 that only airplane mode cleared.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                JITController.shared.closeTunnelForSuspension()

                if cancelTaskIdentifier != .invalid {
                    application.endBackgroundTask(cancelTaskIdentifier)
                    cancelTaskIdentifier = .invalid
                }
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
