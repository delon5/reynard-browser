//
//  CarPlaySceneDelegate.swift
//  Reynard
//
//  Added by fix_carplay_probe_scene.py.
//

import AVFoundation
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
    /// The car browser's session, so the phone side can load URLs into
    /// it. See fix_send_to_carplay.py.
    ///
    /// Weak deliberately - the session is owned by the view controller,
    /// and a strong reference here would keep a Gecko session and its
    /// content process alive after the car is disconnected.
    /// Loads a URL onto the car display with the right settings.
    ///
    /// The phone side must go through this rather than calling
    /// session.load directly - a raw load skips the website mode
    /// settings and the request goes out with Gecko's native user
    /// agent, which reads as a desktop browser. See
    /// fix_carplay_session_settings.py.
    static func load(_ url: String) -> Bool {
        guard let session = currentSession else {
            return false
        }
        
        let settings = GeckoSessionSettings(
            websiteMode: WebsiteModeSettingManager().setting(for: url, tabID: nil),
            pageZoom: .default,
            language: .default
        )
        session.updateSettings(settings)
        session.load(url)
        
        logger(String(format: "CarPlay: loading %@ with %@", url, settings.websiteMode.userAgentOverride ?? "the native user agent"))
        return true
    }
    
    static weak var currentSession: GeckoSession?

    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    /// Keeps the car display's user activation from expiring.
    ///
    /// ADDED - see mse_fix_92's docstring. This delegate deliberately
    /// answers the autoplay permission with .prompt, because .allow and
    /// .deny are both persisted EXPIRE_NEVER into the same store Site
    /// Settings reads, and relies on markUserActivated instead. That is
    /// STICKY activation, granted at page start, first contentful paint
    /// and page stop - and media.autoplay.blocking_policy 1 stops
    /// honouring sticky, so each grant would expire five seconds later
    /// with no touch events on this display to renew it.
    ///
    /// Not a widening of what the car may do: it already holds
    /// activation for the life of every document it loads. This
    /// preserves that, and still writes nothing down.
    private var activationHeartbeat: Timer?
    
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
        logger("carPlayLife: scene CONNECTED")
        
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
        
        configureAudioSessionForCarPlay()
        
        // One-shot cleanup of the autoplay grants this delegate used
        // to write itself. See
        // fix_carplay_autoplay_grant_migration.py.
        Self.clearLegacyAutoplayGrantsIfNeeded()
        
        logCarPlayGeometry(scene: templateApplicationScene, window: window)
    }
    
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        logger("carPlayLife: scene DISCONNECTING - session discarded, audio released")
        self.interfaceController = nil
        // Stopped beside the session close below - see
        // activationHeartbeat.
        activationHeartbeat?.invalidate()
        activationHeartbeat = nil
        // Close the session BEFORE dropping the references to it.
        // currentSession is weak and GeckoSession has no deinit-side
        // close, so clearing references only ORPHANED the open engine
        // window: an active, unthrottled content process - it was
        // deliberately setActive(true)/setFocused(true) at connect,
        // and it never goes through SessionManager, so no
        // backgrounding sweep or tab sleep ever touches it - kept
        // running until the next app relaunch, once per disconnect.
        // See fix_close_carplay_session_on_disconnect.py.
        if let session = CarPlaySceneDelegate.currentSession {
            session.setFocused(false)
            session.setActive(false)
            session.close()
        }
        CarPlaySceneDelegate.currentSession = nil
        
        // Released with notifyOthersOnDeactivation, so whatever was
        // playing before - Spotify, a podcast - resumes by itself rather
        // than staying stopped. See fix_carplay_audio_route.py.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        self.carWindow = nil
        logger("CarPlay: disconnected")
    }
    
    /// UIScreen.main always reports the iPhone's display - confirmed by
    /// an Apple engineer on the developer forums. The car screen comes
    /// from the scene's own carWindow.
    /// Claims the output route so audio reaches the car.
    ///
    /// The app side otherwise leaves the session alone, but the
    /// ENGINE does not: cubeb claims .playback whenever it sets
    /// up a stream (cubeb_audiounit_ios.mm), and
    /// BackgroundAudioKeepAlive (defaults off) claims it too.
    /// Only before any page has touched audio does the session
    /// sit at the default .soloAmbient - a default that still
    /// produces sound from the phone speaker,
    /// which is why playback appeared to work, but it does not claim the
    /// route and so never reaches a connected car.
    ///
    /// Deliberately without .mixWithOthers: watching a video while music
    /// continues underneath is not the intent, so other audio is
    /// interrupted as a video app should. The keepalive mixes precisely
    /// because its job is to be inaudible; this is the opposite case.
    ///
    /// See fix_carplay_audio_route.py.
    private func configureAudioSessionForCarPlay() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            logger("carPlayLife: audio session ACTIVE (.playback/.moviePlayback)")
            logger("CarPlay: audio session claimed for playback")
        } catch {
            logger(String(format: "CarPlay: audio session failed - %@", error.localizedDescription))
        }
    }
    
    /// Clears the autoplay grants the OLD delegate wrote, once per
    /// profile. ADDED - see
    /// fix_carplay_autoplay_grant_migration.py's docstring.
    ///
    /// Until 45f2c0b this delegate answered .allow for autoplay, and
    /// GeckoViewPermission persists whatever it is told with
    /// addFromPrincipal(..., EXPIRE_NEVER) into the profile-wide store
    /// Site Settings reads. 45f2c0b stopped writing them and shipped
    /// nothing to remove the ones already written - and nothing else
    /// removes them either: every removeFromPrincipal path is
    /// user-driven, and restorePermissions skips a host whose
    /// Swift-side action resolves to the default, which for these
    /// hosts it always does since this delegate never wrote a row.
    ///
    /// Only grants with no row in the Swift store are removed. A row
    /// there is a deliberate Site Settings choice and is left alone.
    /// A Gecko entry without one is either this bug or a copy of the
    /// current profile default, and the copy is re-pushed on the next
    /// navigation to that site.
    private static func clearLegacyAutoplayGrantsIfNeeded() {
        let flagKey = Prefs.shared.key("CarPlaySettings", "didClearLegacyAutoplayGrants")
        guard !UserDefaults.standard.bool(forKey: flagKey) else {
            return
        }
        
        Task { @MainActor in
            // ADDED - see
            // fix_carplay_autoplay_migration_checks_store_ready.py's
            // docstring. chosenHosts below is built from the Swift
            // store, and storedHosts returns [] for an unreadable
            // database exactly as it does for an empty one. Without
            // this, a store that failed to open means nothing looks
            // chosen and EVERY autoplay grant is deleted, including
            // the ones the user set in Site Settings - and the flag
            // below would retire the migration before anyone could
            // notice.
            //
            // Not recorded, for the same reason as the guard below.
            guard SitePermissionStore.shared.isReady else {
                logger("CarPlay: site permission store unreadable - legacy autoplay grants left for the next connect")
                return
            }
            
            guard let permissions = try? await PermissionDelegate.allPermissions() else {
                // Deliberately NOT recorded. An enumeration that
                // failed, or ran before Gecko was ready to answer,
                // has cleared nothing - writing the flag here would
                // retire the migration without it ever running.
                logger("CarPlay: permission store unreadable - legacy autoplay grants left for the next connect")
                return
            }
            
            let actions: [SitePermissionAction] = [
                .allowed,
                .askToAllow,
                .blocked,
            ]
            var chosenHosts: Set<String> = []
            for action in actions {
                for entry in SitePermissionStore.shared.storedHosts(for: .autoplay, action: action) {
                    chosenHosts.insert(entry.host)
                }
            }
            
            var cleared = 0
            for permission in permissions {
                guard permission.permission == .autoplay,
                      permission.value == .allow,
                      !permission.privateMode,
                      let host = URLUtils.normalizedHost(fromRawURI: permission.uri),
                      !chosenHosts.contains(host) else {
                    continue
                }
                
                // By the enumerated permission's own principal
                // rather than by a rebuilt origin, so what is
                // removed is exactly what was found.
                PermissionDelegate.removePermission(permission)
                cleared += 1
            }
            
            UserDefaults.standard.set(true, forKey: flagKey)
            logger(String(format: "CarPlay: cleared %d legacy autoplay grant(s)", cleared))
        }
    }
    
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
private final class CarPlayBrowserViewController: UIViewController, ProgressDelegate, PermissionEmbedderDelegate, ContentDelegate {
    private let geckoView = GeckoView(frame: .zero)
    private let websiteModeSettingManager = WebsiteModeSettingManager()
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
    /// A full-bleed test page, base64-encoded - see
    /// fix_carplay_test_homepage_base64.py.
    ///
    /// The previous version carried raw HTML in a data: URL
    /// and rendered nothing: the # in a colour literal begins
    /// a fragment identifier, so Gecko received only the URL
    /// up to that point. base64 output has no characters with
    /// URL meaning, so nothing can truncate it.
    ///
    /// Four labelled corners and a viewport readout: if a
    /// corner is missing the surface is undersized, and the
    /// readout is worth comparing against the CarPlay:
    /// connected line since Gecko's layout still believes
    /// there is a single 3x screen.
    private static let homepage = "data:text/html;base64," + "PGh0bWw+PGhlYWQ+PG1ldGEgbmFtZT0ndmlld3BvcnQnIGNvbnRlbnQ9J3dpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEnPjwvaGVhZD48Ym9keSBzdHlsZT0nbWFyZ2luOjA7b3ZlcmZsb3c6aGlkZGVuJz48ZGl2IHN0eWxlPSdwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjYzAzOTJiLCMyOTgwYjkpO2ZvbnQ6NzAwIDE0cHggLWFwcGxlLXN5c3RlbSxzYW5zLXNlcmlmO2NvbG9yOiNmZmYnPjxkaXYgc3R5bGU9J3Bvc2l0aW9uOmFic29sdXRlO3RvcDo0cHg7bGVmdDo2cHgnPlRPUCBMRUZUPC9kaXY+PGRpdiBzdHlsZT0ncG9zaXRpb246YWJzb2x1dGU7dG9wOjRweDtyaWdodDo2cHgnPlRPUCBSSUdIVDwvZGl2PjxkaXYgc3R5bGU9J3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTo0cHg7bGVmdDo2cHgnPkJPVFRPTSBMRUZUPC9kaXY+PGRpdiBzdHlsZT0ncG9zaXRpb246YWJzb2x1dGU7Ym90dG9tOjRweDtyaWdodDo2cHgnPkJPVFRPTSBSSUdIVDwvZGl2PjxkaXYgaWQ9J2QnIHN0eWxlPSdwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MjJweCc+PC9kaXY+PC9kaXY+PHNjcmlwdD5mdW5jdGlvbiB1KCl7ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2QnKS50ZXh0Q29udGVudD1pbm5lcldpZHRoKycgeCAnK2lubmVySGVpZ2h0KycgIGRwciAnK2RldmljZVBpeGVsUmF0aW99dSgpO2FkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsdSk8L3NjcmlwdD48L2JvZHk+PC9odG1sPg=="

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

