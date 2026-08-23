//
//  TopToolbar.swift
//  Reynard
//
//  Created by Minh Ton on 10/6/26.
//

import UIKit

final class TopToolbar: UIView {
    private enum UX {
        static let topToolbarContentHeight: CGFloat = 60
        static let topToolbarButtonStackHeight: CGFloat = 30
        static let topToolbarStandardButtonStackWidth: CGFloat = 126
        static let topToolbarHorizontalInset: CGFloat = 12
        static let topToolbarButtonSpacing: CGFloat = 10
        static let topToolbarAddressBarSpacing: CGFloat = 12
        static let topToolbarAddressBarVerticalSpacing: CGFloat = 8
        static let topToolbarAddressBarWidthLimit: CGFloat = 650
        static let backgroundViewHorizontalExtension: CGFloat = 16
    }
    
    enum LayoutState {
        case hidden
        case standard
        case compact
    }
    
    var onSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onDownloads: (() -> Void)?
    var onShare: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onTabOverview: (() -> Void)?
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    
    private let backgroundView: UIVisualEffectView = {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect.nonAdaptive(style: .regular)
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
    
   
    private lazy var sidebarButton = ToolbarButton(
        buttonType: .sidebar,
        target: self,
        action: #selector(sidebarTapped)
    )
    private lazy var backButton = ToolbarButton(
        buttonType: .back,
        target: self,
        action: #selector(backTapped)
    )
    private lazy var forwardButton = ToolbarButton(
        buttonType: .forward,
        target: self,
        action: #selector(forwardTapped)
    )
    private lazy var libraryButton = ToolbarButton(
        buttonType: .library,
        target: self,
        action: #selector(libraryTapped)
    )
    private lazy var downloadButton = ToolbarButton(
        buttonType: .download,
        target: self,
        action: #selector(downloadsTapped)
    )
    private lazy var shareButton = ToolbarButton(
        buttonType: .share,
        target: self,
        action: #selector(shareTapped)
    )
    private lazy var newTabButton = ToolbarButton(
        buttonType: .newTab,
        target: self,
        action: #selector(newTabTapped)
    )
    private lazy var tabOverviewButton = ToolbarButton(
        buttonType: .tabOverview,
        target: self,
        action: #selector(tabOverviewTapped)
    )
    
    private lazy var leadingButtons: UIStackView = {
        downloadButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [sidebarButton, downloadButton, backButton, forwardButton, libraryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = UX.topToolbarButtonSpacing
        stack.distribution = .fillEqually
        return stack
    }()
    
    private lazy var trailingButtons: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [shareButton, newTabButton, tabOverviewButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = UX.topToolbarButtonSpacing
        stack.distribution = .fillEqually
        return stack
    }()
    
    private lazy var contentLayoutGuide: UILayoutGuide = {
        if #available(iOS 26.0, *) {
            return layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        }
        
        return safeAreaLayoutGuide
    }()
    
    private var heightConstraint: NSLayoutConstraint!
    private var contentTopConstraint: NSLayoutConstraint!
    private var leadingWidthConstraint: NSLayoutConstraint!
    private var trailingWidthConstraint: NSLayoutConstraint!
    private var standardAddressBarConstraints: [NSLayoutConstraint] = []
    private var compactAddressBarConstraints: [NSLayoutConstraint] = []
    private var widthLimitedStandardAddressBarConstraints: [NSLayoutConstraint] = []
    
    private var layoutState: LayoutState = .hidden
    private var layoutInterfaceIdiom: UIUserInterfaceIdiom = .unspecified
    private var layoutSidebarButtonVisible = false
    private var isUsingStandardAddressBarWidthLimit = false
    
    // MARK: - Lifecycle
    
    init() {
        super.init(frame: .zero)
        configureAppearance()
        configureHierarchy()
        configureConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateStandardAddressBarLayout()
        updateOledCutout()
    }
    
    // MARK: - Layout
    
    func attachAddressBar(_ addressBar: AddressBar) {
        attachedAddressBar = addressBar
        setNeedsLayout()
        if addressBar.superview !== contentView {
            addressBar.removeFromSuperview()
            contentView.addSubview(addressBar)
        }
        if standardAddressBarConstraints.isEmpty {
            standardAddressBarConstraints = [
                addressBar.leadingAnchor.constraint(equalTo: leadingButtons.trailingAnchor, constant: UX.topToolbarAddressBarSpacing),
                addressBar.trailingAnchor.constraint(equalTo: trailingButtons.leadingAnchor, constant: -UX.topToolbarAddressBarSpacing),
                addressBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: UX.topToolbarAddressBarVerticalSpacing),
                addressBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -UX.topToolbarAddressBarVerticalSpacing),
            ]
            widthLimitedStandardAddressBarConstraints = [
                addressBar.centerXAnchor.constraint(equalTo: contentLayoutGuide.centerXAnchor),
                addressBar.widthAnchor.constraint(equalToConstant: UX.topToolbarAddressBarWidthLimit),
                addressBar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingButtons.trailingAnchor, constant: UX.topToolbarAddressBarSpacing),
                addressBar.trailingAnchor.constraint(lessThanOrEqualTo: trailingButtons.leadingAnchor, constant: -UX.topToolbarAddressBarSpacing),
                addressBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: UX.topToolbarAddressBarVerticalSpacing),
                addressBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -UX.topToolbarAddressBarVerticalSpacing),
            ]
            compactAddressBarConstraints = [
                addressBar.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
                addressBar.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
                addressBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: UX.topToolbarAddressBarVerticalSpacing),
                addressBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -UX.topToolbarAddressBarVerticalSpacing),
            ]
        }
    }
    
    func detachAddressBar() {
        NSLayoutConstraint.deactivate(standardAddressBarConstraints + widthLimitedStandardAddressBarConstraints + compactAddressBarConstraints)
        isUsingStandardAddressBarWidthLimit = false
        attachedAddressBar = nil
        updateOledCutout()
    }
    
    private weak var attachedAddressBar: AddressBar?
    
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
        path.append(UIBezierPath(roundedRect: capsule, cornerRadius: AddressBar.capsuleCornerRadius))
        // The dismiss X gets the same treatment as the capsule: its
        // clear glass needs the overlay and the toolbar glass cut
        // behind it too, or it reads as a solid disc while editing.
        let dismiss = addressBar.dismissButtonFrame(in: backgroundView)
        if dismiss.width > 0, bounds.intersects(dismiss) {
            path.append(UIBezierPath(roundedRect: dismiss, cornerRadius: dismiss.height / 2))
        }
        // Overlay mask. The overlay's final frame fills the effect
        // view's contentView, i.e. equals backgroundView.bounds with
        // a zero origin, so this geometry applies verbatim - and
        // stays correct even while the overlay's own layout lags a
        // pass behind.
        // Standalone layers get Core Animation's implicit ~0.25s
        // actions on frame/path changes - UIView.performWithoutAnimation
        // does not gate them - which let the hole glide for a beat
        // while the toolbar and capsule snapped. Masks must snap
        // atomically with the geometry they were measured from.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
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
            backgroundView.mask = glassCutoutMaskView
        } else {
            backgroundView.mask = nil
        }
    }
    
    func apply(
        state: LayoutState,
        topInset: CGFloat,
        interfaceIdiom: UIUserInterfaceIdiom,
        sidebarButtonVisible: Bool
    ) {
        layoutState = state
        layoutInterfaceIdiom = interfaceIdiom
        layoutSidebarButtonVisible = sidebarButtonVisible
        
        UIView.performWithoutAnimation {
            contentTopConstraint.constant = topInset
            heightConstraint.constant = topInset + UX.topToolbarContentHeight
            isHidden = state == .hidden
            guard state != .hidden else { return }
            
            let isCompact = state == .compact
            leadingButtons.isHidden = isCompact
            trailingButtons.isHidden = isCompact
            leadingWidthConstraint.constant = isCompact ? 0 : leadingWidth(
                interfaceIdiom: interfaceIdiom,
                sidebarButtonVisible: sidebarButtonVisible,
                showsDownloads: downloadButton.isShowingDownloads
            )
            trailingWidthConstraint.constant = isCompact ? 0 : UX.topToolbarStandardButtonStackWidth
            
            sidebarButton.isHidden = interfaceIdiom != .pad || !sidebarButtonVisible
            libraryButton.isHidden = interfaceIdiom == .pad
            downloadButton.isHidden = isCompact || !downloadButton.isShowingDownloads
            
            NSLayoutConstraint.deactivate(standardAddressBarConstraints + widthLimitedStandardAddressBarConstraints + compactAddressBarConstraints)
            isUsingStandardAddressBarWidthLimit = false
            if isCompact {
                NSLayoutConstraint.activate(compactAddressBarConstraints)
            } else {
                setStandardAddressBarWidthLimitEnabled(shouldLimitStandardAddressBarWidth)
            }
            layoutIfNeeded()
        }
    }
    
    func setContentAlpha(_ alpha: CGFloat) {
        contentView.alpha = alpha
    }

    /// See BottomToolbar.contentAlpha - the same invisibility applies.
    var contentAlpha: CGFloat {
        contentView.alpha
    }
    
    // MARK: - Updates
    
    func updateNavigation(canGoBack: Bool, canGoForward: Bool, canShare: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        shareButton.isEnabled = canShare
    }
    
    func updateDownload(_ summary: DownloadStoreSummary) {
        downloadButton.applyDownloadSummary(summary)
        updateDownloadButtonVisibility()
    }
    
    func setMenuButtonIndicatesUpdate(_ hasUpdate: Bool) {
        libraryButton.setImage(
            hasUpdate ? UIImage(named: "reynard.ellipsis.circle.badge") : UIImage(named: "reynard.ellipsis.circle"),
            for: .normal
        )
    }
    
    func syncSidebarButton(splitViewController: UISplitViewController?) {
        sidebarButton.setImage(splitViewController?.displayModeButtonItem.image ?? UIImage(named: "reynard.sidebar.left"), for: .normal)
        sidebarButton.accessibilityLabel = splitViewController?.displayModeButtonItem.accessibilityLabel
    }
    
    func sidebarButtonFrame(in view: UIView) -> CGRect {
        return sidebarButton.convert(sidebarButton.bounds, to: view)
    }
    
    func setSidebarButtonTransition(alpha: CGFloat, hidden: Bool) {
        sidebarButton.alpha = alpha
        sidebarButton.isHidden = hidden
    }
    
    // MARK: - Action Wiring
    
    @objc private func sidebarTapped() { onSidebar?() }
    @objc private func backTapped() { onBack?() }
    @objc private func forwardTapped() { onForward?() }
    @objc private func libraryTapped() { onLibrary?() }
    @objc private func downloadsTapped() { onDownloads?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func newTabTapped() { onNewTab?() }
    @objc private func tabOverviewTapped() { onTabOverview?() }
    
    // MARK: - View Setup
    
    private func configureAppearance() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }
    
    private func configureHierarchy() {
        addSubview(backgroundView)
        backgroundView.contentView.addSubview(oledOverlayView)
        addSubview(contentView)
        contentView.addSubview(leadingButtons)
        contentView.addSubview(trailingButtons)
    }
    
    private func configureConstraints() {
        heightConstraint = heightAnchor.constraint(equalToConstant: UX.topToolbarContentHeight)
        contentTopConstraint = contentView.topAnchor.constraint(equalTo: topAnchor)
        leadingWidthConstraint = leadingButtons.widthAnchor.constraint(equalToConstant: UX.topToolbarStandardButtonStackWidth)
        trailingWidthConstraint = trailingButtons.widthAnchor.constraint(equalToConstant: UX.topToolbarStandardButtonStackWidth)
        
        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -UX.backgroundViewHorizontalExtension),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: UX.backgroundViewHorizontalExtension),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            oledOverlayView.leadingAnchor.constraint(equalTo: backgroundView.contentView.leadingAnchor),
            oledOverlayView.trailingAnchor.constraint(equalTo: backgroundView.contentView.trailingAnchor),
            oledOverlayView.topAnchor.constraint(equalTo: backgroundView.contentView.topAnchor),
            oledOverlayView.bottomAnchor.constraint(equalTo: backgroundView.contentView.bottomAnchor),
            
            heightConstraint,
            contentTopConstraint,
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.heightAnchor.constraint(equalToConstant: UX.topToolbarContentHeight),
            
            leadingButtons.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: UX.topToolbarHorizontalInset),
            leadingButtons.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            leadingWidthConstraint,
            leadingButtons.heightAnchor.constraint(equalToConstant: UX.topToolbarButtonStackHeight),
            
            trailingButtons.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -UX.topToolbarHorizontalInset),
            trailingButtons.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            trailingWidthConstraint,
            trailingButtons.heightAnchor.constraint(equalToConstant: UX.topToolbarButtonStackHeight),
        ])
    }
    
    private func leadingWidth(
        interfaceIdiom: UIUserInterfaceIdiom,
        sidebarButtonVisible: Bool,
        showsDownloads: Bool
    ) -> CGFloat {
        guard interfaceIdiom == .pad else { return UX.topToolbarStandardButtonStackWidth }
        let visibleButtonCount = (sidebarButtonVisible ? 3 : 2) + (showsDownloads ? 1 : 0)
        return (CGFloat(visibleButtonCount) * UX.topToolbarButtonStackHeight)
        + (CGFloat(max(visibleButtonCount - 1, 0)) * UX.topToolbarButtonSpacing)
    }
    
    private var shouldLimitStandardAddressBarWidth: Bool {
        let layoutInsets = contentLayoutInsets
        let safeWidth = bounds.width - layoutInsets.left - layoutInsets.right
        guard safeWidth > 0 else { return false }
        
        let leadingBoundary = UX.topToolbarHorizontalInset
        + leadingWidthConstraint.constant
        + UX.topToolbarAddressBarSpacing
        let trailingBoundary = safeWidth
        - UX.topToolbarHorizontalInset
        - trailingWidthConstraint.constant
        - UX.topToolbarAddressBarSpacing
        let centeredWidth = min(
            (safeWidth / 2) - leadingBoundary,
            trailingBoundary - (safeWidth / 2)
        ) * 2
        
        return centeredWidth > UX.topToolbarAddressBarWidthLimit
    }
    
    private var contentLayoutInsets: UIEdgeInsets {
        if #available(iOS 26.0, *) {
            return edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
        }
        
        return safeAreaInsets
    }
    
    private func updateStandardAddressBarLayout() {
        guard layoutState == .standard else {
            return
        }
        
        setStandardAddressBarWidthLimitEnabled(shouldLimitStandardAddressBarWidth)
    }
    
    private func setStandardAddressBarWidthLimitEnabled(_ isEnabled: Bool) {
        let activeConstraints = isEnabled ? widthLimitedStandardAddressBarConstraints : standardAddressBarConstraints
        guard activeConstraints.contains(where: { !$0.isActive }) || isUsingStandardAddressBarWidthLimit != isEnabled else {
            return
        }
        
        NSLayoutConstraint.deactivate(standardAddressBarConstraints + widthLimitedStandardAddressBarConstraints)
        NSLayoutConstraint.activate(activeConstraints)
        isUsingStandardAddressBarWidthLimit = isEnabled
    }
    
    private func updateDownloadButtonVisibility() {
        let isCompact = layoutState == .compact
        downloadButton.isHidden = layoutState != .standard || !downloadButton.isShowingDownloads
        leadingWidthConstraint.constant = isCompact ? 0 : leadingWidth(
            interfaceIdiom: layoutInterfaceIdiom,
            sidebarButtonVisible: layoutSidebarButtonVisible,
            showsDownloads: downloadButton.isShowingDownloads
        )
        updateStandardAddressBarLayout()
        layoutIfNeeded()
    }
}
