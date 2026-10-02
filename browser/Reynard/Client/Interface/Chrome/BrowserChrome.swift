//
//  BrowserChrome.swift
//  Reynard
//
//  Created by Minh Ton on 10/6/26.
//

import UIKit

final class BrowserChrome: UIView {
    /// The pill's own bottom margin from the safe area guide — named so
    /// it's referenced once, not duplicated as a bare "-4" wherever the
    /// pill is positioned.
    static let condensedPillBottomMargin: CGFloat = 20
    
    /// How far above the true bottom of the pill's own clearance the
    /// artificial safe-area boundary should sit. Reached empirically
    /// (bisecting between "too low, overlapping a page's own fixed bar"
    /// and "too far up, gap looked too large") rather than derived from
    /// a formula.
    ///
    /// RAISED 14 -> 32 to lower the pill - see
    /// fix_lower_condensed_pill.py's docstring.
    ///
    /// This is the constant that actually moves it.
    /// condensedPillBottomMargin does not: it appears both in the
    /// pill's constraint against the safe area guide AND in the
    /// artificial inset that inflates that same guide, so raising it
    /// pushes the pill down and up simultaneously and largely cancels
    /// out. This constant appears only in the inset, so raising it
    /// shrinks the guide and the pill follows it down 1:1.
    ///
    /// Web content's env(safe-area-inset-bottom) shrinks by the same
    /// amount, which is the intended coupling rather than a side
    /// effect - the pill is moving into that space, so the strip
    /// reserved above it should shrink to match. That matters more now
    /// that safe-area detection works and pages actually position
    /// against this value.
    private static let condensedPillClearanceBuffer: CGFloat = 32
    
    /// Pill height plus its bottom margin - how much of the screen the
    /// condensed chrome occupies. Reported to Gecko as the dynamic
    /// toolbar max, which shrinks the ICB by exactly this much, so
    /// document content ends level with the pill's top edge.
    static var condensedPillOccupiedHeight: CGFloat {
        return condensedPillBottomMargin + CondensedAddressPill.height
    }
    private enum UX {
        static let overlayTopSpacing: CGFloat = 12
        static let actionBarSpacing: CGFloat = 0
        static let actionBarAnimationDuration: TimeInterval = 0.12
    }
    
    enum PresentationState {
        case browsing
        case tabOverview
        case fullscreenMedia
    }
    
    enum SearchState {
        case inactive
        case focused
        case scrollingEmbeddedSuggestions
        case scrollingDetachedSuggestions
        
        var showsAddressBarDismissButton: Bool {
            switch self {
            case .inactive:
                return false
            case .focused, .scrollingEmbeddedSuggestions, .scrollingDetachedSuggestions:
                return true
            }
        }
    }
    
    struct State {
        let position: BrowserChromePosition
        let mode: BrowserChromeMode
        let presentation: PresentationState
        let search: SearchState
        let topInset: CGFloat
        let interfaceIdiom: UIUserInterfaceIdiom
        let orientation: BrowserLayout.ViewportOrientation
        let isTwoThirdSplitScreenOrSmaller: Bool
        let sidebarButtonVisible: Bool
        let animatesChromeStateChanges: Bool
    }
    
    var onSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onShare: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onBookmarks: (() -> Void)?
    var onHistory: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onSettings: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onReload: (() -> Void)?
    var onTabOverview: (() -> Void)?
    var onOverlayDismiss: (() -> Void)?
    var onActionBarVisibilityChanged: ((Bool) -> Void)?
    var onPageZoomOut: (() -> Void)?
    var onPageZoomIn: (() -> Void)?
    var onPageZoomReset: (() -> Void)?
    
    private let addressBar: AddressBar = {
        let view = AddressBar()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let topToolbar: TopToolbar
    private let bottomToolbar: BottomToolbar
    private let condensedPill = CondensedAddressPill()
    private let overlayDismissView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isHidden = true
        return view
    }()
    private let overlayContentView = ChromeOverlayContentView()
    private let actionBar = ActionBar()
    
    private var bottomConstraint: NSLayoutConstraint!
    private var overlayWidthConstraint: NSLayoutConstraint!
    private var overlayHeightConstraint: NSLayoutConstraint!
    private var overlayTopConstraint: NSLayoutConstraint?
    private var overlayCenterXConstraint: NSLayoutConstraint?
    private var actionBarTopConstraint: NSLayoutConstraint?
    private var actionBarBottomConstraint: NSLayoutConstraint?
    
    // The pill's travel between the address capsule and its resting
    // place - see fix_pill_morphs_from_the_address_capsule.py. The
    // first line is the off switch: false restores the cross-fade.
    private static let pillMorphsFromAddressCapsule = true
    private var pillCenterXConstraint: NSLayoutConstraint!
    private var pillBottomConstraint: NSLayoutConstraint!
    private var pillRestingConstraints: [NSLayoutConstraint] = []
    private var pillMorphWidthConstraint: NSLayoutConstraint!
    private var pillMorphGeneration = 0
    
    private var state: State?
    private(set) var isScrollCondensed = false
    /// Fires whenever `setScrollCondensed` actually changes state (not on
    /// redundant calls). `BrowserViewController` uses this to extend the
    /// content view down to fill the space the full-size toolbar used to
    /// occupy — condensing the toolbar to a pill only fades it out, it
    /// doesn't shrink its layout frame, so without this the content view
    /// stays pinned to where the toolbar's top edge always was.
    var onScrollCondensedChange: ((Bool) -> Void)?
    
