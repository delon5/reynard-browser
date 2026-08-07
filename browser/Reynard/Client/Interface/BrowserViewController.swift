//
//  BrowserViewController.swift
//  Reynard
//
//  Created by Minh Ton on 4/3/26.
//

import GeckoView
import UIKit

final class BrowserViewController: UIViewController {
    private enum UX {
        static let layoutAnimationDuration: TimeInterval = 0.22
        static let fallbackTopInset: CGFloat = 24
        static let keyboardAnimationDuration: TimeInterval = 0.25
        static let keyboardAnimationCurve: UInt = 7
    }
    
    private struct KeyboardAnimation {
        let duration: TimeInterval
        let curve: UIView.AnimationOptions
    }
    
    // MARK: - State
    
    let sessionManager = SessionManager()
    lazy var tabManager: TabManager = TabManagerImplementation(
        delegate: self,
        sessionManager: sessionManager
    )
    lazy var privateBrowsingLockCoordinator = PrivateBrowsingLockCoordinator(
        host: self,
        tabManager: tabManager
    )
    lazy var scrollChromeCoordinator = ScrollChromeCoordinator(browserChrome: browserChrome)
    lazy var scrollbarHapticCoordinator = ScrollbarHapticCoordinator()
    private var preFullscreenOrientation: UIInterfaceOrientation?
    var pendingNewTabKeyboardFocusTabID: UUID?
    var isPendingNewTabKeyboardFocusEventDispatchComplete = false
    var isPendingNewTabContentReady = false
    weak var fullscreenSession: GeckoSession?
    private let allowsSidebarHosting: Bool
    private(set) var browserLayout = BrowserLayout.initial(
        interfaceIdiom: UIDevice.current.userInterfaceIdiom
    )
    
    // MARK: - Views And Coordinators
    
