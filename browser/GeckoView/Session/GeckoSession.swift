//
//  GeckoSession.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import UIKit

protocol GeckoSessionHandlerCommon: GeckoEventListenerInternal {
    var moduleName: String? { get }
    var events: [String] { get }
    var enabled: Bool { get }
}

public enum GeckoSessionLoadFlags {
    public static let none = 0
    public static let replaceHistory = 1 << 6
}

public class GeckoSession {
    // MARK: - State
    
    let dispatcher: GeckoEventDispatcherWrapper = GeckoEventDispatcherWrapper()
    var window: GeckoViewWindow?
    var id: String?
    public let isAddonPopup: Bool
    public let isPrivateMode: Bool
    lazy var addonSessionListener = AddonSessionListener(session: self)
    public private(set) var settings: GeckoSessionSettings
    private var requestedSettings: GeckoSessionSettings
    private var viewportWidth: Double?
    
    // MARK: - Delegates
    
    public func updateSettings(_ requestedSettings: GeckoSessionSettings) {
        self.requestedSettings = requestedSettings
        let settings = effectiveSettings(for: requestedSettings)
        self.settings = settings
        GeckoRuntime.setLocale(acceptLanguages: settings.language.acceptLanguages)
        
        guard isOpen() else { return }
        
        dispatcher.dispatch(
            type: "GeckoView:UpdateSettings",
            message: [
                "userAgentOverride": settings.websiteMode.userAgentOverride ?? NSNull(),
                "userAgentMode": settings.websiteMode.userAgentMode,
                "viewportMode": settings.websiteMode.viewportMode,
                "pageZoom": settings.pageZoom.scale,
            ])
    }
    
    lazy var contentHandler = newContentHandler(self)
    lazy var processHangHandler = newProcessHangHandler(self)
    public var contentDelegate: ContentDelegate? {
        get { contentHandler.delegate(as: ContentDelegate.self) }
        set {
            contentHandler.setDelegate(newValue)
            processHangHandler.setDelegate(newValue)
        }
    }
    
    lazy var contentBlockingHandler = newContentBlockingHandler(self)
    public var contentBlockingDelegate: ContentBlockingDelegate? {
        get { contentBlockingHandler.delegate(as: ContentBlockingDelegate.self) }
        set { contentBlockingHandler.setDelegate(newValue) }
    }
    
    lazy var navigationHandler = newNavigationHandler(self)
    public var navigationDelegate: NavigationDelegate? {
        get { navigationHandler.delegate(as: NavigationDelegate.self) }
        set { navigationHandler.setDelegate(newValue) }
    }
    
    lazy var historyHandler = newHistoryHandler(self)
    public var historyDelegate: HistoryDelegate? {
        get { historyHandler.delegate(as: HistoryDelegate.self) }
        set { historyHandler.setDelegate(newValue) }
    }
    
    lazy var permissionHandler = newPermissionHandler(self)
    public var permissionDelegate: PermissionEmbedderDelegate? {
        get { permissionHandler.delegate(as: PermissionEmbedderDelegate.self) }
        set { permissionHandler.setDelegate(newValue) }
    }
    
    lazy var progressHandler = newProgressHandler(self)
    public var progressDelegate: ProgressDelegate? {
        get { progressHandler.delegate(as: ProgressDelegate.self) }
        set { progressHandler.setDelegate(newValue) }
    }
    
    lazy var promptHandler: GeckoSessionHandler = {
        let handler = newPromptHandler(self)
        return handler
    }()
    public var promptDelegate: PromptDelegate? {
        get { promptHandler.delegate(as: PromptDelegate.self) }
        set { promptHandler.setDelegate(newValue) }
    }
    
    lazy var selectionActionHandler = newSelectionActionHandler(self)
    public var selectionActionDelegate: SelectionActionDelegate? {
        get { selectionActionHandler.delegate(as: SelectionActionDelegate.self) }
        set { selectionActionHandler.setDelegate(newValue) }
    }
    
    lazy var mediaSessionHandler = newMediaSessionHandler(self)
    public var mediaSessionDelegate: MediaSessionDelegate? {
        get { mediaSessionHandler.delegate(as: MediaSessionDelegate.self) }
        set { mediaSessionHandler.setDelegate(newValue) }
    }