    // MARK: - Lifecycle
    
    init() {
        topToolbar = TopToolbar()
        bottomToolbar = BottomToolbar()
        super.init(frame: .zero)
        configureAppearance()
        configureHierarchy()
        configureConstraints()
        configureToolbarActions()
        configureOverlayDismissGesture()
        condensedPill.onTap = { [weak self] in
            self?.setScrollCondensed(false, animated: true)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateOverlayWidth()
    }
    
    // MARK: - Anchors And Frames
    
    var topToolbarBottomAnchor: NSLayoutYAxisAnchor {
        return topToolbar.bottomAnchor
    }
    
    var bottomToolbarTopAnchor: NSLayoutYAxisAnchor {
        return bottomToolbar.topAnchor
    }
    
    /// The pill's own top edge — used as content's bottom anchor while
    /// scroll-condensed on pages the SafeAreaDetector addon confirmed
    /// use env(safe-area-inset-bottom), the same trick the full-size
    /// toolbar already uses via bottomToolbarTopAnchor. Not used
    /// unconditionally — only on pages confirmed to actually respect
    /// the CSS boundary; other pages get the full screen extent
    /// instead, with the pill floating over them as before.
    var condensedPillTopAnchor: NSLayoutYAxisAnchor {
        return condensedPill.topAnchor
    }
    
    var addressBarBottomAnchor: NSLayoutYAxisAnchor {
        return addressBar.bottomAnchor
    }
    
    /// The pill's real frame, for logging the gap it is supposed to
    /// leave against the value the page was actually given.
    func condensedPillFrame(in view: UIView) -> CGRect {
        return condensedPill.convert(condensedPill.bounds, to: view)
    }
    
    func addressBarFrame(in view: UIView) -> CGRect {
        return addressBar.convert(addressBar.bounds, to: view)
    }
    
    func sharePopoverSourceView() -> UIView {
        guard let state else { return bottomToolbar }
        return state.mode == .phone ? bottomToolbar : topToolbar
    }
    
    // MARK: - Layout
    
    func apply(state: State) {
        self.state = state
        if state.presentation != .browsing || state.search != .inactive {
            // Never stay scroll-condensed while search, tab overview, or
            // fullscreen media is active — those have their own chrome
            // rules and scroll-driven condensing would just be confusing.
            setScrollCondensed(false, animated: false)
        }
        addressBar.updateLayout(position: state.position, chromeMode: state.mode)
        attachAddressBar(for: state.mode)
        attachActionBar(for: state.mode)
        configureOverlayPositioningIfNeeded()
        overlayContentView.setLayoutMode(overlayLayoutMode(for: state))
        updateOverlayWidth()
        updateOverlayHeight()
        let canUseActionBar = state.presentation == .browsing && state.search == .inactive
        actionBar.isUserInteractionEnabled = canUseActionBar
        if !canUseActionBar {
            dismissActionBar(animated: false)
        }
        
        let topState: TopToolbar.LayoutState
        let bottomState: BottomToolbar.LayoutState
        if state.presentation != .browsing {
            topState = .hidden
            bottomState = state.mode == .compact ? .collapsed : .hidden
        } else {
            topState = resolvedTopState(for: state)
            bottomState = resolvedBottomState(for: state)
        }
        
        topToolbar.apply(
            state: topState,
            topInset: state.topInset,
            interfaceIdiom: state.interfaceIdiom,
            sidebarButtonVisible: state.sidebarButtonVisible
        )
        bottomToolbar.apply(
            state: bottomState,
            hidesButtons: state.search == .scrollingEmbeddedSuggestions
        )
        addressBar.setDismissButtonVisible(
            state.search.showsAddressBarDismissButton && state.presentation == .browsing,
            animated: state.animatesChromeStateChanges
        )
    }
    
    func dockAddressBar(offset: CGFloat) {
        bottomConstraint.constant = offset
        bottomToolbar.setVerticalOffset(offset)
    }
    
    // MARK: - Action Bar
    
    func showActionBar(_ item: ActionBar.Item, animated: Bool) {
        guard state?.presentation == .browsing,
              state?.search == .inactive else {
            return
        }
        
        actionBar.setItem(item)
        showActionBar(animated: animated)
    }
    
    func dismissActionBar(animated: Bool) {
        guard !actionBar.isHidden else { return }
        
        let finish = {
            self.actionBar.setItem(nil)
            self.onActionBarVisibilityChanged?(false)
        }
        
        guard animated else {
            actionBar.alpha = 0
            finish()
            return
        }
        
        UIView.animate(withDuration: UX.actionBarAnimationDuration, animations: {
            self.actionBar.alpha = 0
        }) { _ in
            finish()
        }
    }
    
    func setPageZoomLevel(_ level: Int) {
        actionBar.setPageZoomLevel(level)
    }

    func syncPageZoomControls(level: Int, maximumLevel: Int) {
        actionBar.setMaximumPageZoomLevel(maximumLevel)
        actionBar.setPageZoomLevel(level)
    }
    
    func nextPageZoomLevel() -> Int {
        return actionBar.nextPageZoomLevel()
    }
    
    func previousPageZoomLevel() -> Int {
        return actionBar.previousPageZoomLevel()
    }
    
    // MARK: - Overlay Content
    
    func setOverlayPresentation(
        _ presentation: ChromeOverlayContentView.PresentationState,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        setOverlayDismissViewVisible(presentation != .hidden)
        overlayContentView.setPresentation(presentation, animated: animated) { [weak self] in
            self?.setOverlayDismissViewVisible(presentation != .hidden)
            completion?()
        }
    }
    
    func setOverlayHeightMode(_ heightMode: ChromeOverlayContentView.HeightMode) {
        overlayContentView.setHeightMode(heightMode)
        updateOverlayHeight()
    }
    
    func setOverlayContentHeight(_ contentHeight: CGFloat) {
        overlayContentView.setContentHeight(contentHeight)
        updateOverlayHeight()
    }
    
    func setOverlayAvailableContentHeight(_ availableContentHeight: CGFloat) {
        overlayContentView.setAvailableContentHeight(availableContentHeight)
        updateOverlayHeight()
    }
    
    func setOverlayController(
        _ viewController: UIViewController,
        for page: ChromeOverlayContentView.Page,
        in parentViewController: UIViewController
    ) {
        overlayContentView.setController(viewController, for: page, in: parentViewController)
    }
    
    func removeOverlayController(for page: ChromeOverlayContentView.Page) {
        overlayContentView.removeController(for: page)
    }
    
    private func updateOverlayHeight() {
        overlayHeightConstraint.constant = overlayContentView.resolvedHeight
    }
    
    private func updateOverlayWidth() {
        overlayWidthConstraint.constant = overlayContentView.layoutMode.resolvedWidth(addressBarWidth: addressBar.bounds.width)
    }
    
    private func overlayLayoutMode(for state: State) -> ChromeOverlayContentView.LayoutMode {
        switch (state.interfaceIdiom, state.orientation) {
        case (.pad, .portrait):
            return .padPortrait
        case (.pad, .landscape) where state.isTwoThirdSplitScreenOrSmaller:
            return .padConstrained
        case (.pad, .landscape):
            return .padLandscape
        default:
            return .phoneLandscape
        }
    }
    
    private func configureOverlayPositioningIfNeeded() {
        guard overlayTopConstraint?.isActive != true,
              overlayCenterXConstraint?.isActive != true else {
            return
        }
        
        NSLayoutConstraint.deactivate([overlayTopConstraint, overlayCenterXConstraint].compactMap { $0 })
        let topConstraint = overlayContentView.topAnchor.constraint(
            equalTo: addressBar.bottomAnchor,
            constant: UX.overlayTopSpacing
        )
        let centerXConstraint = overlayContentView.centerXAnchor.constraint(equalTo: addressBar.centerXAnchor)
        NSLayoutConstraint.activate([topConstraint, centerXConstraint])
        overlayTopConstraint = topConstraint
        overlayCenterXConstraint = centerXConstraint
    }
    
    // MARK: - Address Bar
    
    func configureAddressBar(
        delegate: AddressBarDelegate,
        searchDelegate: AddressBarSearchDelegate,
        gestureDelegate: AddressBarGestureDelegate
    ) {
        addressBar.configure(
            delegate: delegate,
            searchDelegate: searchDelegate,
            gestureDelegate: gestureDelegate
        )
    }
    
    func setAddressBarText(
        _ text: String?,
        locationText: String?,
        locationTitle: String?,
        showsBarMenu: Bool
    ) {
        addressBar.setText(
            text,
            locationText: locationText,
            locationTitle: locationTitle,
            showsBarMenu: showsBarMenu
        )
        condensedPill.setLocationText(locationText ?? text)
    }
    
    /// Condenses the top and bottom toolbars into a small floating pill
    /// (or expands back), matching Safari's scroll behavior. As with
    /// `ScrollChromeCoordinator` generally, this is driven by gesture
    /// direction rather than true scroll position, since GeckoView
    /// exposes no real scroll-offset API.
    /// What the three chrome views actually are when a condense settles.
    ///
    /// Every dynToolbar line reports what the app SENDS. None reports
    /// whether UIKit drew the chrome at all, and that is the one thing
    /// no geometry value can stand in for: a screen recording caught the
    /// bottom 168pt painting neither the pill nor the toolbar nor the
    /// page, with the frames either side of a condense-to-expand
    /// transition pixel-identical, while every sent value was correct
    /// (contentBottom 874 condensed, 732 expanded, engine max 0 then
    /// 426, all within one millisecond).
    ///
    /// Two states are indistinguishable in the logs that exist and need
    /// opposite fixes: the views being wrong - hidden, transparent, out
    /// of the window, or framed outside it - versus the views being
    /// right and that region never being presented. alpha, isHidden,
    /// window and the window-space frame separate them in one capture.
    ///
    /// Window-space, not local: a correct alpha on a view whose frame
    /// has left the window looks identical from inside the view.
    ///
    /// Called from ToolbarController.updateLayout as well as from the
    /// condense animation, and that is the whole point. The first version
    /// logged only from setScrollCondensed, which opens with
    /// `guard condensed != isScrollCondensed` - so a state entered by
    /// ROTATING produced no line at all. A capture with the bug twice
    /// reproduced and twice rotated therefore showed nothing but healthy
    /// condense transitions, and the black band went unseen through three
    /// captures because of it.
    ///
    /// Deduplicated on the formatted line: a layout pass runs on every
    /// scroll tick, and 700 identical lines is how a real one gets
    /// missed. Only changes print, so the bad state is the line that
    /// stands out.
    private var lastChromeState = ""

    func logChromeState(_ phase: String) {
        func describe(_ label: String, _ view: UIView) -> String {
            let frame = view.convert(view.bounds, to: window)
            return String(format: "%@ a=%.2f hid=%d win=%d f=%.0f,%.0f %.0fx%.0f",
                          label, view.alpha, view.isHidden ? 1 : 0,
                          view.window == nil ? 0 : 1,
                          frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height)
        }
        // ca= is the content alpha, and it is the whole reason this bug
        // survived four captures. A toolbar whose own alpha is 1, is
        // unhidden, is in the window and is at the right y still renders
        // as an EMPTY bar if its contentView alpha is 0 - painted black
        // by the OLED overlay, translucent without it, and in both cases
        // exactly the band that was being reported while every value
        // logged here said the chrome was fine.
        let line = String(format: "condensed=%d | %@ ca=%.2f | %@ ca=%.2f | %@",
                          isScrollCondensed ? 1 : 0,
                          describe("top", topToolbar), topToolbar.contentAlpha,
                          describe("bottom", bottomToolbar), bottomToolbar.contentAlpha,
                          describe("pill", condensedPill))
        guard line != lastChromeState else {
            return
        }
        lastChromeState = line
        NSLog("chromeState: %@ %@", phase, line)
    }

    func setScrollCondensed(_ condensed: Bool, animated: Bool) {
        guard condensed != isScrollCondensed else {
            return
        }
        // Where the address capsule is ON SCREEN and what it shows, read
        // before the callback below moves anything - see
        // fix_pill_morphs_from_the_address_capsule.py.
        let morphSource = animated && condensed ? pillMorphSource() : nil
        isScrollCondensed = condensed
        onScrollCondensedChange?(condensed)
        // After the callback, not before: it can re-enter this method,
        // and the call that finishes last is the one whose completion
        // has to settle the pill.
        pillMorphGeneration += 1
        let morphGeneration = pillMorphGeneration
        
        if condensed {
            condensedPill.isHidden = false
        }
        
        // The pill travels between the capsule and its resting place
        // instead of cross-fading where it ends up. The LIVE flag once
        // more: a morph prepared for a state the re-entrant call
        // already reversed would strand the pill on the capsule.
        let requestedCondensed = condensed
        let morphDestination = animated && isScrollCondensed == condensed
            ? preparePillMorph(condensing: condensed, source: morphSource)
            : nil
        if morphDestination == nil {
            settlePillMorph()
        }
        
        let animations = {
            // Read the LIVE flag, not the captured parameter.
            // onScrollCondensedChange (fired above, before any
            // animation) runs applyBrowserLayout, and apply(state:)
            // force-expands while search or a non-browsing
            // presentation is active - re-entering this method and
            // flipping the flag before the outer call's animation
            // block has run. Animating toward the captured value
            // then strands the chrome in the state the re-entrant
            // call just left - toolbars at alpha 0 with the flag
            // already false, which no later call can repair because
            // of the change guard at the top. Reading the flag makes
            // a stale animation converge on whatever state won.
            let condensed = self.isScrollCondensed
            self.topToolbar.alpha = condensed ? 0 : 1
            self.topToolbar.transform = condensed
                ? CGAffineTransform(scaleX: 0.92, y: 0.92)
                : .identity
            self.bottomToolbar.alpha = condensed ? 0 : 1
            self.bottomToolbar.transform = condensed
                ? CGAffineTransform(scaleX: 0.92, y: 0.92)
                : .identity
            if let morphDestination, condensed == requestedCondensed {
                // Travels rather than fades - see
                // fix_pill_morphs_from_the_address_capsule.py. Opaque
                // the whole way; an expand's completion retires it.
                self.condensedPill.alpha = 1
                switch morphDestination {
                case .resting:
                    self.setPillMorphRect(nil)
                case .capsule(let rect):
                    self.setPillMorphRect(rect)
                }
                self.layoutIfNeeded()
            } else {
                self.condensedPill.alpha = condensed ? 1 : 0
            }
            // Assert the CONTENT alpha too, not just the view's.
            //
            // Two systems drive this toolbar and neither knew about the
            // other's alpha. setToolbarTransition, from the scroll path,
            // fades contentView as the bar slides; this method resets
            // alpha and transform but never touched contentView, so a
            // condense-then-expand after a scroll fade put the toolbar
            // back in place with no buttons in it. The background still
            // paints - black under the OLED overlay, translucent without
            // it - which is the band, and is why tapping the pill never
            // recovered: expanding restored everything except the one
            // value that was wrong.
            //
            // Expanding means fully shown, so 1 is not a guess about what
            // the scroll left behind; it is what expanded means.
            self.topToolbar.setContentAlpha(condensed ? 0 : 1)
            self.bottomToolbar.setContentAlpha(condensed ? 0 : 1)
            self.logChromeState("applied")
        }

        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self else {
                return
            }
            // Before the condensed guard below, not after: that guard
            // returns while condensed, which is exactly half the
            // transitions and the half the pill is meant to be visible
            // for.
            // Only the latest transition settles the pill - see
            // fix_pill_morphs_from_the_address_capsule.py. An earlier
            // one's completion can land while its successor is still
            // moving the pill, and hiding it there would cut the
            // successor off mid-flight.
            let isLatest = morphGeneration == self.pillMorphGeneration
            if isLatest {
                if !self.isScrollCondensed {
                    // The pill and the real capsule trade places in
                    // one frame: same rect, same glass, same content.
                    self.condensedPill.alpha = 0
                }
                self.settlePillMorph()
            }
            self.logChromeState("settled")
            guard isLatest, !self.isScrollCondensed else {
                return
            }
            self.condensedPill.isHidden = true
        }
        
        guard animated else {
            animations()
            completion(true)
            return
        }
        
        UIView.animate(
            // A travelling capsule wants a little longer than a
            // cross-fade - see fix_pill_morphs_from_the_address_capsule.py.
            withDuration: morphDestination == nil ? 0.28 : 0.42,
            delay: 0,
            usingSpringWithDamping: morphDestination == nil ? 0.85 : 0.88,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState],
            animations: animations,
            completion: completion
        )
    }
    
    // MARK: - Pill Morph
    //
    // ADDED - see fix_pill_morphs_from_the_address_capsule.py.
    //
    // Condensing used to cross-fade two things that never touched: the
    // toolbars faded where they stood and the pill faded in 70pt lower
    // at its final size. The pill is now the element that travels. For
    // the first frame it sits exactly on the address capsule, wearing a
    // replica of the capsule's text and icons over the same glass; then
    // its real frame - not a transform, so it stays a capsule and its
    // text is never stretched - animates to the resting place. Expanding
    // runs it the other way and hands back to the real capsule.
    
    private enum PillMorphTarget {
        case resting
        case capsule(CGRect)
    }
    
    private struct PillMorphSource {
        let rect: CGRect
        let replica: UIView?
        let contentAlpha: CGFloat
    }
    
    /// Whether the pill can travel at all. The address bar has to be the
    /// bottom toolbar's - from the top toolbar the trip would cross the
    /// whole screen - and Reduce Motion keeps the cross-fade.
    ///
    /// Floating pill only. When the page STOPS at the pill instead, the
    /// content view's bottom edge IS the pill's top edge
    /// (condensedContentBottomAnchor), and a travelling pill would drag
    /// the page's edge along for the length of the animation - the
    /// continuously-changing size onScrollCondensedChange exists to
    /// avoid. Floating, nothing outside this view depends on the pill.
    private var canMorphPill: Bool {
        return Self.pillMorphsFromAddressCapsule
            && Prefs.AppearanceSettings.pillFloatsOverPage
            && !UIAccessibility.isReduceMotionEnabled
            && window != nil
            && addressBar.isDescendant(of: bottomToolbar)
            && !bottomToolbar.isHidden
    }
    
    /// The capsule as it is on screen at this instant: its rect in this
    /// view, slide and all, and a replica of what it shows.
    private func pillMorphSource() -> PillMorphSource? {
        guard canMorphPill, bottomToolbar.alpha > 0.01, !addressBar.isEditingText else {
            return nil
        }
        let rect = addressBar.capsuleFrame(in: self)
        guard rect.width > 1, rect.height > 1 else {
            return nil
        }
        return PillMorphSource(
            rect: rect,
            replica: addressBar.capsuleForegroundReplica(),
            contentAlpha: bottomToolbar.contentAlpha
        )
    }
    
    /// Where the capsule sits once the toolbar is back at rest: its rect
    /// inside the toolbar, placed by the toolbar's LAID-OUT frame. The
    /// toolbar wears a slide or the condense scale while the pill is up,
    /// and convert() through it would honour either.
    private func addressCapsuleRestingRect() -> CGRect? {
        guard canMorphPill else {
            return nil
        }
        let local = addressBar.capsuleFrame(in: bottomToolbar)
        guard local.width > 1, local.height > 1 else {
            return nil
        }
        return local.offsetBy(
            dx: bottomToolbar.center.x - bottomToolbar.bounds.midX,
            dy: bottomToolbar.center.y - bottomToolbar.bounds.midY
        )
    }
    
    /// Puts the pill at `rect` in this view's coordinates, or back on its
    /// resting constraints for nil. Layout only - the caller decides
    /// whether the pass that follows is animated.
    private func setPillMorphRect(_ rect: CGRect?) {
        guard let rect else {
            pillMorphWidthConstraint.isActive = false
            NSLayoutConstraint.activate(pillRestingConstraints)
            pillCenterXConstraint.constant = 0
            pillBottomConstraint.constant = -Self.condensedPillBottomMargin
            condensedPill.setMorphHeight(nil)
            return
        }
        NSLayoutConstraint.deactivate(pillRestingConstraints)
        pillMorphWidthConstraint.constant = rect.width
        pillMorphWidthConstraint.isActive = true
        pillCenterXConstraint.constant = rect.midX - bounds.midX
        pillBottomConstraint.constant = rect.maxY - bounds.maxY
        condensedPill.setMorphHeight(rect.height)
    }
    
    /// Readies the pill to travel and returns where to, or nil when this
    /// transition cross-fades as before.
    private func preparePillMorph(condensing: Bool, source: PillMorphSource?) -> PillMorphTarget? {
        if condensing {
            if condensedPill.alpha > 0.01 {
                // An expand being reversed: the pill is already out and
                // carries on from wherever it has got to.
                guard canMorphPill else {
                    return nil
                }
                // The callback's layout is snapped, never animated -
                // see onScrollCondensedChange. Flushed here so the
                // animated pass that follows cannot pick it up.
                UIView.performWithoutAnimation {
                    layoutIfNeeded()
                }
                condensedPill.removeMorphReplica()
                addressBar.setCapsuleHiddenForPillMorph(true)
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.beginFromCurrentState, .curveEaseOut],
                    animations: { self.condensedPill.setLabelAlpha(1) },
                    completion: nil
                )
                return .resting
            }
            guard let source else {
                return nil
            }
            UIView.performWithoutAnimation {
                // Flush what the callback changed first. Its resize of
                // the content view is deliberately snapped, so the
                // engine gets its final size at once; the animated
                // pass that follows must move the pill and nothing else.
                layoutIfNeeded()
                condensedPill.setLabelAlpha(0)
                if let replica = source.replica {
                    condensedPill.installMorphReplica(replica, alpha: source.contentAlpha)
                } else {
                    condensedPill.removeMorphReplica()
                }
                setPillMorphRect(source.rect)
                condensedPill.alpha = 1
                layoutIfNeeded()
                addressBar.setCapsuleHiddenForPillMorph(true)
            }
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: { self.condensedPill.setMorphReplicaAlpha(0) },
                completion: nil
            )
            UIView.animate(
                withDuration: 0.24,
                delay: 0.1,
                options: [.beginFromCurrentState, .curveEaseOut],
                animations: { self.condensedPill.setLabelAlpha(1) },
                completion: nil
            )
            return .resting
        }
        
        guard condensedPill.alpha > 0.01, !condensedPill.isHidden,
              let destination = addressCapsuleRestingRect() else {
            return nil
        }
        UIView.performWithoutAnimation {
            layoutIfNeeded()
            if let replica = addressBar.capsuleForegroundReplica() {
                condensedPill.installMorphReplica(replica, alpha: 0)
            } else {
                condensedPill.removeMorphReplica()
            }
            addressBar.setCapsuleHiddenForPillMorph(true)
        }
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut],
            animations: { self.condensedPill.setLabelAlpha(0) },
            completion: nil
        )
        UIView.animate(
            withDuration: 0.22,
            delay: 0.14,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: { self.condensedPill.setMorphReplicaAlpha(1) },
            completion: nil
        )
        return .capsule(destination)
    }
    
    /// Returns the pill and the capsule to their own places: the capsule
    /// visible again, the replica gone, the pill on its resting
    /// constraints. Safe at any time and from either state; it forces a
    /// layout pass only when the pill really is somewhere else.
    private func settlePillMorph() {
        addressBar.setCapsuleHiddenForPillMorph(false)
        condensedPill.removeMorphReplica()
        condensedPill.setLabelAlpha(1)
        guard pillMorphWidthConstraint.isActive else {
            return
        }
        UIView.performWithoutAnimation {
            setPillMorphRect(nil)
            layoutIfNeeded()
        }
    }
    
    func updateAddressBarMenu(url: String?, usesDesktopWebsite: Bool?, airPlayTitle: String?) {
        addressBar.updateMenu(url: url, usesDesktopWebsite: usesDesktopWebsite, airPlayTitle: airPlayTitle)
    }
    
    func setAddressBarLoadingProgress(_ progress: Float, isLoading: Bool) {
        addressBar.setLoadingProgress(progress, isLoading: isLoading)
    }
    
    func setAddressBarEditingState(_ state: AddressBar.EditingState) {
        addressBar.setEditingState(state)
    }
    
    func setPreservesAddressBarAutocompleteAfterResign(_ preserves: Bool) {
        addressBar.setPreservesAutocompleteAfterResign(preserves)
    }
    
    func clearAddressBarAutocomplete() {
        addressBar.clearAutocomplete()
    }
    
    func recordAddressBarEdit(previousText: String, currentText: String, isDelete: Bool) {
        addressBar.recordEditForAutocomplete(previousText: previousText, currentText: currentText, isDelete: isDelete)
    }
    
    func applyAddressBarAutocomplete(query: String, result: UserDataSearchResult?, topDomain: String?) {
        addressBar.applySearchAutocomplete(query: query, result: result, topDomain: topDomain)
    }
    
    func resetAddressBarEditing() {
        _ = addressBar.resignFirstResponder()
        addressBar.clearAutocomplete()
        addressBar.setPreservesAutocompleteAfterResign(false)
        addressBar.setEditingState(.inactive)
    }
    
    func resetHorizontalTransition() { addressBar.resetHorizontalTransition() }
    
    func performAfterTransition(_ completion: @escaping () -> Void) -> Bool {
        addressBar.performAfterTransition(completion)
    }
    
    func resignAddressBarFirstResponder() { _ = addressBar.resignFirstResponder() }
    @discardableResult
    func focusAddressBar() -> Bool { return addressBar.becomeFirstResponder() }
    
    func performAfterAddressBarMenuDismissal(_ action: @escaping () -> Void) {
        addressBar.performAfterMenuDismissal(action)
    }

    func invalidateAddressBarMenuPresentation() {
        addressBar.invalidateMenuPresentation()
    }
    
    func animateAutomaticNewTabTransition(to tab: Tab, completion: @escaping () -> Void) {
        addressBar.animateAutomaticNewTabTransition(to: tab, completion: completion)
    }
    
    var isAddressBarEditing: Bool { return addressBar.isEditingText }
    var isShowingAddressBarAutocomplete: Bool { return addressBar.isShowingAutocomplete }
    
    // MARK: - Toolbar Updates
    
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, canShare: Bool) {
        topToolbar.updateNavigation(canGoBack: canGoBack, canGoForward: canGoForward, canShare: canShare)
        bottomToolbar.updateNavigation(canGoBack: canGoBack, canGoForward: canGoForward, canShare: canShare)
    }
    
    func updateDownload(_ summary: DownloadStoreSummary) {
        bottomToolbar.updateDownload(summary)
        topToolbar.updateDownload(summary)
    }
    
    func syncSidebarButton(splitViewController: UISplitViewController?) {
        topToolbar.syncSidebarButton(splitViewController: splitViewController)
    }
    
    // MARK: - Action Wiring
    
    private func configureToolbarActions() {
        topToolbar.onSidebar = { [weak self] in self?.onSidebar?() }
        topToolbar.onBack = { [weak self] in self?.onBack?() }
        topToolbar.onForward = { [weak self] in self?.onForward?() }
        topToolbar.onShare = { [weak self] in self?.onShare?() }
        topToolbar.onLibrary = { [weak self] in self?.onLibrary?() }
        topToolbar.onDownloads = { [weak self] in self?.onDownloads?() }
        topToolbar.onNewTab = { [weak self] in self?.onNewTab?() }
        topToolbar.onTabOverview = { [weak self] in self?.onTabOverview?() }
        
        bottomToolbar.onBack = { [weak self] in self?.onBack?() }
        bottomToolbar.onForward = { [weak self] in self?.onForward?() }
        bottomToolbar.onShare = { [weak self] in self?.onShare?() }
        bottomToolbar.onBookmarks = { [weak self] in self?.onBookmarks?() }
        bottomToolbar.onHistory = { [weak self] in self?.onHistory?() }
        bottomToolbar.onDownloads = { [weak self] in self?.onDownloads?() }
        bottomToolbar.onSettings = { [weak self] in self?.onSettings?() }
        bottomToolbar.onTabOverview = { [weak self] in self?.onTabOverview?() }
        bottomToolbar.onReload = { [weak self] in self?.onReload?() }
        bottomToolbar.onPageZoom = { [weak self] in
            guard let self else { return }
            if !self.actionBar.isHidden, self.actionBar.item == .pageZoom {
                self.dismissActionBar(animated: true)
                return
            }
            if let level = self.addressBar.currentPageZoomLevel() {
                self.syncPageZoomControls(
                    level: level,
                    maximumLevel: self.addressBar.maximumPageZoomLevel()
                )
            }
            self.showActionBar(.pageZoom, animated: true)
        }
        bottomToolbar.onNewTab = { [weak self] in self?.onNewTab?() }
        bottomToolbar.onCloseTab = { [weak self] in self?.onCloseTab?() }
        
        actionBar.onPageZoomOut = { [weak self] in self?.onPageZoomOut?() }
        actionBar.onPageZoomIn = { [weak self] in self?.onPageZoomIn?() }
        actionBar.onPageZoomReset = { [weak self] in self?.onPageZoomReset?() }
        actionBar.onClose = { [weak self] in self?.dismissActionBar(animated: true) }
    }
    
    // MARK: - Transitions
    
    func bottomToolbarTransitionView() -> UIView? {
        return bottomToolbar.snapshotView(afterScreenUpdates: false)
    }
    
    func bottomToolbarTransitionFrame(in view: UIView) -> CGRect {
        return bottomToolbar.convert(bottomToolbar.bounds, to: view)
    }
    
    func topToolbarTransitionView() -> UIView? {
        return topToolbar.snapshotView(afterScreenUpdates: false)
    }
    
    func topToolbarTransitionFrame(in view: UIView) -> CGRect {
        return topToolbar.convert(topToolbar.bounds, to: view)
    }
    
    /// The toolbars' laid-out heights, independent of any transform.
    /// The transitionFrame variants go through convert(), which
    /// honours the condense scale (0.92): a layout pass landing in
    /// the expand window - the condensed flag already false, the
    /// transform not yet reset - measured ~130.6pt for a 142pt
    /// toolbar, which went to the engine as a wrong dynamic-toolbar
    /// max (an extra ICB reflow at the wrong size) and tripped
    /// updateLayout's drift guard into reset(animated: false), twice
    /// per transition. bounds are what layout produced and
    /// transforms never touch them.
    func topToolbarRestingHeight() -> CGFloat {
        return topToolbar.bounds.height
    }
    
    func bottomToolbarRestingHeight() -> CGFloat {
        return bottomToolbar.bounds.height
    }
    
    func setToolbarTransition(
        topOffset: CGFloat,
        bottomOffset: CGFloat,
        topContentAlpha: CGFloat,
        bottomContentAlpha: CGFloat
    ) {
        topToolbar.transform = CGAffineTransform(translationX: 0, y: topOffset)
        topToolbar.setContentAlpha(topContentAlpha)
        bottomToolbar.transform = CGAffineTransform(translationX: 0, y: bottomOffset)
        bottomToolbar.setContentAlpha(bottomContentAlpha)
        actionBar.transform = CGAffineTransform(translationX: 0, y: bottomOffset)
    }
    
    func setChromeTransition(topAlpha: CGFloat, bottomAlpha: CGFloat, bottomTranslationY: CGFloat = 0) {
        topToolbar.alpha = topAlpha
        bottomToolbar.alpha = bottomAlpha
        bottomToolbar.transform = CGAffineTransform(translationX: 0, y: bottomTranslationY)
        actionBar.transform = CGAffineTransform(translationX: 0, y: bottomTranslationY)
    }
    
    func setBottomToolbarHidden(_ hidden: Bool) {
        bottomToolbar.isHidden = hidden
    }
    
    func sidebarButtonFrame(in view: UIView) -> CGRect {
        return topToolbar.sidebarButtonFrame(in: view)
    }
    
    func setSidebarButtonTransition(alpha: CGFloat, hidden: Bool) {
        topToolbar.setSidebarButtonTransition(alpha: alpha, hidden: hidden)
    }
    
    // MARK: - View Setup
    
    private func configureAppearance() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }
    
    private func configureHierarchy() {
        addSubview(topToolbar)
        addSubview(bottomToolbar)
        addSubview(overlayDismissView)
        addSubview(overlayContentView)
        addSubview(actionBar)
        addSubview(condensedPill)
    }
    
    private func configureConstraints() {
        bottomConstraint = bottomToolbar.bottomAnchor.constraint(equalTo: bottomAnchor)
        overlayWidthConstraint = overlayContentView.widthAnchor.constraint(equalToConstant: 0)
        overlayHeightConstraint = overlayContentView.heightAnchor.constraint(equalToConstant: 0)
        // Held so the pill can be moved onto the address capsule and
        // back - see fix_pill_morphs_from_the_address_capsule.py. The
        // same constraints as before; the resting three are swapped for
        // an explicit width only while the pill is somewhere else.
        pillCenterXConstraint = condensedPill.centerXAnchor.constraint(equalTo: centerXAnchor)
        pillBottomConstraint = condensedPill.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -Self.condensedPillBottomMargin
        )
        pillRestingConstraints = [
            condensedPill.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            condensedPill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            condensedPill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ]
        pillMorphWidthConstraint = condensedPill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topToolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topToolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topToolbar.topAnchor.constraint(equalTo: topAnchor),
            
            bottomToolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomToolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomConstraint,
            
            overlayDismissView.topAnchor.constraint(equalTo: topToolbar.bottomAnchor),
            overlayDismissView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayDismissView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayDismissView.bottomAnchor.constraint(equalTo: bottomToolbar.topAnchor),
            
            overlayWidthConstraint,
            overlayHeightConstraint,
            
            actionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            
            pillCenterXConstraint,
            // CHANGED - bottomAnchor, not safeAreaLayoutGuide.bottomAnchor.
            // See fix_repin_pill_to_screen_bottom.py. Against the guide
            // the pill could never sit below the home indicator, and it
            // MOVED depending on the page, because the guide is inflated
            // for pages using safe-area CSS. Measured from the real
            // bottom it has one fixed position everywhere, and
            // condensedPillBottomMargin becomes the only knob that moves
            // it.
            pillBottomConstraint,
        ])
        NSLayoutConstraint.activate(pillRestingConstraints)
        bottomToolbar.configureTopAnchor(to: safeAreaLayoutGuide.bottomAnchor)
    }
    
    private func configureOverlayDismissGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(overlayDismissViewTapped))
        overlayDismissView.addGestureRecognizer(tapGesture)
    }
    
    private func setOverlayDismissViewVisible(_ visible: Bool) {
        overlayDismissView.isHidden = !visible
    }
    
    @objc private func overlayDismissViewTapped() {
        onOverlayDismiss?()
    }
    
    // MARK: - State Resolution
    
    private func attachAddressBar(for mode: BrowserChromeMode) {
        topToolbar.detachAddressBar()
        bottomToolbar.detachAddressBar()
        switch mode {
        case .phone:
            bottomToolbar.attachAddressBar(addressBar)
        case .compact, .pad:
            topToolbar.attachAddressBar(addressBar)
        }
    }
    
    private func attachActionBar(for mode: BrowserChromeMode) {
        NSLayoutConstraint.deactivate([actionBarTopConstraint, actionBarBottomConstraint].compactMap { $0 })
        switch mode {
        case .pad:
            let constraint = actionBar.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -UX.actionBarSpacing
            )
            constraint.isActive = true
            actionBarBottomConstraint = constraint
            actionBarTopConstraint = nil
        case .phone, .compact:
            let constraint = actionBar.bottomAnchor.constraint(
                equalTo: bottomToolbar.topAnchor,
                constant: -UX.actionBarSpacing
            )
            constraint.isActive = true
            actionBarBottomConstraint = constraint
            actionBarTopConstraint = nil
        }
    }
    
    private func showActionBar(animated: Bool) {
        actionBar.isHidden = false
        onActionBarVisibilityChanged?(true)
        let animations = {
            self.actionBar.alpha = 1
        }
        
        guard animated else {
            animations()
            return
        }
        
        UIView.animate(withDuration: UX.actionBarAnimationDuration, animations: animations)
    }
    
    private func resolvedTopState(for state: State) -> TopToolbar.LayoutState {
        switch state.mode {
        case .phone: return .hidden
        case .compact: return .compact
        case .pad: return .standard
        }
    }
    
    private func resolvedBottomState(for state: State) -> BottomToolbar.LayoutState {
        switch state.mode {
        case .pad:
            return .hidden
        case .compact:
            return .compact
        case .phone:
            switch state.search {
            case .inactive: return .standard
            case .focused: return .focused
            case .scrollingEmbeddedSuggestions: return .standard
            case .scrollingDetachedSuggestions: return .hidden
            }
        }
    }
}
