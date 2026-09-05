//
//  AirPlayController.swift
//  Reynard
//
//  The app-process half of AirPlay: route detection, the picker, and
//  the facts about the current route that the chrome and the engine
//  need.
//
//  WebKit keeps one MediaSessionHelper per process for this - a single
//  AVRouteDetector whose isRouteDetectionEnabled is on only while some
//  page holds an availability listener, one AVAudioSession route
//  observer, and the picker presented from the UI process
//  (MediaSessionHelperIOS.mm, WKAirPlayRoutePicker.mm). This class is
//  that helper. It is also the only reader of Prefs.AirPlaySettings:
//  AVPlayerHost lives in the GeckoView framework, which cannot see the
//  app's preference store, so every policy is pushed into it from here
//  (applyPolicy) rather than read there.
//

import AVFoundation
import AVKit
import Foundation
import GeckoView
import UIKit

@MainActor
final class AirPlayController: NSObject {
    static let shared = AirPlayController()
    
    /// What the picker resolved to. The strings are the shim's contract:
    /// remote.prompt() maps them to resolve / NotAllowedError /
    /// NotSupportedError.
    enum PickerResult: String {
        case selected
        case dismissed
        case unavailable
    }
    
    struct State: Equatable {
        /// The AirPlay output's port name, nil while the route is local.
        var routeName: String?
        var routeIsAirPlay: Bool
        /// Some AVPlayer reports isExternalPlaybackActive - its video is
        /// on the receiver, not on the phone.
        var videoActive: Bool
    }
    
    private(set) var state = State(routeName: nil, routeIsAirPlay: false, videoActive: false)
    static let stateDidChange = Notification.Name("Reynard.AirPlayStateDidChange")
    
    /// Set by BrowserViewController. A page may only open the picker
    /// from the selected tab: a background tab putting a system sheet
    /// over whatever the user is looking at is the abuse WebKit's
    /// gesture requirement exists to stop, and the gesture check alone
    /// does not know which tab is in front.
    weak var tabManager: TabManager?
    
    private enum UX {
        /// How long the synthetic tap gets to bring up the system sheet
        /// before the fallback sheet goes up instead.
        static let syntheticTapTimeout: TimeInterval = 0.7
        /// The route change for a picked device lands after
        /// routePickerViewDidEndPresentingRoutes, not before it.
        static let routeChangeGrace: TimeInterval = 1.5
        /// Not zero: a fully transparent view does not present.
        static let hiddenPickerAlpha: CGFloat = 0.02
    }
    
    /// Why detection is on. WebKit counts these
    /// (MediaSessionHelper::m_monitoringWirelessRoutesCount) and only
    /// the 0 -> 1 and 1 -> 0 edges touch the detector; a set of named
    /// reasons is the same count with the callers visible in a capture.
    private enum DetectionReason: Hashable {
        case pickerVisible
        case webListeners(ObjectIdentifier)
    }
    
    private struct Published: Equatable {
        var available: Bool
        var name: String
    }
    
    private var reasons: Set<DetectionReason> = []
    /// Created on the first request and then kept; only
    /// isRouteDetectionEnabled toggles, as WebKit does
    /// (MediaSessionHelperIOS.mm:499-510). Dropped only when media
    /// services reset, which invalidates it.
    private var detector: AVRouteDetector?
    private var detectorObserver: NSObjectProtocol?
    private var isForeground = true
    private var lastPublished: Published?
    private var observers: [NSObjectProtocol] = []
    
    // MARK: Picker state
    
    private var hiddenPicker: AVRoutePickerView?
    /// Resumed exactly once, by finishPicker, which takes it out before
    /// anything else runs so no later callback can find it.
    private var pendingPicker: CheckedContinuation<PickerResult, Never>?
    private var routesPresenting = false
    private var sawRouteChange = false
    private var fallbackTimer: Timer?
    private var graceTimer: Timer?
    private weak var sheet: AirPlayRouteSheetViewController?
    
    private override init() {
        super.init()
        isForeground = UIApplication.shared.applicationState != .background
        installObservers()
        // Seeded silently, never posted. The first touch of `shared` is
        // AirPlayStatusPill's initializer, and a block observer queued
        // on .main is delivered synchronously when the post happens on
        // the main thread - so a stateDidChange from here re-enters
        // `shared` inside its own once-initializer and traps whenever
        // the app launches with an AirPlay output already in the route.
        // applyPolicy's forced refresh posts once `shared` exists.
        state = snapshotState()
    }
    
