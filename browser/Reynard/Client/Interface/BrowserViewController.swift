//
//  BrowserViewController.swift
//  Reynard
//
//  Created by Minh Ton on 4/3/26.
//

import CoreMedia
import GeckoView
import UIKit

final class BrowserViewController: UIViewController, GeckoScreenOrientationDelegate {
    private enum UX {
        static let layoutAnimationDuration: TimeInterval = 0.22
        static let fallbackTopInset: CGFloat = 24
        static let keyboardAnimationDuration: TimeInterval = 0.25
        static let keyboardAnimationCurve: UInt = 7
        /// How long the re-lift takes when the chrome settles under a
        /// live keyboard - see resampleFocusedInputIfChromeMoved.
        static let chromeSettleRelift: TimeInterval = 0.2
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
    private var lockedOrientations: UIInterfaceOrientationMask?
    private var pendingOrientationRequest: (
        id: UUID,
        orientations: UIInterfaceOrientationMask,
        completion: (GeckoOrientationLockResult) -> Void
    )?
    weak var fullscreenSession: GeckoSession?
    private let allowsSidebarHosting: Bool
    private var shouldRestoreContentFocus = false
    private(set) var browserLayout = BrowserLayout.initial(
        interfaceIdiom: UIDevice.current.userInterfaceIdiom
    )
    
    // MARK: - Views And Coordinators
    
    let tabBar = TabBar()
    let tabOverview = TabOverview()
    let contentView = ContentView()
    
    /// Fills the gap between the content view's bottom and the window
    /// bottom - the strip the pill sits on when it is not floating.
    /// Painted with the page's own background color so the page appears
    /// to continue under the pill even though it stops at its top edge.
    /// Zero height whenever the content view already reaches the bottom.
    private let pillUnderlayView = UIView()
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
    private(set) lazy var toolbarController = ToolbarController(
        browserChrome: browserChrome,
        tabBar: tabBar,
        contentView: contentView,
        rootView: view
    )
    
    lazy var overlayCoordinator = OverlayCoordinator(host: self)
    lazy var homepageOverlayCoordinator = HomepageOverlayCoordinator(
        delegate: self,
        overlayCoordinator: overlayCoordinator,
        toolbarController: toolbarController
    )
    lazy var searchOverlayCoordinator = SearchOverlayCoordinator(
        delegate: self,
        overlayCoordinator: overlayCoordinator,
        toolbarController: toolbarController
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
        if let lockedOrientations {
            return lockedOrientations
        }
        
        return browserLayout.interfaceIdiom == .pad ? .all : .allButUpsideDown
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        let allowedOrientations = lockedOrientations ?? supportedInterfaceOrientations
        return preferredInterfaceOrientation(allowedBy: allowedOrientations) ?? .portrait
    }
    
    init(canHostSidebar: Bool = true) {
        self.allowsSidebarHosting = canHostSidebar
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopScreenOrientationHandling()
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
                && !self.homepageOverlayCoordinator.isPresentedForAddressBarFocus
                && !self.searchOverlayCoordinator.isFocused
        }
        // While a pull-to-refresh drag is held, the +40pt expand is
        // deferred to the end of the gesture: expanding mid-pull
        // swaps the content anchor un-animated and flips the
        // dynamic-toolbar max from 0 to the full toolbar height - a
        // real ICB resize under the user's finger. The refresh
        // threshold (350pt) is far past the 40pt decision threshold,
        // so every refresh-strength pull from the pill would
        // otherwise cross it mid-gesture.
        scrollChromeCoordinator.isPullToRefreshActive = { [weak self] in
            self?.contentView.isPullToRefreshActive == true
        }
        