    /// The settings a tab would get for this URL.
    ///
    /// The CarPlay session is created directly rather than through
    /// SessionManager - deliberately, so it does not depend on the
    /// phone's scene existing - and that skipped settings entirely. It
    /// ran with no user agent override, meaning Gecko's own string,
    /// which on iOS reads as a desktop browser. See
    /// fix_carplay_session_settings.py.
    ///
    /// nil tabID falls back to the global and per-site preferences,
    /// which is right here: this is not a tab and has no per-tab desktop
    /// mode of its own.
    private func settings(for url: String) -> GeckoSessionSettings {
        return GeckoSessionSettings(
            websiteMode: websiteModeSettingManager.setting(for: url, tabID: nil),
            pageZoom: .default,
            language: .default
        )
    }
    
    /// Applied before every load, not once at creation - the setting is
    /// per URL, and a per-site override cannot match while the session
    /// is still on about:blank.
    private func load(_ url: String, in session: GeckoSession) {
        session.updateSettings(settings(for: url))
        session.load(url)
        logger(String(format: "CarPlay: loading %@ with %@", url, settings(for: url).websiteMode.userAgentOverride ?? "the native user agent"))
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
        
        // Without this the session is a background tab as far as Gecko
        // is concerned - timers throttled, media suspended after a
        // delay - which is why video stopped after 30-60 seconds. See
        // fix_carplay_session_active.py.
        //
        // SessionManager does this for every session it owns, and the
        // CarPlay session deliberately does not go through it, so it was
        // never activated at all.
        //
        // Both signals: active governs throttling and media suspension,
        // focused governs input and which document Gecko treats as
        // frontmost. The car display shows this session and nothing
        // else, so both are true.
        session.setActive(true)
        session.setFocused(true)
        // Marked active because Gecko otherwise throttles it as a
        // background tab - video stops while audio carries on. If this
        // is ever undone by something else, that is the symptom.
        logger("carPlayLife: session \(ObjectIdentifier(session)) marked active and focused")

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

        // Before the view, so the first page load is not missed.
        session.progressDelegate = self
        
        // Registers with the media session, so the car's transport
        // controls act on the car's video rather than whatever is
        // playing in a tab on the phone. SystemMediaSession already
        // tracks several sessions and gives the controls to whichever
        // played most recently. See fix_carplay_media_session.py.
        session.mediaSessionDelegate = SystemMediaSession.shared
        
        // Outranks the selected tab for the transport controls - the car
        // display cannot be touched, so if its video does not own them
        // there is no way to control it. See
        // fix_carplay_media_priority.py.
        SystemMediaSession.shared.prioritySession = session
        
        // Allows autoplay on this session only, so the profile-wide
        // media.autoplay.default pref can stay blocking. See
        // fix_carplay_autoplay_permission.py.
        session.permissionDelegate = self
        
        // So scripts can report into Reynard's own log by setting
        // document.title - console.log from a content process does not
        // reach the system log on iOS. See
        // fix_carplay_title_channel.py.
        session.contentDelegate = self
        geckoView.session = session
        CarPlaySceneDelegate.currentSession = session

        // See activationHeartbeat. Three seconds against Gecko's
        // five-second transient window, so a missed tick is not a gap.
        //
        // The closure captures no self - it reads the static
        // currentSession - so the timer cannot keep this delegate
        // alive, and disconnect invalidates it beside the session close
        // that is already there.
        activationHeartbeat?.invalidate()
        // .common rather than the default mode Timer.scheduledTimer
        // installs - ADDED while applying fix 92. A default-mode timer
        // is suspended while a UIKit tracking loop runs, so scrolling
        // the phone for more than five seconds would starve the
        // heartbeat at exactly the moment a car video wants to start.
        activationHeartbeat = Timer(
            timeInterval: 3.0, repeats: true
        ) { _ in
            guard let live = CarPlaySceneDelegate.currentSession else {
                return
            }
            Task { @MainActor in
                _ = await live.markUserActivated()
            }
        }
        if let activationHeartbeat {
            RunLoop.main.add(activationHeartbeat, forMode: .common)
        }
        logger("CarPlay: activation heartbeat armed every 3s - "
               + "blocking_policy 1 expires a grant after 5")

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

        load(Self.homepage, in: session)
        logger(String(format: "CarPlay: browser session opened, loading %@", Self.homepage))
    }
    
