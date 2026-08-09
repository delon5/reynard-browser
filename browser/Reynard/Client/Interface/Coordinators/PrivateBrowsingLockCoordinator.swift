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

    /// One authentication at a time. LAContext cancels an in-flight
    /// evaluation when a new one starts, so overlapping requests cancel
    /// each other and produce a prompt that reappears after succeeding.
    /// The log showed five Face ID requests in three seconds, two of them
    /// overlapping, with a "cancelled" that was one evaluation being
    /// killed by the next.
    private var isAuthenticating = false
    
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
            // Only worth attention when locked=YES, which means a
            // curtain is up with nothing on top that can authenticate.
            // locked=NO is the ordinary case.
            logger(String(format: "privateLock: presentLockIfNeeded returned early (locked=%@)", isLocked ? "YES - CURTAIN STAYS UP" : "NO - nothing locked"))
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

        // Presenting on a controller that is already presenting something
        // is a silent no-op in UIKit, and the log caught exactly that:
        // hostAlreadyPresenting=Optional<UIViewController>. The lock never
        // appeared, but presentedLockViewController was assigned anyway, so
        // every later presentLockIfNeeded returned early on the belief that
        // a lock was up - the state that needs a force quit to clear. Walk
        // to the topmost presented controller so the presentation actually
        // happens.
        var presenter: UIViewController = host
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        if presenter !== host {
            logger(String(
                format: "privateLock: presenting on top of %@ rather than the host",
                String(describing: type(of: presenter))
            ))
        }

        // Assigned BEFORE the present call, not inside its completion.
        // This property is the guard above that refuses a second
        // presentation, and the completion does not run until the
        // animation finishes - assigning it there would leave a window of
        // a few hundred milliseconds in which a second call sees nil and
        // presents a second lock screen. The completion instead CLEARS it
        // if the presentation turned out not to take, which covers the
        // stale-state case without opening the double-present one.
        presentedLockViewController = lockViewController
        presenter.present(lockViewController, animated: animated) { [weak self, weak lockViewController] in
            guard let self, let lockViewController else {
                return
            }
            guard lockViewController.presentingViewController != nil else {
                logger("privateLock: presentation did not take - clearing the recorded lock")
                self.presentedLockViewController = nil
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
        // hasRequestedAutomaticUnlock only covers the view controller's own
        // automatic request; the manual button, a re-presentation and a
        // foreground can each start another concurrently.
        guard !isAuthenticating else {
            logger("privateLock: authenticate SKIPPED - one is already in flight")
            return
        }
        isAuthenticating = true
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
            // Cleared on every result. PrivateBrowsingAuthenticator invokes
            // its completion on all four paths (unavailable, success,
            // cancelled, failed), so this cannot latch on.
            self?.isAuthenticating = false
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