    // MARK: - Policy
    
    /// Called by AirPlayPolicyController.apply() at startup and on every
    /// toggle. Everything here is live; nothing needs a restart.
    func applyPolicy() {
        AVPlayerHost.shared.setExternalPlaybackAllowed(Prefs.AirPlaySettings.allowsVideo)
        AVPlayerHost.shared.setDetachesVideoOutputWhileExternal(Prefs.AirPlaySettings.detachesVideoOutputWhileExternal)
        // Turning the fullscreen policy OFF takes effect at once. Turning
        // it on waits for the next fullscreen transition, because only
        // BrowserViewController.applyFullscreenState knows whether a tab
        // is fullscreen right now, and it is the one that pushes true.
        if !Prefs.AirPlaySettings.usesExternalPlaybackInFullscreen {
            AVPlayerHost.shared.setFullscreenExternalPlaybackPolicy(false)
        }
        applyDetection()
        // Forced: the pill and the menu read isEnabled through the
        // state notification, and the route itself may not have moved.
        refreshState(force: true)
    }
    
    // MARK: - Detection
    
    private func applyDetection() {
        let wanted = Prefs.AirPlaySettings.isEnabled && isForeground && !reasons.isEmpty
        if wanted, detector == nil {
            let detector = AVRouteDetector()
            self.detector = detector
            detectorObserver = NotificationCenter.default.addObserver(
                forName: .AVRouteDetectorMultipleRoutesDetectedDidChange,
                object: detector,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishAvailability() }
            }
        }
        if let detector, detector.isRouteDetectionEnabled != wanted {
            detector.isRouteDetectionEnabled = wanted
            logger("airPlay: route detection \(wanted ? "on" : "off") (\(reasons.count) reasons, foreground=\(isForeground))")
        }
        publishAvailability()
    }
    
    /// Hands availability and the route name to every content process
    /// through the default pref branch - the same bus the actor's
    /// pref observer already listens on - and only when they changed,
    /// since each push is an nsPref:changed in every process.
    private func publishAvailability() {
        // multipleRoutesDetected reads false whenever detection is off,
        // so the last reading is kept across a stop rather than snapping
        // every page's availability to false the moment the last
        // listener goes away or the app backgrounds. WebKit ignores the
        // notification while not monitoring for the same reason
        // (wirelessRoutesAvailableDidChange:, MediaSessionHelperIOS.mm:550-561).
        let available: Bool
        if let detector, detector.isRouteDetectionEnabled {
            available = detector.multipleRoutesDetected
        } else {
            available = lastPublished?.available ?? false
        }
        let next = Published(available: available, name: currentAirPlayOutput()?.portName ?? "")
        guard next != lastPublished else {
            return
        }
        lastPublished = next
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.airplay.available": next.available,
            "media.reynard.airplay.route-name": next.name,
        ])
        logger("airPlay: available=\(next.available) route=\(next.name.isEmpty ? "-" : next.name)")
    }
    
    private func currentAirPlayOutput() -> AVAudioSessionPortDescription? {
        return AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }
    }
    
    private func snapshotState() -> State {
        let output = currentAirPlayOutput()
        return State(
            routeName: output?.portName,
            routeIsAirPlay: output != nil,
            videoActive: AVPlayerHost.shared.isAnyExternalPlaybackActive
        )
    }
    
    /// The only poster of stateDidChange; init seeds without posting.
    private func refreshState(force: Bool = false) {
        let next = snapshotState()
        guard force || next != state else {
            return
        }
        if next != state {
            logger("airPlay: route=\(next.routeName ?? "-") airPlay=\(next.routeIsAirPlay) video=\(next.videoActive)")
        }
        state = next
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }
    
    // MARK: - Observers
    
    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(
            forName: AVPlayerHost.externalPlaybackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidEnterBackground() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillEnterForeground() }
        })
    }
    
    private func handleRouteChange(_ note: Notification) {
        let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        let previousWasAirPlay = previous?.outputs.contains { $0.portType == .airPlay } ?? false
        
        if pendingPicker != nil {
            // Any route change counts, including back to "iPhone":
            // Safari resolves the prompt on the change, not on the
            // destination.
            sawRouteChange = true
            if graceTimer != nil {
                finishPicker(.selected)
            }
        }
        
        // The receiver went away (powered off, out of range): pause what
        // Gecko decodes so the phone's speaker does not take over
        // mid-title. WebKit's OldDeviceUnavailable rule
        // (MediaSessionManagerIOS.mm:176-187), scoped to an AirPlay loss so
        // unplugging headphones and a CarPlay disconnect keep today's
        // behaviour. AVPlayers are paused by the host's own observer.
        if reason == .oldDeviceUnavailable, previousWasAirPlay {
            logger("airPlay: route lost - pausing playing sessions")
            SystemMediaSession.shared.pausePlayingSessions()
        }
        
        refreshState()
        publishAvailability()
    }
    
    /// The detector belongs to the media server that just died; it is
    /// recreated lazily by the next applyDetection. Availability is
    /// republished from nothing, since whatever it knew is stale.
    private func handleMediaServicesReset() {
        if let detectorObserver {
            NotificationCenter.default.removeObserver(detectorObserver)
        }
        detectorObserver = nil
        detector = nil
        lastPublished = nil
        logger("airPlay: media services were reset - detector dropped")
        applyDetection()
        refreshState()
    }
    
    /// Detection stops in the background (the reasons are kept for the
    /// return); a picker still waiting is answered with what is known,
    /// because its callbacks may not arrive until the app is back and
    /// the page's promise should not hang until then.
    private func applicationDidEnterBackground() {
        isForeground = false
        if pendingPicker != nil {
            logger("airPlay: picker abandoned - app backgrounded")
            finishPicker(sawRouteChange ? .selected : .dismissed)
        }
        applyDetection()
    }
    
    private func applicationWillEnterForeground() {
        isForeground = true
        applyDetection()
        refreshState()
    }
    
    // MARK: - Picker
    
    /// Whether the shared audio session's category has no AirPlay route
    /// to offer - when the picker is refused and the page menu's row is
    /// left out. .record cannot route to AirPlay at all, and
    /// .playAndRecord offers it only with .allowAirPlay set. cubeb's
    /// recording AND enumeration configurations both set it
    /// (cubeb_audiounit_ios.mm), so a WebRTC page is a legal AirPlay
    /// page - Safari offers the picker there - and a page that merely
    /// called enumerateDevices(), which leaves PlayAndRecord behind
    /// until the next output stream, must not lock every tab out of
    /// AirPlay. Only .record, or a PlayAndRecord written by someone
    /// else without .allowAirPlay, has nothing to list.
    nonisolated static func audioSessionBlocksAirPlay() -> Bool {
        let session = AVAudioSession.sharedInstance()
        return session.category == .record
            || (session.category == .playAndRecord
                && !session.categoryOptions.contains(.allowAirPlay))
    }
    
    /// Presents the system route picker and reports whether a route was
    /// picked. Never throws and never leaves the caller waiting: every
    /// path ends in finishPicker. `anchor`, in window coordinates, is
    /// the caller's button; it places the iPad popover. Nil for a
    /// page-initiated prompt.
    func presentPicker(prioritizesVideo: Bool, anchor: CGRect? = nil) async -> PickerResult {
        guard Prefs.AirPlaySettings.isEnabled else {
            logger("airPlay: picker refused - AirPlay is off")
            return .unavailable
        }
        guard UIApplication.shared.applicationState == .active else {
            logger("airPlay: picker refused - app is not active")
            return .unavailable
        }
        guard !Self.audioSessionBlocksAirPlay() else {
            logger("airPlay: picker refused - audio session \(AVAudioSession.sharedInstance().category.rawValue) offers no AirPlay route")
            return .unavailable
        }
        guard pendingPicker == nil else {
            logger("airPlay: picker refused - a picker is already open")
            return .unavailable
        }
        return await withCheckedContinuation { continuation in
            pendingPicker = continuation
            sawRouteChange = false
            routesPresenting = false
            beginPresentation(prioritizesVideo: prioritizesVideo, anchor: anchor)
        }
    }
    
    /// The synthetic tap goes straight to the system sheet, which is
    /// what Safari's button does; it is a workaround, not API, so it
    /// gets a deadline and the sheet with a real AVRoutePickerView is
    /// the guaranteed path behind it.
    private func beginPresentation(prioritizesVideo: Bool, anchor: CGRect?) {
        if !Prefs.AirPlaySettings.pickerAlwaysUsesSheet,
           let button = installHiddenPicker(prioritizesVideo: prioritizesVideo, anchor: anchor) {
            logger("airPlay: picker - synthetic tap")
            button.sendActions(for: .touchUpInside)
            fallbackTimer = scheduleOnMain(after: UX.syntheticTapTimeout) { [weak self] in
                guard let self, self.pendingPicker != nil, !self.routesPresenting else {
                    return
                }
                logger("airPlay: picker - no system sheet after \(Int(UX.syntheticTapTimeout * 1000)) ms, falling back to the sheet")
                self.presentSheet(prioritizesVideo: prioritizesVideo)
            }
            return
        }
        presentSheet(prioritizesVideo: prioritizesVideo)
    }
    
    /// A 1x1 pt picker in the key window: the button has to be in a
    /// window for its action to present anything. Interaction is off so
    /// a real touch can never reach it; alpha rather than isHidden
    /// because a hidden view does not present either. Hidden from
    /// accessibility too - neither of those takes the picker's UIButton
    /// out of VoiceOver's traversal, and a resident one is a phantom
    /// "AirPlay" element on every screen. Built per use and removed by
    /// finishPicker; see removeHiddenPicker.
    ///
    /// Framed at the anchor's centre when the caller has one: on iPad
    /// AVKit presents the routing UI as a popover anchored on this view,
    /// and at (0,0) it pins to the corner with its arrow pointing at
    /// nothing. A page-initiated prompt has no anchor - iOS WebKit
    /// presents that one unanchored as well - and centres in the window.
    private func installHiddenPicker(prioritizesVideo: Bool, anchor: CGRect?) -> UIButton? {
        guard let window = keyWindow else {
            return nil
        }
        removeHiddenPicker()
        let origin = anchor.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        let picker = AVRoutePickerView(frame: CGRect(origin: origin, size: CGSize(width: 1, height: 1)))
        picker.delegate = self
        picker.prioritizesVideoDevices = prioritizesVideo
        picker.alpha = UX.hiddenPickerAlpha
        picker.isUserInteractionEnabled = false
        picker.isAccessibilityElement = false
        picker.accessibilityElementsHidden = true
        window.addSubview(picker)
        hiddenPicker = picker
        picker.layoutIfNeeded()
        return firstButton(in: picker)
    }
    
    /// Not while the system routing UI is up: on iPad that UI is a
    /// popover whose source view this is, and a background finish can
    /// arrive with it still showing. finishPicker reads routesPresenting
    /// for exactly that, and pickerDidEndPresentingRoutes cleans up the
    /// early-finished case once the routes really go away.
    private func removeHiddenPicker() {
        hiddenPicker?.removeFromSuperview()
        hiddenPicker = nil
    }
    
    private func firstButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton {
                return button
            }
            if let button = firstButton(in: subview) {
                return button
            }
        }
        return nil
    }
    
    private var keyWindow: UIWindow? {
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
    
    private func presentSheet(prioritizesVideo: Bool) {
        guard sheet == nil else {
            return
        }
        // topViewController() walks presentedViewController, which UIKit
        // keeps set for the whole dismiss animation, so it can hand back
        // a controller on its way out - the previous fallback sheet when
        // a page re-prompts the instant its prompt() rejects, or any
        // modal the user is swiping away when a page's sticky activation
        // fires. A present onto one is torn down with it, silently.
        // Step down to the nearest settled presenter instead.
        var candidate = UIApplication.shared.topViewController()
        while let current = candidate, current.isBeingDismissed || current.isBeingPresented {
            candidate = current.presentingViewController
        }
        guard let presenter = candidate else {
            logger("airPlay: picker - nothing to present from")
            finishPicker(.unavailable)
            return
        }
        let controller = AirPlayRouteSheetViewController(prioritizesVideo: prioritizesVideo, pickerDelegate: self)
        // A Cancel tap or a swipe on this sheet is always the end of the
        // picker it belongs to. While the system routing UI is really up
        // it sits modally on top of the sheet and neither can be reached;
        // when they can be, the system presentation failed, and refusing
        // the cancel on routesPresenting - as this once did - is exactly
        // what left pendingPicker stranded with no sheet to resume it.
        // Identity, so a stale sheet cannot finish a newer picker.
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller, self.pendingPicker != nil, self.sheet === controller else {
                return
            }
            logger("airPlay: picker - sheet cancelled")
            self.finishPicker(.dismissed)
        }
        sheet = controller
        presenter.present(controller, animated: true)
        // UIKit sets presentingViewController synchronously when it
        // accepts the presentation. Unchecked, a refused present logged
        // success, the weak `sheet` went nil with the controller, no
        // timer was armed, and the only way out of pendingPicker was
        // backgrounding the app - every later picker refused as "already
        // open" and the page's prompt() promise never settling.
        guard controller.presentingViewController != nil else {
            logger("airPlay: picker - sheet did not present")
            sheet = nil
            finishPicker(.unavailable)
            return
        }
        logger("airPlay: picker - sheet presented")
    }
    
    private func pickerWillBeginPresentingRoutes() {
        routesPresenting = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        // Discovery has to be on while the sheet is up or it lists
        // nothing; WebKit's picker keeps an MPAVRoutingController in
        // Detailed mode for exactly this (WKAirPlayRoutePicker.mm:74-105).
        reasons.insert(.pickerVisible)
        applyDetection()
        logger("airPlay: picker - system sheet presenting")
    }
    
    private func pickerDidEndPresentingRoutes() {
        routesPresenting = false
        reasons.remove(.pickerVisible)
        applyDetection()
        if let sheet {
            self.sheet = nil
            sheet.dismiss(animated: true)
        }
        guard pendingPicker != nil else {
            // Finished early (backgrounded) with the routing UI still
            // up; now that it is gone, so can the picker it hung on.
            removeHiddenPicker()
            return
        }
        if sawRouteChange {
            finishPicker(.selected)
            return
        }
        graceTimer = scheduleOnMain(after: UX.routeChangeGrace) { [weak self] in
            guard let self, self.pendingPicker != nil else {
                return
            }
            self.finishPicker(self.sawRouteChange ? .selected : .dismissed)
        }
    }
    
    private func finishPicker(_ result: PickerResult) {
        // Taken first: nothing below may find a continuation to resume
        // a second time, whatever it re-enters.
        guard let continuation = pendingPicker else {
            return
        }
        pendingPicker = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        graceTimer?.invalidate()
        graceTimer = nil
        sawRouteChange = false
        // Read before the reset: a background finish can land with the
        // system routing UI still up, and the hidden picker is then the
        // live popover's anchor (see removeHiddenPicker).
        let systemUIUp = routesPresenting
        routesPresenting = false
        if let sheet {
            self.sheet = nil
            sheet.dismiss(animated: true)
        }
        if !systemUIUp {
            removeHiddenPicker()
        }
        // A background finish never sees routePickerViewDidEndPresentingRoutes.
        if reasons.remove(.pickerVisible) != nil {
            applyDetection()
        }
        logger("airPlay: picker -> \(result.rawValue)")
        continuation.resume(returning: result)
    }
    
    /// Timers fire on the main run loop, which is the main actor by
    /// construction; the block is not declared so, hence the stated hop.
    private func scheduleOnMain(after seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        return Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated(body)
        }
    }
}