    lazy var translationsHandler = newTranslationsHandler(self)
    public var translationsDelegate: TranslationsDelegate? {
        get { translationsHandler.delegate(as: TranslationsDelegate.self) }
        set { translationsHandler.setDelegate(newValue) }
    }
    public lazy var mediaSession = MediaSession(session: self)
    private lazy var autofillHandler = GeckoAutofillHandler(session: self)
    private lazy var pictureInPictureHandler = newPictureInPictureHandler(self)
    public var pictureInPictureDelegate: PictureInPictureDelegate? {
        get { pictureInPictureHandler.delegate }
        set { pictureInPictureHandler.delegate = newValue }
    }
    public var pictureInPictureDisplayLayer: AVSampleBufferDisplayLayer? {
        return pictureInPictureHandler.displayLayer
    }
    
    public func notifyScreenOrientationChanged(to orientation: UIInterfaceOrientation) {
        window?.updateScreenOrientation(orientation.rawValue)
    }
    
    // MARK: - Session Handlers
    
    lazy var sessionHandlers: [GeckoSessionHandlerCommon] = [
        contentHandler,
        contentBlockingHandler,
        processHangHandler,
        navigationHandler,
        historyHandler,
        permissionHandler,
        progressHandler,
        promptHandler,
        selectionActionHandler,
        mediaSessionHandler,
        translationsHandler,
        autofillHandler,
        pictureInPictureHandler,
    ]
    
    // MARK: - Lifecycle
    
    public init(
        settings: GeckoSessionSettings = .default,
        isPrivateMode: Bool = false,
        isAddonPopup: Bool = false
    ) {
        requestedSettings = settings
        self.settings = Self.effectiveSettings(for: settings, viewportWidth: nil)
        self.isPrivateMode = isPrivateMode
        self.isAddonPopup = isAddonPopup
        
        for sessionHandler in sessionHandlers {
            for type in sessionHandler.events {
                dispatcher.addListener(type: type, listener: sessionHandler)
            }
        }
        
        AddonRuntime.shared.register(sessionListener: addonSessionListener)
    }
    
    public func open(windowId: String? = nil) {
        if isOpen() {
            fatalError("cannot open a GeckoSession twice")
        }
        
        id = windowId ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        
        let sessionSettings = settings
        GeckoRuntime.setLocale(acceptLanguages: sessionSettings.language.acceptLanguages)
        
        let settings: [String: Any?] = [
            "chromeUri": nil,
            "screenId": 0,
            "useTrackingProtection": false,
            "userAgentMode": sessionSettings.websiteMode.userAgentMode,
            "userAgentOverride": sessionSettings.websiteMode.userAgentOverride,
            "viewportMode": sessionSettings.websiteMode.viewportMode,
            "pageZoom": sessionSettings.pageZoom.scale,
            "displayMode": 0,
            "suspendMediaWhenInactive": false,
            "allowJavascript": true,
            "fullAccessibilityTree": false,
            "isExtensionPopup": isAddonPopup,
            "sessionContextId": nil,
            "unsafeSessionContextId": nil,
        ]
        
        let modules: [String: Bool] = Dictionary(
            uniqueKeysWithValues: sessionHandlers.compactMap {
                guard let moduleName = $0.moduleName else {
                    return nil
                }
                return (moduleName, $0.enabled)
            }
        )
        
        window = GeckoViewOpenWindow(
            id,
            dispatcher,
            [
                "settings": settings,
                "modules": modules,
            ],
            isPrivateMode
        )
        guard let engineView = window?.view() else {
            fatalError("GeckoView window has no view")
        }
        autofillHandler.attach(to: engineView)
    }
    
    public func isOpen() -> Bool { window != nil }
    
    public var engineView: UIView? {
        return window?.view()
    }

    public func updateViewportWidth(_ width: CGFloat) {
        let width = Double(width)
        guard width.isFinite,
              width > 0,
              viewportWidth.map({ abs($0 - width) >= 0.5 }) ?? true else {
            return
        }

        viewportWidth = width
        updateSettings(requestedSettings)
    }

    private func effectiveSettings(for settings: GeckoSessionSettings) -> GeckoSessionSettings {
        return Self.effectiveSettings(for: settings, viewportWidth: viewportWidth)
    }

    private static func effectiveSettings(
        for settings: GeckoSessionSettings,
        viewportWidth: Double?
    ) -> GeckoSessionSettings {
        let level = PageZoomViewportPolicy.effectiveLevel(
            requestedLevel: settings.pageZoom.level,
            viewportWidth: viewportWidth,
            minimumLayoutWidth: settings.pageZoom.minimumLayoutWidth
        )
        return GeckoSessionSettings(
            websiteMode: settings.websiteMode,
            pageZoom: PageZoomSetting(
                level: level,
                minimumLayoutWidth: settings.pageZoom.minimumLayoutWidth
            ),
            language: settings.language
        )
    }