    // MARK: - ContentDelegate

    /// Reports titles beginning with the script marker, and ignores
    /// everything else. See fix_carplay_title_channel.py.
    ///
    /// This exists because a script on this session has no other way to
    /// say anything: console.log from a Gecko content process does not
    /// reach the system log on iOS, and the car display shows only the
    /// page.
    ///
    /// Ordinary page titles are skipped rather than logged, so this
    /// does not bury everything else under YouTube video names.
    func onTitleChange(session: GeckoSession, title: String) {
        guard title.hasPrefix("RY:") else {
            return
        }
        
        logger("CarPlay script: " + String(title.dropFirst(3)))
    }

    /// Grants user activation again, once the document that will be
    /// playing actually exists.
    ///
    /// ADDED - see fix_carplay_activation_on_page_stop.py's docstring.
    /// The grant in onPageStart cannot be trusted to reach the document
    /// it names: GeckoView:PageStart is emitted at STATE_START, before
    /// the load commits, and the query resolves the actor at receipt
    /// time - so for a network load it activates the OUTGOING document
    /// and the incoming one boots with nothing.
    ///
    /// A contentful paint cannot happen before the document that paints
    /// it, so this one lands on the right document, and it lands far
    /// earlier than onPageStop - which is the end of the load, well
    /// after a player that calls play() during boot has been refused.
    ///
    /// onPageStop still grants as well, and must: a load that paints
    /// nothing contentful never gets here.
    func onFirstContentfulPaint(session: GeckoSession) {
        Task { @MainActor in
            let activated = await session.markUserActivated()
            logger(String(format: "CarPlay: user activation %@ at first contentful paint",
                          activated ? "granted" : "FAILED"))
        }
    }

