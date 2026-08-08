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
    
    private let promptCoordinator = PromptCoordinator(
        presenter: PromptPresenter()
    )
    private let selectionActionCoordinator = SelectionActionCoordinator(
        presenter: SelectionActionPresenter()
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
    private var selectionCounter = 0
    
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
    }
    
    private var memoryWarningObservationToken: NSObjectProtocol?
    
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
        }
    }
    
    deinit {
        hangWatchdog.stop()
        if let memoryWarningObservationToken {
            NotificationCenter.default.removeObserver(memoryWarningObservationToken)
        }
    }
    
    // MARK: - Tab Sleeping
    
    func sleepBackgroundedTabs() {
        NSLog("[TabMemory] Sleeping backgrounded tab sessions")
        for tab in regularTabs {
            evictSessionIfNeeded(for: tab, isPrivate: false)
        }
        for tab in privateTabs {
            evictSessionIfNeeded(for: tab, isPrivate: true)
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
        
        logger(String(format: "tabSleep: sleeping tab %@ (url=%@, suppressInitialNavigation was %@)", tab.id.uuidString, url, String(tab.state.suppressInitialNavigation)))
        sessionManager.close(tab.session)
        tab.session = createSession(tabID: tab.id, url: url, windowId: nil, isPrivate: isPrivate)
        tab.state.restoreState = .pending(url)
        tab.state.navigationState = sessionManager.restoreNavigation(for: tab.id, isPrivate: isPrivate)
        NSLog("[TabMemory] Slept background session for tab %@", tab.id.uuidString)
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
        
        store.emergencyPersistTabs(
            regularTabs: snapshot.regularTabs,
            privateTabs: snapshot.privateTabs,
            selectedRegularTabID: snapshot.selectedRegularTabID,
            selectedPrivateTabID: snapshot.selectedPrivateTabID,
            selectedTabMode: snapshot.selectedTabMode
        )
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
        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        }
        // A slept tab has had its session closed by
        // evictSessionIfNeeded, and load() on a closed session goes
        // nowhere - which is why a restored tab stayed blank until it was
        // refreshed by hand. See fix_reopen_session_before_restore.py.
        //
        // Replaced rather than reopened: SessionManager owns creation,
        // and a closed GeckoSession is not documented as reusable.
        if !tab.session.isOpen() {
            logger(String(format: "tabRestore: session for tab %@ was closed - creating a new one before loading", tab.id.uuidString))
            tab.session = createSession(
                tabID: tab.id,
                url: nil,
                windowId: nil,
                isPrivate: tab.isPrivate
            )
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
            mediaSession: systemMediaSession
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
                session: createSession(
                    tabID: snapshot.id,
                    url: snapshot.url,
                    windowId: nil,
                    isPrivate: false
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
                    isPrivate: true
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
        
        delegate?.tabManagerDidChangeTabs(self)
        
        selectTab(at: max(selectedIndex(for: selectedTabMode), 0), mode: selectedTabMode)
        return true
    }
    
    private func loadRestoredURLIfNeeded(for index: Int, mode: TabMode) {
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        guard case let .pending(url) = tab.state.restoreState else {
            logger(String(format: "tabRestore: tab at index %d has no pending restore (restoreState=%@) - nothing to do", index, String(describing: tab.state.restoreState)))
            return
        }
        
        logger(String(format: "tabRestore: RESTORING tab %@ (url=%@) - calling loadURL now", tab.id.uuidString, url))
        tab.state.restoreState = .none
        tab.state.suppressInitialNavigation = false
        loadURL(url, in: tab)
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
        
        tab.state.suppressInitialNavigation = false
        tab.state.displayState = .pending(navigationInput)
        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        }
        
        let navigationInputRange = NSRange(location: 0, length: (navigationInput as NSString).length)
        let shouldNavigateDirectly = lenientURLExpression.firstMatch(in: navigationInput, range: navigationInputRange) != nil
        
        if shouldNavigateDirectly {
            loadURL(navigationInput, in: tab)
            return
        }
        
        let searchDestination = SearchEngine.destination(for: navigationInput)
        loadURL(searchDestination, in: tab)
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
        isPrivate: Bool
    ) -> GeckoSession {
        return sessionManager.createSession(
            url: url,
            tabID: tabID,
            isPrivate: isPrivate,
            opening: .immediate(windowID: windowId),
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
        
        // Nothing to reload to - keeping it would leave a permanently
        // blank entry, so removal is still right here.
        guard let url = displayedURL(for: tab) else {
            logger(String(format: "tabRecovery: content process %@ for tab %@ with no restorable URL - removing", reason, tab.id.uuidString))
            removeTab(at: location.index, mode: location.mode)
            return
        }
        
        logger(String(format: "tabRecovery: content process %@ for tab %@ - preserving and marking for restore (%@)", reason, tab.id.uuidString, url))
        
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
    
    func onFirstComposite(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        tab.state.hasFirstComposite = true
        delegate?.tabManager(self, didFirstCompositeFor: tab.id)
    }
    
    func onFirstContentfulPaint(session: GeckoSession) {}
    
    func onPaintStatusReset(session: GeckoSession) {}
    
    func onWebAppManifest(session: GeckoSession, manifest: Any) {}
    
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
        hasUserGesture: Bool
    ) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let shouldPreserveDisplayedURL = hasDisplayURL(for: tab)
        
        if let normalizedURL,
           normalizedURL.hasPrefix("about:blank"),
           (tab.state.suppressInitialNavigation || shouldPreserveDisplayedURL) {
            logger(String(format: "tabLocation: suppressed about:blank for tab %@ (suppressInitialNavigation=%@, shouldPreserveDisplayedURL=%@)", tab.id.uuidString, String(tab.state.suppressInitialNavigation), String(shouldPreserveDisplayedURL)))
            return
        }
        if let normalizedURL {
            logger(String(format: "tabLocation: tab %@ location changed to %@ (not suppressed)", tab.id.uuidString, normalizedURL))
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
        tab.state.displayState = .committed
        tab.favicon = nil

        notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        scheduleFaviconUpdate(forTabAt: location.index, mode: location.mode)
        persistState()

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
    /// In-memory and process-wide - it is a latency optimisation, not
    /// state worth persisting, and a wrong entry self-corrects on the
    /// next detection.
    private static var reservationByHost: [String: GeckoSession.BottomReservation] = [:]

    /// Applies the remembered verdict for a newly committed URL, so the
    /// reservation is right before the page paints rather than after.
    /// Returns true when it changed the tab's current verdict.
    @discardableResult
    private func applyRememberedReservation(to tab: Tab, url: String?) -> Bool {
        guard let host = url.flatMap({ URL(string: $0)?.host }),
              let remembered = Self.reservationByHost[host],
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
            if let reservation = await session.bottomReservation() {
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
                if let host = tab.url.flatMap({ URL(string: $0)?.host }) {
                    Self.reservationByHost[host] = reservation
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
        
        if url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("about:blank"),
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
        }
        
        tab.state.loadingState = .loading(progress: 0)
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
    }
    
    func onPageStop(session: GeckoSession, success: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
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