    public func close() {
        contentDelegate = nil
        contentBlockingDelegate = nil
        navigationDelegate = nil
        historyDelegate = nil
        permissionDelegate = nil
        progressDelegate = nil
        promptDelegate = nil
        selectionActionDelegate = nil
        mediaSessionDelegate?.onDeactivated(session: self)
        mediaSessionDelegate = nil
        translationsDelegate = nil
        pictureInPictureDelegate = nil
        
        guard let window else {
            return
        }
        
        if let engineView = window.view() {
            autofillHandler.detach(from: engineView)
        }
        autofillHandler.close()
        window.close()
        self.window = nil
        id = nil
    }
    
    // MARK: - Navigation
    
    public func load(_ url: String, flags: Int = GeckoSessionLoadFlags.none) {
        let disposition = dispatcher.dispatch(
            type: "GeckoView:LoadUri",
            message: [
                "uri": url,
                "flags": flags,
                "headerFilter": 1,
            ])
        // NSLog rather than logger(): stdout captures carry NSLog, and
        // this is the only record that a user's load left the app at
        // all. One line per navigation. Deliberately no isOpen() guard
        // - isOpen() staying true around a dead content process is the
        // failure being made visible here, not a precondition.
        NSLog("[GeckoSession] LoadUri %@ -> %@ (open=%d)", url, disposition.rawValue, isOpen() ? 1 : 0)
    }
    
    public func reload() {
        dispatcher.dispatch(
            type: "GeckoView:Reload",
            message: [
                "flags": 0
            ])
    }
    
    public func stop() {
        dispatcher.dispatch(type: "GeckoView:Stop")
    }
    
    public func goBack(userInteraction: Bool = true) {
        dispatcher.dispatch(
            type: "GeckoView:GoBack",
            message: [
                "userInteraction": userInteraction
            ])
    }
    
    public func goForward(userInteraction: Bool = true) {
        dispatcher.dispatch(
            type: "GeckoView:GoForward",
            message: [
                "userInteraction": userInteraction
            ])
    }
    
    /// Scrolls by a delta relative to the current VISUAL viewport
    /// offset. The engine side reads the visual offset and re-issues it
    /// through scrollToVisual with UPDATE_TYPE_MAIN_THREAD, which is the
    /// path APZ honours - a layout-viewport scroll alone does not move
    /// what is composited.
    public func scrollBy(_ delta: CGPoint, animated: Bool = true) {
        dispatcher.dispatch(
            type: "GeckoView:ScrollBy",
            message: [
                "widthValue": delta.x,
                "widthType": 0,
                "heightValue": delta.y,
                "heightType": 0,
                "behavior": animated ? 0 : 1,
            ])
    }

    public func scrollTo(_ position: CGPoint, animated: Bool = true) {
        dispatcher.dispatch(
            type: "GeckoView:ScrollTo",
            message: [
                "widthValue": position.x,
                "widthType": 0,
                "heightValue": position.y,
                "heightType": 0,
                "behavior": animated ? 0 : 1,
            ])
    }
    
    // MARK: - State Updates
    
    public func setActive(_ active: Bool) {
        dispatcher.dispatch(type: "GeckoView:SetActive", message: ["active": active])
        if !active {
            flushSessionState()
        }
    }
    
    public func setFocused(_ focused: Bool) {
        dispatcher.dispatch(type: "GeckoView:SetFocused", message: ["focused": focused])
    }

    /// Latches the compositor's off-main-thread CoreAnimation commits
    /// for this session's window. Used while the phone scene is
    /// inactive: a compositor-thread commit flushes any layer with
    /// pending layout in the same CA context - including UIKit's own
    /// windows - and UIKit's Auto Layout engine aborts the app when
    /// that happens off the main thread. An optional protocol
    /// requirement, so this no-ops against an engine artifact built
    /// before the method existed.
    public func setOffMainThreadCommitsSuspended(_ suspended: Bool) {
        window?.setOffMainThreadCommitsSuspended?(suspended)
    }
    
    // MARK: - Session State
    
