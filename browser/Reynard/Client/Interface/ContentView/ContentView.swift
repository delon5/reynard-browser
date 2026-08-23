//
//  ContentView.swift
//  Reynard
//
//  Created by Minh Ton on 10/6/26.
//

import GeckoView
import UIKit

final class ContentView: UIView, UIGestureRecognizerDelegate {
    struct ThumbnailGeometry {
        let fullFrame: CGRect
        let cropRect: CGRect
    }
    
    struct ThumbnailCaptureGeometry {
        let size: CGSize
        let visibleRect: CGRect
    }
    
    private enum UX {
        static let phoneSearchFocusedBottomInset: CGFloat = 94
        static let focusedInputBottomClearance: CGFloat = 12
        static let focusedInputOffsetThreshold: CGFloat = 0.5
        static let historyPreviewParallaxRatio: CGFloat = 0.33
        static let historyTransitionOverlayMaximumAlpha: CGFloat = 0.12
        static let historyTransitionProjectionDuration: CGFloat = 0.2
        static let historyTransitionDuration: TimeInterval = 0.35
    }
    
    private enum HistorySwipeDirection: Equatable {
        case back
        case forward
    }
    
    private enum HistorySwipeState {
        case idle // No history swipe is active.
        case swiping(HistorySwipeDirection) // Gesture is tracking the user's drag.
        case settling // Swipe completed; finish animation is running.
        case settled // Location changed before finish animation ended.
        case loaded // Page load completed before finish animation ended.
        case loading // Finish animation ended; waiting for page load.
        case resetting // Location changed without a load; reset on next run loop.
    }
    
    struct State: Equatable {
        let webVisibility: WebContentView.VisibilityState
        let overlayPresentation: OverlayContentView.PresentationState
        
        static let browsing = State(
            webVisibility: .visible,
            overlayPresentation: .hidden
        )
    }
    
    struct LayoutState: Equatable {
        enum Mode: Equatable {
            case standard
            case searchFocused
            case fullscreen
        }
        
        let mode: Mode
    }
    
    private(set) var state: State = .browsing
    private var layoutState = LayoutState(mode: .standard)
    private var session: GeckoSession?
    private var dynamicToolbarMaxHeight: CGFloat = 0
    private var contentBottomOffset: CGFloat = 0
    private var toolbarBottomOffset: CGFloat = 0
    /// Clearance for chrome that floats OVER the page instead of
    /// reserving layout space - this fork's condensed pill.
    ///
    /// It rides the same channel the toolbar offsets use, because that
    /// channel is a compositor fixed-layer margin, not a viewport change:
    /// setContentBottomOffset -> nsWindow::UpdateDynamicToolbarOffset ->
    /// UiCompositorControllerParent::SetFixedLayerMargins(0, offset), and
    /// APZCTreeManager::ComputeFixedMarginsOffset then does
    /// `translation.y -= effectiveMargin.bottom` for anything fixed to
    /// the bottom. A POSITIVE margin therefore lifts position:fixed and
    /// sticky-bottom content up by exactly that much, while the page
    /// keeps its full height and still paints behind the pill - which is
    /// the floating look, kept.
    ///
    /// The toolbar's own offsets are negative by the same rule: as it
    /// slides away, fixed content follows it down into the strip the
    /// layout viewport already reserved.
    ///
    /// Written only by setCondensedChrome(condensed:pillMargin:), which
    /// sets it together with isChromeCondensed and syncs once.
    private var floatingChromeInset: CGFloat = 0
    private var safeAreaInsetBottom: CGFloat = 0
    private var toolbarTopOffset: CGFloat = 0
    private var maxTopToolbarOffset: CGFloat = 0
    private var focusedInputTask: Task<Void, Never>?
    private var inputBottomRatio: CGFloat?
    private var focusedInputOffset: CGFloat = 0
    
    private var canGoBack = false
    private var canGoForward = false
    private var backPreviewImage: UIImage?
    private var forwardPreviewImage: UIImage?
    private var isHistorySwipeEnabled = false
    private var historySwipeState = HistorySwipeState.idle
    private var activeHistorySwipeDirection: HistorySwipeDirection?
    private var webContentSize: CGSize?
    
    private let webContentView = WebContentView()
    private let overlayContentView = OverlayContentView()
    private let historyPreviewImageView = UIImageView()
    private let historyTransitionOverlayView = UIView()
    
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onHistorySwipeBegan: (() -> Void)?
    var onHistorySwipeEnded: (() -> Void)?
    var onVerticalScroll: ((CGFloat) -> Void)?
    
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var webContentBottomConstraint: NSLayoutConstraint?
    
    var webContentBottomAnchor: NSLayoutYAxisAnchor {
        return webContentView.bottomAnchor
    }
    
