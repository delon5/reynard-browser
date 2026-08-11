//
//  SessionManager.swift
//  Reynard
//
//  Created by Minh Ton on 18/6/26.
//

import Foundation
import GeckoView
import UIKit

protocol SessionManagerApplicationStateObserver: AnyObject {
    func sessionManagerDidChangeApplicationState(_ sessionManager: SessionManager)
    func sessionManagerWillResignActive(_ sessionManager: SessionManager)
}

protocol SessionManagerPictureInPictureHandler: AnyObject {
    func stopPresenting(_ session: GeckoSession) -> Bool
}

final class SessionManager {
    private let sessionSettings: SessionSettingsManager
    private let history: NavigationHistory
    private let permissionStore: SitePermissionStore
    let trackingProtection: TrackingProtectionManager
    
    private var sessionsRequestedActive: [ObjectIdentifier: GeckoSession] = [:]
    private var pageBackgroundColors: [ObjectIdentifier: UIColor] = [:]
    private var isApplicationForeground = true
    // Tracks the resign/become-active pair, which is narrower than
    // foreground/background: Control Centre, the app switcher and the
    // lock screen all resign active while still foreground. The commit
    // latch keys on this because the compositor-vs-UIKit CA race lives
    // in exactly those transitions.
    private var isPhoneSceneActive = true
    private(set) var isApplicationActive = true
    private weak var pictureInPictureSession: GeckoSession?
    
    /// Whether this session is the one Picture in Picture is rendering
    /// from. Exposed because tab eviction has to know: closing it would
    /// tear down a content process that is required to stay alive and
    /// rendering while the app is backgrounded.
    func isRenderingPictureInPicture(_ session: GeckoSession?) -> Bool {
        guard let session, let pictureInPictureSession else {
            return false
        }
        return pictureInPictureSession === session
    }
    private var pendingCleanup: (
        session: GeckoSession,
        perform: (SessionManager) -> Void
    )?
    weak var applicationStateObserver: SessionManagerApplicationStateObserver?
    weak var pictureInPictureHandler: SessionManagerPictureInPictureHandler?
    
    var isForeground: Bool {
        return isApplicationForeground
    }
    
    init(
        sessionSettings: SessionSettingsManager = SessionSettingsManager(),
        history: NavigationHistory = NavigationHistory(),
        permissionStore: SitePermissionStore = .shared,
        trackingProtection: TrackingProtectionManager = TrackingProtectionManager()
    ) {
        self.sessionSettings = sessionSettings
        self.history = history
        self.permissionStore = permissionStore
        self.trackingProtection = trackingProtection
    }
    
    // MARK: - Session Creation
    
    func createSession(
        url: String?,
        tabID: UUID?,
        isPrivate: Bool,
        isAddonPopup: Bool = false,
        opening: SessionOpening,
        delegates: SessionDelegates
    ) -> GeckoSession {
        let session = GeckoSession(
            settings: sessionSettings.settings(for: url, tabID: tabID),
            isPrivateMode: isPrivate,
            isAddonPopup: isAddonPopup
        )
        bindDelegates(to: session, delegates: delegates)
        
        if case let .immediate(windowID) = opening {
            session.open(windowId: windowID)
            deactivate(session)
        }
        return session
    }
    
    func bindDelegates(to session: GeckoSession, delegates: SessionDelegates) {
        session.contentDelegate = delegates.content
        session.contentBlockingDelegate = trackingProtection
        session.navigationDelegate = delegates.navigation
        session.historyDelegate = delegates.history
        session.permissionDelegate = delegates.permission
        session.progressDelegate = delegates.progress
        session.promptDelegate = delegates.prompt
        session.selectionActionDelegate = delegates.selectionAction
        session.mediaSessionDelegate = delegates.mediaSession
        session.translationsDelegate = delegates.translations
    }
    
    func adopt(
        _ session: GeckoSession,
        asTab tabID: UUID,
        url: String,
        delegates: SessionDelegates
    ) {
        deactivate(session)
        bindDelegates(to: session, delegates: delegates)
        updateSettings(of: session, for: url, tabID: tabID)
    }
    
    // MARK: - Session Lifecycle
    
    func open(_ session: GeckoSession, windowID: String? = nil) {
        session.open(windowId: windowID)
    }
    