    /// Accumulating cache of this session's persisted state, keyed the
    /// same way the engine's own cache keys it ("history", "scrolldata",
    /// "formdata"). Mirrors Android's GeckoSession.mStateCache, which
    /// lives on the session for its whole lifetime and is merged into
    /// incrementally as "GeckoView:StateUpdated" messages arrive, rather
    /// than each message carrying the full state on its own.
    private var sessionStateCache: [String: Any?] = [:]
    
    /// Requests that Gecko flush the most current session state (history,
    /// scroll position, form data) and report it via a
    /// "GeckoView:StateUpdated" message. This is asynchronous — the
    /// flush is not guaranteed to have completed by the time this
    /// method returns. setActive(false) already calls this
    /// automatically, matching GeckoView's own documented Android
    /// behavior ("[setActive(false)] will flush the session state and
    /// trigger a ProgressDelegate.onSessionStateChange callback").
    public func flushSessionState() {
        dispatcher.dispatch(type: "GeckoView:FlushSessionState", message: nil)
    }
    
    /// Restores a previously-saved state to this session; only data
    /// that was saved (history, scroll position, and form data) is
    /// restored, overwriting the corresponding state of this session.
    ///
    /// The state dictionary is the message itself, not wrapped under a
    /// key: the engine's handler passes the message straight to
    /// GeckoViewContentParent.restoreState, which destructures
    /// { history, formdata, scrolldata } directly off it — the same
    /// shape Android dispatches ("mEventDispatcher.dispatch(
    /// "GeckoView:RestoreState", state.mState)").
    ///
    /// - Parameter state: A state that originated from this session's
    ///   own ProgressDelegate.onSessionStateChange callback.
    public func restoreSessionState(_ state: GeckoSessionState) {
        dispatcher.dispatch(type: "GeckoView:RestoreState", message: state.state)
    }
    
    /// Merges an incoming "data" payload from a "GeckoView:StateUpdated"
    /// message into this session's accumulating state cache, and
    /// returns the full, merged state.
    ///
    /// The history is always full-replaced rather than spliced. That is
    /// only correct because the pinned engine (FIREFOX_153_0_RELEASE)
    /// always collects the FULL history: GeckoViewSessionStore.collect
    /// hardcodes collectFull=true — the partial path is commented out
    /// upstream pending Mozilla Bug 1915362 — so "historychange" always
    /// arrives with fromIdx == -1. When fromIdx != -1 the payload holds
    /// only the entries from that index on, and Android splices them
    /// onto the previous entries (GeckoSession.SessionState
    /// .getPartiallyUpdatedHistoryChange) — that path is correctness,
    /// not just performance. The guard below is the tripwire for an
    /// engine bump that starts sending partials: it keeps the last full
    /// snapshot (stale but valid) instead of silently truncating.
    func mergeSessionStateUpdate(_ update: [String: Any?]) -> GeckoSessionState {
        if let history = update["historychange"] as? [String: Any?] {
            let fromIdx = (history["fromIdx"] as? Int) ?? -1
            if fromIdx == -1 {
                sessionStateCache["history"] = history
            } else {
                assertionFailure(
                    "Engine sent a PARTIAL history update (fromIdx \(fromIdx)) — "
                    + "mergeSessionStateUpdate needs Android's splice logic now")
                NSLog(
                    "[GeckoSession] Ignoring partial history update (fromIdx %d) — "
                    + "splice not implemented; keeping last full history snapshot",
                    fromIdx)
            }
        }
        if let scroll = update["scroll"] as? [String: Any?] {
            sessionStateCache["scrolldata"] = scroll
        }
        if let formData = update["formdata"] as? [String: Any?] {
            sessionStateCache["formdata"] = formData
        }
        return GeckoSessionState(state: sessionStateCache)
    }
    
    // Keyboard
    public func focusedInputBottomRatio() async -> CGFloat? {
        let response = try? await dispatcher.query(type: "GeckoView:GetFocusedInputMetrics")
        guard let values = response as? [AnyHashable: Any],
              let bottomRatioValue = values["bottomRatio"] else {
            // DIAGNOSTIC - Twitch chat does not lift above the keyboard
            // and this path had no logging at all: the query is wrapped
            // in try?, so a failed query, a missing actor and an element
            // the engine did not consider editable all produced the same
            // silent nil as "nothing focused". The actor sends back what
            // it decided in the same payload, so a refusal says WHY.
            let reason = (response as? [AnyHashable: Any])?["reason"] as? String
            NSLog("focusedInput: no ratio (%@)", reason ?? (response == nil ? "query failed" : "no bottomRatio in payload"))
            return nil
        }

        let ratio = PayloadValue.cgFloat(bottomRatioValue)
        let describe = { (key: String) -> String in
            (values[key] as? String) ?? String(describing: values[key] ?? "?")
        }
        NSLog("focusedInput: ratio=%@ tag=%@ editable=%@ frame=%@ vh=%@ bottom=%@",
              ratio.map { String(format: "%.3f", $0) } ?? "nil",
              describe("tag"), describe("contentEditable"),
              describe("inSubframe"), describe("viewportHeight"), describe("boundsBottom"))
        return ratio
    }
    
