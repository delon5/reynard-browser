//
//  CondensedAddressPill.swift
//  Reynard
//

import UIKit

/// The small floating capsule shown in place of the full toolbars while
/// scrolled down, matching Safari's condensed address pill. Uses real
/// Liquid Glass (`UIGlassEffect`) on iOS 26+, falling back to
/// `UIBlurEffect(.systemMaterial)` on older versions or when Reduce
/// Transparency is on.
final class CondensedAddressPill: UIView {
    /// The pill's actual height — exposed so other layout code (e.g.
    /// the artificial safe-area clearance in BrowserChrome) can derive
    /// its own values from this directly, instead of duplicating the
    /// number as an independent constant that can silently drift out of
    /// sync if this one changes.
    static let height: CGFloat = 40
    
    private enum UX {
        static let horizontalPadding: CGFloat = 14
        static let shadowOpacity: Float = 0.15
        static let shadowRadius: CGFloat = 8
        static let shadowOffset = CGSize(width: 0, height: 2)
        static let darkModeShadowAlpha: CGFloat = 0.35
    }
    
    /// Tapping the pill expands the full chrome back — a standard
    /// affordance for condensed toolbars, in addition to scrolling up.
    var onTap: (() -> Void)?
    
    private let contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        view.layer.cornerRadius = CondensedAddressPill.height / 2
        return view
    }()
    
    private let glassBackground = ToolbarGlassBackgroundView()
    
    // Morph state - see fix_pill_morphs_from_the_address_capsule.py.
    private var heightConstraint: NSLayoutConstraint!
    private var morphReplica: UIView?
    /// Holds the label at its resting width while the pill is somewhere
    /// else - review amendment to fix_pill_morphs_from_the_address_capsule.py.
    private var labelMorphWidthConstraint: NSLayoutConstraint?

    private let locationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        alpha = 0
        isHidden = true
        configureShadow()
        configureHierarchy()
        configureConstraints()
        configureGesture()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setLocationText(_ text: String?) {
        locationLabel.text = text
    }
    
    private func configureShadow() {
        layer.shadowColor = traitCollection.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(UX.darkModeShadowAlpha).cgColor
            : UIColor.black.cgColor
        layer.shadowOpacity = UX.shadowOpacity
        layer.shadowRadius = UX.shadowRadius
        layer.shadowOffset = UX.shadowOffset
        layer.masksToBounds = false
    }
    
    private func configureHierarchy() {
        addSubview(contentView)
        glassBackground.install(in: contentView)
        contentView.addSubview(locationLabel)
    }
    
    private func configureConstraints() {
        heightConstraint = heightAnchor.constraint(equalToConstant: CondensedAddressPill.height)
        // CHANGED - see fix_pill_morphs_from_the_address_capsule.py. The
        // label used to be pinned to both edges, which made it as wide
        // as the capsule: while the capsule changes width the label's
        // bitmap would be dragged along or stretched with it. It now
        // keeps its own width, centred, and the capsule hugs it at a
        // priority the morph's explicit width overrides. At rest this
        // lays out exactly as before: text width plus the padding,
        // truncating once the pill reaches its limits.
        let hugsLabel = contentView.widthAnchor.constraint(
            equalTo: locationLabel.widthAnchor,
            constant: UX.horizontalPadding * 2
        )
        hugsLabel.priority = .defaultHigh
        locationLabel.setContentCompressionResistancePriority(UILayoutPriority(749), for: .horizontal)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
            
            hugsLabel,
            locationLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            locationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: UX.horizontalPadding),
            locationLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -UX.horizontalPadding),
            locationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule at every height - see
        // fix_pill_morphs_from_the_address_capsule.py. Set here so the
        // radius animates with the bounds inside the morph's layout pass.
        contentView.layer.cornerRadius = bounds.height / 2
    }
    
    // MARK: - Morph
    
    /// The pill's height while it stands in for the address capsule, or
    /// nil for its own.
    func setMorphHeight(_ height: CGFloat?) {
        heightConstraint.constant = height ?? CondensedAddressPill.height
        // Review amendment: the label keeps its RESTING width for the
        // whole trip. hugsLabel (750) outranks the label's own hugging
        // (250), so without this the label would be stretched to the
        // capsule's width - 350pt for 378 - and its width animated with
        // the pill. A UILabel draws once for its final size and scales
        // that drawing while its bounds animate, so the URL would
        // visibly stretch as it fades in. Pinned on the way out, from
        // the width the resting layout gave it; released on the way
        // back, where that layout gives it the same width again. 999,
        // not required, so a capsule narrower than the label can never
        // make the constraints unsatisfiable.
        guard height != nil else {
            labelMorphWidthConstraint?.isActive = false
            labelMorphWidthConstraint = nil
            return
        }
        let restingWidth = locationLabel.bounds.width
        guard labelMorphWidthConstraint == nil, restingWidth > 0 else {
            return
        }
        let pin = locationLabel.widthAnchor.constraint(equalToConstant: restingWidth)
        pin.priority = UILayoutPriority(999)
        pin.isActive = true
        labelMorphWidthConstraint = pin
    }
    
    func setLabelAlpha(_ alpha: CGFloat) {
        locationLabel.alpha = alpha
    }
    
    /// Shows `replica` - the address capsule's own text and icons - in
    /// front of the glass, centred at its own size, so the pill can BE
    /// that capsule for the first or last frames of the morph. The
    /// capsule clips it as it narrows.
    func installMorphReplica(_ replica: UIView, alpha: CGFloat) {
        removeMorphReplica()
        let size = replica.bounds.size
        replica.translatesAutoresizingMaskIntoConstraints = false
        replica.isUserInteractionEnabled = false
        replica.alpha = alpha
        contentView.addSubview(replica)
        NSLayoutConstraint.activate([
            replica.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            replica.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            replica.widthAnchor.constraint(equalToConstant: size.width),
            replica.heightAnchor.constraint(equalToConstant: size.height),
        ])
        morphReplica = replica
    }
    
    func setMorphReplicaAlpha(_ alpha: CGFloat) {
        morphReplica?.alpha = alpha
    }
    
    func removeMorphReplica() {
        morphReplica?.removeFromSuperview()
        morphReplica = nil
    }
    
    private func configureGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped))
        addGestureRecognizer(tap)
    }
    
    @objc private func pillTapped() {
        onTap?()
    }
}