        scrollbarHapticCoordinator.attach(to: contentView)
        // Pixel-perfect activation: APZ reports the exact moment a
        // touch lands on the scrollbar thumb (APZCTreeManager patch).
        // The coordinator silences its own edge-strip drag heuristic
        // once this signal proves live.
        GeckoRuntime.setScrollbarTouchBeginHandler { [weak self] in
            self?.scrollbarHapticCoordinator.activateFromEngineSignal()
        }
        scrollbarHapticCoordinator.isEnabled = { [weak self] in
            guard let self else {
                return false
            }
            let selectedURL = self.tabManager.selectedTab?.url?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasRealURL = !(selectedURL?.isEmpty ?? true)
            return hasRealURL && !self.isShowingFullscreenMedia
        }
        // The per-page verdict feeding float mode's env-vs-margin
        // choice. A closure, so ToolbarController does not grow a
        // TabManager dependency.
        toolbarController.bottomReservation = { [weak self] in
            self?.tabManager.selectedTab?.state.bottomReservation
        }
        browserChrome.onScrollCondensedChange = { [weak self] condensed in
            guard let self else {
                return
            }
            // Condensing to a pill only fades the toolbar - its layout
            // frame does not shrink - so the content anchor has to be
            // re-decided explicitly here. applyBrowserLayout below reads
            // condensedContentBottomAnchor, which gates on the selected
            // tab's own env(safe-area-inset-bottom) usage.
            //
            // The reservation has to be re-sent too, and this is the only
            // place that can: how much chrome the page must clear differs
            // between the full toolbar and the pill, but condensing
            // changes no view frame, so viewDidLayoutSubviews - the only
            // other caller - does not necessarily run. Without this the
            // engine keeps whichever reservation it was last given and
            // page content stays at the expanded height while the chrome
            // shrinks to the pill, which is exactly what Facebook showed.
            //
            // Deliberately not animated: content's resize is snapped
            // instantly, before the (separately animated) chrome fade
            // begins, so GeckoView gets its real final size immediately
            // rather than a continuously-changing target.
            self.applyBrowserLayout(animated: false)
            self.toolbarController.updateLayout(
                chromeMode: self.browserLayout.chromeMode,
                isToolbarEnabled: !self.isShowingFullscreenMedia
            )
            // AFTER the engine has been told, not before.
            self.resampleFocusedInputIfChromeMoved()
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
        toolbarController.unlock(for: .viewPresentation)
        performContentLifecycle {
            syncBrowserNavigationChrome(animated: animated)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelAutomaticKeyboardFocusForNewTab()
        performContentLifecycle {
            toolbarController.lock(for: .viewPresentation)
            shouldRestoreContentFocus =
            tabManager.selectedTab?.session.engineView?.isFirstResponder == true
            view.endEditing(true)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // CHANGED - see mse_fix_126's docstring. This asked for first
        // responder and never got it, so the marker never fired. A
        // gesture recogniser on the window needs neither.
        installReynardMarkGesture()
        performContentLifecycle {
            syncBrowserNavigationChrome(animated: false)
            browserChrome.syncSidebarButton(splitViewController: splitViewController)
            downloadsCoordinator.syncToolbarButtonState()
            updateBrowserLayout(animated: false)
            fulfillPendingAutomaticKeyboardFocusIfPossible()
            if shouldRestoreContentFocus {
                shouldRestoreContentFocus = false
                requestContentKeyboardFocus()
            }
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSelectedPageZoomControls()
        toolbarController.updateLayout(
            chromeMode: browserLayout.chromeMode,
            isToolbarEnabled: !isShowingFullscreenMedia
        )
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
            toolbarController.reset(animated: false)
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
        // Autoplay. Never applied before this: media.autoplay.default
        // was not written anywhere in the tree, so the Site Settings
        // choice reached the engine only through a permission request no
        // capture has ever shown Gecko making.
        AutoplayPolicyController.applyAutoplayPolicy()
        MediaCompatibilityPolicyController.applyMediaSourceVisibility()
        // The other half of the same decision, and applied here for the
        // same reason: without it the switch only takes effect when
        // toggled, so turning it OFF would silently revert to on at the
        // next launch - the StaticPrefList default is true.
        MediaCompatibilityPolicyController.applyFairPlayInitDataPolicy()
        // Same reason again: a pref the engine only learns about when the
        // field is edited is one that silently empties on every launch.
        MediaCompatibilityPolicyController.applyWebKitShimExtraHosts()
        // And the track lists, without which a page cannot change audio
        // language at all - see the controller for what the capture
        // showed.
        MediaCompatibilityPolicyController.applyMediaTrackSupport()
        // And why a video stopped being a compositor surface - see
        // mse_fix_160's docstring.
        MediaCompatibilityPolicyController.applySurfacePromotionLogging()
        
        // HLS/FairPlay through AVFoundation
        AVPlayerPolicyController.applyAVPlayerHLS()
        
        // Tracking Protection
        TrackingProtectionPolicyController.applyEnhancedTrackingProtection()
        TrackingProtectionPolicyController.applyGlobalPrivacyControl()

        // Find in page (Cmd+F). Lives here because this is the app's
        // verified once-per-launch bootstrap; the install itself guards
        // against duplicates if this ever runs again.
        setUpFindInPageKeyCommand()


        // iOS's Wi-Fi proxy, which Gecko cannot see for itself on this
        // port - see SystemProxyBridge. Re-applied on foreground too:
        // the setting is per-network and can change while backgrounded.
        SystemProxyBridge.apply()
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            SystemProxyBridge.apply()
            // ADDED - see fix_stand_down_from_orphaned_fullscreen.py's
            // docstring. Leaving fullscreen is driven by a DOM event, and
            // backgrounding is where that event goes missing: sleeping a
            // tab replaces its session, so the exit never arrives and the
            // chrome stays hidden until the user manufactures one by
            // entering and leaving fullscreen again.
            self?.reynardStandDownFromOrphanedFullscreen()
        }
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
        
        pillUnderlayView.translatesAutoresizingMaskIntoConstraints = false
        pillUnderlayView.backgroundColor = .systemBackground
        contentView.onPageBackgroundColorChange = { [weak self] color in
            self?.pillUnderlayView.backgroundColor = color
        }
        view.addSubview(pillUnderlayView)
        view.addSubview(contentView)
        view.addSubview(tabBar)
        view.addSubview(browserChrome)
        view.addSubview(tabOverview)
        contentView.configureLayout(
            topAnchor: view.topAnchor,
            bottomAnchor: view.bottomAnchor
        )
        
        NSLayoutConstraint.activate([
            // Formerly declared inside the addonPopupLoadingView lazy
            // initializer, where they never activated until an add-on
            // popup happened to load - leaving the strip under the
            // pill unconstrained in stop mode.
            pillUnderlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pillUnderlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pillUnderlayView.topAnchor.constraint(equalTo: contentView.bottomAnchor),
            pillUnderlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).withPriority(.defaultHigh),
            contentView.bottomAnchor.constraint(equalTo: browserChrome.bottomToolbarTopAnchor).withPriority(.defaultHigh),
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
            self?.toolbarController.reset()
            self?.captureOutgoingHistoryThumbnail()
            self?.tabManager.goBack()
        }
        browserChrome.onForward = { [weak self] in
            self?.toolbarController.reset()
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
            self?.toolbarController.reset()
            self?.dismissAddressBarEditingAndChromeOverlay()
        }
        browserChrome.onPageZoomOut = { [weak self] in
            self?.setSelectedPageZoomToPreviousLevel()
        }
        browserChrome.onPageZoomIn = { [weak self] in
            self?.setSelectedPageZoomToNextLevel()
        }
        browserChrome.onPageZoomReset = { [weak self] in
            self?.setSelectedPageZoomLevel(Prefs.BrowsingSettings.defaultPageZoomLevel)
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
        requestContentKeyboardFocus()
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

    private func forgetKeyboardLift() {
        visibleKeyboardFrame = nil
        liftChromeCondensed = nil
        chromeSettleResampleTask?.cancel()
        chromeSettleResampleTask = nil
    }

    /// The chrome moved under a live keyboard - measure again.
    ///
    /// ADDED for KBD-03, see visibleKeyboardFrame. Called from
    /// onScrollCondensedChange, which is the one signal for the state
    /// actually changing, and from the tail of that closure rather than
    /// from applyBrowserLayout so the engine has already been given the
    /// new max/env/margin when the first sample goes out. The condensed
    /// != last guard stays as a cheap belt on top of that.
    ///
    /// Twice, the second time late. The viewport change and this query
    /// travel different paths - the dynamic-toolbar IPC on the session,
    /// the metrics query through the dispatcher - so the first sample can
    /// reach the content process before the reflow does and come back
    /// describing the state we just left. relocateFocusedInput cancels
    /// its own task on every call and re-derives from unshifted geometry,
    /// so the second sample costs a query and always wins.
    private func resampleFocusedInputIfChromeMoved() {
        guard let keyboardFrame = visibleKeyboardFrame,
              !searchOverlayCoordinator.isFocused,
              !tabOverview.isPresented else { return }
        let condensed = browserChrome.isScrollCondensed
        guard condensed != liftChromeCondensed else { return }
        liftChromeCondensed = condensed

        contentView.relocateFocusedInput(
            above: keyboardFrame,
            animationDuration: UX.chromeSettleRelift,
            animationOptions: .curveEaseInOut
        )
        chromeSettleResampleTask?.cancel()
        chromeSettleResampleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self,
                  let frame = self.visibleKeyboardFrame else { return }
            self.contentView.relocateFocusedInput(
                above: frame,
                animationDuration: UX.chromeSettleRelift,
                animationOptions: .curveEaseInOut
            )
        }
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
            ? condensedContentBottomAnchor
            : (isSearchFocused ? view.safeAreaLayoutGuide.bottomAnchor : browserChrome.bottomToolbarTopAnchor)
        )
        setTabBarVisible(false)
    }
    
    /// The content view's bottom anchor while the toolbar is condensed to
    /// the pill, chosen by Prefs.AppearanceSettings.pillFloatsOverPage.
    ///
    /// These are the only two coherent behaviors and they are exclusive.
    /// Floating runs the page to the true window bottom: it paints the
    /// full height, and a long feed genuinely scrolls behind the pill,
    /// because that IS the same region - no inset, margin or viewport
    /// value separates "paints behind" from "scrolls behind". Stopping
    /// puts the page's last row at the pill's top edge, so nothing is
    /// ever behind it on any site, at the cost of the float.
    ///
    /// Note what stopping does NOT need: the shortened layout viewport.
    /// setDynamicToolbarMaxHeight is how the full toolbar reserves its
    /// strip, but it shortens Gecko's ICB without giving Gecko anything
    /// to paint there, so on a short page (google.com) the reserved
    /// strip composites as an unpainted black bar. Here the strip is
    /// simply outside the content view and shows this VC's own
    /// background, which is themed - hence maxHeight 0 when not
    /// floating (ToolbarController.updateDynamicToolbarMaxHeight).
    private var condensedContentBottomAnchor: NSLayoutYAxisAnchor {
        // Floating: the view runs to the window bottom, the page paints
        // behind the pill, and a scrolling feed passes under it - the
        // same pixels, so that is not separable. Otherwise the view
        // stops at the pill's top edge and nothing is ever behind it.
        Prefs.AppearanceSettings.pillFloatsOverPage
            ? view.bottomAnchor
            : browserChrome.condensedPillTopAnchor
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
            ? condensedContentBottomAnchor
            : browserChrome.bottomToolbarTopAnchor
        )
        setTabBarVisible(false)
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
    
    func requestContentKeyboardFocus(for expectedSession: GeckoSession? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let presentedController = presentedControllerInHierarchy {
                guard let transitionCoordinator = presentedController.transitionCoordinator else {
                    return
                }
                transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.requestContentKeyboardFocus(for: expectedSession)
                }
                return
            }
            restoreContentKeyboardFocus(for: expectedSession)
        }
    }
    