    // MARK: - PermissionEmbedderDelegate

    /// Allows autoplay, and only autoplay. See
    /// fix_carplay_autoplay_permission.py.
    ///
    /// The car display is the one place autoplay is genuinely needed,
    /// because it is the one place that cannot be tapped - so a video
    /// that waits for a gesture waits forever.
    ///
    /// Everything else returns .prompt, the protocol's own default,
    /// which on this display means it will not happen: a prompt cannot
    /// be answered on a screen that receives no touch events. That is
    /// the right outcome for camera, microphone, geolocation and
    /// notifications in a car.
    ///
    /// media-key-system-access is deliberately not allowed either.
    /// Granting the EME permission would not make DRM work - Gecko's
    /// iOS build has no decryption module - so it would only move the
    /// failure later.
    func permissionDelegate(
        decideContentPermission permission: ContentPermission,
        session: GeckoSession
    ) async -> ContentPermission.Value {
        guard permission.permission == .autoplay else {
            // DENIED, not prompted - see fix_carplay_deny_prompts.py.
            //
            // A prompt on this display can never be answered: the window
            // shows only the page, and the base view receives no touch
            // events. So .prompt does not mean "ask", it means "wait
            // forever", and whatever the page was doing behind the
            // request stops with it.
            //
            // That is what stalled playback: fetching stopped while a
            // request waited, the video ran on for as long as it was
            // buffered, and then died - which looked like a 40-50 second
            // timer but was really the buffer depth.
            //
            // Denying is also right on its own merits here. Camera,
            // microphone, geolocation and notifications should not be
            // granted to a screen the driver cannot supervise.
            logger(String(format: "CarPlay: denying %@ - a prompt cannot be answered on the car display", String(describing: permission.permission)))
            return .deny
        }
        
        // Autoplay is NOT granted here any more, and that is the point.
        //
        // GeckoViewPermission persists whatever this returns with
        // addFromPrincipal(..., EXPIRE_NEVER), into the same store Site
        // Settings reads. So every site ever played on the car display
        // was quietly acquiring a permanent autoplay grant for normal
        // browsing too - and, in the other direction, a site the user
        // blocked in Site Settings could not be played in the car.
        //
        // markUserActivated does the job instead: sticky activation is
        // ORed in ahead of the site permission, so the car display plays
        // regardless, and nothing is written down. See onPageStart.
        // .prompt, which is PROMPT_ACTION - the neutral value. .allow
        // and .deny are BOTH persisted, so either one would decide
        // autoplay for this site in normal browsing as well. With
        // activation granted the request should not be raised at all;
        // if it ever is, this leaves the user's own Site Settings choice
        // as the only thing that decides.
        logger("CarPlay: leaving autoplay to activation, not a stored permission")
        return .prompt
    }

