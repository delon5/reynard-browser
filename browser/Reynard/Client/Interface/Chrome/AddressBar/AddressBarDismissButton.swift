//
//  AddressBarDismissButton.swift
//  Reynard
//
//  Created by Minh Ton on 10/6/26.
//

import UIKit

final class AddressBarDismissButton: UIButton {
    private enum UX {
        static let dismissButtonCornerRadiusDivisor: CGFloat = 2
        static let dismissButtonShadowOpacity: Float = 0.2
        static let dismissButtonDarkModeShadowAlpha: CGFloat = 0.3
        static let dismissButtonShadowRadius: CGFloat = 12
        static let dismissButtonShadowOffset = CGSize(width: 0, height: 4)
        static let dismissButtonSymbolPointSize: CGFloat = 20
    }
    
    /// The pill's structure in miniature: the button's own layer keeps
    /// masksToBounds=false for its shadow, so a dedicated clipped
    /// container hosts the glass and tracks the corner radius.
    private let glassContainer = UIView()
    // Clear-style glass, matching the URL capsule - nothing in the
    // address bar cluster reads frosted. The floating pill keeps its
    // own regular glass.
    private let glassBackground = ToolbarGlassBackgroundView(prefersClearGlass: true)
    
    // MARK: - Lifecycle
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureAppearance()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAppearance()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowOpacity = UX.dismissButtonShadowOpacity
        layer.cornerRadius = bounds.height / UX.dismissButtonCornerRadiusDivisor
        glassContainer.layer.cornerRadius = layer.cornerRadius
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
    
    // MARK: - Appearance
    
    private func configureAppearance() {
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0
        isHidden = true
        // Liquid Glass, matching the condensed pill and the address bar
        // capsule; ToolbarGlassBackgroundView carries the Reduce
        // Transparency and pre-iOS-26 fallbacks.
        backgroundColor = .clear
        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        glassContainer.clipsToBounds = true
        glassContainer.layer.cornerCurve = .continuous
        glassContainer.isUserInteractionEnabled = false
        insertSubview(glassContainer, at: 0)
        NSLayoutConstraint.activate([
            glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassContainer.topAnchor.constraint(equalTo: topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glassBackground.install(in: glassContainer)
        tintColor = .label
        layer.cornerCurve = .continuous
        layer.shadowColor = UITraitCollection.current.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(UX.dismissButtonDarkModeShadowAlpha).cgColor
        : UIColor.black.cgColor
        layer.shadowRadius = UX.dismissButtonShadowRadius
        layer.shadowOffset = UX.dismissButtonShadowOffset
        layer.masksToBounds = false
        setImage(UIImage(named: "reynard.xmark"), for: .normal)
        setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: UX.dismissButtonSymbolPointSize, weight: .regular),
            forImageIn: .normal
        )
    }
}