    let tabBar = TabBar()
    let tabOverview = TabOverview()
    let contentView = ContentView()
    lazy var browserChrome = BrowserChrome()
    let addonPopupLoadingIndicator = UIActivityIndicatorView(style: .large)
    var addonPopupLoadingTimeoutWorkItem: DispatchWorkItem?
    lazy var addonPopupLoadingView: UIView = {
        let loadingView = UIView()
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.backgroundColor = UIColor.appBackground.withAlphaComponent(0.94)
        loadingView.layer.cornerRadius = 16
        loadingView.layer.shadowColor = UIColor.black.cgColor
        loadingView.layer.shadowOpacity = 0.18
        loadingView.layer.shadowRadius = 10
        loadingView.layer.shadowOffset = CGSize(width: 0, height: 4)
        loadingView.accessibilityLabel = NSLocalizedString("Loading Add-on", comment: "")

        addonPopupLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(addonPopupLoadingIndicator)
        NSLayoutConstraint.activate([
            addonPopupLoadingIndicator.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            addonPopupLoadingIndicator.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor)
        ])
        return loadingView
    }()
    
    lazy var overlayCoordinator = OverlayCoordinator(host: self)
    lazy var homepageOverlayCoordinator = HomepageOverlayCoordinator(
        delegate: self,
        overlayCoordinator: overlayCoordinator
    )
    lazy var searchOverlayCoordinator = SearchOverlayCoordinator(
        delegate: self,
        overlayCoordinator: overlayCoordinator
    )
    lazy var contextMenuCoordinator = ContextMenuCoordinator(host: self, sessionManager: sessionManager)
    lazy var downloadsCoordinator = DownloadsCoordinator(delegate: self)
    let addonPackageStagingService = AddonPackageStagingService.shared
    lazy var sidebarCoordinator = SidebarCoordinator(
        host: self,
        canHostSidebar: allowsSidebarHosting
    )
    lazy var addonCoordinator = AddonCoordinator(
        dataSource: self,
        delegate: self,
        sessionManager: sessionManager
    )
    
    private(set) var isShowingFullscreenMedia = false {
        didSet {
            setNeedsStatusBarAppearanceUpdate()
        }
    }
    
    // MARK: - Lifecycle
    
    override var prefersStatusBarHidden: Bool {
        return isShowingFullscreenMedia
    }
    
    override var childForStatusBarHidden: UIViewController? {
        return sidebarCoordinator.statusBarController
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if isShowingFullscreenMedia && browserLayout.interfaceIdiom == .phone {
            return .landscape
        }
        
        return browserLayout.interfaceIdiom == .pad ? .all : .allButUpsideDown
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        if isShowingFullscreenMedia && browserLayout.interfaceIdiom == .phone {
            return .landscapeRight
        }
        
        return .portrait
    }
    
    init(canHostSidebar: Bool = true) {
        self.allowsSidebarHosting = canHostSidebar
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if isShowingFullscreenMedia {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBackground
        
        if sidebarCoordinator.installHostIfNeeded() {
            return
        }
        
        applyGeckoPreferences()
        configureBrowserInterface()
        observeNotifications()
        contextMenuCoordinator.configure()
        downloadsCoordinator.startObservingStore()
        downloadsCoordinator.syncToolbarButtonState()
        tabOverview.restoreMode(TabOverview.Mode(tabMode: TabManagementStore.shared.preferredRestoredMode()))
        syncBrowserNavigationChrome(animated: false)
        browserChrome.syncSidebarButton(splitViewController: splitViewController)
        applyUpdateMenuButtonBadge()
        
        tabManager.createInitialTab(openingScreen: Prefs.HomepageSettings.openingScreen)
        privateBrowsingLockCoordinator.lockInitialStateIfNeeded()
        refreshAddressBar()
        homepageOverlayCoordinator.updatePresentation(animated: false)
        
        scrollChromeCoordinator.attach(to: contentView)
        scrollChromeCoordinator.isEnabled = { [weak self] in
            guard let self else {
                return false
            }
            guard Prefs.AppearanceSettings.hidesToolbarOnScroll else {
                return false
            }
            // Also require an actual, non-blank URL on the selected tab —
            // without this, scrolling the homepage's own content (which
            // is independently scrollable) could condense the pill even
            // though there's no page to show, leaving the reload icon
            // visible with an empty location label next to it.
            let selectedURL = self.tabManager.selectedTab?.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRealURL = !(selectedURL?.isEmpty ?? true)
            return hasRealURL
                && !self.isShowingFullscreenMedia
                && !self.tabOverview.isPresented
                && !self.searchOverlayCoordinator.isFocused
        }
        
        scrollbarHapticCoordinator.attach(to: contentView)
        scrollbarHapticCoordinator.isEnabled = { [weak self] in
            guard let self else {
                return false
            }
            let selectedURL = self.tabManager.selectedTab?.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRealURL = !(selectedURL?.isEmpty ?? true)
            return hasRealURL && !self.isShowingFullscreenMedia
        }
        browserChrome.onScrollCondensedChange = { [weak self] condensed in
            guard let self else {
                return
            }
            // Content's actual frame always extends to the true window
            // bottom — condensing to a pill only fades the toolbar, it
            // doesn't shrink its layout frame, so without adjusting the
            // safe area here there'd be a real gap between the content
            // and the screen bottom.
            //
            // additionalSafeAreaInsets doesn't change any view's frame,
            // only what gets reported as the safe area — which becomes
            // env(safe-area-inset-bottom) for the page's own CSS. This
            // gives the page an artificial boundary just above the pill
            // without touching content's real size, so a page using
            // that CSS variable correctly positions its own
            // fixed-position elements above the pill rather than
            // underneath it.
            // CHANGED - was `condensed ? artificialInset : 0`, which
            // inflated the safe area for EVERY page whenever the pill
            // condensed, regardless of whether that page uses
            // env(safe-area-inset-bottom). The content anchor in
            // applyPhoneLayout already gated on the tab's own flag, so
            // the two decided the same thing differently and every page
            // ended up with the reserved strip. See
            // fix_per_tab_artificial_safe_area_inset.py.
            self.updateArtificialSafeAreaInset()
            // Deliberately not animated: content's resize is snapped
            // instantly, before the (separately animated) chrome fade
            // begins, so GeckoView gets its real final size immediately
            // rather than a continuously-changing target.
            self.updateDynamicToolbarOffset()
            self.applyBrowserLayout(animated: false)
        }
        
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            
            await self.addonCoordinator.start()
            if let session = self.tabManager.selectedTab?.session {
                self.sessionManager.setAddonTabActive(true, for: session)
            }
        }
        
        updateBrowserLayout(animated: false)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        performContentLifecycle {
            syncBrowserNavigationChrome(animated: animated)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelAutomaticKeyboardFocusForNewTab()
        performContentLifecycle {
            view.endEditing(true)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        performContentLifecycle {
            syncBrowserNavigationChrome(animated: false)
            browserChrome.syncSidebarButton(splitViewController: splitViewController)
            downloadsCoordinator.syncToolbarButtonState()
            updateBrowserLayout(animated: false)
            fulfillPendingAutomaticKeyboardFocusIfPossible()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSelectedPageZoomControls()
        updateDynamicToolbarMaxHeight()
        invalidateNavigationThumbnailsIfNeeded()
    }
    
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if sidebarCoordinator.refreshHostVisibility() {
            return
        }
        syncBrowserNavigationChrome(animated: false)
        browserChrome.syncSidebarButton(splitViewController: splitViewController)
        refreshAddressBar()
        updateBrowserLayout(animated: false)
        tabOverview.invalidateCollectionLayouts()
        tabBar.invalidateLayout()
        tabOverview.refreshForCurrentOrientation()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        performContentLifecycle {
            coordinator.animate { _ in
                self.syncBrowserNavigationChrome(animated: false)
                self.browserChrome.syncSidebarButton(splitViewController: self.splitViewController)
                self.tabOverview.invalidateCollectionLayouts()
                self.tabBar.invalidateLayout()
            } completion: { _ in
                self.syncBrowserNavigationChrome(animated: false)
                self.browserChrome.syncSidebarButton(splitViewController: self.splitViewController)
                self.contentView.setTransitionTransform(.identity)
                self.browserChrome.resetHorizontalTransition()
                self.tabOverview.refreshForCurrentOrientation()
                DispatchQueue.main.async {
                    guard self.isViewLoaded, self.view.window != nil else {
                        return
                    }
                    self.updateBrowserLayout(animated: false)
                }
            }
        }
    }
    
    // MARK: - Preferences
    
    private func applyGeckoPreferences() {
        // HTTPS-only mode
        HTTPSOnlyModePolicyController.applyHTTPSOnlyMode()
        
        // Tracking Protection
        TrackingProtectionPolicyController.applyEnhancedTrackingProtection()
        TrackingProtectionPolicyController.applyGlobalPrivacyControl()
    }
    
    // MARK: - Browser Layout
    
    private func configureBrowserInterface() {
        browserChrome.configureAddressBar(
            delegate: self,
            searchDelegate: self,
            gestureDelegate: self
        )
        configureBrowserChromeActions()
        tabBar.dataSource = self
        tabOverview.configure(dataSource: self, delegate: self, presentationContext: self)
        
        view.addSubview(contentView)
        view.addSubview(tabBar)
        view.addSubview(browserChrome)
        view.addSubview(tabOverview)
        
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).withPriority(.defaultHigh),
            contentView.bottomAnchor.constraint(equalTo: browserChrome.bottomToolbarTopAnchor).withPriority(.defaultHigh),
            contentView.webContentBottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            browserChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            browserChrome.topAnchor.constraint(equalTo: view.topAnchor),
            browserChrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: browserChrome.topToolbarBottomAnchor),
            
            tabOverview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabOverview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabOverview.topAnchor.constraint(equalTo: view.topAnchor),
            tabOverview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    private func configureBrowserChromeActions() {
        contentView.onBack = { [weak self] in
            self?.tabManager.goBack()
        }
        contentView.onForward = { [weak self] in
            self?.tabManager.goForward()
        }
        contentView.onHistorySwipeBegan = { [weak self] in
            self?.captureOutgoingHistoryThumbnail()
        }
        browserChrome.onSidebar = { [weak self] in
            self?.sidebarCoordinator.toggle(animated: true)
        }
        browserChrome.onBack = { [weak self] in
            self?.captureOutgoingHistoryThumbnail()
            self?.tabManager.goBack()
        }
        browserChrome.onForward = { [weak self] in
            self?.captureOutgoingHistoryThumbnail()
            self?.tabManager.goForward()
        }
        browserChrome.onShare = { [weak self] in
            self?.presentShareSheet()
        }
        browserChrome.onLibrary = { [weak self] in
            self?.presentLibrary()
        }
        browserChrome.onBookmarks = { [weak self] in
            self?.presentLibrary(initialSection: .bookmarks)
        }
        browserChrome.onHistory = { [weak self] in
            self?.presentLibrary(initialSection: .history)
        }
        browserChrome.onDownloads = { [weak self] in
            self?.presentLibrary(initialSection: .downloads)
        }
        browserChrome.onSettings = { [weak self] in
            self?.presentLibrary(initialSection: .settings)
        }
        browserChrome.onNewTab = { [weak self] in
            self?.createNewTab()
        }
        browserChrome.onCloseTab = { [weak self] in
            guard let self, self.tabManager.selectedTabIndex >= 0 else {
                return
            }
            self.closeTab(at: self.tabManager.selectedTabIndex, mode: self.tabManager.selectedTabMode)
            if self.tabManager.selectedTab == nil {
                self.createNewTab(intent: .lastTabReplacement)
            }
        }
        browserChrome.onReload = { [weak self] in
            self?.tabManager.selectedTab?.session.reload()
        }
        browserChrome.onTabOverview = { [weak self] in
            self?.setTabOverviewVisible(true, animated: true)
        }
        browserChrome.onOverlayDismiss = { [weak self] in
            self?.dismissAddressBarEditingAndChromeOverlay()
        }
        browserChrome.onPageZoomOut = { [weak self] in
            self?.setSelectedPageZoomToPreviousLevel()
        }
        browserChrome.onPageZoomIn = { [weak self] in
            self?.setSelectedPageZoomToNextLevel()
        }
        browserChrome.onPageZoomReset = { [weak self] in
            self?.setSelectedPageZoomLevel(Prefs.AppearanceSettings.defaultPageZoomLevel)
        }
    }
    
    func updateBrowserLayout(
        animated: Bool,
        duration: TimeInterval = UX.layoutAnimationDuration
    ) {
        if sidebarCoordinator.hostsSidebar {
            sidebarCoordinator.updateContentLayout(
                animated: animated,
                duration: duration
            )
            return
        }
        
        let previousLayout = browserLayout
        browserLayout = resolveBrowserLayout()
        if browserLayout != previousLayout {
            dismissAddressBarEditingAndOverlays()
        }
        applyBrowserLayout(animated: animated)
        homepageOverlayCoordinator.updatePresentedLayout()
        homepageOverlayCoordinator.updatePresentation(animated: false)
        searchOverlayCoordinator.updatePresentedLayout()
        
        let layoutBlock = {
            self.view.layoutIfNeeded()
            self.tabOverview.collection.applyPresentationTransforms()
        }
        
        animated
        ? UIView.animate(withDuration: duration, animations: layoutBlock)
        : layoutBlock()
    }
    
    func dismissAddressBarEditingAndOverlays() {
        homepageOverlayCoordinator.resetPresentationSession()
        searchOverlayCoordinator.resetPresentationSession()
        browserChrome.resetAddressBarEditing()
        overlayCoordinator.discardAll(animated: false)
        applyBrowserLayout(animated: false)
    }
    
    func dismissAddressBarEditingAndChromeOverlay() {
        homepageOverlayCoordinator.resetPresentationSession()
        searchOverlayCoordinator.resetPresentationSession()
        browserChrome.resetAddressBarEditing()
        overlayCoordinator.dismiss(.homepage, on: .detached, animated: false)
        overlayCoordinator.dismiss(.search, on: .detached, animated: false)
        applyBrowserLayout(animated: false)
    }
    
    func updateBrowserLayoutIfNeeded(
        animated: Bool,
        duration: TimeInterval = UX.layoutAnimationDuration
    ) {
        guard browserLayout != resolveBrowserLayout() else {
            return
        }
        
        updateBrowserLayout(animated: animated, duration: duration)
    }
    
    func applyBrowserLayout(animated: Bool = false) {
        if isShowingFullscreenMedia {
            applyFullscreenLayout()
        } else {
            switch browserLayout.chromeMode {
            case .phone:
                applyPhoneLayout()
            case .compact:
                applyCompactLayout()
            case .pad:
                applyPadLayout()
            }
        }
        
        applyTabOverviewLayout()
        applyBrowserChromeLayout(animated: animated)
        updateNavigationButtons()
    }
    
    private func applyFullscreenLayout() {
        contentView.applyLayout(
            ContentView.LayoutState(mode: .fullscreen),
            topAnchor: view.topAnchor,
            bottomAnchor: view.bottomAnchor
        )
        tabBar.setVisibility(.hidden, animated: false)
    }
    
    private func applyPhoneLayout() {
        let isSearchFocused = searchOverlayCoordinator.isFocused && !tabOverview.isPresented
        contentView.applyLayout(
            ContentView.LayoutState(mode: isSearchFocused ? .searchFocused : .standard),
            topAnchor: view.safeAreaLayoutGuide.topAnchor,
            // The toolbar condensing to a pill only fades it out — it
            // doesn't shrink its own layout frame — so without this,
            // content would stay pinned to where the toolbar's top edge
            // always is, leaving a real gap between it and the true
            // screen bottom showing the window's own background
            // underneath instead of more page content.
            // Two-rule pill behavior: pages the SafeAreaDetector addon
            // confirmed use env(safe-area-inset-bottom) get a real,
            // reserved strip of space above the pill — the same trick
            // the full-size toolbar already uses — so the pill can
            // never sit above that page's own content. Pages with no
            // confirmed signal (nil, or explicitly false) get the full
            // screen extent instead, same as this app's original,
            // established behavior, with the pill floating over them.
            bottomAnchor: browserChrome.isScrollCondensed
            ? (tabManager.selectedTab?.state.usesSafeAreaInsetCSS == true
                ? browserChrome.condensedPillTopAnchor
                : view.bottomAnchor)
            : (isSearchFocused ? view.safeAreaLayoutGuide.bottomAnchor : browserChrome.bottomToolbarTopAnchor)
        )
        setTabBarVisible(false)
    }
    
    // ADDED - see fix_per_tab_artificial_safe_area_inset.py.
    //
    // Deliberately carries the SAME condition as the content anchor in
    // applyPhoneLayout and applyCompactLayout below, rather than
    // inventing its own - the two having different conditions is what
    // caused every page to get the reserved strip. A single computed
    // property both read would be better still, but that is a wider
    // refactor of code that otherwise works.
    //
    // Must be called whenever EITHER half can change: the pill
    // condensing, a different tab being selected, or detection flipping
    // after a page settles. That last one is real - the device log
    // shows one tab reporting NO and then YES for the same tab as its
    // content loaded.
    func updateArtificialSafeAreaInset() {
        // RE-ENABLED - see fix_reenable_artificial_safe_area_inset.py.
        //
        // This was disabled on the assumption that the dynamic toolbar
        // height had taken over the job. On device the page's own items
        // did not move at all once it was off, which is what it looks
        // like when that value never reaches the content process. This
        // path - additionalSafeAreaInsets -> UIKit safe area -> Gecko
        // safe area -> env(safe-area-inset-bottom) - is the one that
        // was observed working on main.
        let pageReservesSpace = tabManager.selectedTab?.state.usesSafeAreaInsetCSS == true
        // OFF. The dynamic toolbar max now reserves the pill's clearance
        // through the ICB, so inflating env(safe-area-inset-bottom) by
        // the same amount would reserve it twice.
        let shouldInflate = false && browserChrome.isScrollCondensed && pageReservesSpace

        guard shouldInflate else {
            additionalSafeAreaInsets.bottom = 0
            return
        }
        
        // CHANGED - computed from the pill's real position rather than
        // a fixed constant. See fix_repin_pill_to_screen_bottom.py.
        //
        // The window's inset is used rather than the view's
        // deliberately: additionalSafeAreaInsets feeds back into the
        // view's own safeAreaInsets, so reading it here would be
        // circular. The window reports the device's true inset and is
        // unaffected by what we set below - which also makes this
        // device-independent rather than assuming any particular
        // home-indicator height.
        let deviceBottomInset = view.window?.safeAreaInsets.bottom ?? 0
        additionalSafeAreaInsets.bottom = max(0, BrowserChrome.condensedPillContentBoundary - deviceBottomInset)
    }
    
    private func applyCompactLayout() {
        contentView.applyLayout(
            ContentView.LayoutState(mode: .standard),
            topAnchor: browserChrome.topToolbarBottomAnchor,
            // Same reasoning as applyPhoneLayout above — the toolbar's
            // layout frame doesn't shrink when condensed, only its
            // visual appearance fades, so this has to be handled
            // explicitly rather than left to the toolbar's own bounds.
            // Same two-rule reasoning as applyPhoneLayout above.
            bottomAnchor: browserChrome.isScrollCondensed
            ? (tabManager.selectedTab?.state.usesSafeAreaInsetCSS == true
                ? browserChrome.condensedPillTopAnchor
                : view.bottomAnchor)
            : browserChrome.bottomToolbarTopAnchor
        )
        setTabBarVisible(false)
    }
    
    private var dynamicToolbarMaxHeight: CGFloat = 0
    
    // CHANGED - the max is a CONSTANT, not a measurement.
    //
    // The 22:5x trace showed the whole offset chain working end to end:
    //
    //   nsWindow offset=-426 max=426 listener=1 attached=1
    //   PresShellWidgetListener offset=-426 visited=1 delivered=1
    //   nsPresContext RECEIVED offset=-426 max=426 height=426 shell=1
    //   nsPresContext APPLIED height=0 state=3 mvm=1
    //
    // Collapsed reached, every time, and page content still sat exactly
    // at the full toolbar's height. Because the offset was never what
    // reserved that space - the MAX is.
    // SetDynamicToolbarMaxHeight calls
    // ForceResizeReflowWithCurrentDimensions(), and ResizeReflow
    // subtracts the toolbar height from the window dimensions, so the
    // ICB becomes viewHeight - max and ordinary document content ends
    // there. The offset only moves position:fixed content and the
    // visual viewport.
    //
    // So the max carries the pill's clearance instead of the toolbar's
    // height. Content then ends just above the pill, and the expanded
    // toolbar covers content rather than reserving space for it - which
    // is what "underlay the bottom toolbar" means, and it hides on
    // scroll anyway.
    //
    // A constant also makes it genuinely stable: never measured, so no
    // oscillation and no reflow storm. The settle window and
    // plausibility checks that existed to tame the measurement are gone
    // with it.
    private func updateDynamicToolbarMaxHeight() {
        let hasBottomToolbar = !isShowingFullscreenMedia &&
        browserLayout.chromeMode != .pad &&
        !(searchOverlayCoordinator.isFocused && !tabOverview.isPresented)
        
        // Whichever chrome is actually on screen. Content must clear the
        // full toolbar while it is expanded and the pill once condensed,
        // so the reservation follows the state rather than being fixed at
        // the smaller of the two.
        let expandedHeight = BottomToolbar.expandedContentHeight + (view.window?.safeAreaInsets.bottom ?? 0)
        let chromeHeight = browserChrome.isScrollCondensed
            ? BrowserChrome.condensedPillOccupiedHeight
            : expandedHeight
        let target = hasBottomToolbar ? chromeHeight : 0
        
        guard abs(target - dynamicToolbarMaxHeight) > 0.5 else {
            return
        }
        
        logger(String(format: "dynToolbar: max %.1f -> %.1f (hasBottomToolbar=%@ condensed=%@)",
                      dynamicToolbarMaxHeight, target,
                      hasBottomToolbar ? "YES" : "NO",
                      browserChrome.isScrollCondensed ? "YES" : "NO"))
        dynamicToolbarMaxHeight = target
        // Gecko shortens the ICB by exactly this, so the strip behind the
        // pill is exactly this tall - and absent when it is zero.
        browserChrome.setPillBackdropHeight(dynamicToolbarMaxHeight)
        contentView.setDynamicToolbarMaxHeight(dynamicToolbarMaxHeight)
        updateDynamicToolbarOffset()
    }
    
    // The animation channel. Only -maxHeight exactly reaches
    // DynamicToolbarState::Collapsed, the one state where
    // PresShell::GetFixedViewportSize adds the toolbar height back and a
    // page's position:fixed content drops to the true window bottom.
    // Partial offsets are InTransition and move nothing.
    //
    // Condensed is therefore all-or-nothing: as far as Gecko is concerned
    // the toolbar is gone, content underlays the pill, and the strip above
    // the pill is reserved by updateArtificialSafeAreaInset instead.
    private func updateDynamicToolbarOffset() {
        let condensed = browserChrome.isScrollCondensed
        let offset = condensed ? -dynamicToolbarMaxHeight : 0
        // An offset of 0 with a max of 0 is the inert case. Only
        // offset == -max exactly reaches Gecko's Collapsed state.
        logger(String(format: "dynToolbar: offset %.1f (condensed=%@ max=%.1f)",
                      offset,
                      browserChrome.isScrollCondensed ? "YES" : "NO",
                      dynamicToolbarMaxHeight))
        contentView.setDynamicToolbarOffset(offset)
    }
    
    private func applyPadLayout() {
        contentView.applyLayout(
            ContentView.LayoutState(mode: .standard),
            topAnchor: tabBar.bottomAnchor,
            bottomAnchor: view.bottomAnchor
        )
        let showsTabBar = browserLayout.interfaceIdiom == .pad
        ? visibleTabCount > 1
        : visibleTabCount > 1 && Prefs.AppearanceSettings.showsLandscapeTabBar
        setTabBarVisible(showsTabBar)
    }
    
    private var visibleTabCount: Int {
        let tabs = tabManager.selectedTabMode == .private
        ? tabManager.privateTabs
        : tabManager.regularTabs
        return tabs.count
    }
    
    private func setTabBarVisible(_ visible: Bool) {
        tabBar.setVisibility(
            visible ? (tabOverview.isPresented ? .layoutReserved : .visible) : .hidden,
            animated: false
        )
    }
    
    private func applyTabOverviewLayout() {
        tabOverview.applyLayout(
            toolbarPosition: browserLayout.tabOverviewToolbarPosition,
            animated: false
        )
    }
    
    private func applyBrowserChromeLayout(animated: Bool) {
        let searchState = isShowingFullscreenMedia
        ? BrowserChrome.SearchState.inactive
        : (overlayCoordinator.chromeStateForAddressBarScrollDismissal(layout: browserLayout) ?? searchOverlayCoordinator.chromeState)
        browserChrome.apply(state: BrowserChrome.State(
            position: browserLayout.chromePosition,
            mode: browserLayout.chromeMode,
            presentation: isShowingFullscreenMedia
            ? .fullscreenMedia
            : (tabOverview.isPresented ? .tabOverview : .browsing),
            search: searchState,
            topInset: browserTopInset(),
            interfaceIdiom: browserLayout.interfaceIdiom,
            orientation: browserLayout.orientation,
            isTwoThirdSplitScreenOrSmaller: isSidebarOverlayLayout,
            sidebarButtonVisible: sidebarCoordinator.showChromeSidebarButton,
            animatesChromeStateChanges: animated
        ))
    }
    
    private func resolveBrowserLayout() -> BrowserLayout {
        let interfaceIdiom = traitCollection.userInterfaceIdiom
        let orientation = currentViewportOrientation()
        
        if interfaceIdiom == .pad {
            return isCompactPadLayout
            ? resolveCompactLayout(interfaceIdiom: .pad, orientation: orientation)
            : resolvePadLayout(interfaceIdiom: .pad, orientation: orientation)
        }
        
        guard orientation == .portrait else {
            return resolvePadLayout(interfaceIdiom: .phone, orientation: .landscape)
        }
        
        return Prefs.AppearanceSettings.addressBarPosition == .top
        ? resolveCompactLayout(interfaceIdiom: .phone, orientation: .portrait)
        : resolvePhoneLayout()
    }
    
    private func currentViewportOrientation() -> BrowserLayout.ViewportOrientation {
        if let interfaceOrientation = view.window?.windowScene?.interfaceOrientation,
           interfaceOrientation != .unknown {
            return interfaceOrientation.isLandscape ? .landscape : .portrait
        }
        
        return view.bounds.width > view.bounds.height ? .landscape : .portrait
    }
    
    private func invalidateNavigationThumbnailsIfNeeded() {
        let didResizeWebContent = contentView.updateWebContentSize()
        guard didResizeWebContent else {
            return
        }
        
        tabManager.invalidateNavigationThumbnails()
        updateNavigationButtons()
    }
    
    var isCompactPadLayout: Bool {
        guard let window = view.window else {
            return UIApplication.shared.isOneThirdSplitScreenOrSmaller
        }
        
        return UIApplication.shared.isOneThirdSplitScreenOrSmaller(
            forWindowWidth: browserWindowWidth(fallback: window.bounds.width),
            screen: window.screen
        )
    }
    
    var isSidebarOverlayLayout: Bool {
        guard let window = view.window else {
            return UIApplication.shared.isTwoThirdSplitScreenOrSmaller
        }
        
        return UIApplication.shared.isTwoThirdSplitScreenOrSmaller(
            forWindowWidth: browserWindowWidth(fallback: window.bounds.width),
            screen: window.screen
        )
    }
    
    var isHalfSplitScreenOrSmaller: Bool {
        guard let window = view.window else {
            return UIApplication.shared.isHalfSplitScreenOrSmaller
        }
        
        return UIApplication.shared.isHalfSplitScreenOrSmaller(
            forWindowWidth: browserWindowWidth(fallback: window.bounds.width),
            screen: window.screen
        )
    }
    
    private func browserWindowWidth(fallback: CGFloat) -> CGFloat {
        guard let rootView = view.window?.rootViewController?.view,
              rootView.bounds.width > 0 else {
            return fallback
        }
        
        return rootView.bounds.width
    }
    
    private func resolvePhoneLayout() -> BrowserLayout {
        return BrowserLayout(
            interfaceIdiom: .phone,
            orientation: .portrait,
            chromeMode: .phone,
            chromePosition: .bottom,
            tabOverviewToolbarPosition: .bottom,
            overlayHost: .embedded
        )
    }
    
    private func resolveCompactLayout(
        interfaceIdiom: UIUserInterfaceIdiom,
        orientation: BrowserLayout.ViewportOrientation
    ) -> BrowserLayout {
        return BrowserLayout(
            interfaceIdiom: interfaceIdiom,
            orientation: orientation,
            chromeMode: .compact,
            chromePosition: interfaceIdiom == .phone ? .top : .bottom,
            tabOverviewToolbarPosition: .bottom,
            overlayHost: .embedded
        )
    }
    
    private func resolvePadLayout(
        interfaceIdiom: UIUserInterfaceIdiom,
        orientation: BrowserLayout.ViewportOrientation
    ) -> BrowserLayout {
        return BrowserLayout(
            interfaceIdiom: interfaceIdiom,
            orientation: orientation,
            chromeMode: .pad,
            chromePosition: .bottom,
            tabOverviewToolbarPosition: isHalfSplitScreenOrSmaller ? .bottom : .top,
            overlayHost: .detached
        )
    }
    
    private func browserTopInset() -> CGFloat {
        return sidebarCoordinator.topInset(fallback: UX.fallbackTopInset)
    }
    
    // MARK: - Sidebar
    
    private func performContentLifecycle(_ action: () -> Void) {
        guard !sidebarCoordinator.hostsSidebar else {
            return
        }
        
        action()
    }
    
    // MARK: - Notifications
    
    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(addressBarPositionDidChange),
            name: .addressBarPositionDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(landscapeTabBarDidChange),
            name: .landscapeTabBarDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyUpdateMenuButtonBadge),
            name: .appUpdateAvailable,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(newTabDisplayOptionDidChange),
            name: .newTabDisplayOptionDidChange,
            object: nil
        )
    }
    
    @objc private func newTabDisplayOptionDidChange() {
        homepageOverlayCoordinator.updatePresentation(animated: true)
        captureThumbnail(forTabAt: tabManager.selectedTabIndex, mode: tabManager.selectedTabMode)
    }
    
    @objc func addressBarPositionDidChange() {
        updateBrowserLayout(animated: true)
    }
    
    @objc func landscapeTabBarDidChange() {
        updateBrowserLayout(animated: true)
    }
    
    @objc func applyUpdateMenuButtonBadge() {
        browserChrome.setMenuButtonIndicatesUpdate(BrowserUpdates.shared.hasUpdate)
    }
    
    // MARK: - Keyboard
    
    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }
        
        let keyboardFrame = view.convert(frameValue.cgRectValue, from: nil)
        let keyboardInset = max(
            0,
            view.bounds.maxY - keyboardFrame.minY - view.safeAreaInsets.bottom
        )
        let animation = keyboardAnimation(from: notification)
        if !searchOverlayCoordinator.isFocused && !tabOverview.isPresented && keyboardInset > 0 {
            contentView.relocateFocusedInput(
                above: keyboardFrame,
                animationDuration: animation.duration,
                animationOptions: animation.curve
            )
        } else {
            contentView.resetFocusedInputRelocation(
                animationDuration: animation.duration,
                animationOptions: animation.curve
            )
        }
        
        let shouldDockChrome = browserLayout.chromeMode == .phone
        && searchOverlayCoordinator.isFocused
        && !tabOverview.isPresented
        && keyboardInset > 0
        browserChrome.dockAddressBar(offset: shouldDockChrome ? -keyboardInset : 0)
        animateLayout(animation)
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        let animation = keyboardAnimation(from: notification)
        contentView.resetFocusedInputRelocation(
            animationDuration: animation.duration,
            animationOptions: animation.curve
        )
        browserChrome.dockAddressBar(offset: 0)
        animateLayout(animation)
    }
    
    private func keyboardAnimation(from notification: Notification) -> KeyboardAnimation {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        ?? UX.keyboardAnimationDuration
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        ?? UX.keyboardAnimationCurve
        return KeyboardAnimation(
            duration: duration,
            curve: UIView.AnimationOptions(rawValue: rawCurve << 16)
        )
    }
    
    private func animateLayout(_ animation: KeyboardAnimation) {
        UIView.animate(withDuration: animation.duration, delay: 0, options: [animation.curve]) {
            self.view.layoutIfNeeded()
        }
    }
    
    // MARK: - Browser UI Updates
    
    func syncBrowserNavigationChrome(animated: Bool) {
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationItem.leftItemsSupplementBackButton = false
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItems = []
        navigationItem.leftBarButtonItem = nil
    }
    
    func updateNavigationButtons() {
        guard let tab = tabManager.selectedTab else {
            contentView.setHistoryNavigation(
                canGoBack: false,
                canGoForward: false,
                backPreviewImage: nil,
                forwardPreviewImage: nil,
                isSwipeEnabled: false
            )
            return
        }
        
        browserChrome.updateNavigation(
            canGoBack: tab.state.navigationState.canGoBack,
            canGoForward: tab.state.navigationState.canGoForward,
            canShare: tabManager.shareableURL(for: tab) != nil
        )
        
        let previewImages = tabManager.navigationPreviewImages(for: tab)
        contentView.setHistoryNavigation(
            canGoBack: tab.state.navigationState.canGoBack,
            canGoForward: tab.state.navigationState.canGoForward,
            backPreviewImage: previewImages.backImage,
            forwardPreviewImage: previewImages.forwardImage,
            isSwipeEnabled: true
        )
    }
    
    func applyFullscreenState(_ fullScreen: Bool, for session: GeckoSession?) {
        if fullScreen {
            fullscreenSession = session
        } else if fullscreenSession === session || session == nil {
            fullscreenSession = nil
        }
        
        guard isShowingFullscreenMedia != fullScreen else {
            return
        }
        
        if fullScreen {
            if tabOverview.isPresented {
                tabOverview.setPresented(false, animated: false)
            }
            searchOverlayCoordinator.setFocused(false, animated: false)
            view.endEditing(true)
        }
        
        sidebarCoordinator.setFullscreen(fullScreen)
        isShowingFullscreenMedia = fullScreen
        updateBrowserLayout(animated: true)
        updateFullscreenOrientation(fullScreen)
        UIApplication.shared.isIdleTimerDisabled = fullScreen
    }
    
    private func updateFullscreenOrientation(_ fullScreen: Bool) {
        guard browserLayout.interfaceIdiom == .phone else {
            return
        }
        
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        
        if fullScreen {
            if let currentOrientation = view.window?.windowScene?.interfaceOrientation,
               currentOrientation != .unknown {
                preFullscreenOrientation = currentOrientation
            } else if preFullscreenOrientation == nil {
                preFullscreenOrientation = .portrait
            }
            
            let targetOrientation: UIInterfaceOrientation
            if let currentOrientation = view.window?.windowScene?.interfaceOrientation,
               currentOrientation.isLandscape {
                targetOrientation = currentOrientation
            } else {
                targetOrientation = .landscapeRight
            }
            forceInterfaceOrientation(targetOrientation)
        } else {
            let targetOrientation = preFullscreenOrientation ?? .portrait
            forceInterfaceOrientation(targetOrientation)
            preFullscreenOrientation = nil
        }
    }
    
    private func forceInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        let orientationMask: UIInterfaceOrientationMask
        switch orientation {
        case .portrait:
            orientationMask = .portrait
        case .portraitUpsideDown:
            orientationMask = .portraitUpsideDown
        case .landscapeLeft:
            orientationMask = .landscapeLeft
        case .landscapeRight:
            orientationMask = .landscapeRight
        default:
            return
        }
        
        if #available(iOS 16.0, *) {
            guard let windowScene = view.window?.windowScene else {
                return
            }
            
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask)
            windowScene.requestGeometryUpdate(geometryPreferences)
            UIViewController.attemptRotationToDeviceOrientation()
            return
        }
        
        let deviceOrientation: UIDeviceOrientation
        switch orientation {
        case .portrait:
            deviceOrientation = .portrait
        case .portraitUpsideDown:
            deviceOrientation = .portraitUpsideDown
        case .landscapeLeft:
            deviceOrientation = .landscapeRight
        case .landscapeRight:
            deviceOrientation = .landscapeLeft
        default:
            return
        }
        
        UIDevice.current.setValue(deviceOrientation.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
