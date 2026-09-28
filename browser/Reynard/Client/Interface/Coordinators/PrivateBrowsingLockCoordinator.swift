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
    /// Whether the last selection noteTabSelection saw was a private
    /// tab - see fix_private_lock_covers_every_route_into_private_tabs.py.
    private var wasOnPrivateTabs = false
    private var presentedLockViewController: PrivateBrowsingLockViewController?
    /// The dismissal in flight, by serial number - see
    /// fix_private_lock_dismisses_via_presenter.py. Its completion and
    /// its fallback timer both try to settle it; the first to run wins.
    private var lockDismissalInFlight: Int?
    private var lockDismissalSerial = 0
    /// A lock was asked for while the previous one was still leaving -
    /// review amendment to fix_private_lock_dismisses_via_presenter.py.
    /// The recorded lock is kept until its dismissal settles, so
    /// presentLockScreen would otherwise read it as "already up" and
    /// present nothing; settleLockDismissal presents it instead.
    private var lockWantedDuringDismissal = false

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
        // Locked whenever protection is on, not only when the app opens
        // onto private tabs: a session that starts on regular tabs is
        // otherwise never locked, and its private tabs are one last-tab
        // close away. Presentation stays gated on being on private tabs.
        // See fix_private_lock_covers_every_route_into_private_tabs.py.
        guard isProtectionEnabled else {
            return
        }
        wasOnPrivateTabs = isEffectivelyOnPrivateTabs
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

    /// Every tab selection passes through here, from the chrome's
    /// didSelectTabAt - see
    /// fix_private_lock_covers_every_route_into_private_tabs.py. The tab
    /// manager reaches a private tab on its own when the last regular tab
    /// closes or all of them are cleared, and nothing asked for Face ID on
    /// the way; the overview's route authenticates first, which clears
    /// the lock, so its selection presents nothing here. Leaving private
    /// tabs re-arms the lock for the next way back in.
    func noteTabSelection() {
        guard isProtectionEnabled else {
            wasOnPrivateTabs = false
            return
        }
        let onPrivateTabs = tabManager.selectedTabMode == .private
        defer {
            wasOnPrivateTabs = onPrivateTabs
        }
        guard onPrivateTabs else {
            if wasOnPrivateTabs {
                isLocked = true
            }
            return
        }
        // A lock that is on its way out does not count as up: the curtain
        // goes up now and presentLockScreen defers the new lock until the
        // old one is gone.
        guard isLocked, presentedLockViewController == nil || lockDismissalInFlight != nil else {
            return
        }
        guard host?.viewIfLoaded?.window != nil else {
            // Not on screen yet (launch): presentLockIfNeeded runs at
            // didBecomeActive with the lock still armed.
            return
        }
        logger("privateLock: selection landed on private tabs while locked - presenting")
        showPrivacyCurtain()
        presentLockIfNeeded(animated: false)
    }

    private func presentLockScreen(animated: Bool) {
        guard let host else {
            logger("privateLock: presentLockScreen SKIPPED - host is nil")
            return
        }
        guard presentedLockViewController == nil else {
            if lockDismissalInFlight != nil {
                // Presenting over a lock mid-dismissal would be refused;
                // settleLockDismissal presents once it has gone.
                lockWantedDuringDismissal = true
                logger("privateLock: presentLockScreen DEFERRED - the previous lock is still being dismissed")
                return
            }
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
        // STILL LOCKED: nothing was authenticated. The lock screen and the
        // curtain go because regular tabs are now on screen. See
        // fix_private_lock_covers_every_route_into_private_tabs.py.
        dismissPresentedLock(animated: true)
        hidePrivacyCurtain()
        isLocked = true
    }

    private func dismissLockScreen(unlocked: Bool) {
        os_log("dismissLockScreen: unlocked=%{public}@", log: lockLog, type: .debug, String(unlocked))
        isLocked = !unlocked
        dismissPresentedLock(animated: true)
        if unlocked {
            hidePrivacyCurtain()
        }
    }

    /// Dismisses the lock from its PRESENTER and forgets it only once it
    /// is gone. ADDED - see fix_private_lock_dismisses_via_presenter.py.
    ///
    /// `presentedLockViewController?.dismiss(animated:)` asks the lock to
    /// dismiss itself - unless something has been presented ON the lock,
    /// in which case UIKit dismisses that child and leaves the lock where
    /// it is. Capture 2026-09-28 15:54:37: a JIT attach failed while the
    /// lock was mid-presentation, the "Failed to enable JIT" sheet landed
    /// on the topmost controller - the lock - and the first Face ID
    /// success dismissed the sheet, then set the reference to nil. The
    /// lock stayed up with no owner; five more successes dismissed
    /// nothing. Dismissing from the presenter takes the lock and
    /// everything above it, and the reference survives until the
    /// dismissal is settled - so a refused one is retried, here once the
    /// blocking transition has finished and again on the next unlock,
    /// instead of being forgotten.
    private func dismissPresentedLock(animated: Bool, attempt: Int = 0) {
        guard let lockViewController = presentedLockViewController else {
            return
        }
        guard let presenter = lockViewController.presentingViewController else {
            logger("privateLock: lock is not presented - clearing the recorded lock")
            presentedLockViewController = nil
            return
        }
        lockDismissalSerial += 1
        let serial = lockDismissalSerial
        lockDismissalInFlight = serial
        logger(String(
            format: "privateLock: dismissing the lock via its presenter (lockHasChild=%@, attempt %ld)",
            lockViewController.presentedViewController != nil ? "YES" : "NO",
            attempt
        ))
        presenter.dismiss(animated: animated) { [weak self] in
            self?.settleLockDismissal(serial: serial, of: lockViewController, animated: animated, attempt: attempt)
        }
        // UIKit does not run the completion of a dismissal it declines
        // (another transition in progress), so a timer judges it too.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(animated ? 700 : 100)) { [weak self] in
            self?.settleLockDismissal(serial: serial, of: lockViewController, animated: animated, attempt: attempt)
        }
    }

    private func settleLockDismissal(
        serial: Int,
        of lockViewController: PrivateBrowsingLockViewController,
        animated: Bool,
        attempt: Int
    ) {
        guard lockDismissalInFlight == serial else {
            return
        }
        lockDismissalInFlight = nil
        let lockWasWanted = lockWantedDuringDismissal
        lockWantedDuringDismissal = false
        guard presentedLockViewController === lockViewController else {
            return
        }
        guard lockViewController.presentingViewController != nil else {
            logger("privateLock: lock dismissed")
            presentedLockViewController = nil
            if lockWasWanted {
                // presentLockIfNeeded re-checks locked / protection / on
                // private tabs, so a request that no longer applies - the
                // user left private tabs meanwhile - presents nothing.
                logger("privateLock: a lock was requested while this one was leaving - presenting it now")
                presentLockIfNeeded(animated: false)
            }
            return
        }
        if lockWasWanted {
            // UIKit refused the dismissal, and a lock is wanted again
            // anyway: this one stays, and no retry takes it down.
            logger("privateLock: lock STILL presented and wanted again - keeping it")
            return
        }
        // Still up: UIKit declined. The reference stays so the next unlock
        // retries; retry here as well once the transition that blocked it
        // has had time to finish - three attempts at most.
        logger(String(format: "privateLock: lock STILL presented after dismiss (attempt %ld)", attempt))
        guard attempt < 2 else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) { [weak self] in
            self?.dismissPresentedLock(animated: animated, attempt: attempt + 1)
        }
    }
}