    private func restoreContentKeyboardFocus(for expectedSession: GeckoSession? = nil) {
        guard !browserChrome.isAddressBarEditing,
              let selectedSession = tabManager.selectedTab?.session else {
            return
        }
        if let expectedSession, expectedSession !== selectedSession {
            return
        }
        guard contentView.isDisplaying(session: selectedSession),
              let engineView = selectedSession.engineView,
              let window = engineView.window,
              window.isKeyWindow,
              window.windowScene?.activationState == .foregroundActive else {
            return
        }
        selectedSession.focusForHardwareKeyboard()
    }
    
    private var presentedControllerInHierarchy: UIViewController? {
        var controller: UIViewController? = self
        while let currentController = controller {
            if let presentedController = currentController.presentedViewController {
                return presentedController
            }
            controller = currentController.parent
        }
        return nil
    }
    
    /// The keyboard the user is still looking at, so a chrome
    /// transition can re-run the lift against it.
    ///
    /// ADDED for KBD-03. Capture 2026-08-25 17:36:59: the composer is
    /// lifted correctly at 197 while expanded, the toolbar then
    /// scroll-dismisses under the live keyboard, the engine viewport
    /// grows 670 -> 812 and Facebook reflows the composer to the new
    /// bottom - and nothing re-samples. Three condense/expand cycles,
    /// zero focusedInput lines, the composer left ~70pt behind the
    /// keyboard. The lift was right for a chrome state that no longer
    /// existed.
    private var visibleKeyboardFrame: CGRect?
    /// The condense state the standing lift was measured against.
    private var liftChromeCondensed: Bool?
    private var chromeSettleResampleTask: Task<Void, Never>?

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

