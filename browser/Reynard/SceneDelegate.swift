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
        browserViewController.startScreenOrientationHandling()
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
        
        // ADDED - see fix_background_audio_skips_jit_teardown.py.
        // The other half of the pair. Nothing was torn down at the
        // last background, so there is nothing to restore: no census,
        // no setDebuggerListening(true) on a flag that was never
        // cleared, and no reattachOrphanedProcesses over sessions that
        // never went orphaned.
        //
        // setApplicationForeground(true) above still runs - it drives
        // the commit latch and session activation, which have nothing
        // to do with the debugger.
        //
        // sceneDidBecomeActive is deliberately NOT touched. Its
        // applicationDidBecomeActive drains attaches for children that
        // spawned while we were inactive, and those still need
        // attaching whether or not anything was torn down. Skipping it
        // would leave every new tab without JIT.
        //
        // The loop state is dumped on the way out so the next capture
        // says outright whether the sessions actually survived. If it
        // ever reads "0 session(s) registered" here, the app WAS
        // suspended despite the keep-alive, the skip above was wrong,
        // and this branch has to fall through to the normal restore.
        //
        // CHANGED - the preference -> isActive. See
        // fix_background_skip_predicates.py.
        //
        // applyPreference() is now called at launch (AppDelegate), so
        // isActive can mean what it says. Before that it could not:
        // applyPreference had exactly one caller, the Experimental toggle
        // handler, isRunning starts false and only start() sets it - so
        // on EVERY relaunch with the preference already on, this branch
        // fired for a process whose silent-audio engine had never been
        // started. iOS suspends such an app normally.
        //
        // This is the durable half. The restore skipped here is the only
        // caller of reattachOrphanedProcesses; sceneDidBecomeActive's
        // applicationDidBecomeActive drains DEFERRED pids only, and has
        // nothing to say about children that were already attached and
        // lost their session to the suspension. Those children had no
        // session and no route to one for the rest of the launch.
        //
        // isActive rather than the preference also makes this agree with
        // shouldPreserveJITAcrossBackground below, which has always
        // tested isActive. Three sites, one question, one answer.
        if BackgroundAudioKeepAlive.shared.isActive {
            JITEnabler.dumpDebugLoopState(labelled: "loopState at foreground (restore skipped)")
            logger("foregroundRestore: SKIPPED - background audio keep-alive is on, nothing was torn down")
            return
        }
        
        // Logged rather than passed over silently: the user believes
        // the feature is on, and this is the one line that says the
        // engine is not actually up. It is not a reason to skip - an app
        // with a dead engine IS suspended, so the restore below is what
        // it needs.
        if Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled {
            logger("foregroundRestore: keep-alive is ON but its engine is NOT RUNNING - restoring normally")
        }
        
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
    /// ADDED - see fix_media_keeps_its_trapping.py.
    ///
    /// The single question the whole JIT half of the background teardown
    /// turns on: is a content process going to keep running, and running
    /// JavaScript, after we go into the background?
    ///
    /// Three separate decisions used to test this independently -
    /// setDebuggerListening(false), requestDetachForAllDebugSessions()
    /// and the cancel/tunnelClose - and the first of them did not test it
    /// at all. Routed through here so they cannot disagree.
    ///
    /// They MUST agree. Trapping enabled while the loops are gone is the
    /// SIGBUS combination: the child executes brk #0xf00d with no
    /// debugger to service it, or - worse, because it is silent -
    /// PrepareExecutableRegionForWriting bails, CommitPages ignores the
    /// bail and returns true, and the JIT writes into a chunk TXM never
    /// backed. That fault surfaces as an instruction abort on first
    /// entry, which no signal handler can recover.
    private func shouldPreserveJITAcrossBackground(
        for browserViewController: BrowserViewController
    ) -> Bool {
        // CHANGED - see fix_keepalive_holds_the_jit_teardown.py.
        //
        // The keep-alive holds the app awake indefinitely, so its tab
        // keeps executing JavaScript and keeps needing new JIT regions -
        // the same requirement PiP has, for longer. Before this, turning
        // the toggle on kept the app running and let its JIT be torn down
        // anyway, which is the worst of both: battery spent running
        // interpreted.
        //
        // isActive, not the preference. The preference can be true while
        // the engine is dead (a call, Siri, a media services reset), and
        // holding the tunnel open for an app that then gets suspended
        // loses the tunnel for the rest of the launch.
        //
        // hasSystemMediaSession is deliberately NOT widened to include
        // this. It is also read by isMediaPriority, which tab eviction
        // uses; keeping tabs resident on a preference rather than on
        // actual playback is a different change with a different risk.
        //
        // CHANGED - see fix_background_skip_predicates.py.
        //
        // hasSystemMediaSession -> hasPlayingSystemMediaSession. The two
        // differ in exactly one arm: a lock-screen card that exists for
        // merely PAUSED media.
        //
        // SystemMediaSession.applicationDidEnterBackground runs 1.5s
        // before this teardown - sceneDidEnterBackground calls it inline
        // and defers the teardown - and for paused media it keeps the
        // card while deactivating the audio session UNCONDITIONALLY:
        //
        //   mediaSession: backgrounded with only paused media -
        //                 audio session released, card kept
        //
        // so hasNowPlayingSession stayed true for an app holding no
        // assertion whatsoever. Every step below was then skipped -
        // listening left on, no detach, no cancel, no tunnel close - and
        // iOS suspended the app anyway. Measured: all three skip lines,
        // then the transport dying 93 seconds later regardless.
        //
        // The comment further down that justifies skipping the tunnel
        // close - "an app holding a background audio assertion is not
        // suspended" - was simply false in that case. Requiring actual
        // playback makes it true again, because PLAYING is precisely the
        // condition under which this app keeps the audio session active:
        // both places that release it test the same `anyPlaying`, and
        // hasPlayingSession IS that expression.
        return browserViewController.sessionManager.hasPlayingSystemMediaSession
            || BackgroundAudioKeepAlive.shared.isActive
    }

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
        
        // ADDED - see fix_background_audio_skips_jit_teardown.py.
        //
        // Background audio on means the app is meant to keep running,
        // which means its tabs keep executing JavaScript, which means
        // they keep needing JIT. So take none of the teardown: the
        // listening flag stays set, the sessions stay attached, the
        // loops stay parked, and the tunnel stays open.
        //
        // An early return rather than wrapping the rest of the method:
        // with the toggle OFF this branch is false and every line below
        // runs byte-identical to before, which is the requirement. The
        // existing shouldPreserveJITAcrossBackground gates below are
        // left in place for exactly that reason - they are what still
        // protects PiP and system media when the toggle is off.
        //
        // sleepBackgroundedTabsWithTimeBudget above is deliberately NOT
        // skipped - it is a memory measure with its own media-priority
        // exclusion, not part of the JIT teardown.
        //
        // flushNavigationHistoryInBackground is the last statement on
        // the normal path and is unrelated to JIT, so it is called here
        // rather than dropped.
        //
        // Risk, once: the pairing socket stays open across the
        // background. Safe while the app is genuinely not suspended,
        // which is what the keep-alive is for.
        //
        // CHANGED - the preference -> isActive, which is what the note
        // that used to sit here said to do if the parent turned out to
        // be suspended anyway. It does not need a capture to settle it:
        // nothing called applyPreference() at launch, so on every
        // relaunch with the preference already on this branch skipped the
        // whole teardown for a process whose engine had never started.
        // See fix_background_skip_predicates.py.
        //
        // The teardown skipped here includes
        // waitForInFlightAttachesBeforeSuspending(), whose entire purpose
        // is that an attach in flight has left its target STOPPED -
        // measured at 260 seconds and a watchdog kill.
        //
        // shouldPreserveJITAcrossBackground below has always tested
        // isActive; now all three sites do, and the launch call in
        // AppDelegate is what makes that answer honest.
        if BackgroundAudioKeepAlive.shared.isActive {
            logger("backgroundTeardown: SKIPPED - background audio keep-alive is on, leaving JIT fully up")
            flushNavigationHistoryInBackground()
            return
        }
        
        // Named rather than silent, for the same reason as the
        // foreground half: an engine that is not running is the one
        // thing that makes this feature do nothing, and it is otherwise
        // invisible. Falling through is correct - iOS is about to
        // suspend an app with no assertion, so it needs the teardown.
        if Prefs.ExperimentalSettings.isBackgroundAudioKeepAliveEnabled {
            logger("backgroundTeardown: keep-alive is ON but its engine is NOT RUNNING - tearing down normally")
        }
        
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
        // CHANGED - see fix_media_keeps_its_trapping.py.
        //
        // This used to run unconditionally, above and outside the media
        // guard. Measured on device, 6 for 6 across three captures:
        //
        //   00:58:23.430765  jitListening: debugger is GONE
        //   00:58:23.431475  backgroundTeardown: skipping the
        //                    debug-session detach - PiP or system media
        //                    is live ...
        //   00:58:23.662815  backgroundTeardown: skipping the cancel and
        //                    the tunnel close ...
        //
        // The sessions survived, the tunnel survived, and the one tab
        // still executing JavaScript was told it could not trap - 0.7ms
        // before the guard that exists to keep it working.
        //
        // The old comment justified that as "a region needed during
        // playback is simply prepared interpreted". It is not:
        // PrepareExecutableRegionForWriting returns void, CommitPages
        // ignores it, SetAliasProtection has already marked the alias
        // executable, so the allocation succeeds into a chunk TXM never
        // backed and the failure lands on the first instruction fetch.
        //
        // Safe to leave listening on here for one reason only: on this
        // branch nothing is torn down. No detach, no cancel, no tunnel
        // close, every loop still parked in its continue. A child that
        // traps has a live loop to service it.
        if shouldPreserveJITAcrossBackground(for: browserViewController) {
            logger("backgroundTeardown: keeping the debugger listening - PiP or system media is live and its content process still needs to compile")
        } else {
            JITEnabler.setDebuggerListening(false)
        }
        
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
        // CHANGED - fix_media_keeps_its_trapping.py routes this through
        // the shared predicate. Same value as before; the point is that
        // this and the listening flag above can no longer diverge.
        if shouldPreserveJITAcrossBackground(for: browserViewController) {
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
        
        // CHANGED from 1.0s - see fix_close_before_suspension.py.
        // closeBeforeSuspension.
        //
        // The second was there to let a loop between iterations see the
        // detach flag and exit cleanly on its own. Measurement says no
        // such loop exists: every session has printed WAITING - parked
        // in a blocking read - at background in every capture, and
        // "Detach response" has never once appeared at background.
        //
        // What the second actually bought was a teardown that finished
        // at +3.70s when iOS suspended the coalition at +3.59s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // ADDED - see fix_media_keeps_its_tunnel.py.
            //
            // The media guard further up wraps ONLY
            // requestDetachForAllDebugSessions, so without this the
            // cancel below and the tunnel close after it run while PiP
            // or CarPlay audio is live - killing the debug loop that
            // services the content process drawing the PiP window, and
            // then freeing the adapter underneath it. That is the exact
            // opposite of what that guard exists for, and its own
            // comment says so: "the loops stay alive, parked in their
            // continue".
            //
            // Re-read here rather than beside the other test because
            // this fires 0.15s later: if media stopped in between the
            // teardown should proceed, and if it started it should be
            // skipped. Both are the right answer, and only a fresh read
            // gives them.
            //
            // Nothing is lost by skipping. The close exists because a
            // suspension kills every socket; an app holding a background
            // audio assertion is not suspended, which is why its tunnel
            // survives in the first place. The next background after
            // media stops tears down normally.
            // CHANGED - fix_media_keeps_its_trapping.py. Same value,
            // still re-read at this moment rather than sampled earlier,
            // now through the shared predicate.
            guard !self.shouldPreserveJITAcrossBackground(for: browserViewController) else {
                logger("backgroundTeardown: skipping the cancel and the tunnel close - PiP or system media is still live")
                if cancelTaskIdentifier != .invalid {
                    application.endBackgroundTask(cancelTaskIdentifier)
                    cancelTaskIdentifier = .invalid
                }
                return
            }

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
            // CHANGED from 1.0s - see fix_close_before_suspension.py.
            //
            // A second to let the loops notice the cancel and exit. They
            // exit in ONE millisecond: cancelled at 19:23:14.098584, all
            // three "Debug loop ended" by 19:23:14.099063. The other 999
            // were spent arriving 0.11s after the suspension that this
            // close exists to beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