    func activate(_ session: GeckoSession) {
        guard session.isOpen() else {
            // Not a no-op worth ignoring: the caller believes this
            // session is now on screen, and it will not be activated by
            // anything else. A tab whose activate landed here loads into
            // an inactive docshell and never paints.
            NSLog("[SessionActivation] activate SKIPPED - session %p is not open (caller believes it is selected)",
                  session)
            return
        }
        sessionsRequestedActive[ObjectIdentifier(session)] = session
        // Keep the commit latch consistent for sessions that enter the
        // active set after the scene-wide sweep ran - without this, a
        // session activated mid-transition could carry a stale latch
        // and render frozen, or commit while the scene is inactive.
        session.setOffMainThreadCommitsSuspended(
            !isPhoneSceneActive && !isCommitLatchExempt(session)
        )
        // isApplicationForeground alone would DEACTIVATE a session
        // activated while backgrounded. Harmless for a tab, but it is how
        // a session that must keep running gets throttled the moment
        // anything routes it through here - Gecko stops painting while
        // audio carries on, which is what CarPlay video stopping on lock
        // looks like.
        let active = isApplicationForeground || mustStayActive(session)
        NSLog("[SessionActivation] activate session %p -> active=%@ foreground=%@ commitsSuspended=%@ (%d in active set)",
              session,
              active ? "YES" : "NO",
              isApplicationForeground ? "YES" : "NO",
              (!isPhoneSceneActive && !isCommitLatchExempt(session)) ? "YES" : "NO",
              sessionsRequestedActive.count)
        session.setActive(active)
        session.setFocused(true)
    }
    
    /// Whether this session must keep running while the app is
    /// backgrounded - Picture in Picture, or whatever currently owns the
    /// system media controls. CarPlay registers itself as the latter.
    private func mustStayActive(_ session: GeckoSession) -> Bool {
        return pictureInPictureSession === session
            || SystemMediaSession.shared.prioritySession === session
    }
    
    /// Exposed for tab eviction, which must not sleep a tab whose
    /// session is one of these.
    func isMediaPriority(_ session: GeckoSession?) -> Bool {
        guard let session else {
            return false
        }
        return mustStayActive(session)
    }
    
    func deactivate(_ session: GeckoSession) {
        sessionsRequestedActive.removeValue(forKey: ObjectIdentifier(session))
        guard session.isOpen() else {
            return
        }
        session.setFocused(false)
        if mustStayActive(session) {
            return
        }
        session.setActive(false)
    }
    
    func setApplicationForeground(_ isForeground: Bool) {
        guard isApplicationForeground != isForeground else {
            return
        }
        isApplicationForeground = isForeground
        for session in sessionsRequestedActive.values {
            session.setActive(isForeground || mustStayActive(session))
            if pictureInPictureSession === session {
                session.setFocused(isForeground)
            }
        }
        if let pictureInPictureSession,
           sessionsRequestedActive[ObjectIdentifier(pictureInPictureSession)] == nil {
            pictureInPictureSession.setFocused(false)
            pictureInPictureSession.setActive(true)
        }
        applicationStateObserver?.sessionManagerDidChangeApplicationState(self)
    }
    
    func applicationWillResignActive() {
        setCommitsSuspendedForPhoneHostedSessions(true)
        isApplicationActive = false
        applicationStateObserver?.sessionManagerWillResignActive(self)
    }

    func applicationDidBecomeActive() {
        setCommitsSuspendedForPhoneHostedSessions(false)
        isApplicationActive = true
        applicationStateObserver?.sessionManagerDidChangeApplicationState(self)
    }

    /// Latches compositor CoreAnimation commits off for phone-hosted
    /// sessions while the phone scene is inactive, and back on when it
    /// returns.
    ///
    /// A commit made on Gecko's compositor thread flushes any layer
    /// with pending layout in the phone display's CA context -
    /// including UIKit's own windows - and UIKit's Auto Layout engine
    /// aborts the app when that happens off the main thread. Observed
    /// on device as NSInternalInconsistencyException in
    /// _AssertAutoLayoutOnAllowedThreadsOnly under
    /// NativeLayerRootCA::CommitToScreen, during a
    /// background-to-foreground transition with the keyboard window's
    /// layout pending.
    ///
    /// Exempt, deliberately: the Picture in Picture session, because
    /// its video frames ride these commits, and the CarPlay session,
    /// because it renders to the car display's own CA context - which
    /// the crash cannot involve - and car video must keep playing
    /// while the phone is locked.
    private func setCommitsSuspendedForPhoneHostedSessions(_ suspended: Bool) {
        isPhoneSceneActive = !suspended
        for session in sessionsRequestedActive.values {
            session.setOffMainThreadCommitsSuspended(
                suspended && !isCommitLatchExempt(session)
            )
        }
    }