        // DIAGNOSTIC - the else branch relocates nothing and logs
        // nothing, so a page input that never lifted was indistinguishable
        // from one this gate rejected. See the focusedInput logging in
        // ContentView.
        NSLog("focusedInput: keyboard inset=%.1f searchFocused=%@ overview=%@",
              keyboardInset,
              searchOverlayCoordinator.isFocused ? "YES" : "NO",
              tabOverview.isPresented ? "YES" : "NO")

        let isInHardwareKeyboardMode = tabManager.selectedTab?.session.isInHardwareKeyboardMode() == true
        if !searchOverlayCoordinator.isFocused
            && !tabOverview.isPresented
            && keyboardInset > 0
            && !isInHardwareKeyboardMode {
            visibleKeyboardFrame = keyboardFrame
            liftChromeCondensed = browserChrome.isScrollCondensed
            contentView.relocateFocusedInput(
                above: keyboardFrame,
                animationDuration: animation.duration,
                animationOptions: animation.curve
            )
        } else {
            forgetKeyboardLift()
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
        forgetKeyboardLift()
        contentView.resetFocusedInputRelocation(
            animationDuration: animation.duration,
            animationOptions: animation.curve
        )
        browserChrome.dockAddressBar(offset: 0)

        // Swiping the keyboard away ends the search session, exactly as
        // Cancel does.
        //
        // Without this the app is left in a state with no way out.
        // Search focus is only released where
        // isSearchAddressBarEditing is false, and dismissing the
        // keyboard does not clear the address bar's editing state - so
        // isFocused stayed true, the toolbar stayed suppressed for
        // search, and the layout went on reserving its full height for
        // it. A capture shows the state held for five seconds:
        //
        //   focusedInput: keyboard inset=0.0 searchFocused=YES
        //   dynToolbar: max=142.0 contentBottom=732.0 viewH=874.0
        //
        // 874 - 732 is the toolbar's 142pt, empty, with no control left
        // on screen to leave the page by. The only way off was tapping a
        // favourite or a recent site. Cancel already recovered it, which
        // is what says the two gestures should agree.
        //
        // Guarded on the hardware keyboard: there the inset is
        // legitimately zero while the user is still typing, and ending
        // the session under them would be its own bug. Same condition
        // the relocation path above already trusts.
        //
        // Guarded on the address bar scroll dismissal too - see
        // fix_keyboard_hide_respects_scroll_dismissal.py's docstring.
        // Dragging the suggestion list resigns the address bar on
        // purpose and keeps the session alive, and because the list
        // sets keyboardDismissMode = .none that resign is the only
        // thing that hides the keyboard. Without this term the
        // gesture ends the very session it was meant to preserve,
        // in either notification order: .pending when this arrives
        // first, .dismissed when addressBarDidEndEditing does.
        let isInHardwareKeyboardMode =
            tabManager.selectedTab?.session.isInHardwareKeyboardMode() == true
        let isDismissingAddressBarByScroll =
            overlayCoordinator.chromeStateForAddressBarScrollDismissal(layout: browserLayout) != nil
        if searchOverlayCoordinator.isFocused
            && !tabOverview.isPresented
            && !isInHardwareKeyboardMode
            && !isDismissingAddressBarByScroll {
            searchOverlayCoordinator.endSearchSession()
        }

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
        updateBrowserLayout(animated: false)
        UIApplication.shared.isIdleTimerDisabled = fullScreen
        requestContentKeyboardFocus(for: tabManager.selectedTab?.session)
    }

