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
        dispatcher.dispatch(
            type: "GeckoView:LoadUri",
            message: [
                "uri": url,
                "flags": flags,
                "headerFilter": 1,
            ])
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
    /// - Parameter state: A state that originated from this session's
    ///   own ProgressDelegate.onSessionStateChange callback.
    public func restoreSessionState(_ state: GeckoSessionState) {
        dispatcher.dispatch(type: "GeckoView:RestoreState", message: ["state": state.state])
    }
    
    /// Merges an incoming "data" payload from a "GeckoView:StateUpdated"
    /// message into this session's accumulating state cache, and
    /// returns the full, merged state.
    ///
    /// Deliberately simpler than Android's own merge logic: Android
    /// applies an index-based partial splice to the history array as a
    /// CPU-time optimization, with a code comment noting it exists
    /// purely for performance ("the legacy bundle operation performs
    /// better" for a full replace) — not for correctness. Reynard always
    /// takes the full-replace path here, trading a little efficiency on
    /// large history updates for meaningfully lower risk of a subtly
    /// incorrect incremental merge.
    func mergeSessionStateUpdate(_ update: [String: Any?]) -> GeckoSessionState {
        if let history = update["historychange"] as? [String: Any?] {
            sessionStateCache["history"] = history
        }
        if let scroll = update["scroll"] as? [String: Any?] {
            sessionStateCache["scrolldata"] = scroll
        }
        if let formData = update["formdata"] as? [String: Any?] {
            sessionStateCache["formdata"] = formData
        }
        return GeckoSessionState(state: sessionStateCache)
    }
    
    public func focusedInputBottomRatio() async -> CGFloat? {
        let response = try? await dispatcher.query(type: "GeckoView:GetFocusedInputMetrics")
        guard let values = response as? [AnyHashable: Any],
              let bottomRatioValue = values["bottomRatio"] else {
            return nil
        }
        
        return PayloadValue.cgFloat(bottomRatioValue)
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
    public func usesSafeAreaInsetCSS() async -> Bool? {
        let response = try? await dispatcher.query(type: "GeckoView:GetSafeAreaInsetUsage")
        guard let values = response as? [AnyHashable: Any],
              let usesSafeAreaInset = values["usesSafeAreaInset"] as? Bool else {
            return nil
        }
        
        return usesSafeAreaInset
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
    
    // Toolbar
    public func setDynamicToolbarMaxHeight(_ height: CGFloat) {
        window?.setDynamicToolbarMaxHeight(max(0, height))
    }
    
    /// How far the toolbar is displaced from fully visible. Zero while
    /// expanded; -maxHeight once condensed, which is the only value that
    /// reaches Gecko's Collapsed state and lets fixed-position content
    /// drop to the window bottom.
    public func setDynamicToolbarOffset(_ offset: CGFloat) {
        window?.setDynamicToolbarOffset(min(0, offset))
    }
    
    /// Reported to web content as env(safe-area-inset-*), so a page can
    /// reserve the space the chrome occupies itself instead of the
    /// viewport being shortened or a view drawn over it.
    public func setSafeAreaInsets(bottom: CGFloat) {
        window?.setSafeAreaInsetsTop(0, right: 0, bottom: max(0, bottom), left: 0)
    }
}
