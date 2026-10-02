//
//  BottomToolbar.swift
//  Reynard
//
//  Created by Minh Ton on 10/6/26.
//

import UIKit


final class BottomToolbar: UIView {
    /// The expanded toolbar's content height, without the safe area
    /// inset it sits above.
    ///
    /// Exposed so the dynamic toolbar max can be a constant rather than
    /// a measurement: bottomToolbarTransitionFrame goes through
    /// convert(), which honours the condense transform, and sampling it
    /// produced values from 108 to 928 in a single run.
    static var expandedContentHeight: CGFloat {
        return UX.bottomToolbarStandardContentHeight
    }
    
    private enum UX {
        static let bottomToolbarStandardContentHeight: CGFloat = 108
        static let bottomToolbarFocusedContentHeight: CGFloat = 58
        static let bottomToolbarCompactContentHeight: CGFloat = 58
        static let bottomToolbarButtonStackHeight = BottomToolbarLayoutPolicy.minimumTargetSize
        static let addressBarHorizontalInset: CGFloat = 12
        static let addressBarTopInset: CGFloat = 8
        static let bottomToolbarButtonStackHorizontalInset = BottomToolbarLayoutPolicy.horizontalInset
        static let bottomToolbarButtonStackTopSpacing: CGFloat = 7
        static let bottomToolbarButtonSpacing = BottomToolbarLayoutPolicy.spacing
        static let backgroundViewHorizontalExtension: CGFloat = 16
    }
    