    private func isCommitLatchExempt(_ session: GeckoSession) -> Bool {
        if session === pictureInPictureSession {
            return true
        }
        // CarPlay scenes require iOS 14; on 13 there is nothing to
        // exempt.
        if #available(iOS 14.0, *) {
            return session === CarPlaySceneDelegate.currentSession
        }
        return false
    }
    
    func close(_ session: GeckoSession) {
        performCleanup(for: session) { manager in
            manager.closeImmediately(session)
        }
    }
    
    func discard(_ session: GeckoSession, forTab tabID: UUID, keepingHistory: Bool = false) {
        performCleanup(for: session) { manager in
            manager.discardImmediately(
                session,
                forTab: tabID,
                keepingHistory: keepingHistory
            )
        }
    }
    
    // MARK: - Picture in Picture
    
    func setPictureInPictureSession(_ session: GeckoSession) {
        pictureInPictureSession = session

        // Clear the commit latch NOW, because this session was almost
        // certainly latched a moment ago.
        //
        // isCommitLatchExempt only helps a session that is already known
        // to be PiP's when the sweep runs, and for system-initiated PiP
        // it never is: iOS resigns the app active BEFORE calling
        // pipWillStart, so applicationWillResignActive latches every
        // phone-hosted session while pictureInPictureSession is still
        // nil. PiP then registers here and nothing re-evaluates the
        // latch - activate() re-checks only for sessions ENTERING the
        // active set, and this one is already in it.
        //
        // The compositor then stops presenting while audio, which never
        // goes through it, carries on: a frozen picture with sound,
        // which is exactly how this was reported on Twitch.
        session.setOffMainThreadCommitsSuspended(false)

        if !isApplicationForeground {
            session.setFocused(false)
        }
        session.setActive(true)
    }
    
    func pictureInPicturePresentationDidEnd(_ session: GeckoSession) {
        clearPictureInPictureSession(session)
        executePendingCleanup(for: session)
    }
    
    private func clearPictureInPictureSession(_ session: GeckoSession) {
        guard pictureInPictureSession === session else {
            return
        }
        pictureInPictureSession = nil

        // The mirror of setPictureInPictureSession: this session just
        // lost its exemption, so if the scene is still inactive it has
        // to be latched again. Otherwise it keeps committing off-main
        // while inactive, which is the UIKit Auto Layout crash the latch
        // exists to prevent - PiP ending while backgrounded is exactly
        // when that would happen.
        session.setOffMainThreadCommitsSuspended(
            !isPhoneSceneActive && !isCommitLatchExempt(session)
        )

        if isApplicationForeground,
           sessionsRequestedActive[ObjectIdentifier(session)] != nil {
            session.setActive(true)
            session.setFocused(true)
        } else {
            session.setFocused(false)
            session.setActive(false)
        }
    }
    
    private func performCleanup(
        for session: GeckoSession,
        _ perform: @escaping (SessionManager) -> Void
    ) {
        if let pendingCleanup {
            if pendingCleanup.session !== session {
                perform(self)
            }
            return
        }
        pendingCleanup = (session, perform)
        if pictureInPictureHandler?.stopPresenting(session) != true {
            executePendingCleanup(for: session)
        }
    }
    
    private func executePendingCleanup(for session: GeckoSession) {
        guard let cleanup = pendingCleanup,
              cleanup.session === session else {
            return
        }
        pendingCleanup = nil
        cleanup.perform(self)
    }
    
    private func closeImmediately(_ session: GeckoSession) {
        deactivate(session)
        trackingProtection.removeSession(session)
        permissionStore.removePrivateActions(for: session)
        pageBackgroundColors.removeValue(forKey: ObjectIdentifier(session))
        session.close()
    }
    
    private func discardImmediately(
        _ session: GeckoSession,
        forTab tabID: UUID,
        keepingHistory: Bool
    ) {
        sessionSettings.websiteMode.clearWebsiteOverrides(for: tabID)
        if !keepingHistory {
            history.removeHistory(for: tabID)
        }
        closeImmediately(session)
    }
    
    // MARK: - Page Background Color
    
    func pageBackgroundColor(for session: GeckoSession) -> UIColor {
        return pageBackgroundColors[ObjectIdentifier(session)] ?? .systemBackground
    }
    
    func setPageBackgroundColor(_ color: UIColor, for session: GeckoSession) {
        pageBackgroundColors[ObjectIdentifier(session)] = color
    }
    
    // MARK: - Addon Tab State
    
    func setAddonTabActive(_ active: Bool, for session: GeckoSession) {
        session.setAddonTabActive(active)
    }
    
    func transferAddonTabActivation(from previousSession: GeckoSession, to replacementSession: GeckoSession) {
        setAddonTabActive(false, for: previousSession)
        setAddonTabActive(true, for: replacementSession)
    }
    
    // MARK: - Website Settings
    
    func updateSettings(of session: GeckoSession, for url: String, tabID: UUID?) {
        let settings = sessionSettings.settings(for: url, tabID: tabID)
        
        // See fix_log_user_agent_resolution.py. The user agent is
        // resolved from the URL being applied, so a session that has not
        // navigated yet resolves against about:blank - which no per-site
        // override can match.
        //
        // NATIVE means no override was chosen and Gecko sends its own
        // string, which on iOS has no mobile identifier and reads as a
        // desktop browser.
        logger(String(format: "userAgent: %@ -> %@ (uaMode=%d, viewport=%d)",
                      url,
                      settings.websiteMode.userAgentOverride ?? "NATIVE",
                      settings.websiteMode.userAgentMode,
                      settings.websiteMode.viewportMode))
        
        session.updateSettings(settings)
    }
    
    func setPageZoom(_ level: Int, of session: GeckoSession, for url: String, tabID: UUID?) {
        sessionSettings.pageZoom.save(level, for: url)
        updateSettings(of: session, for: url, tabID: tabID)
    }
    
    func isDesktopMode(for url: String, tabID: UUID) -> Bool? {
        return sessionSettings.websiteMode.isDesktopMode(for: url, tabID: tabID)
    }
    
    func toggleWebsiteMode(for url: String, tabID: UUID) -> WebsiteModeAction? {
        return sessionSettings.websiteMode.toggleWebsiteMode(for: url, tabID: tabID)
    }

    func setPersistentWebsiteMode(_ mode: SiteWebsiteMode, for url: String, tabID: UUID) -> WebsiteModeAction? {
        return sessionSettings.websiteMode.setPersistentWebsiteMode(mode, for: url, tabID: tabID)
    }

    func resetPersistentWebsiteMode(for url: String, tabID: UUID) -> WebsiteModeReset? {
        return sessionSettings.websiteMode.resetPersistentWebsiteMode(for: url, tabID: tabID)
    }
    
    func needsSettingsUpdate(
        to session: GeckoSession,
        currentURL: String?,
        requestedURL: String,
        tabID: UUID
    ) -> Bool {
        sessionSettings.needsUpdate(
            for: session,
            currentURL: currentURL,
            requestedURL: requestedURL,
            tabID: tabID
        )
    }
    
    // MARK: - Navigation
    
    func restoreNavigation(for tabID: UUID, isPrivate: Bool = false) -> NavigationAvailability {
        return history.restoreState(
            for: tabID,
            storageMode: isPrivate ? .memoryOnly : .persistent
        )
    }
    
    func navigationAvailability(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationAvailability {
        return history.availability(for: tabID, sessionState: sessionState)
    }
    
    func recordNavigation(
        to url: String,
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationAvailability {
        return history.record(to: url, for: tabID, sessionState: sessionState)
    }
    
    func goBack(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationTransition? {
        return history.goBack(for: tabID, sessionState: sessionState)
    }
    
    func goForward(
        for tabID: UUID,
        sessionState: SessionNavigationAvailability
    ) -> NavigationTransition? {
        return history.goForward(for: tabID, sessionState: sessionState)
    }
    
    func useStoredNavigationHistory(for tabID: UUID) -> NavigationAvailability {
        return history.useStoredHistory(for: tabID)
    }
    
    func updateCurrentHistoryThumbnail(_ image: UIImage?, for tabID: UUID, matching url: String) {
        history.updateCurrentHistoryThumbnail(image, for: tabID, matching: url)
    }
    
    func navigationPreviewImages(for tabID: UUID) -> NavigationPreviewImages {
        return history.previewImages(for: tabID)
    }
    
    func invalidateNavigationThumbnails() {
        history.invalidateThumbnails()
    }
}