    /// Leave fullscreen when the page that asked for it is no longer the
    /// page on screen.
    ///
    /// ADDED - see fix_stand_down_from_orphaned_fullscreen.py's
    /// docstring. This is the same question, and the same remedy, that
    /// BrowserViewController+TabManager already applies on tab
    /// selection:
    ///
    ///     if isShowingFullscreenMedia,
    ///        fullscreenSession !== selectedTab.session {
    ///         applyFullscreenState(false, for: fullscreenSession)
    ///     }
    ///
    /// That check never runs across a background cycle, because
    /// backgrounding and foregrounding the same tab does not change the
    /// selection - and a background cycle is precisely where the
    /// fullscreenExit event is lost. sleepBackgroundedTabs REPLACES
    /// tab.session with a new object, and fullscreenSession is a weak
    /// reference to the old one.
    ///
    /// Silent and free on a glance and return: the session is untouched,
    /// owner is the same live object as the selected tab's, and a video
    /// that really is still fullscreen stays fullscreen.
    private func reynardStandDownFromOrphanedFullscreen() {
        guard isShowingFullscreenMedia else {
            return
        }
        let owner = fullscreenSession
        // owner == nil is the deallocated case and has to be spelled out:
        // when there is also no selected tab, `nil !== nil` is false and
        // the comparison alone would leave the chrome hidden with nothing
        // on screen able to bring it back.
        guard owner == nil || owner !== tabManager.selectedTab?.session else {
            return
        }
        NSLog("fullscreenState: fullscreen owner is %@ - standing down so the toolbar comes back",
              owner == nil ? "deallocated" : "no longer the selected session")
        applyFullscreenState(false, for: owner)
    }
    
