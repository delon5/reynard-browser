//
//  TabManagerImpl.swift
//  Reynard
//
//  Created by Minh Ton on 5/3/26.
//

import Foundation
import GeckoView
import UIKit

final class TabManagerImplementation: NSObject, TabManager {
    /// How many content processes may stay alive behind the selected tab.
    private static let liveSessionCap = 5

    private(set) var regularTabs: [Tab] = []
    private(set) var privateTabs: [Tab] = []
    private(set) var selectedTabMode: TabMode = .regular
    private var selectedRegularTabIndex = -1
    private var selectedPrivateTabIndex = -1
    
    var selectedTabIndex: Int {
        return selectedIndex(for: selectedTabMode)
    }
    
    var selectedTab: Tab? {
        return tabs(for: selectedTabMode)[safe: selectedTabIndex]
    }
    
    private lazy var requestContentKeyboardFocus: (GeckoSession) -> Void = { [weak self] session in
        guard let self else { return }
        self.delegate?.tabManager(self, didRequestContentKeyboardFocusFor: session)
    }
    private lazy var promptCoordinator = PromptCoordinator(
        presenter: PromptPresenter(),
        onPromptFinished: requestContentKeyboardFocus
    )
    // The merged presenter has no no-arg init any more; keep it stored
    // (init wires onFindSelection through it) but make it lazy so it can
    // hand over the keyboard-focus callback.
    private lazy var selectionActionPresenter = SelectionActionPresenter(
        onMenuDismissed: requestContentKeyboardFocus
    )
    private lazy var selectionActionCoordinator = SelectionActionCoordinator(
        presenter: selectionActionPresenter
    )
    private let permissionCoordinator = PermissionCoordinator(
        promptPresenter: PermissionPromptPresenter()
    )
    private lazy var externalAppLinkRouter = ExternalAppLinkRouter(
        isAutomaticRoutingEnabled: { Prefs.BrowsingSettings.openLinksInApps },
        open: Self.openExternalApplication
    )
    // The shared instance rather than a private one, so the CarPlay
    // session can register with the same media session. Same object,
    // same behaviour here. See fix_carplay_media_session.py.
    private let systemMediaSession = SystemMediaSession.shared
    private lazy var pictureInPictureCoordinator: PictureInPictureCoordinating? = {
        guard Prefs.ExperimentalSettings.isVideoPictureInPictureEnabled,
              #available(iOS 15.0, *) else {
            return nil
        }
        return PictureInPictureCoordinator(
            delegate: self,
            mediaSession: systemMediaSession,
            sessionManager: sessionManager
        )
    }()
    
    private weak var delegate: TabManagerDelegate?
    private let store: TabManagementStore
    private let faviconStore: FaviconStore
    private let historyStore: HistoryStore
    let sessionManager: SessionManager
    private var faviconTasks: [UUID: Task<Void, Never>] = [:]
    // Main-thread confined, like the tab arrays: armed from browse and
    // cleared from the engine delegate callbacks, all of which arrive
    // on the main thread.
    private struct LoadWatchdog {
        let workItem: DispatchWorkItem
        /// 0 = armed by browse(); 1 = armed by the first retry. The
        /// second rung rebuilds the session instead of re-dispatching.
        let attempt: Int
        let pendingInput: String
        let retryURL: String
        let armedAt: CFAbsoluteTime
    }
    private var loadWatchdogs: [UUID: LoadWatchdog] = [:]
    /// Tabs that have begun a load and not yet composited a frame, with
    /// when and for what. The LoadWatchdog only proves the ENGINE
    /// answered - a tab can report pageStart within 70ms and then never
    /// paint, which is indistinguishable in the logs from a load that
    /// failed outright. Device capture 2026-08-10 19:13:32: twitch.tv
    /// committed on a fresh tab, produced pageStart, and its content
    /// process then emitted nothing at all for the 22 seconds until the
    /// tab was abandoned - two log lines for the tab's entire life.
    private var paintWaits: [UUID: (startedAt: CFAbsoluteTime, url: String, retryURL: String, workItem: DispatchWorkItem, attempt: Int)] = [:]
    /// Whether this process has EVER received a first-contentful-paint
    /// event from the engine. The paint watchdog's committed-page
    /// escalation rests entirely on "no paint signal since arming"
    /// meaning "nothing painted" - which is only true on a build whose
    /// engine actually delivers the signal. This build's engine has no
    /// emitter for GeckoView:FirstContentfulPaint (nothing in the
    /// pinned release's geckoview modules or this repo's patches sends
    /// it; on Android it comes from a compositor bridge this port does
    /// not have), so until the first event proves the wire live, the
    /// escalation must treat an expired wait as absence of evidence.
    private var hasObservedFirstPaintSignal = false
    /// Long enough that a slow page is not reported as a failure; short
    /// enough to land before a user gives up and force-quits.
    private static let paintWatchdogSeconds: TimeInterval = 8.0
    private var selectionCounter = 0
    
    // A background termination may be reported after the app becomes active.
    // Keep the session eligible for silent recovery until a foreground composite confirms it survived.
    
    private lazy var lenientURLExpression: NSRegularExpression = {
        let pattern = "^\\s*(\\w+-+)*[\\w\\[]+(://[/]*|:|\\.)(\\w+-+)*[\\w\\[:]+([\\S&&[^\\w-]]\\S*)?\\s*$"
        return try! NSRegularExpression(pattern: pattern)
    }()
    
    private struct EmergencyTabSnapshot {
        let regularTabs: [(id: UUID, title: String, url: String?)]
        let privateTabs: [(id: UUID, title: String, url: String?)]
        let selectedRegularTabID: UUID?
        let selectedPrivateTabID: UUID?
        let selectedTabMode: TabMode
    }
    private let emergencySnapshotLock = NSLock()
    private var emergencySnapshot: EmergencyTabSnapshot?
    
    /// Detects a genuinely unresponsive main thread and proactively
    /// flushes the last known tab state to disk before the OS's own,
    /// much harsher watchdog gets a chance to SIGKILL the process — see
    /// MainThreadHangWatchdog's own doc comment for the full reasoning.
    /// This exists specifically because a real crash showed a SIGKILL
    /// can happen with zero cooperation from any lifecycle hook this
    /// app already flushes on.
    private lazy var hangWatchdog = MainThreadHangWatchdog { [weak self] in
        self?.performEmergencyFlush()
        // The tabs are safe on disk; now try to save the process. A
        // main thread parked this long is, in every device capture so
        // far, ExtensionFoundation's synchronous lifecycle XPC waiting
        // on a content process that a dying debug transport left
        // stopped. kill() cannot help - extension processes answer to
        // RunningBoard, not the host, and every attempt returns EPERM
        // - so the only actor able to resume the child is a debugger.
        // The normal +2s foreground recovery is queued on the main
        // thread, BEHIND the very hang it would fix; this runs the
        // same recovery from the watchdog's queue instead. See
        // fix_resume_stopped_children_on_foreground_hang.py.
        JITController.shared.recoverStoppedChildrenAfterForegroundHang()
    }
    
    private var memoryWarningObservationToken: NSObjectProtocol?

    /// Recoveries parked because the content process died while the
    /// app was not active. Closing the dead session and opening a
    /// replacement spawns an NSExtension process, and a process
    /// spawned into a backgrounded app is suspended mid-launch and
    /// cannot answer the synchronous XPC ExtensionFoundation sends
    /// every hosted extension during willEnterForeground - the main
    /// thread blocks inside the cascade and the watchdog kills the app
    /// at 10s (0x8BADF00D, seen on device with PiP active). Parked
    /// here instead and drained at didBecomeActive, the same lifecycle
    /// point where every user-initiated tab open already spawns
    /// safely. See fix_defer_respawns_while_inactive.py.
    private var deferredSessionRecoveries: [(tabID: UUID, reason: String)] = []
    private var didBecomeActiveObservationToken: NSObjectProtocol?
    
    init(
        delegate: TabManagerDelegate?,
        sessionManager: SessionManager,
        store: TabManagementStore = .shared,
        faviconStore: FaviconStore = .shared,
        historyStore: HistoryStore = .shared
    ) {
        self.delegate = delegate
        self.sessionManager = sessionManager
        self.store = store
        self.faviconStore = faviconStore
        self.historyStore = historyStore
        super.init()

        // "Find" in the text-selection callout. Routed up rather than
        // handled here: the presenter knows the selected text, the
        // browser owns the find bar.
        selectionActionPresenter.onFindSelection = { [weak self] text in
            guard let self else { return }
            self.delegate?.tabManager(self, didRequestFindInPage: text)
        }

        hangWatchdog.start()
        
        // Defensive safety net alongside the explicit backgrounding
        // trigger (called separately from SceneDelegate) — genuine
        // memory pressure can happen while still in the foreground too,
        // and sleeping background tabs at that point is strictly safe:
        // sleepBackgroundedTabs() never touches the tab actually on
        // screen.
        memoryWarningObservationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleepBackgroundedTabs()
            self?.dropBackgroundThumbnails()
        }

        // Recoveries deferred while the app was not active run here -
        // after the foreground cascade, so the spawn cannot collide
        // with the synchronous extension messaging inside it. See
        // fix_defer_respawns_while_inactive.py.
        didBecomeActiveObservationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.drainDeferredSessionRecoveries()
        }
    }
    
    deinit {
        hangWatchdog.stop()
        if let memoryWarningObservationToken {
            NotificationCenter.default.removeObserver(memoryWarningObservationToken)
        }
        if let didBecomeActiveObservationToken {
            NotificationCenter.default.removeObserver(didBecomeActiveObservationToken)
        }
    }
    
    // MARK: - Tab Sleeping
    
    /// Live content processes cost more than memory on this platform:
    /// iOS sends one SYNCHRONOUS XPC per hosted extension, on the main
    /// thread, at every scene transition, against a 10 second watchdog.
    /// Twelve tabs visited is twelve of those, and that is what has been
    /// killing the app on the way back from the background.
    ///
    /// Gecko retires a process the moment its last tab lets go -
    /// dom.ipc.processReuse.unusedGraceMs is 0 and no keepalive pref is
    /// set - so all this has to do is let go. evictSessionIfNeeded closes
    /// the session and leaves the replacement unopened; the selection
    /// rule above opens it again if the tab is returned to.
    ///
    /// Least recently selected first, and deliberately generous: this
    /// only fires well past what a transition can survive.
    private func retireSessionsBeyondCap(keeping selected: Tab) {
        let live = (regularTabs + privateTabs)
            .filter { $0 !== selected && $0.session.isOpen() }
        guard live.count > Self.liveSessionCap else {
            return
        }
        let doomed = live
            .sorted { $0.state.selectionOrder < $1.state.selectionOrder }
            .prefix(live.count - Self.liveSessionCap)
        for tab in doomed {
            logger(String(format: "tabRetire: closing the session for tab %@ (cap %d, live %d)", tab.id.uuidString, Self.liveSessionCap, live.count))
            evictSessionIfNeeded(for: tab, isPrivate: tab.isPrivate)
        }
    }

    func sleepBackgroundedTabs() {
        // Not while the system is showing media from us. That means
        // Picture in Picture, or a now-playing entry driving the lock
        // screen and CarPlay: in every case something OUTSIDE the app is
        // presenting a page we would be closing. Sleeping
        // closes content processes - including, as a device capture
        // showed, the one PiP is rendering from:
        //
        //   22:29:05.230  pipLife: willStart
        //   22:29:06.370  tabSleep: sleeping tab 96DB0CF2
        //
        // The per-tab guard below could not catch it: it asks whether
        // tab.session IS the PiP session, and sleeping REPLACES
        // tab.session with a new object, so after any tab has slept the
        // registration no longer matches the object it registered. This
        // check needs no identity to hold.
        //
        // The cost is bounded - PiP is a transient state, and the memory
        // sleeping would have freed is reclaimed the moment it ends,
        // when backgrounding runs this again.
        if sessionManager.hasSystemMediaSession {
            NSLog("[TabMemory] NOT sleeping - Picture in Picture or system media (lock screen / CarPlay) is active")
            return
        }
        NSLog("[TabMemory] Sleeping backgrounded tab sessions")
        for tab in regularTabs {
            evictSessionIfNeeded(for: tab, isPrivate: false)
        }
        for tab in privateTabs {
            evictSessionIfNeeded(for: tab, isPrivate: true)
        }
    }

    /// Releases the in-memory thumbnail of every tab except the
    /// selected one. Companion to sleepBackgroundedTabs for the other
    /// big per-tab allocation - a full-screen decompressed screenshot
    /// per tab - which session eviction never touched. Strictly safe:
    /// every thumbnail was persisted to disk by updateThumbnail at
    /// capture time, and reloadEvictedThumbnails() brings them back on
    /// demand. Cells currently on screen keep the bitmap their image
    /// view already holds, so nothing visibly blanks at the moment of
    /// the drop.
    func dropBackgroundThumbnails() {
        NSLog("[TabMemory] Dropping in-memory thumbnails for background tabs")
        for tab in regularTabs where tab !== selectedTab {
            tab.thumbnail = nil
        }
        for tab in privateTabs where tab !== selectedTab {
            tab.thumbnail = nil
        }
    }

    /// Asynchronously restores any thumbnails dropped by
    /// dropBackgroundThumbnails (or never loaded). Cheap when nothing
    /// is missing - one array scan - so callers can invoke it
    /// unconditionally.
    func reloadEvictedThumbnails() {
        let evicted = (regularTabs + privateTabs).filter { $0.thumbnail == nil }
        guard !evicted.isEmpty else {
            return
        }

        for tab in evicted {
            let tabID = tab.id
            store.loadThumbnail(for: tabID) { [weak self] image in
                guard let self, let image else {
                    return
                }
                // Looked up again by id on delivery - the tab can have
                // been closed, moved, or captured a fresh thumbnail
                // while the load was in flight, and a fresh capture
                // must never be clobbered by this stale disk copy.
                guard let location = self.tabLocation(for: tabID) else {
                    return
                }
                let tab = self.tabs(for: location.mode)[location.index]
                guard tab.thumbnail == nil else {
                    return
                }
                tab.thumbnail = image
                self.notifyUpdate(at: location.index, mode: location.mode, reason: .thumbnail)
            }
        }
    }
    
    /// Closes `tab`'s Gecko session and replaces it with a fresh, unopened
    /// one marked as pending restoration — the same state a tab restored
    /// from a previous launch starts in. Title, favicon, thumbnail, and
    /// navigation (back/forward) history are untouched, since none of
    /// those live on the session itself.
    private func evictSessionIfNeeded(for tab: Tab, isPrivate: Bool) {
        // Already evicted, or never had anything loaded worth evicting.
        guard case .none = tab.state.restoreState,
              let url = displayedURL(for: tab) else {
            return
        }
        
        // Never evict the tab currently on-screen, or one that's actively
        // mid-navigation (evicting it would strand the load).
        guard tab !== selectedTab, !tab.state.loadingState.isLoading else {
            return
        }
        
        // Nor the one Picture in Picture is rendering from. It is not the
        // selected tab - the video is in the floating window and the user
        // is elsewhere - so nothing above catches it, and closing its
        // session tears down a content process that has to stay alive and
        // rendering while the app is backgrounded. SessionManager already
        // keeps that session active; this stops us closing it anyway.
        guard !sessionManager.isMediaPriority(tab.session) else {
            logger(String(format: "tabSleep: NOT sleeping tab %@ - it holds Picture in Picture or the media controls", tab.id.uuidString))
            return
        }
        
        logger(String(format: "tabSleep: sleeping tab %@ (url=%@, suppressInitialNavigation was %@)", tab.id.uuidString, loggableURL(url, isPrivate: isPrivate), String(tab.state.suppressInitialNavigation)))
        sessionManager.close(tab.session)
        // NOT opened. An immediate open spawns a replacement content
        // process straight away, so sleeping a tab freed its page but
        // left the process - and therefore the hosted app extension -
        // alive. That is what iOS charges for on the way back in:
        // ExtensionFoundation's -[EXConcreteExtension
        // _hostWillEnterForegroundNote:] does a SYNCHRONOUS XPC
        // round-trip to every hosted extension, on the main thread, and
        // the 08:00:52 capture died in exactly that call with 17 live
        // children to work through against a 10 second allowance.
        //
        // Deferring the open to selection means a slept tab costs no
        // process at all. loadRestoredURLIfNeeded opens it on the way
        // back.
        tab.session = createSession(tabID: tab.id, url: url, windowId: nil, isPrivate: isPrivate, opening: .manual)
        tab.state.restoreState = .pending(url)
        tab.state.navigationState = sessionManager.restoreNavigation(for: tab.id, isPrivate: isPrivate)
        NSLog("[TabMemory] Slept background session for tab %@", tab.id.uuidString)
    }
    
    // MARK: - Application Lifecycle
    
    func applicationWillResignActive() {
    }
    
    func applicationDidBecomeActive() {
        guard selectedTab?.session.isOpen() == false else {
            return
        }
        
        selectTab(at: selectedTabIndex, mode: selectedTabMode)
    }
    
    // MARK: - Persistence And Lookup
    
    private func cancelFaviconTask(for tabID: UUID) {
        faviconTasks.removeValue(forKey: tabID)?.cancel()
    }
    
    private func persistState() {
        let selectedRegularTabID = regularTabs[safe: selectedRegularTabIndex]?.id
        let selectedPrivateTabID = privateTabs[safe: selectedPrivateTabIndex]?.id
        
        // Cheap value-type copy, safe for the watchdog to read from a
        // background thread later — must happen on the main thread,
        // here, while regularTabs/privateTabs are still safe to read.
        emergencySnapshotLock.lock()
        emergencySnapshot = EmergencyTabSnapshot(
            regularTabs: regularTabs.map { (id: $0.id, title: $0.title, url: $0.url) },
            privateTabs: privateTabs.map { (id: $0.id, title: $0.title, url: $0.url) },
            selectedRegularTabID: selectedRegularTabID,
            selectedPrivateTabID: selectedPrivateTabID,
            selectedTabMode: selectedTabMode
        )
        emergencySnapshotLock.unlock()
        
        // DIAGNOSTIC - see fix_tab_lifecycle_logging_to_file.py.
        // Written through logger() rather than NSLog so it reaches
        // Documents/reynard_jit_log.txt, which survives the app being
        // killed. The tab-loss bug appears spontaneously after
        // backgrounding, so it cannot be caught with a live syslog
        // capture - it has to be recorded and read afterwards.
        logger(String(format: "tabPersist: writing %d regular, %d private tabs", regularTabs.count, privateTabs.count))
        
        store.persistTabs(
            regularTabs: regularTabs,
            privateTabs: privateTabs,
            selectedRegularTabID: selectedRegularTabID,
            selectedPrivateTabID: selectedPrivateTabID,
            selectedTabMode: selectedTabMode
        )
    }
    
    /// Called from MainThreadHangWatchdog's background queue — never
    /// the main thread, since that's the one that's stuck. Reads the
    /// last snapshot persistState() captured and writes it directly,
    /// bypassing the normal async queue entirely for maximum immediacy.
    private func performEmergencyFlush() {
        emergencySnapshotLock.lock()
        let snapshot = emergencySnapshot
        emergencySnapshotLock.unlock()
        
        guard let snapshot else {
            logger("tabFlush: HangWatchdog fired but NO snapshot available yet - nothing written")
            return
        }
        
        // ADDED - see fix_helper_entitlements_and_emergency_flush_guard.py's
        // docstring. The nil check above is not enough on its own:
        // emergencySnapshot is written only by persistState(), which
        // copies whatever the tab arrays hold at that instant, so if
        // persistState() ever runs before restoreTabsIfNeeded() has
        // populated them, the snapshot is non-nil but EMPTY and passes
        // straight through. Writing that here - from a background
        // thread, deliberately bypassing the normal async queue -
        // overwrites a good persisted tab list with nothing, and
        // restoreTabsIfNeeded() then finds an empty snapshot on the
        // next launch and presents a single blank tab.
        //
        // Deliberately does not consult the store to compare against
        // what is already persisted: this runs on the watchdog's
        // background queue while the main thread is stuck, and
        // reaching into the store from here would add exactly the
        // cross-thread access this path exists to avoid. An emergency
        // flush of "no tabs" carries no information worth writing
        // under any circumstances.
        guard !snapshot.regularTabs.isEmpty || !snapshot.privateTabs.isEmpty else {
            logger("tabFlush: REFUSING to emergency-flush an EMPTY snapshot - this would have destroyed the persisted tab list")
            return
        }
        
        logger(String(format: "tabFlush: HangWatchdog emergency-writing %d regular, %d private tabs", snapshot.regularTabs.count, snapshot.privateTabs.count))
        
        // The watchdog firing means the main thread has already been
        // blocked for a while, and a stopped content process is the
        // likeliest reason. This says which one. See
        // fix_dump_loop_state_on_hang.py.
        JITEnabler.dumpDebugLoopState()

        // ADDED - see fix_child_heartbeat_instrument.py's docstring.
        //
        // The loop dump above reports registered debug loops, and by hang
        // time there are usually none - every capture so far ends
        // "hangDump: 0 session(s) registered", which is accurate and
        // names nobody. This is the moment that can actually identify the
        // extension the main thread is blocked on, because it runs from
        // this background queue while that thread is stuck.
        JITEnabler.dumpChildHeartbeats(labelled: "hangHeartbeat")

        // And act on what that just printed.
        //
        // The dump has been able to name the wedged child for a while -
        // one capture reads "pid 35088 type=tab main=512619ms
        // bg=512618ms  <<< STOPPED - cannot answer XPC" - and then did
        // nothing with it, while interruptLiveDebugSessions found no
        // live session to interrupt because the loop had long since
        // exited. Ten seconds later iOS killed the app.
        //
        // A child stopped that long cannot be resumed from here; its
        // debugger transport is gone. Killing it is the whole move, and
        // it is the right one - Gecko rebuilds a dead content process,
        // whereas the watchdog kill takes the session with it.
        let killed = JITEnabler.killStoppedChildren()
        if killed > 0 {
            logger(String(format: "tabFlush: HangWatchdog killed %d stopped child(ren)", killed))
        }
        
        store.emergencyPersistTabs(
            regularTabs: snapshot.regularTabs,
            privateTabs: snapshot.privateTabs,
            selectedRegularTabID: snapshot.selectedRegularTabID,
            selectedPrivateTabID: snapshot.selectedPrivateTabID,
            selectedTabMode: snapshot.selectedTabMode
        )

        // The tabs are safe; the process is not. The watchdog fires at
        // two seconds and iOS terminates at ten, so roughly eight
        // seconds of the scene-update budget are left here and nothing
        // was using them. A child a supervision session has stopped
        // cannot answer the synchronous XPC the foreground handshake is
        // waiting on, and interrupting the loops and cancelling their
        // in-flight calls is the one lever available from this queue.
        // It is not a guaranteed save - it is the difference between
        // spending the remaining budget and spending none of it.
        //
        // Both calls are safe from a background thread and neither can
        // touch the main thread, which is stuck by definition.
        // See fix_hang_watchdog_recovery.py.
        JITEnabler.interruptLiveDebugSessions()
        JITEnabler.cancelAllDebugSessionCalls()
        logger("tabFlush: HangWatchdog escalation - interrupted live sessions, cancelled in-flight calls")
    }
    
    private func tabs(for mode: TabMode) -> [Tab] {
        switch mode {
        case .regular:
            return regularTabs
        case .private:
            return privateTabs
        }
    }
    
    private func selectedIndex(for mode: TabMode) -> Int {
        switch mode {
        case .regular:
            return selectedRegularTabIndex
        case .private:
            return selectedPrivateTabIndex
        }
    }
    
    private func setSelectedIndex(_ index: Int, for mode: TabMode) {
        switch mode {
        case .regular:
            selectedRegularTabIndex = index
        case .private:
            selectedPrivateTabIndex = index
        }
    }
    
    private func tabLocation(for session: GeckoSession) -> (mode: TabMode, index: Int)? {
        if let index = regularTabs.firstIndex(where: { $0.session === session }) {
            return (.regular, index)
        }
        
        if let index = privateTabs.firstIndex(where: { $0.session === session }) {
            return (.private, index)
        }
        
        return nil
    }
    
    private func tabLocation(for tabID: UUID) -> (mode: TabMode, index: Int)? {
        if let index = regularTabs.firstIndex(where: { $0.id == tabID }) {
            return (.regular, index)
        }
        
        if let index = privateTabs.firstIndex(where: { $0.id == tabID }) {
            return (.private, index)
        }
        
        return nil
    }
    
    private func notifyUpdate(at index: Int, mode: TabMode, reason: TabManagerUpdateReason) {
        if mode == selectedTabMode {
            delegate?.tabManager(self, didUpdateTabAt: index, reason: reason)
        } else {
            delegate?.tabManagerDidChangeTabs(self)
        }
    }
    
    // MARK: - Navigation State
    
    private func loadURL(_ url: String, in tab: Tab) {
        tab.state.showsStartupHomepage = false
        tab.state.loadingState = .loading(progress: 0)
        // A slept tab has had its session closed by
        // evictSessionIfNeeded, and load() on a closed session goes
        // nowhere - which is why a restored tab stayed blank until it was
        // refreshed by hand. See fix_reopen_session_before_restore.py.
        //
        // Replaced rather than reopened: SessionManager owns creation,
        // and a closed GeckoSession is not documented as reusable.
        //
        // The swap happens BEFORE the .loading notify below: the
        // contentView rebind check runs on that notify and used to see
        // the old session, leaving the replacement off screen until
        // some later update. The replacement is activated when it
        // belongs to the on-screen tab - createSession(.immediate)
        // deliberately deactivates - and seeded with the real URL so
        // UA/viewport settings are right from the first load.
        if !tab.session.isOpen() {
            NSLog("[TabRestore] session for tab %@ was closed - creating a new one before loading", tab.id.uuidString)
            tab.session = createSession(
                tabID: tab.id,
                url: url,
                windowId: nil,
                isPrivate: tab.isPrivate
            )
            if tab === selectedTab {
                sessionManager.activate(tab.session)
            }
        }
        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        }
        
        sessionManager.updateSettings(of: tab.session, for: url, tabID: tab.id)
        tab.session.load(url)
    }
    
    private func applyNavigationState(to tab: Tab) {
        if tab.isPrivate {
            tab.state.navigationState = NavigationAvailability(
                canGoBack: tab.state.sessionNavigationAvailability.canGoBack,
                canGoForward: tab.state.sessionNavigationAvailability.canGoForward
            )
            return
        }
        tab.state.navigationState = sessionManager.navigationAvailability(
            for: tab.id,
            sessionState: tab.state.sessionNavigationAvailability
        )
    }
    
    private func recordNavigation(_ url: String, for tab: Tab) {
        if tab.isPrivate {
            applyNavigationState(to: tab)
            return
        }
        tab.state.navigationState = sessionManager.recordNavigation(
            to: url,
            for: tab.id,
            sessionState: tab.state.sessionNavigationAvailability
        )
    }
    
    // MARK: - Session Creation
    
    private func makeTab(windowId: String?, isPrivate: Bool) -> Tab {
        let tabID = UUID()
        return Tab(
            id: tabID,
            session: createSession(tabID: tabID, url: nil, windowId: windowId, isPrivate: isPrivate),
            isPrivate: isPrivate
        )
    }
    
    private var sessionDelegates: SessionDelegates {
        return SessionDelegates(
            content: self,
            navigation: self,
            history: self,
            permission: permissionCoordinator,
            progress: self,
            prompt: promptCoordinator,
            selectionAction: selectionActionCoordinator,
            mediaSession: systemMediaSession,
            // The translate bar lives on BrowserViewController, which
            // is this manager's delegate - the engine offers a
            // translation per session and the bar follows the
            // selected tab.
            translations: delegate as? TranslationsDelegate
        )
    }
    
    // MARK: - Transferred Tabs
    
    private func applyTransferredState(to tab: Tab, url: String, title: String?) {
        tab.url = url
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.title = title
        }
        tab.state.displayState = .committed
        tab.state.suppressInitialNavigation = true
        tab.favicon = cachedFavicon(for: url)
    }
    
    private func recordTransferredHistory(for tab: Tab, title: String?) {
        guard !tab.isPrivate,
              let url = remoteURL(from: tab.url) else {
            return
        }
        
        historyStore.recordVisit(url: url, title: tab.title)
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyStore.updatePageTitle(for: url, title: title)
        }
    }
    
    // MARK: - URL Resolution
    
    private func restoredURL(from value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty,
              trimmedValue.lowercased() != "about:blank" else {
            return nil
        }
        
        return trimmedValue
    }
    
    private func displayedURL(for tab: Tab) -> String? {
        switch tab.state.displayState {
        case let .pending(url):
            return restoredURL(from: url)
        case .committed:
            return restoredURL(from: tab.url)
        }
    }
    
    private func hasDisplayURL(for tab: Tab) -> Bool {
        return displayedURL(for: tab) != nil
    }
    
    private func remoteURL(from value: String?) -> URL? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        
        return url
    }
    
    // MARK: - Favicons
    
    private func cachedFavicon(for value: String?) -> UIImage? {
        guard let url = remoteURL(from: value) else {
            return nil
        }
        
        return faviconStore.cachedFavicon(for: url)
    }
    
    private func scheduleFaviconUpdate(forTabAt index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        cancelFaviconTask(for: tab.id)
        
        let cachedImage = cachedFavicon(for: tab.url)
        tab.favicon = cachedImage
        notifyUpdate(at: index, mode: mode, reason: .favicon)
        
        guard cachedImage == nil,
              let url = remoteURL(from: tab.url) else {
            return
        }
        
        let tabID = tab.id
        let expectedURL = url.absoluteString
        faviconTasks[tabID] = Task { [weak self] in
            guard let self else {
                return
            }
            
            let image = await self.faviconStore.favicon(for: url)
            guard !Task.isCancelled else {
                return
            }
            
            await MainActor.run {
                self.applyResolvedFavicon(image, toTabWithID: tabID, expectedURL: expectedURL)
            }
        }
    }
    
    @MainActor
    private func applyResolvedFavicon(_ image: UIImage?, toTabWithID tabID: UUID, expectedURL: String) {
        defer {
            faviconTasks.removeValue(forKey: tabID)
        }
        
        guard let location = tabLocation(for: tabID),
              tabs(for: location.mode)[location.index].url == expectedURL else {
            return
        }
        
        tabs(for: location.mode)[location.index].favicon = image
        notifyUpdate(at: location.index, mode: location.mode, reason: .favicon)
    }
    
    // MARK: - Tab Restoration
    
    private func restoreTabsIfNeeded() -> Bool {
        guard regularTabs.isEmpty && privateTabs.isEmpty else {
            logger(String(format: "tabRestore: already populated (%d regular, %d private) - nothing to restore", regularTabs.count, privateTabs.count))
            return true
        }
        
        let snapshot = store.currentSnapshot()
        
        // DIAGNOSTIC - the count found in the store on launch. Paired
        // with tabPersist from the previous session this identifies
        // exactly where tabs are lost: a persist of N followed by a
        // restore of 0 means the store was overwritten or lost between
        // the two, whereas a persist of 0 means they were already gone
        // in memory and the store is innocent.
        logger(String(format: "tabRestore: store holds %d regular, %d private tabs", snapshot.regularTabs.count, snapshot.privateTabs.count))
        
        guard !snapshot.regularTabs.isEmpty || !snapshot.privateTabs.isEmpty else {
            logger("tabRestore: store is EMPTY - no tabs will be restored, a blank tab will be created")
            return false
        }
        
        regularTabs = snapshot.regularTabs.map { snapshot in
            let tab = Tab(
                id: snapshot.id,
                // NOT opened. A restored tab is .pending until it is
                // selected - nothing has been loaded into this session -
                // so opening it here buys a content process, and
                // therefore a hosted app extension, per restored tab
                // before the user has touched anything. A capture seven
                // seconds after launch counted 11 tab processes, and
                // iOS sync-XPCs every one of them on the main thread at
                // each scene transition. loadRestoredURLIfNeeded opens
                // the session when the tab is actually selected.
                session: createSession(
                    tabID: snapshot.id,
                    url: snapshot.url,
                    windowId: nil,
                    isPrivate: false,
                    opening: .manual
                ),
                title: snapshot.title,
                url: snapshot.url,
                favicon: cachedFavicon(for: snapshot.url),
                thumbnail: snapshot.thumbnail,
                isPrivate: false
            )
            tab.state.restoreState = restoredURL(from: snapshot.url).map(TabRestoreState.pending) ?? .none
            tab.state.navigationState = sessionManager.restoreNavigation(for: tab.id)
            return tab
        }
        
        privateTabs = snapshot.privateTabs.map { snapshot in
            let tab = Tab(
                id: snapshot.id,
                session: createSession(
                    tabID: snapshot.id,
                    url: snapshot.url,
                    windowId: nil,
                    isPrivate: true,
                    opening: .manual
                ),
                title: snapshot.title,
                url: snapshot.url,
                favicon: cachedFavicon(for: snapshot.url),
                thumbnail: snapshot.thumbnail,
                isPrivate: true
            )
            tab.state.restoreState = restoredURL(from: snapshot.url).map(TabRestoreState.pending) ?? .none
            tab.state.navigationState = sessionManager.restoreNavigation(
                for: tab.id,
                isPrivate: true
            )
            return tab
        }
        
        selectedRegularTabIndex = snapshot.selectedRegularTabID.flatMap { selectedTabID in
            regularTabs.firstIndex(where: { $0.id == selectedTabID })
        } ?? (regularTabs.isEmpty ? -1 : 0)
        
        selectedPrivateTabIndex = snapshot.selectedPrivateTabID.flatMap { selectedTabID in
            privateTabs.firstIndex(where: { $0.id == selectedTabID })
        } ?? (privateTabs.isEmpty ? -1 : 0)
        
        selectedTabMode = snapshot.selectedTabMode
        
        if tabs(for: selectedTabMode).isEmpty {
            selectedTabMode = regularTabs.isEmpty ? .private : .regular
        }
        
        // The tab you are about to look at opens EAGERLY. Everything
        // else stays deferred, which is where the process saving is - a
        // capture after the deferral counted 5 live children at launch
        // against 14 before it - but the selected tab has to behave
        // exactly as it always did: app opens, tab loads, pull to
        // refresh works. Leaving it to the same lazy path as the rest
        // made startup depend on a chain of callbacks that is easy to
        // break and hard to notice.
        if let selected = tabs(for: selectedTabMode)[safe: max(selectedIndex(for: selectedTabMode), 0)],
           !selected.session.isOpen() {
            logger(String(format: "tabRestore: opening the selected tab's session eagerly (%@)", selected.id.uuidString))
            sessionManager.open(selected.session)
            sessionManager.activate(selected.session)
        }

        delegate?.tabManagerDidChangeTabs(self)

        selectTab(at: max(selectedIndex(for: selectedTabMode), 0), mode: selectedTabMode)

        // Restore seeds every tab with thumbnail: nil (see
        // currentSnapshot) - fill them in off the startup path. Runs
        // after selection so the selected tab's session work is not
        // competing with a burst of image decodes.
        reloadEvictedThumbnails()
        return true
    }
    
    private func loadRestoredURLIfNeeded(for index: Int, mode: TabMode) {
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        // A slept tab's session is created unopened on purpose, so this
        // is where it comes back - before the isOpen() guard below,
        // which exists to catch a session that DIED, not one that was
        // never started.
        if !tab.session.isOpen(), case .pending = tab.state.restoreState {
            logger(String(format: "tabRestore: opening the deferred session for tab %@", tab.id.uuidString))
            sessionManager.open(tab.session)
            // ...and activate it here, because the activate() selectTab
            // already made was a no-op: it runs before this point and
            // returns early on a session that is not open yet. Without
            // this the tab loads into an INACTIVE docshell - the page
            // runs, and never composites, until some later transition
            // activates it. That is what
            // "toolbarTrace: ... visited=1 delivered=0" is reporting.
            if tab === selectedTab {
                sessionManager.activate(tab.session)
                // Re-bind as well, because the view bound to this
                // session while it was still closed: selectTab notifies
                // didSelectTabAt - which sends the toolbar limits and the
                // content bottom offset - BEFORE this line runs, and a
                // session with no window drops both silently. Without
                // this the tab lays out with no chrome reservation at all
                // and its content sits under the pill. Same session on
                // both sides deliberately; what changed is that it is
                // now open.
                delegate?.tabManager(
                    self,
                    didReplaceSelectedSession: tab.session,
                    with: tab.session
                )
            }
        }
        
        guard tab.session.isOpen(),
              case let .pending(url) = tab.state.restoreState else {
            logger(String(format: "tabRestore: tab at index %d not restorable (open=%@, restoreState=%@) - nothing to do", index, String(tab.session.isOpen()), String(describing: tab.state.restoreState)))
            return
        }
        
        logger(String(format: "tabRestore: RESTORING tab %@ (url=%@) - calling loadURL now", tab.id.uuidString, loggableURL(url, isPrivate: tab.isPrivate)))
        tab.state.restoreState = .none
        tab.state.suppressInitialNavigation = false
        // A restored load reaches the engine only by this path, and a
        // queued LoadUri the engine never acknowledges has no recovery
        // of its own. browse() arms the same ladder for exactly that
        // reason. displayState is what the ladder's retry compares
        // against, so it is set here as browse() sets it.
        // See fix_loadwatchdog_restore_loads.py.
        tab.state.displayState = .pending(url)
        loadURL(url, in: tab)
        armLoadWatchdog(for: tab, pendingInput: url, retryURL: url)
    }
    
    @discardableResult
    func restoreRecentlyClosedTab(id: UUID) -> Bool {
        guard let snapshot = store.takeRecentlyClosedTab(id: id) else {
            return false
        }
        
        let tab = Tab(
            id: snapshot.id,
            session: createSession(
                tabID: snapshot.id,
                url: snapshot.url,
                windowId: nil,
                isPrivate: false
            ),
            title: snapshot.title,
            url: snapshot.url,
            favicon: cachedFavicon(for: snapshot.url),
            isPrivate: false
        )
        tab.state.restoreState = restoredURL(from: snapshot.url).map(TabRestoreState.pending) ?? .none
        tab.state.navigationState = sessionManager.restoreNavigation(for: tab.id)
        
        let index = regularTabs.count
        regularTabs.append(tab)
        delegate?.tabManagerDidChangeTabs(self)
        selectedTabMode = .regular
        delegate?.tabManager(self, animateNewTabSelectionAt: index) { [weak self] in
            self?.selectTab(at: index, mode: .regular)
        }
        return true
    }
    
    // MARK: - Session Recovery
    
    // MARK: - Tab Lifecycle
    
    private func saveClosedTabIfNeeded(_ tab: Tab, mode: TabMode) {
        guard mode == .regular,
              let url = displayedURL(for: tab) else {
            return
        }
        
        store.saveRecentlyClosedTab(id: tab.id, title: tab.title, url: url)
    }
    
    func createInitialTab(openingScreen: HomepageOpeningScreen) {
        switch openingScreen {
        case .lastTab:
            if !restoreTabsIfNeeded() {
                addTab(selecting: true, windowId: nil, at: nil, isPrivate: false)
            }
        case .homepage:
            createHomepageInitialTab()
        }
    }
    
    private func createHomepageInitialTab() {
        let didRestoreTabs = restoreTabsIfNeeded()
        
        if didRestoreTabs,
           let selectedTab,
           displayedURL(for: selectedTab) == nil {
            selectedTab.state.showsStartupHomepage = true
            return
        }
        
        let index = addTab(selecting: true, windowId: nil, at: nil, isPrivate: false)
        regularTabs[index].state.showsStartupHomepage = true
    }
    
    @discardableResult
    func addTab(selecting: Bool, windowId: String? = nil, at insertionIndex: Int? = nil, isPrivate: Bool = false) -> Int {
        let tab = makeTab(windowId: windowId, isPrivate: isPrivate)
        let mode: TabMode = isPrivate ? .private : .regular
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(tab)
            } else {
                regularTabs.insert(tab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(tab)
            } else {
                privateTabs.insert(tab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        
        if selecting {
            selectTab(at: index, mode: mode)
        } else {
            persistState()
        }
        
        return index
    }
    
    @discardableResult
    func addTransferredSession(_ session: GeckoSession, url: String, title: String?, selecting: Bool, at insertionIndex: Int?, isPrivate: Bool = false) -> Int {
        let tab = Tab(session: session, isPrivate: isPrivate)
        let mode: TabMode = isPrivate ? .private : .regular
        sessionManager.adopt(session, asTab: tab.id, url: url, delegates: sessionDelegates)
        applyTransferredState(to: tab, url: url, title: title)
        recordNavigation(url, for: tab)
        
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(tab)
            } else {
                regularTabs.insert(tab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(tab)
            } else {
                privateTabs.insert(tab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        notifyUpdate(at: index, mode: mode, reason: .location)
        notifyUpdate(at: index, mode: mode, reason: .title)
        scheduleFaviconUpdate(forTabAt: index, mode: mode)
        recordTransferredHistory(for: tab, title: title)
        
        if selecting {
            if let previousSession = selectedTab?.session,
               previousSession !== session {
                sessionManager.deactivate(previousSession)
            }
            selectedTabMode = mode
            delegate?.tabManager(self, animateNewTabSelectionAt: index) { [weak self] in
                self?.selectTab(at: index, mode: mode)
            }
        } else {
            persistState()
        }
        
        return index
    }
    
    func selectTab(at index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let previousTab = selectedTab
        let previousMode = selectedTabMode
        let previousIndex = previousMode == mode && tabs(for: previousMode).indices.contains(selectedTabIndex) ? selectedTabIndex : nil
        
        selectedTabMode = mode
        selectionCounter += 1
        setSelectedIndex(index, for: mode)
        tabs(for: mode)[index].state.selectionOrder = selectionCounter
        let selectedTab = tabs(for: mode)[index]
        if previousTab?.session !== selectedTab.session,
           let previousSession = previousTab?.session {
            sessionManager.deactivate(previousSession)
        }

        retireSessionsBeyondCap(keeping: selectedTab)

        // THE RULE: a selected tab always has an open session.
        //
        // Restored and slept tabs are created unopened - that is the
        // whole saving, one content process instead of twenty - and
        // every previous attempt tied the open to some particular
        // condition instead: loadRestoredURLIfNeeded only opens when
        // restoreState is .pending, so a tab in any other state kept a
        // closed session, activate() skipped it ("activate SKIPPED - is
        // not open"), the docshell never activated and the tab came up
        // black or simply never loaded.
        //
        // Selection is the one thing every route has in common, and it
        // is here, before activate() and before the delegate binds the
        // view - so the session is open in time for the toolbar limits
        // and content offset that binding sends.
        if !selectedTab.session.isOpen() {
            logger(String(format: "tabSelect: opening the deferred session for tab %@", selectedTab.id.uuidString))
            sessionManager.open(selectedTab.session)
        }

        sessionManager.activate(selectedTab.session)
        systemMediaSession.select(session: selectedTab.session)
        pictureInPictureCoordinator?.selectedSessionDidChange()
        applyNavigationState(to: selectedTab)
        
        delegate?.tabManager(self, didSelectTabAt: index, previousIndex: previousIndex)
        loadRestoredURLIfNeeded(for: index, mode: mode)
        persistState()
    }
    
    func moveTab(from sourceIndex: Int, to destinationIndex: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(sourceIndex),
              tabs(for: mode).indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return
        }
        
        let selectedTabID = tabs(for: mode)[safe: selectedIndex(for: mode)]?.id
        if mode == .regular {
            let movedTab = regularTabs.remove(at: sourceIndex)
            regularTabs.insert(movedTab, at: destinationIndex)
        } else {
            let movedTab = privateTabs.remove(at: sourceIndex)
            privateTabs.insert(movedTab, at: destinationIndex)
        }
        
        if let selectedTabID,
           let selectedIndex = tabs(for: mode).firstIndex(where: { $0.id == selectedTabID }) {
            setSelectedIndex(selectedIndex, for: mode)
        }
        
        persistState()
    }
    
    func removeTab(at index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let wasSelected = mode == selectedTabMode && index == selectedTabIndex
        let removedTab: Tab
        if mode == .regular {
            removedTab = regularTabs.remove(at: index)
        } else {
            removedTab = privateTabs.remove(at: index)
        }
        saveClosedTabIfNeeded(removedTab, mode: mode)
        if wasSelected {
            sessionManager.deactivate(removedTab.session)
        }
        cancelFaviconTask(for: removedTab.id)
        
        if tabs(for: mode).isEmpty {
            setSelectedIndex(-1, for: mode)
        } else if index < selectedIndex(for: mode) {
            setSelectedIndex(selectedIndex(for: mode) - 1, for: mode)
        }
        
        if regularTabs.isEmpty && privateTabs.isEmpty {
            delegate?.tabManagerDidChangeTabs(self)
            persistState()
            sessionManager.discard(removedTab.session, forTab: removedTab.id, keepingHistory: mode == .regular)
            return
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        
        if wasSelected {
            if !tabs(for: mode).isEmpty {
                selectTab(at: min(index, tabs(for: mode).count - 1), mode: mode)
            } else {
                let fallbackMode: TabMode = mode == .regular ? .private : .regular
                selectTab(at: max(selectedIndex(for: fallbackMode), 0), mode: fallbackMode)
            }
        } else {
            persistState()
        }
        
        sessionManager.discard(removedTab.session, forTab: removedTab.id, keepingHistory: mode == .regular)
    }
    
    func removeAllTabs(mode: TabMode) {
        // Deliberately no default/optional here anymore, and no
        // fallback to whatever mode happens to be currently selected —
        // a real incident (5 tabs lost at once, unconfirmed root cause)
        // made clear how dangerous an implicit fallback is for an
        // operation this destructive. Every caller must now say exactly
        // which mode it means to clear.
        logger(String(format: "tabRemoval: removeAllTabs(%@) called - about to remove %d tabs", String(describing: mode), tabs(for: mode).count))
        guard !tabs(for: mode).isEmpty else {
            return
        }
        
        if mode == selectedTabMode,
           let selectedSession = selectedTab?.session {
            sessionManager.deactivate(selectedSession)
        }
        let removedTabs = tabs(for: mode)
        if mode == .regular {
            regularTabs.removeAll(keepingCapacity: true)
            selectedRegularTabIndex = -1
        } else {
            privateTabs.removeAll(keepingCapacity: true)
            selectedPrivateTabIndex = -1
        }
        removedTabs.forEach { saveClosedTabIfNeeded($0, mode: mode) }
        removedTabs.forEach { cancelFaviconTask(for: $0.id) }
        delegate?.tabManagerDidChangeTabs(self)
        logger(String(format: "tabRemoval: removeAllTabs(%@) completed - removed %d tabs", String(describing: mode), removedTabs.count))
        
        if mode == selectedTabMode {
            if mode == .private && !regularTabs.isEmpty {
                selectTab(at: max(selectedRegularTabIndex, 0), mode: .regular)
            } else if mode == .regular && !privateTabs.isEmpty {
                selectTab(at: max(selectedPrivateTabIndex, 0), mode: .private)
            } else {
                persistState()
            }
        } else {
            persistState()
        }
        
        removedTabs.forEach { sessionManager.discard($0.session, forTab: $0.id, keepingHistory: mode == .regular) }
    }
    
    // MARK: - Browsing
    
    func browse(to term: String) {
        guard let tab = selectedTab else {
            return
        }
        browse(to: term, in: tab)
    }
    
    func browse(to term: String, in tab: Tab) {
        let navigationInput = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !navigationInput.isEmpty else {
            return
        }
        
        tab.state.restoreState = .none
        tab.state.suppressInitialNavigation = false
        tab.state.displayState = .pending(navigationInput)
        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        }
        
        let navigationInputRange = NSRange(location: 0, length: (navigationInput as NSString).length)
        let shouldNavigateDirectly = lenientURLExpression.firstMatch(in: navigationInput, range: navigationInputRange) != nil
        
        if shouldNavigateDirectly {
            loadURL(navigationInput, in: tab)
            armLoadWatchdog(for: tab, pendingInput: navigationInput, retryURL: navigationInput)
            return
        }

        let searchDestination = SearchEngine.destination(for: navigationInput)
        loadURL(searchDestination, in: tab)
        armLoadWatchdog(for: tab, pendingInput: navigationInput, retryURL: searchDestination)
    }

    // MARK: - Load Watchdog

    /// A self-healing ladder for a user-initiated load the engine never
    /// acknowledges.
    ///
    /// A tab whose content process died silently swallows the next
    /// LoadUri whole: no pageStart, no pageStop, no location change.
    /// Captured directly on device - the process behind a tab exited
    /// (Target exited, packet W00) without onCrash/onKill ever firing,
    /// so recoverTabAfterSessionLoss never ran; a load into that tab a
    /// minute later produced nothing for six seconds, and an identical
    /// second load then forced the engine to rebuild, spawn a fresh
    /// process and commit within 1.5s.
    ///
    /// Acknowledgment is deliberately narrow: only a pageStart or
    /// locationChange for something other than about:blank counts. The
    /// previous rule - "any engine callback for the tab" - was wrong in
    /// exactly the reported way: the OUTGOING page's pageStop arrives
    /// ~100ms after the submit, and a rebuilt session's initial
    /// about:blank commits inside a second, so on any non-idle tab the
    /// watchdog was disarmed by evidence that had nothing to do with
    /// the requested load - which is how "press Go twice" survived the
    /// first version of this watchdog.
    ///
    /// The ladder: silence for 3s reissues the load on the same session
    /// (attempt 0 -> 1); silence for another 3s closes the session,
    /// builds a fresh one and loads into that (attempt 1, final). One
    /// re-dispatch plus one rebuild per user action, never more. A new
    /// browse() for the same tab replaces the ladder - the user's own
    /// press is itself a load, now backed by a working ladder.
    private static let loadWatchdogSeconds: TimeInterval = 3.0

    /// The deadline for the second stage: pageStart arrived (the engine
    /// is alive and took the LoadUri), but the navigation has not
    /// committed. pageStart fires when the request STARTS - before DNS,
    /// TLS, the redirect chain and any cross-site process switch - so
    /// it is not proof the load will land. Long enough for a cold
    /// handshake plus a multi-hop redirect on an old device; short
    /// enough to fire well before the 22 seconds of dead air in the
    /// captured twitch.tv trace.
    ///
    /// Retuned from 12s on device evidence: healthy commits land
    /// within 2.4s in every captured trace, while a user facing a
    /// blank page gives up and backgrounds the app at about 8s - a
    /// 12s retry is real but invisible, which reads exactly like the
    /// bug it fixes. Six seconds is 2.5x the slowest healthy commit
    /// observed and lands the retry while the user is still watching.
    private static let commitWatchdogSeconds: TimeInterval = 6.0

    /// URLs are evidence in logs that exist to be handed to strangers:
    /// Documents/reynard_stdout.txt and reynard_jit_log.txt both sit
    /// under UIFileSharingEnabled and persist across launches. Private
    /// browsing promises the opposite, so its URLs never enter them -
    /// the tab id keeps every line traceable without the URL.
    private func loggableURL(_ url: String, isPrivate: Bool) -> String {
        return isPrivate ? "<private>" : url
    }

    /// Starts the composite clock for a tab. Reports the latency when
    /// the frame arrives; on expiry it no longer merely logs the
    /// absence - it escalates once, re-dispatching the watched load,
    /// which is the user's second Go press automated. `url` is the
    /// redacted display string and is all the logs ever print;
    /// `retryURL` is the real URL and is all a retry ever loads.
    private func armPaintWatch(for tabID: UUID, url: String, retryURL: String, attempt: Int = 0) {
        paintWaits[tabID]?.workItem.cancel()
        let startedAt = CFAbsoluteTimeGetCurrent()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let wait = self.paintWaits[tabID] else {
                return
            }
            self.paintWaits.removeValue(forKey: tabID)
            // A tab closed inside the window never had to paint, and
            // reporting it would be a false lead in exactly the logs
            // this exists to make readable.
            guard let location = self.tabLocation(for: tabID) else {
                return
            }
            NSLog("[PaintWatch] tab %@ NO FIRST PAINT %.1fs after load started (%@, attempt %d)",
                  tabID.uuidString,
                  CFAbsoluteTimeGetCurrent() - wait.startedAt,
                  wait.url,
                  wait.attempt)

            let tab = self.tabs(for: location.mode)[location.index]

            // The same respawn-while-inactive rule the ladder follows:
            // an escalation load must not go to a process that may be
            // suspended. Re-arm and judge on the foreground side.
            guard UIApplication.shared.applicationState == .active else {
                NSLog("[PaintWatch] tab %@ fired while app is not active - re-arming", tabID.uuidString)
                self.armPaintWatch(for: tabID, url: wait.url, retryURL: wait.retryURL, attempt: wait.attempt)
                return
            }

            // The load ladder still owns a pending load; a second
            // recovery path re-dispatching alongside it would race it.
            // The ladder re-arms this watch with each of its own loads.
            guard self.loadWatchdogs[tabID] == nil else {
                return
            }

            // Still visibly loading: the engine is working, so give it
            // one more full window before concluding anything. Once
            // only - the captured failure holds loadingState at
            // .loading FOREVER, and a stuck spinner must not defer the
            // escalation indefinitely.
            if wait.attempt == 0, tab.state.loadingState.isLoading {
                self.armPaintWatch(for: tabID, url: wait.url, retryURL: wait.retryURL, attempt: 1)
                return
            }

            // Background tabs are left alone: they may legitimately
            // not composite, and reloading them churns sessions the
            // user is not looking at.
            guard tab === self.selectedTab else {
                return
            }

            // The tab may have moved on - a link click or back/forward
            // navigation arms nothing here, so a wait can outlive the
            // load it watched. Escalate only while the tab still
            // corresponds to that load: displayState still .pending
            // (the typed input never committed), or committed onto the
            // watched URL's own site (twitch.tv committing as
            // m.twitch.tv counts). Anything else means the user went
            // somewhere else, and re-dispatching the watched URL would
            // hijack that navigation. Judged against retryURL - the
            // real one - because the display string may be redacted.
            let isPendingLoad: Bool
            if case .pending = tab.state.displayState {
                isPendingLoad = true
            } else {
                isPendingLoad = false
            }
            if !isPendingLoad {
                // "No paint signal since arming" only means "nothing
                // painted" on a build whose engine actually DELIVERS
                // the signal. This one does not (no emitter exists in
                // the engine or its patches), so the wait ALWAYS
                // expires, painted or not - and escalating a committed
                // page on that non-evidence reloaded every site once
                // at the 8s deadline. Until the first signal proves
                // the wire live, a committed page's expiry is what it
                // was before escalation existed: a log line. A PENDING
                // page needs no such proof - its evidence is the
                // missing COMMIT, not the missing paint.
                guard self.hasObservedFirstPaintSignal else {
                    NSLog("[PaintWatch] tab %@ not escalating - no paint signal has ever arrived from this engine", tabID.uuidString)
                    return
                }
                guard let currentHost = DomainMatcher.host(from: tab.url ?? ""),
                      let watchedHost = DomainMatcher.host(from: wait.retryURL),
                      !currentHost.isEmpty,
                      !watchedHost.isEmpty,
                      DomainMatcher.matches(host: currentHost, domain: watchedHost)
                          || DomainMatcher.matches(host: watchedHost, domain: currentHost) else {
                    return
                }
            }

            // One escalation, ever, per armed watch: re-dispatch the
            // load. The captured trace shows an identical second
            // LoadUri forcing the engine to rebuild and commit within
            // ~1.5 seconds - this is that second Go press, automated.
            NSLog("[PaintWatch] tab %@ escalating - re-dispatching %@", tabID.uuidString, wait.url)
            self.loadURL(wait.retryURL, in: tab)
        }
        paintWaits[tabID] = (startedAt: startedAt, url: url, retryURL: retryURL, workItem: workItem, attempt: attempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.paintWatchdogSeconds, execute: workItem)
    }

    private func armLoadWatchdog(
        for tab: Tab,
        pendingInput: String,
        retryURL: String,
        attempt: Int = 0,
        delay: TimeInterval = TabManagerImplementation.loadWatchdogSeconds
    ) {
        let tabID = tab.id
        loadWatchdogs[tabID]?.workItem.cancel()
        // Redacted at arm time, so every later PaintWatch line -
        // success and timeout alike - is safe in a shared log. The
        // real URL rides along separately: the watch's escalation
        // re-dispatches it, and a redacted placeholder must never be
        // what gets loaded.
        armPaintWatch(for: tabID, url: loggableURL(retryURL, isPrivate: tab.isPrivate), retryURL: retryURL)

        let armedAt = CFAbsoluteTimeGetCurrent()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.loadWatchdogs.removeValue(forKey: tabID)

            guard let location = self.tabLocation(for: tabID) else {
                return
            }
            let tab = self.tabs(for: location.mode)[location.index]

            // Anything that happened in the meantime - a commit, a
            // back/forward transition, another browse - moves the tab
            // off this exact pending state, and the retry is then not
            // ours to make.
            guard tab.state.displayState == .pending(pendingInput) else {
                return
            }

            // ADDED - see fix_defer_respawns_while_inactive.py. The
            // rebuild rung below spawns a content process, which must
            // not happen while the app is backgrounded (it is the
            // respawn-while-inactive hazard recoverTabAfterSessionLoss
            // now defers), and a re-dispatch would go to a process
            // that may be suspended. Re-arm with the same attempt and
            // judge again on the foreground side.
            guard UIApplication.shared.applicationState == .active else {
                NSLog("[LoadWatchdog] tab %@ fired while app is not active - re-arming (attempt %d)", tabID.uuidString, attempt)
                self.armLoadWatchdog(for: tab, pendingInput: pendingInput, retryURL: retryURL, attempt: attempt)
                return
            }

            if attempt == 0 {
                NSLog("[LoadWatchdog] tab %@ silent %.1fs after LoadUri %@ - re-dispatching (retry 1 of 1)", tabID.uuidString, CFAbsoluteTimeGetCurrent() - armedAt, self.loggableURL(retryURL, isPrivate: tab.isPrivate))
                self.loadURL(retryURL, in: tab)
                self.armLoadWatchdog(for: tab, pendingInput: pendingInput, retryURL: retryURL, attempt: 1)
                return
            }

            // Re-dispatching down the same channel changed nothing, so
            // the session itself is presumed unrecoverable - the same
            // conclusion recoverTabAfterSessionLoss draws, but keyed on
            // the resolved retryURL rather than displayedURL (which for
            // a search-term browse is the raw typed input, not a
            // loadable URL) and without the restoreState detour.
            NSLog("[LoadWatchdog] tab %@ still silent after retry - rebuilding session and reloading (final)", tabID.uuidString)
            let oldSession = tab.session
            self.sessionManager.close(oldSession)
            tab.session = self.createSession(tabID: tab.id, url: retryURL, windowId: nil, isPrivate: tab.isPrivate)
            if tab === self.selectedTab {
                // createSession(.immediate) deliberately deactivates;
                // the on-screen tab needs its replacement live.
                self.sessionManager.activate(tab.session)
                self.delegate?.tabManager(self, didReplaceSelectedSession: oldSession, with: tab.session)
            }
            self.notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
            self.loadURL(retryURL, in: tab)
        }

        loadWatchdogs[tabID] = LoadWatchdog(
            workItem: workItem,
            attempt: attempt,
            pendingInput: pendingInput,
            retryURL: retryURL,
            armedAt: armedAt
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        NSLog("[LoadWatchdog] tab %@ armed (attempt %d, %.0fs) for %@", tabID.uuidString, attempt, delay, loggableURL(retryURL, isPrivate: tab.isPrivate))
    }

    private func clearLoadWatchdog(for tab: Tab, signal: String) {
        guard let watchdog = loadWatchdogs.removeValue(forKey: tab.id) else {
            return
        }
        watchdog.workItem.cancel()
        NSLog("[LoadWatchdog] tab %@ engine responded (%@) - watchdog cleared", tab.id.uuidString, signal)
    }

    /// pageStart is an ANSWER but not an OUTCOME: it proves the engine
    /// took the LoadUri, and nothing more. The redirect chain, the
    /// cross-site process switch, the commit and the first paint all
    /// happen after it - and the captured twitch.tv trace is exactly a
    /// pageStart followed by 22 seconds of nothing. Clearing here
    /// (which this replaced) left that entire window unprotected, and
    /// the user's second Go press was the only retry that existed.
    ///
    /// So instead of standing down, the ladder moves to a longer
    /// deadline: same attempt, same inputs, commitWatchdogSeconds. The
    /// fire-time guard - displayState still .pending(pendingInput) -
    /// is untouched, so a load that commits (onLocationChange flips
    /// the state to .committed) turns the staged timer into a no-op.
    /// A tab with no armed watchdog stages nothing: SPA traffic and
    /// engine-initiated loads never enter the ladder. Repeated
    /// pageStarts (each rung's own re-dispatch) re-stage, which is
    /// intended - each is fresh evidence the engine is still there.
    private func stageLoadWatchdogForCommit(for tab: Tab, signal: String) {
        guard let watchdog = loadWatchdogs[tab.id] else {
            return
        }
        NSLog("[LoadWatchdog] tab %@ engine responded (%@) - watching for commit", tab.id.uuidString, signal)
        armLoadWatchdog(
            for: tab,
            pendingInput: watchdog.pendingInput,
            retryURL: watchdog.retryURL,
            attempt: watchdog.attempt,
            delay: Self.commitWatchdogSeconds
        )
    }

    /// A user-initiated Stop supersedes the recovery machinery for the
    /// tab's current load attempt: the ladder and the paint watch
    /// exist to finish loads the ENGINE dropped, not to overrule the
    /// user. Called from the stop button's path before session.stop().
    /// Clears both by hand rather than through clearLoadWatchdog,
    /// whose "engine responded" log line would misattribute a user
    /// action to the engine in exactly the traces these logs exist to
    /// make readable.
    func cancelLoadRecovery(for tab: Tab, signal: String) {
        if let watchdog = loadWatchdogs.removeValue(forKey: tab.id) {
            watchdog.workItem.cancel()
        }
        if let wait = paintWaits.removeValue(forKey: tab.id) {
            wait.workItem.cancel()
        }
        NSLog("[LoadWatchdog] tab %@ recovery stood down (%@)", tab.id.uuidString, signal)
    }

    func goBack() {
        guard let tab = selectedTab else {
            return
        }
        if tab.isPrivate {
            guard tab.state.sessionNavigationAvailability.canGoBack else {
                return
            }
            tab.session.goBack()
            return
        }
        guard let transition = sessionManager.goBack(
            for: tab.id,
            sessionState: tab.state.sessionNavigationAvailability
        ) else {
            return
        }
        
        tab.state.navigationState = transition.availability
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        switch transition.action {
        case .session:
            tab.session.goBack()
        case let .load(url):
            loadURL(url, in: tab)
        }
    }
    
    func goForward() {
        guard let tab = selectedTab else {
            return
        }
        if tab.isPrivate {
            guard tab.state.sessionNavigationAvailability.canGoForward else {
                return
            }
            tab.session.goForward()
            return
        }
        guard let transition = sessionManager.goForward(
            for: tab.id,
            sessionState: tab.state.sessionNavigationAvailability
        ) else {
            return
        }
        
        tab.state.navigationState = transition.availability
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        switch transition.action {
        case .session:
            tab.session.goForward()
        case let .load(url):
            loadURL(url, in: tab)
        }
    }
    
    // MARK: - Session Replacement
    
    func replaceSelectedSession(with session: GeckoSession, url: String, title: String?) {
        guard let tab = selectedTab else {
            return
        }
        
        let oldSession = tab.session
        
        sessionManager.adopt(session, asTab: tab.id, url: url, delegates: sessionDelegates)
        tab.session = session
        applyTransferredState(to: tab, url: url, title: title)
        tab.state.sessionNavigationAvailability = .unavailable
        recordNavigation(url, for: tab)
        tab.state.navigationState = sessionManager.useStoredNavigationHistory(for: tab.id)
        sessionManager.activate(session)
        systemMediaSession.select(session: session)
        pictureInPictureCoordinator?.selectedSessionDidChange()
        
        delegate?.tabManagerDidChangeTabs(self)
        delegate?.tabManager(self, didReplaceSelectedSession: oldSession, with: session)
        sessionManager.close(oldSession)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .location)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .title)
        scheduleFaviconUpdate(forTabAt: selectedTabIndex)
        persistState()
        recordTransferredHistory(for: tab, title: title)
    }
    
    // MARK: - Tab Queries And Updates
    
    func tabIndex(for session: GeckoSession) -> Int? {
        return tabs(for: selectedTabMode).firstIndex(where: { $0.session === session })
    }
    
    func shareableURL(for tab: Tab) -> URL? {
        guard let value = tab.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.lowercased() != "about:blank",
              let url = URL(string: value),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            return nil
        }
        return url
    }
    
    func updateThumbnail(_ image: UIImage?, forTabAt index: Int, mode: TabMode) {
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        tab.thumbnail = image
        store.persistThumbnail(image, for: tab.id)
        notifyUpdate(at: index, mode: mode, reason: .thumbnail)
    }
    
    func updateHistoryThumbnail(_ image: UIImage?, for tab: Tab, url: String) {
        guard !tab.isPrivate else {
            return
        }
        sessionManager.updateCurrentHistoryThumbnail(image, for: tab.id, matching: url)
    }

    func navigationPreviewImages(for tab: Tab) -> NavigationPreviewImages {
        guard !tab.isPrivate else {
            return NavigationPreviewImages(backImage: nil, forwardImage: nil)
        }
        return sessionManager.navigationPreviewImages(for: tab.id)
    }
    
    func invalidateNavigationThumbnails() {
        sessionManager.invalidateNavigationThumbnails()
    }
    
    // MARK: - Session Factory
    
    private func createSession(
        tabID: UUID,
        url: String?,
        windowId: String?,
        isPrivate: Bool,
        opening: SessionOpening? = nil
    ) -> GeckoSession {
        return sessionManager.createSession(
            url: url,
            tabID: tabID,
            isPrivate: isPrivate,
            opening: opening ?? .immediate(windowID: windowId),
            delegates: sessionDelegates
        )
    }
}

