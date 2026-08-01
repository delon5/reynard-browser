//
//  CarPlaySceneDelegate.swift
//  Reynard
//
//  Added by fix_carplay_probe_scene.py.
//

import CarPlay
import GeckoView
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
        
        // CHANGED - the browser replaces the geometry probe. See
        // fix_carplay_browser_view.py.
        let browser = CarPlayBrowserViewController()
        window.rootViewController = browser
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
/// An independent browser on the car display.
///
/// Creates its OWN GeckoSession rather than going through
/// SessionManager and the tab manager. That is deliberate: CarPlay can
/// connect before the phone's window scene exists, and reaching through
/// BrowserViewController for a SessionManager would be nil in that
/// case. It also makes the car browser genuinely independent of the
/// phone, which was the option chosen over mirroring.
///
/// The cost is no delegates - no title reporting, history, downloads or
/// error pages. Loading and displaying a page needs none of them, and
/// wiring them up is step three, once rendering is confirmed.
@available(iOS 14.0, *)
private final class CarPlayBrowserViewController: UIViewController {
    private let geckoView = GeckoView(frame: .zero)
    private var session: GeckoSession?

    /// Where the car browser starts. Deliberately something simple and
    /// obviously rendered, so a blank screen means a rendering problem
    /// rather than a slow page.
    private static let homepage = "https://example.com"

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        geckoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(geckoView)

        // Against the safe area rather than bounds. The simulator
        // reports zero insets, but real head units do not always, and a
        // page drawn under CarPlay's own chrome would be partly
        // unreadable.
        NSLayoutConstraint.activate([
            geckoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            geckoView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            geckoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            geckoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])

        startSession()
    }

    private func startSession() {
        let session = GeckoSession()
        session.open()

        // Assigning the session is what embeds its window view.
        // GeckoView.layoutSubviews then calls updateViewportWidth, so
        // the page adapts to the car display without anything extra.
        geckoView.session = session
        self.session = session

        session.load(Self.homepage)

        logger(String(format: "CarPlay: browser session opened, loading %@", Self.homepage))
    }
}