    // MARK: - Orientation
    
    func lockScreenOrientation(
        to requestedOrientations: UIInterfaceOrientationMask,
        completion: @escaping (GeckoOrientationLockResult) -> Void
    ) {
        guard !requestedOrientations.isEmpty else {
            completion(.notSupported)
            return
        }
        
        rejectPendingOrientationRequest()
        
        if #available(iOS 16.0, *) {
            guard let windowScene = view.window?.windowScene else {
                completion(.notSupported)
                return
            }
            
            lockedOrientations = requestedOrientations
            setNeedsUpdateOfSupportedInterfaceOrientations()
            if let currentOrientationMask = orientationMask(
                for: windowScene.interfaceOrientation
            ), requestedOrientations.contains(currentOrientationMask) {
                completion(.success)
                return
            }
            
            let requestID = UUID()
            pendingOrientationRequest = (requestID, requestedOrientations, completion)
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
                interfaceOrientations: requestedOrientations
            )
            windowScene.requestGeometryUpdate(geometryPreferences) { [weak self] error in
                let geometryError = error as NSError
                let lockResult: GeckoOrientationLockResult =
                geometryError.domain == UISceneErrorDomain &&
                geometryError.code == UISceneError.Code.geometryRequestUnsupported.rawValue
                ? .notSupported
                : .rejected
                self?.completePendingOrientationRequest(id: requestID, with: lockResult)
            }
            return
        }
        
        guard let preferredOrientation = preferredInterfaceOrientation(
            allowedBy: requestedOrientations
        ) else {
            completion(.notSupported)
            return
        }
        
