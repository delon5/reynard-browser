//
//  ToolbarGlassBackgroundView.swift
//  Reynard
//

import UIKit

/// A full-bleed background that renders real Liquid Glass (`UIGlassEffect`)
/// on iOS 26+, falls back to a system blur material on earlier versions,
/// and falls back further to an opaque fill whenever
/// `UIAccessibility.isReduceTransparencyEnabled` is on — glass and Reduce
/// Transparency are mutually exclusive in Apple's own apps, and rendering
/// a translucent toolbar over arbitrary web content when the user has
/// explicitly asked for reduced transparency would hurt legibility.
///
/// Usage: create one and call `install(in:)` on the toolbar's own view to
/// pin it as the back-most, edge-to-edge background layer. Toolbar
/// buttons/content should be added as normal sibling subviews on top of it.
final class ToolbarGlassBackgroundView: UIView {
    private var effectView: UIVisualEffectView?
    /// Clear-style glass is maximally transparent - the backdrop pops
    /// through - where regular glass is adaptive and frosted. Used by
    /// the address bar capsule, whose backdrop is the toolbar's own
    /// regular glass: stacking two frosted layers reads as a solid
    /// fill, one clear layer over one frosted layer reads as glass.
    private var prefersClearGlass = false
    private var reduceTransparencyObserver: NSObjectProtocol?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        configureEffect()
        
        reduceTransparencyObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureEffect()
        }
    }
    
    convenience init(prefersClearGlass: Bool) {
        self.init(frame: .zero)
        self.prefersClearGlass = prefersClearGlass
        configureEffect()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let reduceTransparencyObserver {
            NotificationCenter.default.removeObserver(reduceTransparencyObserver)
        }
    }
    
    /// Pins this view as the back-most, edge-to-edge background of `host`.
    /// Safe to call repeatedly; a no-op if already installed.
    func install(in host: UIView) {
        guard superview !== host else {
            return
        }
        removeFromSuperview()
        host.insertSubview(self, at: 0)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
    
    // No re-adapt hooks: with clear-style glass there is nothing to
    // adaptively latch, and rebuilding the effect view at runtime was
    // itself the last flicker source. The effect is built once and
    // never touched during browsing. See fix_no_frost_no_flicker.py.
    private func configureEffect() {
        effectView?.removeFromSuperview()
        effectView = nil
        
        guard !UIAccessibility.isReduceTransparencyEnabled else {
            backgroundColor = .systemGray6
            NSLog("[ToolbarGlass] Reduce Transparency is ON — using opaque .systemGray6 fallback")
            return
        }
        
        backgroundColor = .clear
        
        let newEffectView: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = prefersClearGlass ? UIGlassEffect(style: .clear) : UIGlassEffect()
            newEffectView = UIVisualEffectView(effect: glass)
            NSLog("[ToolbarGlass] iOS 26 available — using real UIGlassEffect (%@)",
                  prefersClearGlass ? "clear" : "regular")
        } else {
            newEffectView = UIVisualEffectView(
                effect: UIBlurEffect(style: prefersClearGlass ? .systemUltraThinMaterial : .systemMaterial)
            )
            NSLog("[ToolbarGlass] iOS 26 NOT available — using UIBlurEffect fallback (%@)",
                  prefersClearGlass ? "ultraThin" : "systemMaterial")
        }
        
        newEffectView.translatesAutoresizingMaskIntoConstraints = false
        newEffectView.isUserInteractionEnabled = false
        addSubview(newEffectView)
        NSLayoutConstraint.activate([
            newEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            newEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            newEffectView.topAnchor.constraint(equalTo: topAnchor),
            newEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        effectView = newEffectView
    }
}
