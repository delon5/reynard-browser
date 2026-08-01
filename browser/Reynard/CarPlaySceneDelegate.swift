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
        browser.interfaceController = interfaceController
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
    weak var interfaceController: CPInterfaceController?

    /// Where the car browser starts. Deliberately something simple and
    /// obviously rendered, so a blank screen means a rendering problem
    /// rather than a slow page.
    /// A full-bleed test page - see
    /// fix_carplay_test_homepage.py.
    ///
    /// example.com is a small centred block, which cannot
    /// distinguish a correctly sized surface from an
    /// undersized one on a mostly-empty screen. This should
    /// reach every edge: if a corner label is missing, the
    /// surface is undersized.
    ///
    /// The centre readout shows what the PAGE believes the
    /// viewport to be, which is worth comparing against the
    /// CarPlay: connected line - ScreenHelperUIKit still
    /// reports a single 3x screen to Gecko's layout, so they
    /// may disagree even once rendering is correct.
    ///
    /// A data: URL so there is no network dependency: a
    /// failed load would look identical to a rendering fault.
    private static let homepage = "data:text/html," + """
<html id='carplay-scale-test'><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0;overflow:hidden'><div style='position:fixed;inset:0;background:linear-gradient(135deg,#c0392b,#2980b9);font:700 14px -apple-system,sans-serif;color:#fff'><div style='position:absolute;top:4px;left:6px'>TOP LEFT</div><div style='position:absolute;top:4px;right:6px'>TOP RIGHT</div><div style='position:absolute;bottom:4px;left:6px'>BOTTOM LEFT</div><div style='position:absolute;bottom:4px;right:6px'>BOTTOM RIGHT</div><div id='d' style='position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:22px'></div></div><script>function u(){document.getElementById('d').textContent=innerWidth+' x '+innerHeight+'  dpr '+devicePixelRatio}u();addEventListener('resize',u)</script></body></html>
"""

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

    }

    // Whether the base view receives touches at all is an
    // open question. Apple's guide says it does not, but
    // that is written as design guidance, and CarPlay
    // clearly delivers touches to the TEMPLATE layer -
    // CPMapTemplate has pan mode and, since iOS 26, pinch,
    // pitch and rotate. This settles it rather than
    // assuming. See fix_carplay_scale_v3.py.
    private func installTouchProbe() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleProbeTap(_:)))
        view.addGestureRecognizer(tap)
    }

    @objc private func handleProbeTap(_ sender: UITapGestureRecognizer) {
        let point = sender.location(in: view)
        logger(String(format: "CarPlay: tap received at %.0f,%.0f", point.x, point.y))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Gecko sizes its surface from the engine view's bounds
        // when the window is created, and in viewDidLoad those
        // are zero - which painted the page into the top-left
        // corner with unpainted background around it. This is
        // the first pass with real bounds.
        //
        // The phone browser gets this ordering by accident:
        // ContentView.setSession runs after the hierarchy has
        // laid out, so it never had to be explicit.
        guard session == nil, view.bounds.width > 0, view.bounds.height > 0 else {
            return
        }

        startSession()
    }

    private func startSession() {
        let session = GeckoSession()

        // The car display's scale must be supplied BEFORE the window is
        // created - see fix_carplay_backing_scale_override.py. The
        // compositor is sized inside ww->OpenWindow, before SetIOSView
        // runs, so nsWindow::BackingScaleFactor falls back to
        // [UIScreen mainScreen].scale, which always reports the
        // iPhone's display.
        //
        // Cleared immediately afterwards so nothing else is affected.
        let carScale = interfaceController?.carTraitCollection.displayScale ?? 0
        if carScale > 0 {
            GeckoViewSetBackingScaleOverride(carScale)
        }

        session.open()

        if carScale > 0 {
            GeckoViewSetBackingScaleOverride(0)
        }

        // Assigning the session is what embeds its window view.
        // GeckoView.layoutSubviews then calls updateViewportWidth, so
        // the page adapts to the car display without anything extra.
        // The car display's scale, from carTraitCollection -
        // which is what Apple's CarPlay Developer Guide
        // specifies for exactly this. Set BEFORE the session is
        // assigned, so it is in place when Gecko creates its
        // surface. See fix_carplay_scale_v2.py.
        //
        // The guide warns to "be sure to get the scale for the
        // car's screen (not the scale for the iPhone screen)" -
        // UIScreen.main always reports the iPhone's, which is 3.0
        // here against CarPlay's 2.0.
        if let carScale = interfaceController?.carTraitCollection.displayScale, carScale > 0 {
            geckoView.contentScaleFactor = carScale
            geckoView.layer.contentsScale = carScale
        }

        logger(String(format: "CarPlay: scales - carTraitCollection %.1f, window screen %.1f, UIScreen.main %.1f", interfaceController?.carTraitCollection.displayScale ?? 0, view.window?.screen.scale ?? 0, UIScreen.main.scale))

        geckoView.session = session

        // The scale has to go on the ENGINE VIEW, not the
        // GeckoView wrapper. See
        // fix_carplay_engine_view_scale.py.
        //
        // nsWindow::BackingScaleFactor prefers
        // [mNativeView contentScaleFactor] and only falls back to
        // UIScreen.mainScreen when mNativeView is nil - which is
        // the window-creation moment. mNativeView is the engine
        // view embedSessionView adds as a subview here, not the
        // wrapper the earlier fix was setting.
        if let carScale = interfaceController?.carTraitCollection.displayScale, carScale > 0 {
            for engineView in geckoView.subviews {
                engineView.contentScaleFactor = carScale
                engineView.layer.contentsScale = carScale
            }
        
            // Nudge Gecko to re-read its settings, in the hope
            // that BackingScaleFactor is consulted again rather
            // than cached at open().
            session.updateViewportWidth(geckoView.bounds.width)
        }

        logger(String(format: "CarPlay: engine views %d, scale now %.1f", geckoView.subviews.count, geckoView.subviews.first?.contentScaleFactor ?? 0))

        self.session = session

        session.load(Self.homepage)

        installTouchProbe()

        logger(String(format: "CarPlay: browser session opened, loading %@", Self.homepage))
    }
}