    enum LayoutState {
        case hidden
        case collapsed // visually hidden but still takes up space
        case standard
        case focused
        case compact
    }
    
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onShare: (() -> Void)?
    var onBookmarks: (() -> Void)?
    var onHistory: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onSettings: (() -> Void)?
    var onTabOverview: (() -> Void)?
    var onReload: (() -> Void)?
    var onPageZoom: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    
    private let backgroundView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            // THE SAME GLASS THE PILL USES. Every other chrome element -
            // the pill, the address bar capsule, its dismiss button -
            // goes through ToolbarGlassBackgroundView, which builds a
            // plain UIGlassEffect(). This built its own through
            // UIGlassEffect.nonAdaptive instead, which reaches into the
            // private glass object and turns adaptivity off, so the two
            // toolbars were the only chrome that did not respond to what
            // was behind them. Matching them means they now do.
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemChromeMaterial)
        }
        let view = UIVisualEffectView(effect: effect)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
     /// Restores pure black on OLED - see UIColor.oledToolbarOverlay.
    /// Lives inside the effect view's contentView so it covers the blur
    /// rather than sitting behind it.
    private let oledOverlayView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .oledToolbarOverlay
        view.isUserInteractionEnabled = false
        return view
    }()
    
   
    private lazy var backButton = ToolbarButton(buttonType: .back, target: self, action: #selector(backTapped))
    private lazy var forwardButton = ToolbarButton(buttonType: .forward, target: self, action: #selector(forwardTapped))
    private lazy var shareButton = ToolbarButton(buttonType: .share, target: self, action: #selector(shareTapped))
    private lazy var bookmarksButton = ToolbarButton(buttonType: .bookmarks, target: self, action: #selector(bookmarksTapped))
    private lazy var historyButton = ToolbarButton(buttonType: .history, target: self, action: #selector(historyTapped))
    private lazy var downloadButton = ToolbarButton(buttonType: .download, target: self, action: #selector(downloadsTapped))
    private lazy var settingsButton = ToolbarButton(buttonType: .settings, target: self, action: #selector(settingsTapped))
    private lazy var tabOverviewButton = ToolbarButton(buttonType: .tabOverview, target: self, action: #selector(tabOverviewTapped))
    private lazy var reloadButton = ToolbarButton(buttonType: .reload, target: self, action: #selector(reloadTapped))
    private lazy var pageZoomButton = ToolbarButton(buttonType: .pageZoom, target: self, action: #selector(pageZoomTapped))
    private lazy var newTabButton: ToolbarButton = {
        let button = ToolbarButton(buttonType: .newTab, target: self, action: #selector(newTabTapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(newTabLongPressed(_:)))
        longPress.minimumPressDuration = 0.5
        button.addGestureRecognizer(longPress)
        return button
    }()
    private lazy var closeTabButton: ToolbarButton = {
        let button = ToolbarButton(buttonType: .closeTab, target: self, action: #selector(closeTabTapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(closeTabLongPressed(_:)))
        longPress.minimumPressDuration = 0.5
        button.addGestureRecognizer(longPress)
        return button
    }()

    private lazy var actionButtons: [BottomToolbarAction: ToolbarButton] = [
        .back: backButton,
        .forward: forwardButton,
        .reload: reloadButton,
        .share: shareButton,
        .pageZoom: pageZoomButton,
        .bookmarks: bookmarksButton,
        .history: historyButton,
        .downloads: downloadButton,
        .settings: settingsButton,
        .newTab: newTabButton,
        .closeTab: closeTabButton,
        .tabOverview: tabOverviewButton,
    ]

    private lazy var buttons: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = BottomToolbarLayoutPolicy.verticalSpacing
        return stack
    }()
    
    private var topConstraint: NSLayoutConstraint!
    private var contentHeightConstraint: NSLayoutConstraint!
    private var buttonsHeightConstraint: NSLayoutConstraint!
    private var standardButtonsTopConstraint: NSLayoutConstraint!
    private var compactButtonsTopConstraint: NSLayoutConstraint!
    private var addressBarConstraints: [NSLayoutConstraint] = []
    
    private var verticalOffset: CGFloat = 0
    private var displayedActions: [BottomToolbarAction] = []
    private var displayedLayout: BottomToolbarLayoutPolicy.Layout?
    private var layoutState: LayoutState = .standard
    private var hidesButtons = false
    
    // MARK: - Lifecycle
    
    init() {
        super.init(frame: .zero)
        configureAppearance()
        configureHierarchy()
        configureConstraints()
        configureInitialState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bottomToolbarActionsDidChange),
            name: .bottomToolbarActionsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bottomToolbarShortcutsDidChange),
            name: .bottomToolbarShortcutsDidChange,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyConfiguredActionsIfNeeded()
        // The pill's geometry is derived from this view's size - see
        // fix_address_bar_is_the_pill.py. Does nothing unless the
        // address bar is doubling as the pill.
        applyPillLayout()
        updateOledCutout()
    }
    
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            // A display link retains its target; do not leave one running
            // for a view that is off screen.
            settlePillAnimation()
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard usesAddressPill, layoutState == .standard,
              !isHidden, alpha > 0.01, isUserInteractionEnabled else {
            return super.hitTest(point, with: event)
        }
        // ADDED - see fix_address_bar_is_the_pill.py. This view no
        // longer moves or fades with the chrome; its parts do. So what
        // can be touched has to be said here, to match what is drawn.
        //
        // The capsule first: as the pill it sits below contentView's
        // bounds, where the default walk would never reach it.
        if let addressBar = attachedAddressBar, addressBar.superview === contentView,
           let hit = addressBar.hitTest(convert(point, to: addressBar), with: event) {
            return hit
        }
        // Condensed, nothing else is drawn: the page gets the touch, as
        // it did when this whole view was at alpha 0.
        if pillBlend >= 0.5 {
            return nil
        }
        // The buttons ride the slide transform out of contentView's
        // bounds too.
        if let hit = buttons.hitTest(convert(point, to: buttons), with: event) {
            return hit
        }
        // Above the slid-down toolbar is page, as it was when the slide
        // moved this view's own frame.
        if point.y < displayedPillOffset {
            return nil
        }
        return super.hitTest(point, with: event)
    }
    
    // MARK: - Layout
    
    func configureTopAnchor(to safeAreaBottomAnchor: NSLayoutYAxisAnchor) {
        topConstraint = topAnchor.constraint(
            equalTo: safeAreaBottomAnchor,
            constant: -contentHeight(for: layoutState)
        )
        topConstraint.isActive = true
    }
    
    func attachAddressBar(_ addressBar: AddressBar) {
        attachedAddressBar = addressBar
        setNeedsLayout()
        if addressBar.superview !== contentView {
            addressBar.removeFromSuperview()
            contentView.addSubview(addressBar)
        }
        if addressBarConstraints.isEmpty {
            addressBarConstraints = [
                addressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: UX.addressBarHorizontalInset),
                addressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -UX.addressBarHorizontalInset),
                addressBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: UX.addressBarTopInset),
            ]
        }
        standardButtonsTopConstraint?.isActive = false
        // CHANGED - see fix_address_bar_is_the_pill.py. Was
        // addressBar.bottomAnchor + spacing. The address bar now travels
        // and shrinks inside this view on its way to being the pill, and
        // the buttons must not follow it. Same 59pt as before: the bar's
        // top inset, its resting height, the spacing.
        standardButtonsTopConstraint = buttons.topAnchor.constraint(
            equalTo: contentView.topAnchor,
            constant: UX.addressBarTopInset + AddressBar.capsuleRestingHeight + UX.bottomToolbarButtonStackTopSpacing
        )
        NSLayoutConstraint.activate(addressBarConstraints)
    }
    
    func detachAddressBar() {
        NSLayoutConstraint.deactivate(addressBarConstraints)
        standardButtonsTopConstraint?.isActive = false
        attachedAddressBar = nil
        updateOledCutout()
    }
    
    private weak var attachedAddressBar: AddressBar?
    
    // MARK: - Address Pill
    //
    // ADDED - see fix_address_bar_is_the_pill.py.
    //
    // The condensed pill is the address bar. There is one capsule and one
    // piece of glass; this view moves it between its slot above the
    // buttons and the pill's place 20pt above the screen bottom, and
    // narrows it to the pill's width on the way.
    //
    // Two inputs, one function of them (applyPillLayout):
    //
    //   offset  how far the dynamic toolbar has slid, from
    //           ToolbarController on every scroll tick. The capsule rides
    //           down with the toolbar until it reaches the pill's place,
    //           then stays there while the rest slides on underneath -
    //           and the same in reverse, which is the point: on the way
    //           back the toolbar rises to meet the pill and picks it up.
    //   blend   0 expanded, 1 condensed. Condensed, the capsule is the
    //           pill wherever the toolbar is, and the bar's background
    //           and buttons are invisible.
    //
    // Nothing here is a UIKit animation. A flip of the condensed flag
    // moves `blend` on a display link, so every frame is a complete,
    // consistent layout - capsule, label, shadow and the cutout behind
    // the capsule - and a scroll tick landing mid-flight just changes
    // `offset` for the next frame.
    //
    // This view itself is neither transformed nor faded in this mode.
    // Its background and buttons are, which is what lets the capsule stay
    // behind as the pill.
    
    private enum PillUX {
        /// Critically damped: no overshoot, 99% there in a third of a second.
        static let springRate: CGFloat = 20
        static let blendEpsilon: CGFloat = 0.002
        static let offsetEpsilon: CGFloat = 0.2
        /// A stalled frame advances the spring by at most this much, so
        /// work done at the flip delays the animation rather than
        /// skipping its start.
        static let maximumFrameStep: CFTimeInterval = 1.0 / 30.0
        /// CondensedAddressPill's limits, from BrowserChrome's constraints.
        static let maximumPillWidth: CGFloat = 280
        static let minimumPillSideMargin: CGFloat = 24
    }
    
    private(set) var usesAddressPill = false
    private var pillScrollOffset: CGFloat = 0
    /// Added to the scroll offset for display, and sprung to zero - what
    /// turns a jump in the offset (the pill tap) into a glide.
    private var pillOffsetResidual: CGFloat = 0
    private var pillOffsetResidualVelocity: CGFloat = 0
    private var pillBlend: CGFloat = 0
    private var pillBlendVelocity: CGFloat = 0
    private var pillBlendTarget: CGFloat = 0
    private var holdsPillLayout = false
    private var isApplyingPillLayout = false
    private var pillDisplayLink: CADisplayLink?
    private var pillLastTick: CFTimeInterval = 0
    private var pillSettleHandlers: [() -> Void] = []
    private var requestedContentAlpha: CGFloat = 1
    
    private var displayedPillOffset: CGFloat {
        return max(0, pillScrollOffset + pillOffsetResidual)
    }
    
    /// The slide has taken everything but the capsule off screen.
    var isSlidFullyAway: Bool {
        return usesAddressPill && bounds.height > 0 && pillScrollOffset >= bounds.height - 0.5
    }
    
    /// The capsule's width at rest in this toolbar.
    var addressBarRestingWidth: CGFloat {
        return max(contentView.bounds.width - 2 * UX.addressBarHorizontalInset, 0)
    }
    
    /// For chromeState: the toolbar's own frame no longer shows the slide.
    var pillStateDescription: String {
        return String(format: "pill=%d t=%.2f c=%.2f o=%.1f",
                      usesAddressPill ? 1 : 0,
                      attachedAddressBar?.pillProgress ?? 0,
                      pillBlend,
                      displayedPillOffset)
    }
    
    /// Chosen by BrowserChrome: phone layout with the floating pill.
    /// Everything else keeps CondensedAddressPill and the cross-fade.
    func setUsesAddressPill(_ uses: Bool, condensed: Bool) {
        guard uses != usesAddressPill else {
            return
        }
        stopPillAnimation()
        usesAddressPill = uses
        pillBlendTarget = uses && condensed ? 1 : 0
        pillBlend = pillBlendTarget
        pillBlendVelocity = 0
        pillOffsetResidual = 0
        pillOffsetResidualVelocity = 0
        if uses {
            // The slide and the fade move to the parts.
            transform = .identity
            contentView.alpha = 1
            applyPillLayout()
        } else {
            resetPillLayout()
            transform = CGAffineTransform(translationX: 0, y: pillScrollOffset)
            contentView.alpha = requestedContentAlpha
        }
        firePillSettleHandlers()
    }
    
    /// The dynamic toolbar's slide. In the legacy mode this is exactly
    /// what BrowserChrome.setToolbarTransition used to do itself.
    func setScrollTransition(offset: CGFloat, contentAlpha: CGFloat) {
        pillScrollOffset = offset
        requestedContentAlpha = contentAlpha
        guard usesAddressPill else {
            transform = CGAffineTransform(translationX: 0, y: offset)
            contentView.alpha = contentAlpha
            return
        }
        if !holdsPillLayout {
            applyPillLayout()
        }
    }
    
    func setPillCondensed(_ condensed: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        guard usesAddressPill else {
            completion?()
            return
        }
        pillBlendTarget = condensed ? 1 : 0
        if let completion {
            pillSettleHandlers.append(completion)
        }
        if animated, window != nil {
            startPillAnimation()
        } else {
            settlePillAnimation()
        }
    }
    
    /// Runs `change`, which is expected to move the scroll offset, and
    /// glides there instead of jumping. For the pill tap: the dynamic
    /// toolbar is sent home in one step, and the capsule travels.
    func glidePillOffset(through change: () -> Void) {
        guard usesAddressPill else {
            change()
            return
        }
        let before = displayedPillOffset
        holdsPillLayout = true
        change()
        holdsPillLayout = false
        pillOffsetResidual = before - pillScrollOffset
        if window != nil, pillOffsetResidual != 0 {
            startPillAnimation()
        } else {
            pillOffsetResidual = 0
            pillOffsetResidualVelocity = 0
        }
        applyPillLayout()
    }
    
    /// The pill's text changed, and with it the pill's width.
    func refreshPillLayout() {
        applyPillLayout()
    }
    
    private func startPillAnimation() {
        guard pillDisplayLink == nil else {
            return
        }
        pillLastTick = 0
        let link = CADisplayLink(target: self, selector: #selector(pillAnimationTick(_:)))
        link.add(to: .main, forMode: .common)
        pillDisplayLink = link
    }
    
    private func stopPillAnimation() {
        pillDisplayLink?.invalidate()
        pillDisplayLink = nil
    }
    
    private func firePillSettleHandlers() {
        let handlers = pillSettleHandlers
        pillSettleHandlers = []
        handlers.forEach { $0() }
    }
    
    /// Straight to the end state.
    private func settlePillAnimation() {
        stopPillAnimation()
        pillBlend = pillBlendTarget
        pillBlendVelocity = 0
        pillOffsetResidual = 0
        pillOffsetResidualVelocity = 0
        applyPillLayout()
        firePillSettleHandlers()
    }
    
    @objc private func pillAnimationTick(_ link: CADisplayLink) {
        // The first frame only starts the clock.
        guard pillLastTick != 0 else {
            pillLastTick = link.timestamp
            return
        }
        let step = CGFloat(min(link.timestamp - pillLastTick, PillUX.maximumFrameStep))
        pillLastTick = link.timestamp
        let blendSettled = Self.advanceSpring(
            &pillBlend, &pillBlendVelocity,
            toward: pillBlendTarget, step: step, epsilon: PillUX.blendEpsilon
        )
        let offsetSettled = Self.advanceSpring(
            &pillOffsetResidual, &pillOffsetResidualVelocity,
            toward: 0, step: step, epsilon: PillUX.offsetEpsilon
        )
        applyPillLayout()
        if blendSettled, offsetSettled {
            stopPillAnimation()
            firePillSettleHandlers()
        }
    }
    
    /// One exact step of a critically damped spring - stable for any
    /// step length, and it keeps its velocity when the target changes
    /// mid-flight, so a reversed flip turns round instead of restarting.
    private static func advanceSpring(
        _ value: inout CGFloat,
        _ velocity: inout CGFloat,
        toward target: CGFloat,
        step: CGFloat,
        epsilon: CGFloat
    ) -> Bool {
        let rate = PillUX.springRate
        let distance = value - target
        let decay = exp(-rate * step)
        let momentum = velocity + rate * distance
        value = target + (distance + momentum * step) * decay
        velocity = (velocity - momentum * rate * step) * decay
        if abs(value - target) < epsilon, abs(velocity) < epsilon * 10 {
            value = target
            velocity = 0
            return true
        }
        return false
    }
    
    private func setConstant(_ constant: CGFloat, on constraint: NSLayoutConstraint) {
        if constraint.constant != constant {
            constraint.constant = constant
        }
    }
    
    /// Everything the pill mode draws, from `offset` and `blend`.
    private func applyPillLayout() {
        guard usesAddressPill, !isApplyingPillLayout else {
            return
        }
        isApplyingPillLayout = true
        defer { isApplyingPillLayout = false }
        
        let offset = displayedPillOffset
        let blend = pillBlend
        let restingWidth = addressBarRestingWidth
        var progress: CGFloat = 0
        var travel: CGFloat = 0
        var inset = UX.addressBarHorizontalInset
        
        let addressBar = attachedAddressBar.flatMap { $0.superview === contentView ? $0 : nil }
        if let addressBar, layoutState == .standard, bounds.height > 0, restingWidth > 0 {
            // From the capsule's slot to the pill's place: the pill sits
            // condensedPillBottomMargin above this view's bottom edge,
            // which is the screen's.
            let distance = max(
                0,
                bounds.height - BrowserChrome.condensedPillBottomMargin
                    - CondensedAddressPill.height - UX.addressBarTopInset
            )
            let slid = min(offset, distance)
            let slide: CGFloat = distance > 0 ? slid / distance : (offset > 0 ? 1 : 0)
            progress = slide + (1 - slide) * blend
            travel = slid + (distance - slid) * blend
            let pillWidth = addressBar.pillWidth(
                maximum: min(PillUX.maximumPillWidth, bounds.width - 2 * PillUX.minimumPillSideMargin)
            )
            let width = restingWidth + (min(pillWidth, restingWidth) - restingWidth) * progress
            inset = (contentView.bounds.width - width) / 2
        }
        
        if addressBarConstraints.count == 3 {
            setConstant(inset, on: addressBarConstraints[0])
            setConstant(-inset, on: addressBarConstraints[1])
            setConstant(UX.addressBarTopInset + travel, on: addressBarConstraints[2])
        }
        addressBar?.setPillProgress(progress, restingWidth: restingWidth)
        
        // The rest of the toolbar slides out from under the capsule and,
        // condensed, is not there at all.
        let slideTransform = CGAffineTransform(translationX: 0, y: offset)
        if backgroundView.transform != slideTransform {
            backgroundView.transform = slideTransform
        }
        if buttons.transform != slideTransform {
            buttons.transform = slideTransform
        }
        backgroundView.alpha = 1 - blend
        applyButtonsAlpha()
        
        contentView.layoutIfNeeded()
        updateOledCutout()
    }
    
    /// Back to the plain toolbar: the capsule in its slot at full width.
    private func resetPillLayout() {
        if addressBarConstraints.count == 3 {
            setConstant(UX.addressBarHorizontalInset, on: addressBarConstraints[0])
            setConstant(-UX.addressBarHorizontalInset, on: addressBarConstraints[1])
            setConstant(UX.addressBarTopInset, on: addressBarConstraints[2])
        }
        attachedAddressBar?.setPillProgress(0, restingWidth: addressBarRestingWidth)
        backgroundView.transform = .identity
        buttons.transform = .identity
        backgroundView.alpha = 1
        applyButtonsAlpha()
        setNeedsLayout()
    }
    
    /// The one place the button row's alpha is decided.
    private func applyButtonsAlpha() {
        let stateAlpha: CGFloat = layoutState == .focused || hidesButtons ? 0 : 1
        guard usesAddressPill else {
            buttons.alpha = stateAlpha
            return
        }
        // The fade the slide used to give the whole content view. The
        // capsule is exempt: it is on its way to being the pill.
        let slideAlpha = 1 - min(displayedPillOffset / max(bounds.height, 1), 1)
        buttons.alpha = stateAlpha * slideAlpha * (1 - pillBlend)
    }
    
    /// When true the capsule is also cut out of the toolbar's GLASS
    /// (backgroundView), so the capsule's own glass sits directly
    /// over the page pixels composited behind the toolbar - the
    /// floating pill's exact optical situation, page visible through
    /// it. Flip to false if iOS ever renders the masked glass
    /// incorrectly: the overlay-only cutout (toolbar frost behind
    /// the capsule) returns.
    private static let cutsGlassBehindCapsule = true
    
    private lazy var glassCutoutMaskView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        let shape = CAShapeLayer()
        shape.fillRule = .evenOdd
        shape.fillColor = UIColor.white.cgColor
        view.layer.addSublayer(shape)
        return view
    }()
    
    /// Cuts the address bar capsule out of the OLED overlay AND (see
    /// cutsGlassBehindCapsule) the toolbar's glass, so the capsule's
    /// glass samples the page composited behind the toolbar instead
    /// of an opaque black fill or the toolbar's own frost. All
    /// geometry is sized from backgroundView.bounds, which IS final
    /// during this view's layoutSubviews - the overlay's own bounds
    /// are not (they settle in the effect view's later pass), and a
    /// mask sized from them can freeze short whenever the toolbar
    /// has just grown, leaving a bare-glass strip under the button
    /// row that shows whenever the page composited behind it is
    /// bright.
    private func updateOledCutout() {
        guard let addressBar = attachedAddressBar,
              addressBar.superview === contentView else {
            oledOverlayView.layer.mask = nil
            backgroundView.mask = nil
            return
        }
        // The capsule lives inside the address bar inside
        // contentView, whose subtrees lay out after this view's
        // layoutSubviews - force them current before measuring.
        backgroundView.layoutIfNeeded()
        contentView.layoutIfNeeded()
        let bounds = backgroundView.bounds
        let capsule = addressBar.capsuleFrame(in: backgroundView)
        guard bounds.width > 0, capsule.width > 0, bounds.intersects(capsule) else {
            oledOverlayView.layer.mask = nil
            backgroundView.mask = nil
            return
        }
        let path = UIBezierPath(rect: bounds)
        // The live radius: the capsule is 22 at rest and 20 as the pill.
        path.append(UIBezierPath(roundedRect: capsule, cornerRadius: addressBar.currentCapsuleCornerRadius))
        // Overlay mask. The overlay's final frame fills the effect
        // view's contentView, i.e. equals backgroundView.bounds with
        // a zero origin, so this geometry applies verbatim - and
        // stays correct even while the overlay's own layout lags a
        // pass behind.
        let mask = (oledOverlayView.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = bounds
        mask.path = path.cgPath
        oledOverlayView.layer.mask = mask
        // Glass mask: a UIView mask (UIKit's supported way to mask a
        // UIVisualEffectView) with the same hole. Kept separate from
        // the overlay mask so either can fail or be disabled without
        // taking the other down.
        if Self.cutsGlassBehindCapsule {
            glassCutoutMaskView.frame = bounds
            if let shape = glassCutoutMaskView.layer.sublayers?.first as? CAShapeLayer {
                shape.frame = glassCutoutMaskView.bounds
                shape.path = path.cgPath
            }
            // Not reassigned when it is already this view: in the pill
            // mode this runs every frame of a scroll.
            if backgroundView.mask !== glassCutoutMaskView {
                backgroundView.mask = glassCutoutMaskView
            }
        } else {
            backgroundView.mask = nil
        }
    }
    
    func apply(state: LayoutState, hidesButtons: Bool) {
        layoutState = state
        self.hidesButtons = hidesButtons
        let contentHeight = contentHeight(for: state)
        
        UIView.performWithoutAnimation {
            topConstraint.constant = verticalOffset - contentHeight
            contentHeightConstraint.constant = contentHeight
            isHidden = state == .hidden || state == .collapsed
            backgroundView.isHidden = state == .focused
            
            let isCompact = state == .compact || state == .collapsed
            standardButtonsTopConstraint?.isActive = !isCompact
            compactButtonsTopConstraint.isActive = isCompact
            buttonsHeightConstraint.constant = state == .focused ? 0 : configuredButtonsHeight
            applyButtonsAlpha()
            buttons.isUserInteractionEnabled = state != .focused && !hidesButtons
            applyPillLayout()
            layoutIfNeeded()
        }
    }
    
    // MARK: - Updates
    
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, canShare: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        shareButton.isEnabled = canShare
    }
    
    func setVerticalOffset(_ offset: CGFloat) {
        verticalOffset = offset
        topConstraint.constant = offset - contentHeightConstraint.constant
    }
    
    func setContentAlpha(_ alpha: CGFloat) {
        requestedContentAlpha = alpha
        // In the pill mode the content view holds the capsule, which
        // must not fade - see fix_address_bar_is_the_pill.py. The button
        // row's alpha is derived instead (applyButtonsAlpha).
        guard !usesAddressPill else {
            return
        }
        contentView.alpha = alpha
    }

    /// Readable because it is invisible from outside otherwise, and that
    /// is what hid the black band for four captures: the toolbar's own
    /// alpha reads 1 while its CONTENT alpha is 0, so every diagnostic
    /// reported healthy chrome while the bar rendered empty.
    var contentAlpha: CGFloat {
        // What is actually drawn, which is what this exists to report:
        // in the pill mode that is the button row.
        usesAddressPill ? buttons.alpha : contentView.alpha
    }
    
    func updateDownload(_ summary: DownloadStoreSummary) {
        downloadButton.applyDownloadSummary(summary)
    }
    
    // MARK: - Action Wiring
    
    @objc private func backTapped() { onBack?() }
    @objc private func forwardTapped() { onForward?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func bookmarksTapped() { onBookmarks?() }
    @objc private func historyTapped() { onHistory?() }
    @objc private func downloadsTapped() { onDownloads?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func tabOverviewTapped() { onTabOverview?() }
    @objc private func reloadTapped() { onReload?() }
    @objc private func pageZoomTapped() { onPageZoom?() }
    @objc private func newTabTapped() { onNewTab?() }
    @objc private func closeTabTapped() { onCloseTab?() }

    @objc private func closeTabLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              BottomToolbarShortcutPolicy.longPressAction(
                for: .closeTab,
                closeTabOpensNewTab: Prefs.ToolbarSettings.closeTabLongPressOpensNewTab,
                newTabClosesTab: Prefs.ToolbarSettings.newTabLongPressClosesTab
              ) == .newTab else {
            return
        }
        if Prefs.ToolbarSettings.toolbarButtonHapticsEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        onNewTab?()
    }

    @objc private func newTabLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              BottomToolbarShortcutPolicy.longPressAction(
                for: .newTab,
                closeTabOpensNewTab: Prefs.ToolbarSettings.closeTabLongPressOpensNewTab,
                newTabClosesTab: Prefs.ToolbarSettings.newTabLongPressClosesTab
              ) == .closeTab else {
            return
        }
        if Prefs.ToolbarSettings.toolbarButtonHapticsEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        onCloseTab?()
    }

    @objc private func bottomToolbarActionsDidChange() {
        applyConfiguredActions()
    }

    @objc private func bottomToolbarShortcutsDidChange() {
        updateShortcutAccessibility()
    }
    
    // MARK: - View Setup
    
    private func configureAppearance() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }
    
    private func configureHierarchy() {
        addSubview(backgroundView)
        backgroundView.contentView.addSubview(oledOverlayView)
        addSubview(contentView)
        contentView.addSubview(buttons)
        applyConfiguredActions()
    }
    
    private func configureConstraints() {
        contentHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: UX.bottomToolbarStandardContentHeight)
        buttonsHeightConstraint = buttons.heightAnchor.constraint(equalToConstant: UX.bottomToolbarButtonStackHeight)
        compactButtonsTopConstraint = buttons.topAnchor.constraint(equalTo: contentView.topAnchor, constant: UX.bottomToolbarButtonStackTopSpacing)
        
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -UX.backgroundViewHorizontalExtension),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: UX.backgroundViewHorizontalExtension),
            backgroundView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            oledOverlayView.leadingAnchor.constraint(equalTo: backgroundView.contentView.leadingAnchor),
            oledOverlayView.trailingAnchor.constraint(equalTo: backgroundView.contentView.trailingAnchor),
            oledOverlayView.topAnchor.constraint(equalTo: backgroundView.contentView.topAnchor),
            oledOverlayView.bottomAnchor.constraint(equalTo: backgroundView.contentView.bottomAnchor),
            
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentHeightConstraint,
            
            buttons.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: UX.bottomToolbarButtonStackHorizontalInset),
            buttons.trailingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -UX.bottomToolbarButtonStackHorizontalInset),
            buttonsHeightConstraint,
        ])
    }
    
    private func configureInitialState() {
        shareButton.isEnabled = false
        updateShortcutAccessibility()
    }

    private func applyConfiguredActions() {
        displayedActions = []
        displayedLayout = nil
        setNeedsLayout()
        applyConfiguredActionsIfNeeded()
    }

    private func applyConfiguredActionsIfNeeded() {
        guard bounds.width > 0 else {
            return
        }
        let visibleActions = BottomToolbarAction.displayedActions(
            from: Prefs.ToolbarSettings.bottomToolbarActions
        )
        let layout = BottomToolbarLayoutPolicy.layout(
            containerWidth: bounds.width,
            safeAreaLeft: safeAreaInsets.left,
            safeAreaRight: safeAreaInsets.right,
            configuredCount: visibleActions.count
        )
        guard displayedActions != visibleActions || displayedLayout != layout else {
            return
        }

        for row in buttons.arrangedSubviews {
            buttons.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        var actionIndex = 0
        for rowActionCount in layout.rowActionCounts {
            let row = makeButtonRow()
            for _ in 0..<rowActionCount {
                let action = visibleActions[actionIndex]
                actionIndex += 1
                if let button = actionButtons[action] {
                    button.isHidden = false
                    row.addArrangedSubview(button)
                }
            }
            buttons.addArrangedSubview(row)
        }
        displayedActions = visibleActions
        displayedLayout = layout
        accessibilityElements = visibleActions.compactMap { actionButtons[$0] }
        applyLayoutMetrics()
    }

    private func makeButtonRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = UX.bottomToolbarButtonSpacing
        return row
    }

    private var configuredButtonsHeight: CGFloat {
        displayedLayout?.requiredHeight ?? UX.bottomToolbarButtonStackHeight
    }

    private func contentHeight(for state: LayoutState) -> CGFloat {
        let additionalRowsHeight = max(
            0,
            configuredButtonsHeight - UX.bottomToolbarButtonStackHeight
        )
        switch state {
        case .hidden, .standard:
            return UX.bottomToolbarStandardContentHeight + additionalRowsHeight
        case .collapsed, .compact:
            return UX.bottomToolbarCompactContentHeight + additionalRowsHeight
        case .focused:
            return UX.bottomToolbarFocusedContentHeight
        }
    }

    private func applyLayoutMetrics() {
        let contentHeight = contentHeight(for: layoutState)
        buttonsHeightConstraint.constant = layoutState == .focused ? 0 : configuredButtonsHeight
        contentHeightConstraint.constant = contentHeight
        topConstraint?.constant = verticalOffset - contentHeight
        applyButtonsAlpha()
        buttons.isUserInteractionEnabled = layoutState != .focused && !hidesButtons
    }

    private func updateShortcutAccessibility() {
        closeTabButton.accessibilityHint = Prefs.ToolbarSettings.closeTabLongPressOpensNewTab
            ? NSLocalizedString("Touch and hold to open a new tab", comment: "")
            : nil
        newTabButton.accessibilityHint = Prefs.ToolbarSettings.newTabLongPressClosesTab
            ? NSLocalizedString("Touch and hold to close the current tab", comment: "")
            : nil
    }

    private var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController {
                return viewController
            }
            responder = next
        }
        return nil
    }
}