        lockedOrientations = requestedOrientations
        forceInterfaceOrientation(preferredOrientation)
        completion(.success)
    }
    
    func unlockScreenOrientation() {
        rejectPendingOrientationRequest()
        lockedOrientations = nil
        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
    
    private func completePendingOrientationRequestIfSatisfied() {
        guard let pendingOrientationRequest,
              let interfaceOrientation = view.window?.windowScene?.interfaceOrientation,
              let currentOrientationMask = orientationMask(for: interfaceOrientation),
              pendingOrientationRequest.orientations.contains(currentOrientationMask) else {
            return
        }
        
        completePendingOrientationRequest(id: pendingOrientationRequest.id, with: .success)
    }
    
    private func completePendingOrientationRequest(
        id: UUID,
        with result: GeckoOrientationLockResult
    ) {
        guard let pendingOrientationRequest,
              pendingOrientationRequest.id == id else {
            return
        }
        
        self.pendingOrientationRequest = nil
        if result != .success {
            lockedOrientations = nil
            if #available(iOS 16.0, *) {
                setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
        pendingOrientationRequest.completion(result)
    }
    
    private func rejectPendingOrientationRequest() {
        guard let pendingOrientationRequest else {
            return
        }
        
        self.pendingOrientationRequest = nil
        pendingOrientationRequest.completion(.rejected)
    }
    
    func startScreenOrientationHandling() {
        guard allowsSidebarHosting else {
            return
        }
        
        GeckoRuntime.orientationController.delegate = self
        guard let interfaceOrientation = view.window?.windowScene?.interfaceOrientation else {
            return
        }
        screenOrientationChanged(to: interfaceOrientation)
    }
    
    func stopScreenOrientationHandling() {
        guard let registeredDelegate = GeckoRuntime.orientationController.delegate,
              registeredDelegate === self else {
            return
        }
        
        rejectPendingOrientationRequest()
        GeckoRuntime.orientationController.delegate = nil
    }
    
    // ===== MARKING THE LOG =====
    //
    // ADDED - see mse_fix_122's docstring. A capture is twenty-seven
    // thousand lines and none of them say what was being done to the
    // phone, so every report of "in landscape, with the controls up,
    // the picture went black" has had to be located by scanning for a
    // plausible window. Shaking the phone puts a numbered line in the
    // log; the region between two of them is the fault.
    //
    // The same clock fix 119 stamps the parser's lines with, so a mark
    // lands exactly in the stream of everything else.
    private static var reynardMarkCount = 0

    private static let reynardMarkClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return f
    }()

    fileprivate static func reynardNote(_ message: String) {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        fputs("reynardMark: " + message + " host "
              + String(format: "%.3f", host) + "\n", stderr)
    }

    private func reynardOrientationName(
        _ orientation: UIInterfaceOrientation
    ) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }

    // A GESTURE, NOT A MOTION EVENT - see mse_fix_126's docstring. The
    // shake this replaces never fired once: motion events go to the
    // first responder, the engine view holds that from the moment a
    // page loads, and asking for it would have taken focus off the URL
    // bar.
    //
    // A recogniser is delivered by hit-testing instead, so nothing has
    // to hold first responder and nothing loses focus. Two fingers held
    // for half a second cannot happen by accident and collides with no
    // system gesture.
    private var reynardMarkGesture: UILongPressGestureRecognizer?

    fileprivate func installReynardMarkGesture() {
        guard reynardMarkGesture == nil, let window = view.window else {
            return
        }
        let press = UILongPressGestureRecognizer(
            target: self, action: #selector(reynardMarkPressed(_:)))
        press.numberOfTouchesRequired = 2
        press.minimumPressDuration = 0.5
        // The page must not notice this at all.
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        window.addGestureRecognizer(press)
        reynardMarkGesture = press
        Self.reynardNote("mark gesture installed - two fingers, half a "
                         + "second, anywhere")
    }

    @objc private func reynardMarkPressed(
        _ sender: UILongPressGestureRecognizer
    ) {
        guard sender.state == .began else { return }
        Self.reynardMarkCount += 1
        let now = Self.reynardMarkClock.string(from: Date())
        let facing = view.window?.windowScene?.interfaceOrientation
        Self.reynardNote(
            "===== MARK \(Self.reynardMarkCount) ===== by two-finger "
            + "press orientation "
            + reynardOrientationName(facing ?? .unknown)
            + " " + now)
    }

    func screenOrientationChanged(to interfaceOrientation: UIInterfaceOrientation) {
        guard interfaceOrientation != .unknown else {
            return
        }
        // ADDED - see mse_fix_122's docstring. This already runs on
        // every rotation and told nobody, and "does it happen in
        // landscape" is a question every recent capture has had to
        // answer by inference.
        Self.reynardNote("orientation -> "
                         + reynardOrientationName(interfaceOrientation))
        tabManager.selectedTab?.session.notifyScreenOrientationChanged(to: interfaceOrientation)
        completePendingOrientationRequestIfSatisfied()
    }
    
    private func preferredInterfaceOrientation(
        allowedBy orientations: UIInterfaceOrientationMask
    ) -> UIInterfaceOrientation? {
        if let currentOrientation = view.window?.windowScene?.interfaceOrientation,
           currentOrientation != .unknown,
           let currentOrientationMask = orientationMask(for: currentOrientation),
           orientations.contains(currentOrientationMask) {
            return currentOrientation
        }
        
        if orientations.contains(.portrait) {
            return .portrait
        }
        if orientations.contains(.portraitUpsideDown) {
            return .portraitUpsideDown
        }
        if orientations.contains(.landscapeRight) {
            return .landscapeRight
        }
        if orientations.contains(.landscapeLeft) {
            return .landscapeLeft
        }
        return nil
    }
    
    private func orientationMask(
        for orientation: UIInterfaceOrientation
    ) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            return nil
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
