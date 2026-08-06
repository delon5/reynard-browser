//
//  PrivateBrowsingLockCoordinator.swift
//  Reynard
//

import UIKit
import os

private let lockLog = OSLog(subsystem: "com.minh-ton.Reynard", category: "PrivateLockDebug")

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
    
    /// A simple, non-interactive curtain shown the instant locking
    /// begins and kept up until real, successful authentication — not
    /// tied to any scene-lifecycle timing, and never itself a presented
    /// view controller, which is what made the earlier, broken attempt
    /// at this unreliable. Adding a plain subview to an already-stable
    /// window doesn't carry the same presentation-timing hazards.
    private lazy var privacyCurtain: UIView = {
        let view = UIView()
        view.backgroundColor = .appBackground
        let imageView = UIImageView(image: UIImage(systemName: "lock.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }()

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
        guard isProtectionEnabled, isEffectivelyOnPrivateTabs else {
            return
        }
        isLocked = true
    }

    /// Call when the app is about to leave the foreground (backgrounding,
    /// or about to be suspended).
    func lockIfNeeded() {
        os_log("lockIfNeeded called, isProtectionEnabled=%{public}@, mode=%{public}@, tabOverviewMode=%{public}@", log: lockLog, type: .debug, String(isProtectionEnabled), String(describing: tabManager.selectedTabMode), String(describing: host?.tabOverview.mode))
        guard isProtectionEnabled, isEffectivelyOnPrivateTabs else {
            return
        }
        isLocked = true
        os_log("lockIfNeeded: isLocked=true, showing curtain", log: lockLog, type: .debug)
        showPrivacyCurtain()
    }
    
    /// True if either the actual selected tab is private, or the tab
    /// switcher is currently displaying the private side — even if
    /// nothing has actually been tapped into yet. Switching the tab
    /// switcher's own display to the private side does NOT, on its own,
    /// change tabManager.selectedTabMode at all — that only updates once
    /// a specific tab is actually selected — so relying on
    /// selectedTabMode alone misses the case where private tab titles
    /// and thumbnails are visibly on screen in the switcher itself, with
    /// nothing yet selected.
    private var isEffectivelyOnPrivateTabs: Bool {
        return tabManager.selectedTabMode == .private || host?.tabOverview.mode == .privateTabs
    }
    
    private func showPrivacyCurtain() {
        guard let window = host?.view.window else {
            logger("privateLock: showPrivacyCurtain SKIPPED - host has no window")
            return
        }
        guard privacyCurtain.superview == nil else {
            logger("privateLock: showPrivacyCurtain SKIPPED - curtain already up")
            return
        }
        privacyCurtain.frame = window.bounds
        window.addSubview(privacyCurtain)
        logger(String(
            format: "privateLock: curtain ADDED as window subview %ld of %ld",
            window.subviews.firstIndex(of: privacyCurtain) ?? -1,
            window.subviews.count
        ))
        // Force the curtain to actually render immediately, rather than
        // leaving it to UIKit's normal, deferred layout pass. Without
        // this, the system's app-switcher snapshot can be captured
        // before the curtain has genuinely been drawn to screen, even
        // though it was already added here in code — resulting in the
        // snapshot still showing the real page underneath.
        window.layoutIfNeeded()
    }
    
    private func hidePrivacyCurtain() {
        logger(String(format: "privateLock: curtain REMOVED (wasUp=%@)", privacyCurtain.superview != nil ? "YES" : "NO"))
        privacyCurtain.removeFromSuperview()
    }

    /// Call when the app becomes visible again (foreground, or right after
    /// the initial tab is created on launch). Presents the lock screen if
    /// needed; otherwise does nothing.
    func presentLockIfNeeded(animated: Bool) {
        os_log("presentLockIfNeeded called, isLocked=%{public}@, alreadyPresented=%{public}@", log: lockLog, type: .debug, String(isLocked), String(presentedLockViewController != nil))
        logger(String(
            format: "privateLock: presentLockIfNeeded locked=%@ protectionOn=%@ onPrivate=%@ selectedMode=%@ overviewMode=%@ alreadyPresented=%@ curtainUp=%@ hostPresenting=%@",
            isLocked ? "YES" : "NO",
            isProtectionEnabled ? "YES" : "NO",
            isEffectivelyOnPrivateTabs ? "YES" : "NO",
            String(describing: tabManager.selectedTabMode),
            String(describing: host?.tabOverview.mode),
            presentedLockViewController != nil ? "YES" : "NO",
            privacyCurtain.superview != nil ? "YES" : "NO",
            String(describing: type(of: host?.presentedViewController))
        ))
        guard isLocked, isProtectionEnabled, isEffectivelyOnPrivateTabs else {
            logger("privateLock: presentLockIfNeeded RETURNED EARLY - curtain stays up with no lock screen")
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
                self?.hidePrivacyCurtain()
                completion(true)
            case .cancelled, .failed:
                completion(false)
            }
        }
    }

    // MARK: - Lock Screen

    private func presentLockScreen(animated: Bool) {
        guard let host else {
            logger("privateLock: presentLockScreen SKIPPED - host is nil")
            return
        }
        guard presentedLockViewController == nil else {
            logger(String(
                format: "privateLock: presentLockScreen SKIPPED - already presented (onScreen=%@)",
                presentedLockViewController?.viewIfLoaded?.window != nil ? "YES" : "NO"
            ))
            return
        }
        logger(String(
            format: "privateLock: presentLockScreen presenting (hostInWindow=%@ hostAlreadyPresenting=%@)",
            host.viewIfLoaded?.window != nil ? "YES" : "NO",
            String(describing: type(of: host.presentedViewController))
        ))

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
        host.present(lockViewController, animated: animated) { [weak self, weak lockViewController] in
            guard let self, let lockViewController else {
                return
            }
            let window = lockViewController.viewIfLoaded?.window
            let lockIndex = window.flatMap { w in
                lockViewController.viewIfLoaded.flatMap { w.subviews.firstIndex(of: $0) }
            } ?? -1
            let curtainIndex = window.flatMap { w in
                w.subviews.firstIndex(of: self.privacyCurtain)
            } ?? -1
            logger(String(
                format: "privateLock: presented onScreen=%@ lockIndex=%ld curtainIndex=%ld curtainCoversLock=%@",
                window != nil ? "YES" : "NO",
                lockIndex,
                curtainIndex,
                (curtainIndex >= 0 && curtainIndex > lockIndex) ? "YES" : "NO"
            ))
        }
    }

    private func authenticateAndUnlock() {
        logger("privateLock: authenticate requested")
        os_log("authenticateAndUnlock: starting authentication request", log: lockLog, type: .debug)
        PrivateBrowsingAuthenticator.shared.authenticate(
            reason: NSLocalizedString("Authenticate to view your private tabs", comment: "")
        ) { [weak self] result in
            os_log("authenticateAndUnlock: result=%{public}@", log: lockLog, type: .debug, String(describing: result))
            var detail = String(describing: result)
            if case .failed(let error) = result, let nsError = error as NSError? {
                detail += String(format: " domain=%@ code=%ld", nsError.domain, nsError.code)
            }
            logger("privateLock: authenticate result " + detail)
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
        os_log("dismissLockScreen: unlocked=%{public}@", log: lockLog, type: .debug, String(unlocked))
        isLocked = !unlocked
        presentedLockViewController?.dismiss(animated: true)
        presentedLockViewController = nil
        if unlocked {
            hidePrivacyCurtain()
        }
    }
}