    /// Camera and microphone, denied outright. Nothing on the car
    /// display should be reaching for either, and a prompt could not be
    /// answered there in any case.
    func permissionDelegate(
        decideMediaPermission request: MediaPermissionRequest,
        session: GeckoSession
    ) async -> Bool {
        return false
    }

    // MARK: - ProgressDelegate
    
    /// The car display receives no touch events - Apple's guide says so
    /// and a tap probe on device confirmed it - so no document here ever
    /// gets a real gesture. Activation is granted on its behalf, at page
    /// start so a player feature-detecting during boot already sees it.
    ///
    /// CHANGED - nothing depends on this one landing on the document it
    /// names any more. See fix_carplay_activation_on_page_stop.py's
    /// docstring: page start is emitted before the load commits, so for
    /// anything slower to commit than the data: homepage this activates
    /// the document being replaced. It stays because it is cheap and it
    /// is right whenever the load commits before the query arrives, but
    /// the grant that is guaranteed to reach the new document is the one
    /// in onFirstContentfulPaint.
    func onPageStart(session: GeckoSession, url: String) {
        Task { @MainActor in
            let activated = await session.markUserActivated()
            logger(String(format: "CarPlay: user activation %@ for %@",
                          activated ? "granted" : "FAILED", url))
        }
    }
    
    func onProgressChange(session: GeckoSession, progress: Int) {}
    
    func onSessionStateChange(session: GeckoSession, state: GeckoSessionState) {}
    
    /// Runs the enabled scripts once the page has loaded.
    ///
    /// Once per load rather than on a timer: the scripts install
    /// their own MutationObserver, which handles sites rebuilding
    /// their DOM far better than Swift-side polling could. See
    /// fix_carplay_scripts_ui.py.
    func onPageStop(session: GeckoSession, success: Bool) {
        // Before the scripts guard: activation is not a scripting
        // feature, and a car display with the scripts toggle off still
        // must not be left unable to play. Again here because a
        // same-document navigation swaps out the document that was
        // activated at page start.
        if success {
            Task { @MainActor in
                await session.markUserActivated()
            }
        }

        guard success, Prefs.ExperimentalSettings.isCarPlayScriptsEnabled else {
            return
        }
        
        let scripts = Prefs.ExperimentalSettings.carPlayScripts.filter { $0.isEnabled }
        guard !scripts.isEmpty else {
            return
        }
        
        Task { @MainActor in
            for script in scripts {
                let failure = await session.runUserScript(script.body)
                if let failure {
                    logger(String(format: "CarPlay: script %@ failed - %@", script.name, failure))
                } else {
                    logger(String(format: "CarPlay: script %@ ran", script.name))
                }
            }
        }

        installTouchProbe()

    }
}