extension TabManagerImplementation: ContentDelegate {
    func onTitleChange(session: GeckoSession, title: String) {
        guard let location = tabLocation(for: session) else {
            return
        }
        
        let tab = tabs(for: location.mode)[location.index]
        tab.title = title
        if !tab.isPrivate,
           let url = remoteURL(from: tab.url) {
            historyStore.updatePageTitle(for: url, title: title)
        }
        notifyUpdate(at: location.index, mode: location.mode, reason: .title)
        persistState()
    }
    
    func onPreviewImage(session: GeckoSession, previewImageUrl: String) {}
    
    func onFocusRequest(session: GeckoSession) {
        guard selectedTab?.session === session else {
            return
        }
        
        sessionManager.activate(session)
    }
    
    func onCloseRequest(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }
        removeTab(at: location.index, mode: location.mode)
    }
    
    func onFullScreen(session: GeckoSession, fullScreen: Bool) {
        guard selectedTab?.session === session else {
            return
        }
        
        delegate?.tabManager(self, didChangeFullscreen: fullScreen, for: session)
    }
    
    func onMetaViewportFitChange(session: GeckoSession, viewportFit: String) {}
    
    func onProductUrl(session: GeckoSession) {}
    
    func onContextMenu(session: GeckoSession, screenX: Int, screenY: Int, element: ContextElement) {
        guard selectedTab?.session === session else {
            return
        }
        
        let hasImageSource = element.type == .image && element.srcUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLink = element.linkUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasImageSource || hasLink else {
            return
        }
        
        delegate?.tabManager(self, didRequestContextMenuAt: CGPoint(x: screenX, y: screenY), for: element, in: session)
    }
    
    // CHANGED - both used to call removeTab, deleting the tab outright.
    // See fix_preserve_tabs_on_content_process_death.py's docstring.
    //
    // Caught directly in the log: twenty content processes died during
    // a suspension and twenty tabs were deleted one at a time on
    // resume, counting the persisted list down 18 -> 0 in under a
    // second, with tabRemoval never firing because these were
    // individual deletions rather than removeAllTabs.
    //
    // onKill in particular is iOS reclaiming a backgrounded content
    // process under memory pressure - routine, not an error - and
    // destroying the user's tab over it is plainly wrong.
    func onCrash(session: GeckoSession) {
        recoverTabAfterSessionLoss(session: session, reason: "crash")
    }
    
    func onKill(session: GeckoSession) {
        recoverTabAfterSessionLoss(session: session, reason: "kill")
    }
    
    // Mirrors evictSessionIfNeeded, which already proves a tab can
    // outlive its Gecko session: close it, make a fresh one, and mark
    // the URL pending so it reloads on next use. The tab keeps its
    // identity, position and history.
    private func recoverTabAfterSessionLoss(session: GeckoSession, reason: String) {
        guard let location = tabLocation(for: session) else {
            return
        }
        
        let tab = tabs(for: location.mode)[location.index]
        let isPrivate = location.mode == .private

        // Recovery replaces the session and reloads on its own; a
        // watchdog left armed here would fire against the fresh session
        // and double-load.
        clearLoadWatchdog(for: tab, signal: "sessionRecovery")

        // ADDED - see fix_defer_respawns_while_inactive.py.
        //
        // createSession(.immediate) below opens the window on the
        // spot, which spawns the replacement NSExtension process. A
        // process spawned while the app is backgrounded is suspended
        // mid-launch, cannot answer the synchronous XPC iOS sends
        // every hosted extension on the next willEnterForeground, and
        // the watchdog kills the app for the hang - 0x8BADF00D, on
        // device: onKill at 22:29:06.67 during a PiP background stay,
        // replacement pid spawned 54ms later, main thread dead from
        // the moment the user tapped back in at 22:29:12.95. The dead
        // session stays on the tab, inert, until the drain at
        // didBecomeActive re-enters this method.
        if UIApplication.shared.applicationState != .active {
            if !deferredSessionRecoveries.contains(where: { $0.tabID == tab.id }) {
                deferredSessionRecoveries.append((tabID: tab.id, reason: reason))
            }
            logger(String(format: "tabRecovery: content process %@ for tab %@ while app is not active - deferring respawn until didBecomeActive", reason, tab.id.uuidString))
            return
        }

        // Nothing to reload to - keeping it would leave a permanently
        // blank entry, so removal is still right here.
        guard let url = displayedURL(for: tab) else {
            logger(String(format: "tabRecovery: content process %@ for tab %@ with no restorable URL - removing", reason, tab.id.uuidString))
            removeTab(at: location.index, mode: location.mode)
            return
        }
        
        logger(String(format: "tabRecovery: content process %@ for tab %@ - preserving and marking for restore (%@)", reason, tab.id.uuidString, loggableURL(url, isPrivate: isPrivate)))
        
        sessionManager.close(tab.session)
        tab.session = createSession(tabID: tab.id, url: url, windowId: nil, isPrivate: isPrivate)
        tab.state.restoreState = .pending(url)
        tab.state.navigationState = sessionManager.restoreNavigation(for: tab.id, isPrivate: isPrivate)
        
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        
        // Unlike eviction, which deliberately never touches the
        // on-screen tab, a crash gives no choice - the session is
        // already gone. Leaving the selected tab merely pending is what
        // leaves a blank page staring back, so restore it now rather
        // than waiting for it to be reselected.
        if tab === selectedTab {
            loadRestoredURLIfNeeded(for: location.index, mode: location.mode)
        }
    }

    /// Runs the recoveries parked while the app was not active - see
    /// the deferral in recoverTabAfterSessionLoss and
    /// fix_defer_respawns_while_inactive.py. Called from the
    /// didBecomeActive observer, so the app is genuinely active and
    /// the foreground cascade - with its synchronous per-extension
    /// XPC - is over before any process spawns.
    private func drainDeferredSessionRecoveries() {
        guard !deferredSessionRecoveries.isEmpty else {
            return
        }
        let parked = deferredSessionRecoveries
        deferredSessionRecoveries = []
        logger(String(format: "tabRecovery: draining %d recovery(ies) deferred while inactive", parked.count))
        for entry in parked {
            guard let location = tabLocation(for: entry.tabID) else {
                // Closed while parked - nothing left to recover.
                continue
            }
            let tab = tabs(for: location.mode)[location.index]
            // sleepBackgroundedTabs may have rebuilt this tab while it
            // was parked (a memory warning mid-background evicts it:
            // dead session closed, fresh pending one in place - the
            // same end state recovery produces). Recovering again
            // would close the healthy replacement.
            guard case .none = tab.state.restoreState else {
                logger(String(format: "tabRecovery: tab %@ already rebuilt while parked - skipping", entry.tabID.uuidString))
                continue
            }
            recoverTabAfterSessionLoss(session: tab.session, reason: entry.reason)
        }
    }
    
    // NEVER CALLED. The event bridge has dispatch cases for
    // firstContentfulPaint and paintStatusReset and none for first
    // composite, so nothing in this port delivers it - which is why no
    // log in this project has ever contained a "first composite after"
    // line, only the 8-second complaints from a watch that could not be
    // satisfied. The work moved to onFirstContentfulPaint below.
    func onFirstComposite(session: GeckoSession) {}
    
    /// The paint signal this port actually delivers.
    ///
    /// First contentful paint is not first composite - it fires when the
    /// page paints content, not when the compositor first presents a
    /// frame - but it is the one that arrives, and it answers the
    /// question both callers are really asking: has this tab put
    /// anything on screen yet.
    func onFirstContentfulPaint(session: GeckoSession) {
        // Proof the engine delivers the paint signal on this build -
        // the committed-page escalation is gated on having seen it.
        hasObservedFirstPaintSignal = true
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        if let wait = paintWaits.removeValue(forKey: tab.id) {
            wait.workItem.cancel()
            NSLog("[PaintWatch] tab %@ first contentful paint after %.2fs (%@)",
                  tab.id.uuidString,
                  CFAbsoluteTimeGetCurrent() - wait.startedAt,
                  wait.url)
        }
        tab.state.hasFirstComposite = true
        delegate?.tabManager(self, didFirstCompositeFor: tab.id)
    }
    
    func onPaintStatusReset(session: GeckoSession) {}
    
    func onPageBackgroundColorChange(session: GeckoSession, color: UIColor) {
        sessionManager.setPageBackgroundColor(color, for: session)
        guard let location = tabLocation(for: session) else {
            return
        }
        
        guard location.mode == selectedTabMode else {
            return
        }
        delegate?.tabManager(self, didUpdateTabAt: location.index, reason: .pageBackgroundColor)
    }
    
    func onWebAppManifest(session: GeckoSession, manifest: Any) {
        guard let location = tabLocation(for: session),
              let url = remoteURL(from: tabs(for: location.mode)[location.index].url) else {
            return
        }
        
        let tab = tabs(for: location.mode)[location.index]
        let tabID = tab.id
        let expectedURL = url.absoluteString
        cancelFaviconTask(for: tabID)
        faviconTasks[tabID] = Task { [weak self] in
            guard let self else {
                return
            }
            
            let image = await self.faviconStore.favicon(for: url, webAppManifest: manifest)
            guard !Task.isCancelled else {
                return
            }
            
            await MainActor.run {
                self.applyResolvedFavicon(image, toTabWithID: tabID, expectedURL: expectedURL)
            }
        }
    }
    
    func onSlowScript(session: GeckoSession, scriptFileName: String) async -> SlowScriptResponse {
        return .halt
    }
    
    func onShowDynamicToolbar(session: GeckoSession) {}
    
    func onCookieBannerDetected(session: GeckoSession) {}
    
    func onCookieBannerHandled(session: GeckoSession) {}
    
    func onExternalResponse(session: GeckoSession, response: ExternalResponseInfo) async -> Bool {
        return await delegate?.tabManager(
            self,
            shouldStartExternalResponse: response,
            for: session
        ) ?? false
    }
    
    func onExternalResponseProgress(
        session: GeckoSession,
        localFilePath: String,
        bytesReceived: Int64
    ) -> Bool {
        return delegate?.tabManager(
            self,
            shouldContinueExternalResponseAt: localFilePath,
            bytesReceived: bytesReceived
        ) ?? false
    }
    
    func onExternalResponseComplete(session: GeckoSession, localFilePath: String, succeeded: Bool) {
        delegate?.tabManager(
            self,
            didCompleteExternalResponseAt: localFilePath,
            succeeded: succeeded
        )
    }
    
    func onSavePdf(session: GeckoSession, request: SavePdfInfo) {
        guard let download = DownloadStore.shared.pendingDownload(from: request) else {
            return
        }
        
        delegate?.tabManager(self, didRequestDownload: download)
    }
}