// MARK: - AVRoutePickerViewDelegate

/// AVKit calls these on the main thread; the witnesses are nonisolated
/// only so the conformance does not cross into the actor on paper.
extension AirPlayController: AVRoutePickerViewDelegate {
    nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated { pickerWillBeginPresentingRoutes() }
    }
    
    nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        MainActor.assumeIsolated { pickerDidEndPresentingRoutes() }
    }
}

// MARK: - AirPlayDelegate

/// Reached from AirPlayHandler.handleMessage (@MainActor) and from
/// GeckoSession.close(), which the tab manager runs on the main thread.
extension AirPlayController: AirPlayDelegate {
    func onShowPicker(session: GeckoSession, hasVideo: Bool) async -> String {
        guard let selected = tabManager?.selectedTab?.session, selected === session else {
            logger("airPlay: picker refused - request from a tab that is not selected")
            return PickerResult.unavailable.rawValue
        }
        return await presentPicker(prioritizesVideo: hasVideo).rawValue
    }
    
    nonisolated func onWatchAvailability(session: GeckoSession, watching: Bool) {
        let reason = DetectionReason.webListeners(ObjectIdentifier(session))
        MainActor.assumeIsolated {
            if watching {
                reasons.insert(reason)
            } else {
                reasons.remove(reason)
            }
            applyDetection()
        }
    }
    
    nonisolated func onSessionClosed(session: GeckoSession) {
        let reason = DetectionReason.webListeners(ObjectIdentifier(session))
        MainActor.assumeIsolated {
            guard reasons.remove(reason) != nil else {
                return
            }
            applyDetection()
        }
    }
}
