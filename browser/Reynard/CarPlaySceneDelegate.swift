//
//  CarPlaySceneDelegate.swift
//  Reynard
//
//  Added by fix_carplay_probe_scene.py.
//

import CarPlay
import UIKit

/// Step one of CarPlay support: proves the car window connects and
/// reports its actual geometry.
///
/// Nothing browser-related is shown yet. The open question is whether
/// GeckoView can render into a second UIWindow on a different UIScreen
/// - Gecko on mobile assumes one window per process - and there is no
/// point building either the native or the screen-mirroring version
/// until that is known.
@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    
    /// The THREE-argument form. The two-argument version exists for
    /// template-only apps and never yields a window - implementing only
    /// that one is a common way to get a working connection and a blank
    /// screen.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.carWindow = window
        
        // A navigation app MUST set a CPMapTemplate as its root, and
        // Apple's guidance is explicit that it must contain no
        // additional graphics or UI elements. Real content goes in the
        // CPWindow underneath. An empty one is correct here, not an
        // omission.
        let mapTemplate = CPMapTemplate()
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)
        
        let probe = CarPlayProbeViewController()
        probe.templateApplicationScene = templateApplicationScene
        window.rootViewController = probe
        window.makeKeyAndVisible()
        
        logCarPlayGeometry(scene: templateApplicationScene, window: window)
    }
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        self.interfaceController = nil
        self.carWindow = nil
        logger("CarPlay: disconnected")
    }
    
    /// UIScreen.main always reports the iPhone's display - confirmed by
    /// an Apple engineer on the developer forums. The car screen comes
    /// from the scene's own carWindow.
    private func logCarPlayGeometry(scene: CPTemplateApplicationScene, window: CPWindow) {
        let screen = scene.carWindow.screen
        let insets = window.safeAreaInsets
        
        logger(String(format: "CarPlay: connected - screen %.0fx%.0f @%.1fx, window %.0fx%.0f, safeArea t%.0f l%.0f b%.0f r%.0f",
                      screen.bounds.width, screen.bounds.height, screen.scale,
                      window.bounds.width, window.bounds.height,
                      insets.top, insets.left, insets.bottom, insets.right))
    }
}

/// Shows the car display's geometry on the car screen itself, so it can
/// be read without a log capture.
@available(iOS 14.0, *)
private final class CarPlayProbeViewController: UIViewController {
    weak var templateApplicationScene: CPTemplateApplicationScene?
    
    private let label = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        // Against the safe area rather than bounds: CarPlay chrome
        // differs by head unit and the insets are how that is
        // communicated.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshText()
    }
    
    private func refreshText() {
        let insets = view.safeAreaInsets
        var lines = ["Reynard CarPlay probe", ""]
        
        if let screen = templateApplicationScene?.carWindow.screen {
            lines.append(String(format: "screen  %.0f x %.0f @%.1fx",
                                screen.bounds.width, screen.bounds.height, screen.scale))
        }
        
        lines.append(String(format: "view    %.0f x %.0f", view.bounds.width, view.bounds.height))
        lines.append(String(format: "insets  t%.0f l%.0f b%.0f r%.0f",
                            insets.top, insets.left, insets.bottom, insets.right))
        lines.append(String(format: "idiom   %d", traitCollection.userInterfaceIdiom.rawValue))
        
        label.text = lines.joined(separator: "\n")
    }
}