extension TabManagerImplementation: NavigationDelegate {
    func onLocationChange(
        session: GeckoSession,
        url: String?,
        permissions: [ContentPermission],
        hasUserGesture: Bool,
        isSameDocument: Bool
    ) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]

        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Only a location change for something other than about:blank
        // clears the watchdog. "The session is alive" is NOT proof the
        // pending load will be handled - a rebuilt window's initial
        // about:blank commits within a second while the requested load
        // can still have been swallowed, which is precisely the failure
        // the watchdog exists to catch.
        //
        // Nor is a SAME-DOCUMENT change while a load is pending: a
        // pushState or hashchange from the page being LEFT - any SPA -
        // used to be indistinguishable from a real commit here,
        // clearing the watchdog and flipping displayState to
        // .committed with the OLD page's URL - the address bar visibly
        // reverted and the pending load lost its only protection: the
        // historical "press Go twice" hole through another event. The
        // engine reports the distinction now (isSameDocument; false on
        // an engine built without this fix's patch, which keeps the
        // old behavior exactly). A pending CROSS-document load can
        // never commit as a same-document change; the one same-doc
        // arrival that may commit the pending state is a typed
        // fragment jump within the current page. Input carrying a
        // fragment is therefore never filtered at all - the engine's
        // fixup can rewrite such a URL (inserted slash, punycode,
        // percent-encoding) beyond what string matching can follow, so
        // for that rare input the pre-fix behavior is kept wholesale.
        // The exact-match arm then covers the fragmentless shape of
        // the same corner: typing the current page's own URL, which
        // the engine may resolve same-document by stripping the hash.
        let isOutgoingPageNoise: Bool
        if isSameDocument, case let .pending(pendingInput) = tab.state.displayState,
           !pendingInput.contains("#") {
            isOutgoingPageNoise = URLUtils.normalizedURLMatchString(from: url ?? "")
                != URLUtils.normalizedURLMatchString(from: pendingInput)
        } else {
            isOutgoingPageNoise = false
        }
        if let normalizedURL, !normalizedURL.isEmpty, !normalizedURL.hasPrefix("about:blank"),
           !isOutgoingPageNoise {
            clearLoadWatchdog(for: tab, signal: "locationChange")
        }
        
        let shouldPreserveDisplayedURL = hasDisplayURL(for: tab)
        
        if let normalizedURL,
           normalizedURL.hasPrefix("about:blank"),
           (tab.state.suppressInitialNavigation || shouldPreserveDisplayedURL) {
            logger(String(format: "tabLocation: suppressed about:blank for tab %@ (suppressInitialNavigation=%@, shouldPreserveDisplayedURL=%@)", tab.id.uuidString, String(tab.state.suppressInitialNavigation), String(shouldPreserveDisplayedURL)))
            return
        }
        if let normalizedURL {
            logger(String(format: "tabLocation: tab %@ location changed to %@ (not suppressed)", tab.id.uuidString, loggableURL(normalizedURL, isPrivate: tab.isPrivate)))
        }
        
        if let normalizedURL, !normalizedURL.isEmpty {
            tab.state.suppressInitialNavigation = false
        }
        
        if let url {
            sessionManager.updateSettings(of: session, for: url, tabID: tab.id)
            permissionCoordinator.restorePermissions(for: session, at: url)
        }
        
        if let url {
            if let currentURL = tab.url,
               currentURL != url {
                delegate?.tabManager(
                    self,
                    captureHistoryThumbnailForTabAt: location.index,
                    mode: location.mode,
                    url: currentURL
                )
            }
            
            tab.url = url
            recordNavigation(url, for: tab)
        } else {
            tab.url = url
        }
        if !isOutgoingPageNoise {
            tab.state.displayState = .committed
        }
        // A cross-document commit retires the outgoing page's reported
        // background color along with its pixels. The color cache is
        // per-session and nothing else clears it on navigation, so the
        // strip under the toolbar (pillUnderlayView) and the backing
        // behind the engine view kept wearing the OLD page's color for
        // the entire load of the new one - a not-black band under the
        // toolbar until the incoming page's own style flush reports
        // its color, which under a slow hydration is seconds away.
        // Reset to the theme default the rest of this pipeline already
        // uses; the incoming page's real color overwrites it at its
        // first style flush, which is strictly after this commit. A
        // same-document change keeps its color - the document did not
        // change, so its color did not either.
        if !isSameDocument {
            sessionManager.setPageBackgroundColor(.systemBackground, for: session)
            if location.mode == selectedTabMode {
                delegate?.tabManager(self, didUpdateTabAt: location.index, reason: .pageBackgroundColor)
            }
        }
        tab.favicon = nil

        notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        scheduleFaviconUpdate(forTabAt: location.index, mode: location.mode)
        persistState()

        // Every cross-document commit on the selected tab restarts the
        // paint clock - not only the typed loads that armed it via
        // browse(). The captured gap: a site's own re-navigation
        // (youtube.com's hop to m.youtube.com) swapped content
        // processes after a successful first paint, the replacement
        // never painted its document, and no watchdog of any kind was
        // armed for it - the escalation that heals exactly this for
        // typed loads never engaged. For a browse()-armed load this
        // re-arm merely moves the 8s deadline from submit time to
        // commit time. Same-document changes and noise are excluded
        // above; background tabs and non-web URLs are excluded here -
        // the escalation's own guards would discard them at fire time
        // anyway, so arming them buys only log noise.
        if !isSameDocument, !isOutgoingPageNoise,
           tab === selectedTab,
           let committedURL = url,
           remoteURL(from: committedURL) != nil {
            armPaintWatch(
                for: tab.id,
                url: loggableURL(committedURL, isPrivate: tab.isPrivate),
                retryURL: committedURL
            )
        }

        // Re-detect on location change, not only at PageStop. Facebook,
        // YouTube and Reddit are single-page apps: moving from the feed
        // to messages swaps the whole bottom of the page - adding or
        // removing a composer - through pushState, which fires this but
        // never fires another PageStop. Without this the tab keeps the
        // verdict from its first load, which is exactly the case where
        // the composer ended up behind the pill.
        //
        // Cheap enough to repeat: the detector short-circuits on the
        // first matching stylesheet rule, and its fallback is three
        // elementFromPoint probes regardless of DOM size.
        //
        // Seed from what this origin did last time FIRST, so the
        // reservation is already right while the page paints. Detection
        // below then confirms or corrects it. Without this the verdict
        // only lands after first paint and the page visibly jumps - the
        // YouTube bounce that a refresh did not show, because a refresh
        // still had the previous verdict in hand.
        if applyRememberedReservation(to: tab, url: url), selectedTab === tab {
            delegate?.tabManagerDidUpdateSafeAreaUsage(self)
        }

        detectSafeAreaInsetUsage(for: tab, session: session, reason: "locationChange")

        // A first-ever visit has nothing remembered, and at this instant
        // the new document usually has neither its stylesheets parsed nor
        // its bottom bar built - the detector answers "no" and the page
        // then settles into something else, which is why such a load
        // needed a manual refresh to come good.
        //
        // These re-asks let it settle by itself. The detector is cheap
        // (a stylesheet scan that short-circuits on the first match, else
        // three elementFromPoint probes regardless of DOM size) and only
        // triggers a relayout when the verdict actually moves, so a page
        // that was already right pays nothing but the query.
        //
        // Spread rather than repeated at one delay because sites differ
        // by an order of magnitude in when their chrome appears: a static
        // page is done by 400ms, an SPA that builds its nav bar after
        // hydration often is not settled before ~2s.
        for delay in [0.4, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak tab, weak session] in
                guard let self, let tab, let session,
                      self.tabLocation(for: session) != nil else {
                    return
                }
                self.detectSafeAreaInsetUsage(
                    for: tab, session: session, reason: "settle+\(delay)s")
            }
        }
    }

    /// Asks the content process whether this page reserves space at the
    /// bottom - either through env(safe-area-inset-bottom) in CSS the
    /// scan can read, or by having a real bottom bar pinned there - so
    /// the condensed pill knows whether to reserve a strip above itself.
    /// See fix_native_safe_area_detection.py.
    ///
    /// PageStop rather than an earlier hook deliberately: the previous
    /// WebExtension scanned at document_idle, which on a heavy site runs
    /// before the CSS it is looking for exists. By PageStop, loading is
    /// genuinely complete. Also runs on location change for SPA routes,
    /// which never reach PageStop again.
    ///
    /// The pill reads the result lazily when it is about to condense, so
    /// this triggers no relayout by itself.
    /// What each origin was last found to do about its bottom edge.
    ///
    /// Detection can only answer once the page has parsed its CSS, which
    /// is after first paint, so a page whose reservation differs from the
    /// default visibly jumps when the verdict lands. On device that was
    /// YouTube "bouncing" on first load but being correct on refresh -
    /// refresh works precisely because the tab still holds the previous
    /// verdict and applies it before the page paints.
    ///
    /// This gives every tab that same head start: the origin's remembered
    /// verdict is applied the moment navigation commits, and detection
    /// only corrects it afterwards if the page really did change. The
    /// first ever visit to a site still resolves late, once.
    ///
    /// Keyed by host rather than full URL: sites are consistent about
    /// this across their own pages, and per-URL would almost never hit.
    /// Persisted, deliberately. An in-memory cache is empty at every
    /// launch, so the first load of a site after starting the app - the
    /// load anyone actually notices - still resolved late and still
    /// jumped. Remembering across launches is what makes the very first
    /// load of a known site correct.
    ///
    /// A wrong entry is applied immediately and then corrected by the
    /// next detection, so the worst case is one stale frame rather than
    /// a persistent error; UserDefaults is the right weight for that.
    private static let reservationStoreKey = "Reynard.SafeArea.ReservationByHost"

    private static var reservationByHost: [String: GeckoSession.BottomReservation] = loadReservations()

    /// Hosts whose verdict is known ahead of any visit.
    /// tv.apple.com: the player is a full-viewport fixed overlay whose
    /// bottom controls only env() can reach; its CSS is CDN-served, so
    /// the stylesheet scan cannot prove it reads env, and the first
    /// detection can run before the player exists. The overlay probe
    /// reaches the same verdict once playback starts - the seed just
    /// makes the very first player paint correct too.
    /// m.twitch.tv: the documented env-reading page whose 'Open in App'
    /// sheet is NOT a fixed root-content layer - only env() can reach
    /// it (the pre-merge branch proved env at the pill height lifts
    /// it), while its CDN CSS keeps the stylesheet scan blind and the
    /// sheet's non-fixed position keeps the bottom-edge probe blind.
    private static let seededReservations: [String: GeckoSession.BottomReservation] = [
        "tv.apple.com": .needsViewportShrink,
        "m.twitch.tv": .needsViewportShrink,
        // Redirect aliases: the tab enters as twitch.tv or
        // www.twitch.tv and only becomes m.twitch.tv after the
        // ?desktop-redirect chain settles - a device log showed a
        // condense inside that window taking the margin branch
        // because the m.twitch.tv seed had no host to match yet.
        "twitch.tv": .needsViewportShrink,
        "www.twitch.tv": .needsViewportShrink,
    ]

    /// Bumped whenever seededReservations changes. An install that
    /// visited a seeded host BEFORE the seed existed has a stale
    /// verdict persisted, and a seed that only fills absences loses
    /// to it - so on a version bump the seeds are applied OVER the
    /// persisted entries exactly once; after that, live detection
    /// overwrites them as usual.
    private static let seedVersion = 4
    private static let seedVersionKey = "Reynard.SafeArea.SeedVersion"

    /// Bumped whenever the DETECTOR's verdict semantics change, as
    /// distinct from the seed list above. See loadReservations.
    private static let classifierVersion = 2
    private static let classifierVersionKey = "Reynard.SafeArea.ClassifierVersion"

    /// The user's pill-clearance list (Settings > General >
    /// Compatibility > Toolbar > Pill Clearance Sites): hosts pinned
    /// to .needsViewportShrink by hand, for sites whose bottom UI the
    /// automatic detector cannot classify correctly. Unlike the seeds
    /// above this is a PIN: read live so Settings edits apply on the
    /// next load, consulted before the persisted store, and never
    /// overwritten by live detection - a pin is a decision, not a
    /// guess. Matches a listed host and its subdomains.
    static func pinnedShrinkVerdict(forHost host: String) -> GeckoSession.BottomReservation? {
        let needle = host.lowercased()
        for entry in Prefs.CompatibilitySettings.pillClearanceSites.split(separator: ",") {
            var trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let schemeRange = trimmed.range(of: "://") {
                trimmed = String(trimmed[schemeRange.upperBound...])
            }
            trimmed = String(trimmed.split(separator: "/").first ?? "")
            trimmed = String(trimmed.split(separator: ":").first ?? "")
            guard !trimmed.isEmpty else {
                continue
            }
            if needle == trimmed || needle.hasSuffix("." + trimmed) {
                return .needsViewportShrink
            }
        }
        return nil
    }

    private static func loadReservations() -> [String: GeckoSession.BottomReservation] {
        let defaults = UserDefaults.standard
        let applySeedsOverPersisted = defaults.integer(forKey: seedVersionKey) < seedVersion
        if applySeedsOverPersisted {
            defaults.set(seedVersion, forKey: seedVersionKey)
        }
        // The learned store was populated by an older detector whose
        // semantics no longer hold, so it would keep steering pages
        // wrongly until each host happened to be re-visited and
        // re-detected - most visibly, env-reading hosts learned as
        // readsSafeAreaInset whose bottom bars the compositor margin
        // lifts fine. Dropped back to the seeds exactly once per
        // semantics change; live detection repopulates with the new
        // meaning, and the pill-clearance pins are unaffected (they
        // are read live from the preference, not from this store).
        //
        // 2: env() became a fallback rather than a verdict - the
        //    liftable-bar cutout
        //    (fix_pill_cutout_for_liftable_bottom_bars.py).
        if defaults.integer(forKey: classifierVersionKey) < classifierVersion {
            defaults.set(classifierVersion, forKey: classifierVersionKey)
            defaults.removeObject(forKey: reservationStoreKey)
            return seededReservations
        }
        guard let raw = defaults.dictionary(forKey: reservationStoreKey) as? [String: String] else {
            return seededReservations
        }
        var reservations = raw.reduce(into: [String: GeckoSession.BottomReservation]()) { result, entry in
            switch entry.value {
            case "readsSafeAreaInset": result[entry.key] = .readsSafeAreaInset
            case "hasBottomBar": result[entry.key] = .hasBottomBar
            case "none": result[entry.key] = GeckoSession.BottomReservation.none
            case "needsViewportShrink": result[entry.key] = .needsViewportShrink
            default: break
            }
        }
        for (host, reservation) in seededReservations
        where applySeedsOverPersisted || reservations[host] == nil {
            reservations[host] = reservation
        }
        return reservations
    }

    /// Drops every remembered bottom-reservation verdict, on disk and in
    /// memory. Keyed by host, so the store is a browsing-history-shaped
    /// list and belongs with the history it was derived from - clearing
    /// history must clear this too.
    static func clearReservationCache() {
        // Back to the built-in seeds, not to empty: seeds are shipped
        // knowledge, not derived from browsing history.
        reservationByHost = seededReservations
        UserDefaults.standard.removeObject(forKey: reservationStoreKey)
    }

    private static func persistReservations() {
        let raw: [String: String] = reservationByHost.reduce(into: [:]) { result, entry in
            switch entry.value {
            case GeckoSession.BottomReservation.readsSafeAreaInset:
                result[entry.key] = "readsSafeAreaInset"
            case GeckoSession.BottomReservation.hasBottomBar:
                result[entry.key] = "hasBottomBar"
            case GeckoSession.BottomReservation.none:
                result[entry.key] = "none"
            case GeckoSession.BottomReservation.needsViewportShrink:
                result[entry.key] = "needsViewportShrink"
            }
        }
        UserDefaults.standard.set(raw, forKey: reservationStoreKey)
    }

    /// Applies the remembered verdict for a newly committed URL, so the
    /// reservation is right before the page paints rather than after.
    /// Returns true when it changed the tab's current verdict.
    @discardableResult
    private func applyRememberedReservation(to tab: Tab, url: String?) -> Bool {
        guard let host = url.flatMap({ URL(string: $0)?.host }),
              let remembered = Self.pinnedShrinkVerdict(forHost: host) ?? Self.reservationByHost[host],
              tab.state.bottomReservation != remembered else {
            return false
        }
        tab.state.bottomReservation = remembered
        logger(String(format: "safeArea: tab %@ pre-seeded %@ for %@",
                      tab.id.uuidString, String(describing: remembered), host))
        return true
    }

    private func detectSafeAreaInsetUsage(
        for tab: Tab,
        session: GeckoSession,
        reason: String
    ) {
        Task { @MainActor in
            // DIAGNOSTIC - see
            // fix_log_safe_area_detection_result.py. Without this the
            // log is silent whether the query succeeds, returns false,
            // or fails outright, since dispatcher.query is wrapped in
            // try? and nil is treated as "no answer". That made a
            // missing actor case indistinguishable from a page that
            // simply does not use safe-area CSS.
            if var reservation = await session.bottomReservation() {
                // A user pin outranks live detection: the pin exists
                // exactly because the automatic detector cannot
                // classify this site (Settings > Compatibility >
                // Toolbar > Pill Clearance Sites). The store still
                // receives the detector's RAW verdict below, so
                // removing the pin restores automatic behavior with
                // nothing stale left behind.
                let rawReservation = reservation
                if let host = tab.url.flatMap({ URL(string: $0)?.host }),
                   let pinned = Self.pinnedShrinkVerdict(forHost: host) {
                    reservation = pinned
                }
                let changed = tab.state.bottomReservation != reservation
                logger(String(format: "safeArea: tab %@ reservation=%@ (%@%@)",
                              tab.id.uuidString,
                              String(describing: reservation),
                              reason,
                              changed ? ", CHANGED" : ""))
                tab.state.bottomReservation = reservation

                // Remember it for this origin, so the next load of the
                // same site starts with the right reservation instead of
                // discovering it after first paint.
                //
                // NEVER for a private tab. This store is written to
                // UserDefaults and survives relaunch, so recording hosts
                // from private browsing would leave a
                // browsing-history-shaped list of them on disk - the one
                // thing private mode exists to avoid. Not even kept in
                // memory: the cache is process-wide and read by normal
                // tabs, so a private-only host appearing there is still a
                // leak. The cost is that private tabs resolve their
                // verdict late, which is a layout nicety, not privacy.
                let isPrivate = self.privateTabs.contains { $0 === tab }
                if !isPrivate,
                   let host = tab.url.flatMap({ URL(string: $0)?.host }),
                   Self.reservationByHost[host] != rawReservation {
                    Self.reservationByHost[host] = rawReservation
                    Self.persistReservations()
                }

                // Only relayout when the verdict actually moved, and
                // only for the tab on screen - an SPA route change in a
                // background tab must not disturb the visible one.
                if changed, self.selectedTab === tab {
                    self.delegate?.tabManagerDidUpdateSafeAreaUsage(self)
                }
            } else {
                // Only this case indicates something is actually wrong -
                // the actor case missing from the build, or the query
                // failing. The existing value is deliberately left
                // alone rather than being overwritten with a guess.
                logger(String(format: "safeArea: tab %@ - no answer from the content process (%@)", tab.id.uuidString, reason))
            }
        }
    }

    
    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.state.sessionNavigationAvailability = .available(
            back: canGoBack,
            forward: tab.state.sessionNavigationAvailability.canGoForward
        )
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.state.sessionNavigationAvailability = .available(
            back: tab.state.sessionNavigationAvailability.canGoBack,
            forward: canGoForward
        )
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        let disposition = await externalAppLinkRouter.handle(ExternalAppLinkRequest(
            uri: request.uri,
            triggerUri: request.triggerUri,
            source: .navigation,
            hasUserGesture: request.hasUserGesture,
            isRedirect: request.isRedirect
        ))
        
        let decision: AllowOrDeny = disposition == .opened ? .deny : .allow

        if decision == .deny {
            // The external-app router took this navigation: Gecko will
            // never load it, which under the stricter acknowledgment
            // rule would read as silence and re-trigger the router 3s
            // later - a second bounce out of the browser. A DENY is an
            // answer, so it clears the watchdog.
            await MainActor.run {
                guard let location = self.tabLocation(for: session) else {
                    return
                }
                let tab = self.tabs(for: location.mode)[location.index]
                self.clearLoadWatchdog(for: tab, signal: "loadDenied")
            }
        }
        
        // A .deny means Gecko never loads the page and nothing else
        // records that it happened - from outside it looks like the
        // navigation simply did nothing. See
        // fix_log_navigation_decisions.py.
        logger(String(format: "navDecision: %@ %@ (source=navigation, gesture=%@, redirect=%@, disposition=%@)",
                      decision == .deny ? "DENY" : "ALLOW",
                      request.uri,
                      String(request.hasUserGesture),
                      String(request.isRedirect),
                      String(describing: disposition)))
        
        return decision
    }
    
    func onSubframeLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        return .allow
    }

    func onLoadError(session: GeckoSession, uri: String?, error: Int, errorModule: Int, errorClass: Int) -> String? {
        guard let location = tabLocation(for: session) else {
            return nil
        }
        let tab = tabs(for: location.mode)[location.index]

        // One line per failed navigation, mirroring the LoadUri log: a
        // load that died used to leave no app-side trace at all.
        NSLog("[LoadError] tab %@ failed %@ (error=%d module=%d class=%d)",
              tab.id.uuidString, uri ?? "?", error, errorModule, errorClass)

        // Nothing will paint out of a failed load, and an escalating
        // paint watch must not re-dispatch a load the engine just
        // declared dead.
        if let wait = paintWaits.removeValue(forKey: tab.id) {
            wait.workItem.cancel()
        }

        // A still-armed ladder for a pending user load is LEFT ARMED:
        // this error is the flaky-network variant of "press Go twice"
        // (cold DNS/TLS dying on a redirect leg), and the ladder's own
        // re-dispatch is the automated second press. The spinner stays,
        // honestly - a retry is coming.
        if case .pending = tab.state.displayState, loadWatchdogs[tab.id] != nil {
            return nil
        }

        // Otherwise the failure is final. The stuck progress bar was
        // the only thing the user ever saw of it.
        tab.state.loadingState = .idle
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        return nil
    }

    func onLinkActivated(
        session: GeckoSession,
        uri: String,
        triggerUri: String,
        isDefaultPrevented: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await externalAppLinkRouter.handle(ExternalAppLinkRequest(
                uri: uri,
                triggerUri: triggerUri,
                source: .trustedLink,
                hasUserGesture: true,
                isDefaultPrevented: isDefaultPrevented
            ))
        }
    }

    func onExternalProtocolRequest(
        session: GeckoSession,
        uri: String,
        triggerUri: String?,
        hasUserGesture: Bool
    ) async -> Bool {
        let disposition = await externalAppLinkRouter.handle(ExternalAppLinkRequest(
            uri: uri,
            triggerUri: triggerUri,
            source: .externalProtocol,
            hasUserGesture: hasUserGesture
        ))
        return disposition == .opened || disposition == .handled
    }

    @MainActor
    private static func openExternalApplication(_ attempt: ExternalAppLinkAttempt) async -> Bool {
        let options: [UIApplication.OpenExternalURLOptionsKey: Any]
        switch attempt.mode {
        case .universalLink:
            options = [.universalLinksOnly: true]
        case .externalScheme:
            options = [:]
        }

        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(attempt.url, options: options) { opened in
                continuation.resume(returning: opened)
            }
        }
    }
    
    func onNewSession(session: GeckoSession, uri: String, windowId: String) async -> GeckoSession? {
        let sourceLocation = tabLocation(for: session)
        let mode = sourceLocation?.mode ?? selectedTabMode
        let sourceIsPrivate = mode == .private
        let tabID = UUID()
        let newSession = sessionManager.createSession(
            url: uri,
            tabID: tabID,
            isPrivate: sourceIsPrivate,
            opening: .external,
            delegates: sessionDelegates
        )
        let newTab = Tab(id: tabID, session: newSession, isPrivate: sourceIsPrivate)
        permissionCoordinator.restorePermissions(for: newSession, at: uri)
        newTab.url = uri
        newTab.favicon = cachedFavicon(for: uri)
        recordNavigation(uri, for: newTab)
        
        let insertionIndex = sourceLocation.map { $0.index + 1 }
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(newTab)
            } else {
                regularTabs.insert(newTab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(newTab)
            } else {
                privateTabs.insert(newTab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        notifyUpdate(at: index, mode: mode, reason: .location)
        scheduleFaviconUpdate(forTabAt: index, mode: mode)
        persistState()
        if let previousSession = selectedTab?.session,
           previousSession !== newSession {
            sessionManager.deactivate(previousSession)
        }
        selectedTabMode = mode
        delegate?.tabManager(self, animateNewTabSelectionAt: index) { [weak self] in
            self?.selectTab(at: index, mode: mode)
        }
        return newSession
    }
}

@available(iOS 15.0, *)
extension TabManagerImplementation: PictureInPictureCoordinatorDelegate {
    func pictureInPictureCoordinator(
        _ coordinator: PictureInPictureCoordinator,
        restore session: GeckoSession
    ) -> Bool {
        guard let location = tabLocation(for: session) else {
            return false
        }
        selectTab(at: location.index, mode: location.mode)
        return true
    }
}

extension TabManagerImplementation: HistoryDelegate {
    func onVisited(
        session: GeckoSession,
        url: String,
        lastVisitedURL: String?,
        flags: HistoryVisitFlags
    ) async -> Bool {
        guard !session.isPrivateMode,
              flags.contains(.topLevel),
              !flags.contains(.unrecoverableError),
              let pageURL = remoteURL(from: url) else {
            return false
        }
        
        let title = tabLocation(for: session).map { tabs(for: $0.mode)[$0.index].title } ?? ""
        return await historyStore.recordVisitImmediately(
            url: pageURL,
            title: title,
            isRedirectSource: flags.contains(.redirectSource) || flags.contains(.redirectSourcePermanent)
        )
    }
    
    func getVisited(session: GeckoSession, urls: [String]) async -> [Bool]? {
        guard !session.isPrivateMode else {
            return Array(repeating: false, count: urls.count)
        }
        
        return await historyStore.visitedStatuses(for: urls)
    }
}

extension TabManagerImplementation: ProgressDelegate {
    func onPageStart(session: GeckoSession, url: String) {
        systemMediaSession.navigationStarted(in: session)
        pictureInPictureCoordinator?.navigationStarted(in: session)
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]

        let normalizedPageStartURL = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // A pageStart for about:blank is a rebuilt window settling, not
        // the requested load being taken - it must not disarm the
        // watchdog.
        //
        // A real pageStart no longer CLEARS the watchdog either - it
        // STAGES it. pageStart fires when the request starts, before
        // the network answers, so it proves the engine is alive and
        // nothing else. See stageLoadWatchdogForCommit.
        if !normalizedPageStartURL.hasPrefix("about:blank") {
            stageLoadWatchdogForCommit(for: tab, signal: "pageStart")
        }

        if normalizedPageStartURL.hasPrefix("about:blank"),
           hasDisplayURL(for: tab) {
            tab.state.isSuppressingInitialBlankPageLoad = true
            return
        }
        
        sessionManager.trackingProtection.clearBlockedTrackers(for: session)
        if sessionManager.needsSettingsUpdate(
            to: session,
            currentURL: tab.url,
            requestedURL: url,
            tabID: tab.id
        ) {
            loadURL(url, in: tab)
            // This restart CANCELS the in-flight navigation and issues
            // a fresh LoadUri mid-flight - across a twitch.tv ->
            // m.twitch.tv style redirect that lands right in the
            // cross-site process switch, which is the documented window
            // for a LoadUri to be swallowed whole. browse() pairs every
            // load with a watchdog; this one ran bare, so a swallowed
            // restart left the tab pending forever and the next Go
            // press was the only recovery. Re-arm around it, keyed to
            // the NEW url so a retry re-issues what was actually
            // cancelled. Only a user-initiated load carries .pending
            // state; SPA and engine-initiated traffic stays out of the
            // ladder.
            if case let .pending(pendingInput) = tab.state.displayState {
                armLoadWatchdog(for: tab, pendingInput: pendingInput, retryURL: url)
            }
        }
        
        tab.state.loadingState = .loading(progress: 0)
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)

        // The chrome expands for a NEW DOCUMENT, and pageStart is the
        // signal that means one: same-document navigations
        // (pushState/replaceState/fragment) never produce a pageStart,
        // while every real load does. Driving this from the .location
        // update had the chrome popping open mid-scroll on single-page
        // apps. about:blank is a rebuilt window settling, not a
        // document the user asked for, so it does not qualify.
        if tab === selectedTab, !normalizedPageStartURL.hasPrefix("about:blank") {
            delegate?.tabManagerDidStartDocumentLoad(self)
        }
    }
    
    func onPageStop(session: GeckoSession, success: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]

        // No watchdog clear here, deliberately: a real load always
        // emits pageStart first, and the pageStop seen right after a
        // submit is dominated by the OUTGOING page finishing its
        // teardown - the exact signal that used to disarm the watchdog
        // while the new load had been swallowed.

        if tab.state.isSuppressingInitialBlankPageLoad {
            tab.state.isSuppressingInitialBlankPageLoad = false
            return
        }
        
        tab.state.loadingState = .idle
        
        // Ask the content process whether this page uses
        // env(safe-area-inset-bottom), so the condensed pill knows
        // whether to reserve space above itself. See
        // fix_native_safe_area_detection.py.
        //
        // PageStop rather than an earlier hook deliberately: the
        // previous WebExtension scanned at document_idle, which on a
        // heavy site runs before the CSS it is looking for exists. By
        // PageStop, loading is genuinely complete.
        //
        // The pill reads this lazily when it is about to condense, so
        // no relayout is triggered here.
        detectSafeAreaInsetUsage(for: tab, session: session, reason: "pageStop")

        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        notifyUpdate(at: location.index, mode: location.mode, reason: .thumbnail)
        delegate?.tabManager(self, didFinishLoading: session)
    }
    
    func onProgressChange(session: GeckoSession, progress: Int) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.state.loadingState = .loading(progress: Float(progress) / 100)
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
    }
}
