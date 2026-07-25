//
//  CondensedAddressPill.swift
//  Reynard
//

import UIKit

/// The small floating capsule shown in place of the full toolbars while
/// scrolled down, matching Safari's condensed address pill. Uses a
/// plain background matching the toolbars' own .systemGray6 styling.
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
        view.backgroundColor = .toolbarBackground
        return view
    }()
    
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
        contentView.addSubview(locationLabel)
    }
    
    private func configureConstraints() {
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: CondensedAddressPill.height),
            
            locationLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: UX.horizontalPadding),
            locationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -UX.horizontalPadding),
            locationLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    
    private func configureGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(pillTapped))
        addGestureRecognizer(tap)
    }
    
    @objc private func pillTapped() {
        onTap?()
    }
}