    /// Whether this page's CSS uses env(safe-area-inset-bottom),
    /// asked directly of the content process. Mirrors
    /// focusedInputBottomRatio above - see
    /// fix_native_safe_area_detection.py for why this replaces the
    /// SafeAreaDetector WebExtension, whose native messages dispatched
    /// to a runtime dispatcher Reynard never registered a listener on
    /// and so never arrived at all.
    ///
    /// nil means no answer - the query failed or the actor returned
    /// null - and callers should treat that the same as false.
    /// How a page reserves space at the bottom, which decides which
    /// mechanism can actually move its content.
    public enum BottomReservation: Equatable {
        /// Nothing pinned at the bottom - the pill floats over the page.
        case none
        /// The page reads env(safe-area-inset-bottom), so reporting a
        /// larger inset moves its own content.
        case readsSafeAreaInset
        /// The page has a bar pinned to the bottom edge but is not known
        /// to read env() - reporting an inset does nothing for it, so the
        /// layout viewport has to be shortened instead. Observed on
        /// device: Facebook's composer stayed behind the pill even once
        /// the inset was reported correctly.
        case hasBottomBar
    }

    public func bottomReservation() async -> BottomReservation? {
        let response = try? await dispatcher.query(type: "GeckoView:GetSafeAreaInsetUsage")
        guard let values = response as? [AnyHashable: Any] else {
            return nil
        }

        if values["usesSafeAreaInset"] as? Bool == true {
            return .readsSafeAreaInset
        }
        if values["hasBottomBar"] as? Bool == true {
            return .hasBottomBar
        }
        // Only treat a well-formed negative as "none"; a response missing
        // both keys means an engine without this actor change, which must
        // not be read as a confident no.
        guard values["usesSafeAreaInset"] is Bool else {
            return nil
        }
        return .none
    }
    
    /// Runs a script against this session's page, as page script.
    /// Returns nil if the query failed, or an error string if the
    /// script itself threw. See fix_carplay_user_script.py.
    ///
    /// Generic by design, but only the CarPlay session calls it -
    /// ordinary tabs get no injection at all.
    public func runUserScript(_ script: String) async -> String? {
        let response = try? await dispatcher.query(
            type: "GeckoView:RunUserScript",
            message: ["script": script]
        )
        
        guard let values = response as? [AnyHashable: Any] else {
            return "no response"
        }
        
        if let ok = values["ok"] as? Bool, ok {
            return nil
        }
        
        return (values["error"] as? String) ?? "unknown error"
    }
    
    @discardableResult
    public func focusForHardwareKeyboard() -> Bool {
        return window?.focusForHardwareKeyboard() ?? false
    }
    
    public func isInHardwareKeyboardMode() -> Bool {
        return window?.isInHardwareKeyboardMode() ?? false
    }
    
    // MARK: - Selection Actions
    
    public func executeSelectionAction(actionId: String, commandId: String) {
        dispatcher.dispatch(
            type: "GeckoView:ExecuteSelectionAction",
            message: [
                "actionId": actionId,
                "id": commandId,
            ]
        )
    }
    
    // MARK: - Toolbar
    public func setDynamicToolbarMaxHeight(_ height: CGFloat) {
        window?.setDynamicToolbarMaxHeight(max(0, height))
    }
    
    public func setContentBottomOffset(_ offset: CGFloat) {
        window?.setFixedBottomOffset(offset)
    }

    /// Reported to the page as env(safe-area-inset-bottom).
    ///
    /// The compositor margin above moves fixed and sticky layers only.
    /// This reaches any page that reads the variable, which is how a
    /// site lifts its own bottom controls clear of the floating pill
    /// while its background still runs the full height behind it.
    public func setSafeAreaInsetBottom(_ inset: CGFloat) {
        window?.setSafeAreaInsetBottom(inset)
    }
}
