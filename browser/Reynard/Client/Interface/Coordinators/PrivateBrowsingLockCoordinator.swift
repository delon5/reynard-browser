//
//  PrivateBrowsingLockCoordinator.swift
//  Reynard
//

import UIKit

/// Gates access to private tabs behind Face ID / Touch ID / passcode when
/// `Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs` is on.
///
/// There are two entry points into private browsing that both need to be
/// covered:
///  1. Switching into Private mode from the tab overview's mode toggle
///     while the app is already running — see `requestAccessToPrivateTabs`.
///  2. The app launching or returning to the foreground with private
///     browsing already active, since tabs persist across launches — see
///     `lockIfNeeded` / `presentLockIfNeeded`.
final class PrivateBrowsingLockCoordinator {
    private weak var host: BrowserViewController?
    private let tabManager: TabManager

    private(set) var isLocked = false
    private var presentedLockViewController: PrivateBrowsingLockViewController?

    init(host: BrowserViewController, tabManager: TabManager) {
        self.host = host
        self.tabManager = tabManager
    }

    /// Whether the feature is both enabled in Settings and actually usable
    /// on this device (a passcode or biometrics must be configured).
    var isProtectionEnabled: Bool {
        return Prefs.PrivacySettings.requiresAuthenticationForPrivateTabs
            && PrivateBrowsingAuthenticator.shared.isAvailable
    }

    // MARK: - App Lifecycle

    /// Call as soon as the browser's initial tab has been created. If the
    /// restored session left the user on a private tab, this locks the app
    /// immediately so `presentLockIfNeeded` has something to enforce.
    func lockInitialStateIfNeeded() {
        guard isProtectionEnabled, tabManager.selectedTabMode == .private else {
            return
        }
        isLocked = true
    }

    /// Call when the app is about to leave the foreground (backgrounding,
    /// or about to be suspended).
    func lockIfNeeded() {
        guard isProtectionEnabled, tabManager.selectedTabMode == .private else {
            return
        }
        isLocked = true
    }

    /// Call when the app becomes visible again (foreground, or right after
    /// the initial tab is created on launch). Presents the lock screen if
    /// needed; otherwise does nothing.
    func presentLockIfNeeded(animated: Bool) {
        guard isLocked, isProtectionEnabled, tabManager.selectedTabMode == .private else {
            return
        }
        presentLockScreen(animated: animated)
    }

    // MARK: - Tab Overview Gate

    /// Call before allowing the tab overview to switch into Private mode.
    /// `completion` receives `true` once the switch is allowed to proceed
    /// (either because protection is off/unavailable, or the user just
    /// authenticated), and `false` if the user cancelled.
    func requestAccessToPrivateTabs(completion: @escaping (Bool) -> Void) {
        guard isProtectionEnabled else {
            completion(true)
            return
        }

        PrivateBrowsingAuthenticator.shared.authenticate(
            reason: NSLocalizedString("Authenticate to view your private tabs", comment: "")
        ) { [weak self] result in
            switch result {
            case .success, .unavailable:
                self?.isLocked = false
                completion(true)
            case .cancelled, .failed:
                completion(false)
            }
        }
    }

    // MARK: - Lock Screen

    private func presentLockScreen(animated: Bool) {
        guard let host, presentedLockViewController == nil else {
            return
        }

        let lockViewController = PrivateBrowsingLockViewController()
        lockViewController.modalPresentationStyle = .overFullScreen
        lockViewController.modalTransitionStyle = .crossDissolve
        lockViewController.onUnlockRequested = { [weak self] in
            self?.authenticateAndUnlock()
        }
        lockViewController.onSwitchToRegularTabsRequested = { [weak self] in
            self?.switchToRegularTabsAndDismissLock()
        }

        presentedLockViewController = lockViewController
        host.present(lockViewController, animated: animated)
    }

    private func authenticateAndUnlock() {
        PrivateBrowsingAuthenticator.shared.authenticate(
            reason: NSLocalizedString("Authenticate to view your private tabs", comment: "")
        ) { [weak self] result in
            switch result {
            case .success, .unavailable:
                self?.dismissLockScreen(unlocked: true)
            case .cancelled, .failed:
                // Leave the lock screen up; the user can retry with the
                // button or switch to their regular tabs instead.
                break
            }
        }
    }

    private func switchToRegularTabsAndDismissLock() {
        if tabManager.regularTabs.isEmpty {
            tabManager.addTab(selecting: true, windowId: nil, at: nil, isPrivate: false)
        } else {
            tabManager.selectTab(at: 0, mode: .regular)
        }
        dismissLockScreen(unlocked: true)
    }

    private func dismissLockScreen(unlocked: Bool) {
        isLocked = !unlocked
        presentedLockViewController?.dismiss(animated: true)
        presentedLockViewController = nil
    }
}