    // MARK: - Lifecycle
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAppearance()
        configureHierarchy()
        configureConstraints()
        configureHistoryNavigation()
        applyState()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        focusedInputTask?.cancel()
    }
    
    // MARK: - Configuration
    
    private func configureAppearance() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .appBackground
    }
    
    private func configureHierarchy() {
        webContentView.translatesAutoresizingMaskIntoConstraints = false
        historyPreviewImageView.translatesAutoresizingMaskIntoConstraints = false
        historyTransitionOverlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayContentView.translatesAutoresizingMaskIntoConstraints = false
        historyPreviewImageView.isHidden = true
        historyPreviewImageView.backgroundColor = .appBackground
        historyPreviewImageView.contentMode = .scaleAspectFill
        historyPreviewImageView.clipsToBounds = true
        historyTransitionOverlayView.isHidden = true
        historyTransitionOverlayView.backgroundColor = .black
        historyTransitionOverlayView.alpha = 0
        addSubview(webContentView)
        addSubview(historyPreviewImageView)
        addSubview(historyTransitionOverlayView)
        addSubview(overlayContentView)
    }
    
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            webContentView.topAnchor.constraint(equalTo: topAnchor),
            webContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        
        [historyPreviewImageView, historyTransitionOverlayView].forEach { contentView in
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }
    
    private func configureHistoryNavigation() {
        let backGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleBackHistoryPan(_:))
        )
        backGesture.edges = .left
        backGesture.delegate = self
        addGestureRecognizer(backGesture)
        
        let forwardGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleForwardHistoryPan(_:))
        )
        forwardGesture.edges = .right
        forwardGesture.delegate = self
        addGestureRecognizer(forwardGesture)
        
        webContentView.historySwipeDirectionsProvider = { [weak self] in
            return self?.allowedTrackpadHistorySwipeDirections() ?? []
        }
        webContentView.onHistorySwipeDidStart = { [weak self] direction in
            self?.beginTrackpadHistoryNavigation(direction)
        }
        webContentView.onHistorySwipeDidUpdate = { [weak self] progress in
            self?.updateTrackpadHistoryNavigation(progress)
        }
        webContentView.onHistorySwipeDidComplete = { [weak self] direction in
            self?.completeTrackpadHistoryNavigation(direction)
        }
        webContentView.onHistorySwipeDidEnd = { [weak self] in
            self?.endTrackpadHistoryNavigation()
        }
        webContentView.onVerticalScroll = { [weak self] delta in
            self?.onVerticalScroll?(delta)
        }
    }
    
    // MARK: - Layout
    
    func applyLayout(
        _ layoutState: LayoutState,
        topAnchor: NSLayoutYAxisAnchor,
        bottomAnchor: NSLayoutYAxisAnchor
    ) {
        self.layoutState = layoutState
        applyLayoutState(topAnchor: topAnchor, bottomAnchor: bottomAnchor)
    }
    
    func updateWebContentSize() -> Bool {
        let size = webContentView.bounds.size
        guard size.width > 1, size.height > 1 else {
            return false
        }
        defer { webContentSize = size }
        
        guard let previousSize = webContentSize else {
            return false
        }
        
        return previousSize != size
    }
    
    func setToolbarLimits(maxHeight: CGFloat, topOffset: CGFloat) {
        // ALWAYS send - never gate on our own copy.
        //
        // There are two caches on this path and a value can be dropped
        // between them. nsWindow::UpdateDynamicToolbarMaxHeight already
        // early-returns on an unchanged value, so it is the authority;
        // this one only ever suppressed a needed send. The call is
        // `session?`, so any moment with no session - a tab switch, a
        // session replacement - advanced this copy while the engine kept
        // the old value, and because our copy then matched, the correct
        // value was never sent again.
        //
        // A device capture caught exactly that: the app logging max=0.0
        // while condensed, and nsPresContext still holding max=426 (the
        // 142pt full toolbar) minutes later. The page reserved a toolbar
        // that was not on screen, which is the gap above the pill.
        //
        // Cost of always sending is one scalar over IPC per layout pass.
        if maxHeight != dynamicToolbarMaxHeight {
            NSLog("dynToolbar: max height \(dynamicToolbarMaxHeight) -> \(maxHeight) (session \(session == nil ? "MISSING" : "live"))")
        }
        dynamicToolbarMaxHeight = maxHeight
        session?.setDynamicToolbarMaxHeight(maxHeight)
        
        guard abs(topOffset - maxTopToolbarOffset) > 0.5 else {
            return
        }
        maxTopToolbarOffset = topOffset
        updateContentBottomInset()
    }
    
    func applyToolbarOffsets(top: CGFloat, bottom: CGFloat) {
        toolbarTopOffset = top
        toolbarBottomOffset = bottom
        webContentView.transform = toolbarAlignedTransform(
            translationX: webContentView.transform.tx
        )
        historyPreviewImageView.transform = toolbarAlignedTransform(
            translationX: historyPreviewImageView.transform.tx
        )
        historyTransitionOverlayView.transform = toolbarAlignedTransform(
            translationX: historyTransitionOverlayView.transform.tx
        )
        syncContentBottomOffset()
    }

    /// What the page is told to keep clear via env(safe-area-inset-bottom).
    ///
    /// Deliberately separate from the compositor margin: that one moves
    /// fixed and sticky layers at composite time, this one asks the page
    /// to lay itself out around the chrome. A site that reads env - and
    /// YouTube does - lifts its own controls with it while its
    /// background keeps painting the full height behind the pill.
    func setSafeAreaInsetBottom(_ inset: CGFloat) {
        // Always send, for the same reason as setToolbarLimits above:
        // the widget already ignores an unchanged value, and gating here
        // loses the send whenever there is no session to send it to.
        let changed = inset != safeAreaInsetBottom
        if changed {
            NSLog("dynToolbar: env(safe-area-inset-bottom) \(safeAreaInsetBottom) -> \(inset)pt (session \(session == nil ? "MISSING" : "live"))")
        }
        safeAreaInsetBottom = inset
        session?.setSafeAreaInsetBottom(inset)

        // GROUND TRUTH, 700ms after a nonzero send so the content
        // restyle has landed: ask the classifier actor, whose response
        // carries what env(safe-area-inset-bottom) actually resolved
        // to inside the document (logged by
        // GeckoSession.bottomReservation as "page resolves env(...)").
        // The old runUserScript probe here could never carry an answer
        // back - that API's success return is nil by design, so its
        // "returned nothing" line meant the script RAN and its value
        // went nowhere.
        guard let session, inset > 0, changed else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            _ = await session.bottomReservation()
        }
    }
    
    /// Whether the chrome is condensed to the pill. Gates the fixed-layer
    /// margin, which belongs to the full toolbar alone.
    private var isChromeCondensed = false
    
    /// Both at once, then ONE sync.
    ///
    /// These two were set in separate calls, and syncContentBottomOffset
    /// routes on isChromeCondensed - compositor margin when condensed,
    /// dynamic-toolbar offset otherwise. Whichever went first therefore
    /// sent with the other's stale value, and a device capture caught
    /// the consequence: the pill's +60 was sent while the flag still
    /// read false, took the TOOLBAR path, and arrived as
    /// "nsPresContext RECEIVED offset=180 max=426" - the exact bug
    /// SetFixedLayerMarginBottom was added to remove. Flipping the order
    /// only moves the hazard to the other value, so set both, then sync
    /// once.
    func setCondensedChrome(condensed: Bool, pillMargin: CGFloat) {
        guard condensed != isChromeCondensed
                || pillMargin != floatingChromeInset else {
            return
        }
        isChromeCondensed = condensed
        floatingChromeInset = pillMargin
        syncContentBottomOffset()
    }
    
    private func syncContentBottomOffset() {
        // REPLACES, not adds. While the pill is showing the toolbar is
        // not on screen, but ToolbarController goes on sliding it, so
        // summing the two let the clearance decay with every scroll
        // frame - 60 -> 44 -> 29 -> 0 -> -20 in one capture, i.e. the
        // page's fixed content drifting down past the pill it was
        // supposed to clear. The pill's height IS the clearance while it
        // is up, whatever the toolbar thinks it is doing.
        // While condensed, ZERO - not the toolbar's sliding offset.
        //
        // This margin exists to keep a page's fixed bars glued to a
        // toolbar that is sliding off screen. Condensed, that toolbar is
        // already gone and the condensed mode has its own single
        // mechanism (a shorter view when stopping, env when floating),
        // so letting this keep reporting -(top+bottom) = -142 stacked a
        // second displacement underneath it. That is the doubling.
        let offset: CGFloat
        if isChromeCondensed {
            // The pill's own clearance when floating, zero when the view
            // stops at it - never the toolbar's sliding offset, which
            // belongs to a toolbar that is no longer on screen.
            offset = floatingChromeInset
        } else {
            // Never the pill inset here: while not condensed it can
            // only be stale, and a POSITIVE value sent down the
            // toolbar path is the viewport corruption
            // SetFixedLayerMarginBottom exists to prevent.
            offset = -(toolbarTopOffset + toolbarBottomOffset)
        }
        guard offset != contentBottomOffset else {
            return
        }
        contentBottomOffset = offset
        NSLog("dynToolbar: fixed-layer bottom margin %.1f (toolbar %.1f/%.1f, pill %.1f, condensed %d)",
              offset, toolbarTopOffset, toolbarBottomOffset, floatingChromeInset,
              isChromeCondensed ? 1 : 0)
        // Two different engine entry points, because they mean different
        // things. The pill's clearance is a compositor margin and nothing
        // more; the toolbar's offset genuinely moves the dynamic toolbar
        // and must reach nsPresContext. Sending the pill's POSITIVE value
        // through the toolbar path made nsPresContext compute a 202pt
        // toolbar that does not exist and shrink the visual viewport to
        // match - which is what pushed Facebook's fixed banner off screen.
        if isChromeCondensed {
            session?.setFixedLayerMarginBottom(offset)
        } else {
            session?.setContentBottomOffset(offset)
        }
    }
    
    private func toolbarAlignedTransform(translationX: CGFloat) -> CGAffineTransform {
        return CGAffineTransform(translationX: translationX, y: -toolbarTopOffset)
    }
    
    func configureLayout(
        topAnchor: NSLayoutYAxisAnchor,
        bottomAnchor: NSLayoutYAxisAnchor
    ) {
        let bottomConstraint = webContentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.isActive = true
        webContentBottomConstraint = bottomConstraint
        webContentView.extendPageBackground(to: topAnchor)
        [historyPreviewImageView, historyTransitionOverlayView].forEach { contentView in
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor),
            ])
        }
        overlayContentView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        overlayContentView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        overlayContentView.configureContentLayout(
            topAnchor: self.topAnchor,
            bottomAnchor: self.bottomAnchor
        )
    }
    
    private func applyLayoutState(
        topAnchor: NSLayoutYAxisAnchor,
        bottomAnchor: NSLayoutYAxisAnchor
    ) {
        let nextTopConstraint = self.topAnchor.constraint(equalTo: topAnchor)
        let nextBottomConstraint = self.bottomAnchor.constraint(equalTo: bottomAnchor)
        guard canActivateConstraints([nextTopConstraint, nextBottomConstraint]) else {
            return
        }
        
        topConstraint?.isActive = false
        bottomConstraint?.isActive = false
        
        NSLayoutConstraint.activate([nextTopConstraint, nextBottomConstraint])
        topConstraint = nextTopConstraint
        bottomConstraint = nextBottomConstraint
        updateLayoutOffsets()
        transform = focusedInputTransform
        updatePullToRefreshAvailability()
    }
    
    private func canActivateConstraints(_ constraints: [NSLayoutConstraint]) -> Bool {
        constraints.allSatisfy { constraint in
            guard let firstView = owningView(for: constraint.firstItem),
                  let secondView = owningView(for: constraint.secondItem) else {
                return true
            }
            
            return firstView.hasCommonAncestor(with: secondView)
        }
    }
    
    private func owningView(for item: Any?) -> UIView? {
        if let view = item as? UIView {
            return view
        }
        
        if let layoutGuide = item as? UILayoutGuide {
            return layoutGuide.owningView
        }
        
        return nil
    }
    
    private func updateLayoutOffsets() {
        let constraintOffset = layoutState.mode == .standard ? 0 : focusedInputOffset
        topConstraint?.constant = layoutState.mode == .fullscreen ? 0 : -constraintOffset
        switch layoutState.mode {
        case .standard:
            bottomConstraint?.constant = 0
        case .searchFocused:
            bottomConstraint?.constant = -UX.phoneSearchFocusedBottomInset
        case .fullscreen:
            bottomConstraint?.constant = 0
        }
        updateContentBottomInset()
    }
    
    private func updateContentBottomInset() {
        // Upstream 8da4dfb8 subtracts here only outside .standard, where
        // it now moves the view by transform instead. The offset it
        // subtracts from is webContentBottomOffset upstream and
        // maxTopToolbarOffset here - the dynamic toolbar work in 92aa7cf2
        // replaced the one with the other - so the base stays ours and
        // the mode test is theirs.
        let constraintOffset = layoutState.mode == .standard ? 0 : focusedInputOffset
        webContentBottomConstraint?.constant = maxTopToolbarOffset - constraintOffset
    }
    
    private var focusedInputTransform: CGAffineTransform {
        guard layoutState.mode == .standard else {
            return .identity
        }
        return CGAffineTransform(translationX: 0, y: -focusedInputOffset)
    }
    
    // MARK: - Focused Input Relocation
    
    func relocateFocusedInput(
        above keyboardFrame: CGRect,
        animationDuration: TimeInterval,
        animationOptions: UIView.AnimationOptions
    ) {
        focusedInputTask?.cancel()
        guard let session else {
            resetFocusedInputRelocation(
                animationDuration: animationDuration,
                animationOptions: animationOptions
            )
            return
        }
        
        focusedInputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let bottomRatio = await session.focusedInputBottomRatio()
            guard !Task.isCancelled else { return }
            
            inputBottomRatio = bottomRatio
            superview?.layoutIfNeeded()
            let newOffset = calculateFocusedInputOffset(keyboardFrame: keyboardFrame)

            // DIAGNOSTIC - the other half of the Twitch chat question.
            // A ratio can arrive and still produce no movement, because
            // the offset is min(keyboardOverlap, focusBottom -
            // visibleBottom) and either term can be zero. Logging the
            // inputs distinguishes "the engine never told us where the
            // input is" from "we were told, and computed no shift".
            let unshifted = frame.offsetBy(dx: 0, dy: focusedInputOffset)
            NSLog("focusedInput: offset %.1f -> %.1f (ratio=%@ viewH=%.1f kbTop=%.1f overlap=%.1f)",
                  focusedInputOffset, newOffset,
                  bottomRatio.map { String(format: "%.3f", $0) } ?? "nil",
                  unshifted.height, keyboardFrame.minY,
                  max(0, unshifted.maxY - keyboardFrame.minY))

            guard abs(newOffset - focusedInputOffset) > UX.focusedInputOffsetThreshold else {
                return
            }
            
            focusedInputOffset = newOffset
            updateLayoutOffsets()
            animateLayout(duration: animationDuration, options: animationOptions)
        }
    }
    
    private func calculateFocusedInputOffset(keyboardFrame: CGRect) -> CGFloat {
        guard let inputBottomRatio else { return 0 }
        
        let unshiftedFrame = frame.offsetBy(dx: 0, dy: focusedInputOffset)
        guard unshiftedFrame.height > 1 else { return 0 }
        
        let keyboardOverlap = max(0, unshiftedFrame.maxY - keyboardFrame.minY)
        guard keyboardOverlap > 0 else { return 0 }
        
        let focusBottom = unshiftedFrame.height * inputBottomRatio
        let visibleBottom = max(
            0,
            unshiftedFrame.height - keyboardOverlap - UX.focusedInputBottomClearance
        )
        return max(0, focusBottom - visibleBottom)
    }
    
    func resetFocusedInputRelocation(
        animationDuration: TimeInterval = 0,
        animationOptions: UIView.AnimationOptions = []
    ) {
        focusedInputTask?.cancel()
        focusedInputTask = nil
        inputBottomRatio = nil
        guard focusedInputOffset != 0 else { return }
        
        focusedInputOffset = 0
        updateLayoutOffsets()
        animateLayout(duration: animationDuration, options: animationOptions)
    }
    
    private func animateLayout(duration: TimeInterval, options: UIView.AnimationOptions) {
        guard duration > 0 else {
            transform = focusedInputTransform
            superview?.layoutIfNeeded()
            return
        }
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [options, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.transform = self.focusedInputTransform
            self.superview?.layoutIfNeeded()
        }
    }
    
    // MARK: - State
    
    func setState(_ state: State) {
        guard self.state != state else {
            return
        }
        
        self.state = state
        applyState()
    }
    
    func setWebVisibility(_ visibility: WebContentView.VisibilityState) {
        setState(State(
            webVisibility: visibility,
            overlayPresentation: state.overlayPresentation
        ))
    }
    
    func setOverlayPresentation(
        _ presentation: OverlayContentView.PresentationState,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        self.state = State(
            webVisibility: state.webVisibility,
            overlayPresentation: presentation
        )
        webContentView.setVisibility(state.webVisibility)
        overlayContentView.setPresentation(presentation, animated: animated, completion: completion)
        updatePullToRefreshAvailability()
    }
    
    private func applyState() {
        webContentView.setVisibility(state.webVisibility)
        overlayContentView.setPresentation(state.overlayPresentation, animated: false)
        updatePullToRefreshAvailability()
    }
    
    // MARK: - Session
    
    func setTab(_ tab: Tab?, pageBackgroundColor: UIColor? = nil) {
        resetHistoryNavigation()
        self.session = tab?.session
        resetFocusedInputRelocation()
        webContentView.setTab(tab, pageBackgroundColor: pageBackgroundColor)
        onPageBackgroundColorChange?(pageBackgroundColor ?? .systemBackground)
        tab?.session.setDynamicToolbarMaxHeight(dynamicToolbarMaxHeight)
        // Re-seed the channel the cached value BELONGS to.
        // contentBottomOffset is one cache feeding two engine entry
        // points: while condensed it holds the pill's compositor
        // margin and must go back through setFixedLayerMarginBottom.
        // Sending it as a (positive) toolbar offset is the exact
        // viewport corruption SetFixedLayerMarginBottom was added to
        // remove ("nsPresContext RECEIVED offset=180 max=426"), and
        // the margin channel was never re-seeded at all, so a tab
        // switch while condensed left the incoming session's fixed
        // bars behind the pill.
        if isChromeCondensed {
            tab?.session.setFixedLayerMarginBottom(contentBottomOffset)
        } else {
            tab?.session.setContentBottomOffset(contentBottomOffset)
        }
        tab?.session.setSafeAreaInsetBottom(safeAreaInsetBottom)
        updatePullToRefreshAvailability()
    }
    
    /// Fires whenever the page's background color is known, so anything
    /// drawn OUTSIDE this view can match it - specifically the strip
    /// below the content view when the pill is not floating, which would
    /// otherwise read as a black bar against a light page.
    var onPageBackgroundColorChange: ((UIColor) -> Void)?
    
    func setPageBackgroundColor(_ color: UIColor) {
        webContentView.setPageBackgroundColor(color)
        onPageBackgroundColorChange?(color)
    }
    
    func showPageError(for url: String?) {
        webContentView.showPageError(for: url)
    }
    
    func didFinishLoading(session: GeckoSession) {
        webContentView.didFinishLoading(session: session)
    }
    
    func isDisplaying(session: GeckoSession) -> Bool {
        webContentView.isDisplaying(session: session)
    }
    
    func restoreInteraction(for session: GeckoSession) {
        webContentView.restoreInteraction(for: session)
    }
    
    // MARK: - Interaction
    
    func addWebViewInteraction(_ interaction: UIInteraction) {
        webContentView.addWebViewInteraction(interaction)
    }
    
    // MARK: - History Navigation
    
    func setHistoryNavigation(
        canGoBack: Bool,
        canGoForward: Bool,
        backPreviewImage: UIImage?,
        forwardPreviewImage: UIImage?,
        isSwipeEnabled: Bool
    ) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.backPreviewImage = backPreviewImage
        self.forwardPreviewImage = forwardPreviewImage
        isHistorySwipeEnabled = isSwipeEnabled
    }
    
    @objc private func handleBackHistoryPan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        handleHistoryPan(gesture, direction: .back)
    }
    
    @objc private func handleForwardHistoryPan(_ gesture: UIScreenEdgePanGestureRecognizer) {
        handleHistoryPan(gesture, direction: .forward)
    }
    
    private func handleHistoryPan(
        _ gesture: UIScreenEdgePanGestureRecognizer,
        direction: HistorySwipeDirection
    ) {
        switch gesture.state {
        case .began:
            beginHistoryNavigation(direction)
        case .changed:
            updateHistoryNavigation(gesture, direction: direction)
        case .ended:
            finishHistoryNavigation(gesture, direction: direction, cancelled: false)
        case .cancelled, .failed:
            finishHistoryNavigation(gesture, direction: direction, cancelled: true)
        default:
            break
        }
    }
    
    private func beginHistoryNavigation(_ direction: HistorySwipeDirection) {
        guard case .idle = historySwipeState else {
            return
        }
        
        onHistorySwipeBegan?()
        historySwipeState = .swiping(direction)
        activeHistorySwipeDirection = direction
        updatePullToRefreshAvailability()
        historyPreviewImageView.image = direction == .back ? backPreviewImage : forwardPreviewImage
        historyPreviewImageView.isHidden = false
        historyTransitionOverlayView.isHidden = false
        
        let width = bounds.width
        switch direction {
        case .back:
            insertSubview(historyPreviewImageView, belowSubview: webContentView)
            insertSubview(historyTransitionOverlayView, belowSubview: webContentView)
            historyPreviewImageView.transform = toolbarAlignedTransform(
                translationX: -width * UX.historyPreviewParallaxRatio
            )
            updateHistoryTransitionOverlay(direction: direction, progress: 0)
        case .forward:
            insertSubview(historyTransitionOverlayView, aboveSubview: webContentView)
            insertSubview(historyPreviewImageView, aboveSubview: historyTransitionOverlayView)
            historyPreviewImageView.transform = toolbarAlignedTransform(translationX: width)
            updateHistoryTransitionOverlay(direction: direction, progress: 0)
        }
        historyTransitionOverlayView.transform = toolbarAlignedTransform(translationX: 0)
    }
    
    private func updateHistoryNavigation(
        _ gesture: UIScreenEdgePanGestureRecognizer,
        direction: HistorySwipeDirection
    ) {
        let progress = historyNavigationProgress(for: gesture, direction: direction)
        updateHistoryNavigation(progress: progress, direction: direction)
    }
    
    private func updateHistoryNavigation(
        progress: CGFloat,
        direction: HistorySwipeDirection
    ) {
        guard case .swiping(let activeDirection) = historySwipeState,
              activeDirection == direction else {
            return
        }
        
        let width = bounds.width
        switch direction {
        case .back:
            webContentView.transform = toolbarAlignedTransform(translationX: width * progress)
            historyPreviewImageView.transform = toolbarAlignedTransform(
                translationX: -width * UX.historyPreviewParallaxRatio * (1 - progress)
            )
        case .forward:
            historyPreviewImageView.transform = toolbarAlignedTransform(
                translationX: width * (1 - progress)
            )
        }
        updateHistoryTransitionOverlay(direction: direction, progress: progress)
    }
    
    private func finishHistoryNavigation(
        _ gesture: UIScreenEdgePanGestureRecognizer,
        direction: HistorySwipeDirection,
        cancelled: Bool
    ) {
        guard case .swiping(let activeDirection) = historySwipeState,
              activeDirection == direction else {
            resetHistoryNavigation()
            return
        }
        
        let progress = historyNavigationProgress(for: gesture, direction: direction)
        let velocityX = gesture.velocity(in: self).x
        let directionalVelocity: CGFloat
        switch direction {
        case .back:
            directionalVelocity = max(velocityX, 0)
        case .forward:
            directionalVelocity = max(-velocityX, 0)
        }
        
        let width = bounds.width
        let projectedDistance = width * progress
        + directionalVelocity * UX.historyTransitionProjectionDuration
        let shouldComplete = !cancelled && projectedDistance >= width
        
        settleHistoryNavigation(
            direction: direction,
            shouldComplete: shouldComplete,
            velocityX: velocityX
        )
    }
    
    private func settleHistoryNavigation(
        direction: HistorySwipeDirection,
        shouldComplete: Bool,
        velocityX: CGFloat
    ) {
        let width = bounds.width
        UIView.animate(
            withDuration: UX.historyTransitionDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: abs(velocityX) / max(width, 1),
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            if shouldComplete {
                self.historySwipeState = .settling
                switch direction {
                case .back:
                    self.webContentView.transform = self.toolbarAlignedTransform(translationX: width)
                    self.historyPreviewImageView.transform = self.toolbarAlignedTransform(translationX: 0)
                    self.updateHistoryTransitionOverlay(direction: direction, progress: 1)
                    self.onBack?()
                case .forward:
                    self.historyPreviewImageView.transform = self.toolbarAlignedTransform(translationX: 0)
                    self.updateHistoryTransitionOverlay(direction: direction, progress: 1)
                    self.onForward?()
                }
            } else {
                self.webContentView.transform = self.toolbarAlignedTransform(translationX: 0)
                switch direction {
                case .back:
                    self.historyPreviewImageView.transform = self.toolbarAlignedTransform(
                        translationX: -width * UX.historyPreviewParallaxRatio
                    )
                    self.updateHistoryTransitionOverlay(direction: direction, progress: 0)
                case .forward:
                    self.historyPreviewImageView.transform = self.toolbarAlignedTransform(translationX: width)
                    self.updateHistoryTransitionOverlay(direction: direction, progress: 0)
                }
            }
        } completion: { _ in
            guard shouldComplete else {
                self.resetHistoryNavigation()
                return
            }
            
            if case .loaded = self.historySwipeState {
                self.resetHistoryNavigation()
                return
            }
            
            switch self.historySwipeState {
            case .settling:
                self.historySwipeState = .loading
            case .settled:
                self.scheduleHistoryLocationReset()
            default:
                break
            }
        }
    }
    
    private func historyNavigationProgress(
        for gesture: UIScreenEdgePanGestureRecognizer,
        direction: HistorySwipeDirection
    ) -> CGFloat {
        let translationX = gesture.translation(in: self).x
        let distance: CGFloat
        switch direction {
        case .back:
            distance = translationX
        case .forward:
            distance = -translationX
        }
        return min(max(distance / max(bounds.width, 1), 0), 1)
    }
    
    private func allowedTrackpadHistorySwipeDirections() -> GeckoEdgeSwipeDirections {
        guard canBeginHistoryNavigation else {
            return []
        }
        
        var directions: GeckoEdgeSwipeDirections = []
        if canGoBack {
            directions.insert(.left)
        }
        if canGoForward {
            directions.insert(.right)
        }
        return directions
    }
    
    private func beginTrackpadHistoryNavigation(_ direction: GeckoEdgeSwipeDirections) {
        guard let direction = historySwipeDirection(from: direction) else {
            return
        }
        beginHistoryNavigation(direction)
    }
    
    private func updateTrackpadHistoryNavigation(_ progress: CGFloat) {
        guard let direction = activeHistorySwipeDirection else {
            return
        }
        updateHistoryNavigation(
            progress: min(max(progress, 0), 1),
            direction: direction
        )
    }
    
    private func completeTrackpadHistoryNavigation(_ direction: GeckoEdgeSwipeDirections) {
        guard let direction = historySwipeDirection(from: direction),
              direction == activeHistorySwipeDirection,
              case .swiping(let activeDirection) = historySwipeState,
              activeDirection == direction else {
            return
        }
        
        settleHistoryNavigation(
            direction: direction,
            shouldComplete: true,
            velocityX: 0
        )
    }
    
    private func endTrackpadHistoryNavigation() {
        guard case .swiping = historySwipeState else {
            return
        }
        resetHistoryNavigation()
    }
    
    private func historySwipeDirection(
        from direction: GeckoEdgeSwipeDirections
    ) -> HistorySwipeDirection? {
        if direction.contains(.left) {
            return .back
        }
        if direction.contains(.right) {
            return .forward
        }
        return nil
    }
    
    /// The content layer's own black-capable views, which chromeState
    /// cannot see.
    ///
    /// chromeState reports BrowserChrome - toolbars and pill - and three
    /// captures of the black band showed all of those correct. But
    /// historyTransitionOverlayView is `backgroundColor = .black` and
    /// lives HERE, above webContentView during a back/forward swipe, and
    /// nothing clears it except resetHistoryNavigation(). A swipe
    /// interrupted before that reset - by a rotation, for instance -
    /// leaves a black view over the page that no chrome log would ever
    /// mention.
    ///
    /// historyPreviewImageView is included because it is the sibling that
    /// paints .appBackground rather than black, so the two together say
    /// whether a stranded overlay is the black or merely near it.
    ///
    /// Deduplicated like chromeState: this runs on every layout pass.
    private var lastContentState = ""

    func logContentState(_ phase: String) {
        func describe(_ label: String, _ view: UIView) -> String {
            let frame = view.convert(view.bounds, to: window)
            return String(format: "%@ a=%.2f hid=%d f=%.0f,%.0f %.0fx%.0f ty=%.0f",
                          label, view.alpha, view.isHidden ? 1 : 0,
                          frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height,
                          view.transform.ty)
        }
        let line = String(format: "%@ | %@ | %@",
                          describe("web", webContentView),
                          describe("overlay", historyTransitionOverlayView),
                          describe("preview", historyPreviewImageView))
        guard line != lastContentState else {
            return
        }
        lastContentState = line
        NSLog("contentState: %@ %@", phase, line)
    }

    private func updateHistoryTransitionOverlay(
        direction: HistorySwipeDirection,
        progress: CGFloat
    ) {
        let leadingEdgeProgress: CGFloat
        switch direction {
        case .back:
            leadingEdgeProgress = 1 - progress
        case .forward:
            leadingEdgeProgress = progress
        }
        
        historyTransitionOverlayView.alpha = UX.historyTransitionOverlayMaximumAlpha * leadingEdgeProgress
    }
    
    private func resetHistoryNavigation() {
        webContentView.transform = toolbarAlignedTransform(translationX: 0)
        historyPreviewImageView.transform = .identity
        historyTransitionOverlayView.transform = .identity
        historyPreviewImageView.image = nil
        historyPreviewImageView.isHidden = true
        historyTransitionOverlayView.alpha = 0
        historyTransitionOverlayView.isHidden = true
        historySwipeState = .idle
        activeHistorySwipeDirection = nil
        updatePullToRefreshAvailability()
        onHistorySwipeEnded?()
    }
    
    /// Whether a pull-to-refresh drag is currently held on the web
    /// surface. The chrome-condense coordinator consults this so a
    /// mid-pull expand never resizes the page under the user's
    /// finger.
    var isPullToRefreshActive: Bool {
        return webContentView.isPullToRefreshActive
    }
    
    private func updatePullToRefreshAvailability() {
        let isHistoryNavigationIdle: Bool
        if case .idle = historySwipeState {
            isHistoryNavigationIdle = true
        } else {
            isHistoryNavigationIdle = false
        }
        let isEnabled = session != nil &&
        state == .browsing &&
        webContentView.visibility == .visible &&
        layoutState.mode != .fullscreen &&
        isHistoryNavigationIdle
        webContentView.setPullToRefreshEnabled(isEnabled)
    }
    
    func finishHistoryLoad() {
        switch historySwipeState {
        case .settling, .settled:
            historySwipeState = .loaded
        case .loading, .resetting:
            resetHistoryNavigation()
        case .idle, .swiping, .loaded:
            break
        }
    }
    
    func noteHistoryLocationChange() {
        switch historySwipeState {
        case .settling:
            historySwipeState = .settled
        case .loading:
            scheduleHistoryLocationReset()
        case .idle, .swiping, .settled, .loaded, .resetting:
            break
        }
    }
    
    private func scheduleHistoryLocationReset() {
        historySwipeState = .resetting
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  case .resetting = self.historySwipeState else {
                return
            }
            
            self.resetHistoryNavigation()
        }
    }
    
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // UIKit asks this of the VIEW for every recognizer attached to
        // it, not just our own, so answering for all of them vetoes
        // recognizers this view does not own - the scrollbar-haptic
        // long-press is attached here and its delegate implements only
        // shouldRecognizeSimultaneouslyWith, leaving this the sole gate
        // that can fail it. Only the history edge-swipes are ours to
        // decide; everything else keeps UIKit's default.
        guard gestureRecognizer is UIScreenEdgePanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        guard canBeginHistoryNavigation else {
            return false
        }

        if let backGesture = gestureRecognizer as? UIScreenEdgePanGestureRecognizer,
           backGesture.edges == .left {
            return canGoBack
        }
        
        return canGoForward
    }
    
    private var canBeginHistoryNavigation: Bool {
        guard case .idle = historySwipeState else {
            return false
        }
        
        return isHistorySwipeEnabled &&
        state == .browsing &&
        webContentView.visibility == .visible
    }
    
    // MARK: - Presentation
    
    func setTransitionTransform(_ transform: CGAffineTransform) {
        self.transform = transform
    }
    
    func setTransitionHidden(_ hidden: Bool) {
        isHidden = hidden
    }
    
    func frame(in view: UIView) -> CGRect {
        convert(bounds, to: view)
    }
    
    // MARK: - Thumbnail
    
    func thumbnailGeometry(in view: UIView) -> ThumbnailGeometry? {
        let fullFrame = webContentView.thumbnailFrame(in: view)
        let visibleFrame = fullFrame.intersection(frame(in: view))
        guard fullFrame.width > 1,
              fullFrame.height > 1,
              visibleFrame.width > 1,
              visibleFrame.height > 1 else {
            return nil
        }
        
        return ThumbnailGeometry(
            fullFrame: fullFrame,
            cropRect: CGRect(
                x: (visibleFrame.minX - fullFrame.minX) / fullFrame.width,
                y: (visibleFrame.minY - fullFrame.minY) / fullFrame.height,
                width: visibleFrame.width / fullFrame.width,
                height: visibleFrame.height / fullFrame.height
            )
        )
    }
    
    var thumbnailCaptureGeometry: ThumbnailCaptureGeometry? {
        guard let geometry = thumbnailGeometry(in: self) else {
            return nil
        }
        
        let size = geometry.fullFrame.size
        return ThumbnailCaptureGeometry(
            size: size,
            visibleRect: CGRect(
                x: geometry.cropRect.minX * size.width,
                y: geometry.cropRect.minY * size.height,
                width: geometry.cropRect.width * size.width,
                height: geometry.cropRect.height * size.height
            )
        )
    }
    
    func makeWebThumbnail() -> UIImage? {
        return webContentView.makeThumbnail()
    }
    
    // MARK: - Overlay Hosting
    
    func setOverlayController(
        _ viewController: UIViewController,
        for page: OverlayContentView.Page,
        in parentViewController: UIViewController
    ) {
        overlayContentView.setController(viewController, for: page, in: parentViewController)
    }
    
    func layoutOverlayIfNeeded() {
        overlayContentView.layoutIfNeeded()
    }
    
    func removeOverlayController(for page: OverlayContentView.Page) {
        overlayContentView.removeController(for: page)
    }
    
}
