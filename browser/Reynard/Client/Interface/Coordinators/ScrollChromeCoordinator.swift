//
//  ScrollChromeCoordinator.swift
//  Reynard
//

import UIKit

/// Condenses the browser chrome (top/bottom toolbars) into a small
/// floating pill on a downward scroll and expands it back on an upward
/// one, Safari-style.
///
/// GeckoView's Swift bridge doesn't expose real scroll-offset/direction
/// callbacks from the page content (`ContentDelegate.onShowDynamicToolbar`
/// exists but is never actually wired to a native event in this fork —
/// see the corresponding gap in `ContentEvents`). Lacking that, this
/// approximates scroll direction with a `UIPanGestureRecognizer` layered
/// over the content view, tracking net vertical drag since the last
/// condense/expand decision. It intentionally does **not** consume or
/// cancel touches — `cancelsTouchesInView = false` and simultaneous
/// recognition are both enabled, so the page's own scrolling is never
/// interfered with; this recognizer only ever *observes* the same drag.
final class ScrollChromeCoordinator: NSObject {
    private enum UX {
        /// Net vertical drag (points) required to flip from expanded to
        /// condensed, or vice versa. Small back-and-forth jitter within
        /// this threshold doesn't cause flicker, since only net movement
        /// since the last decision counts.
        static let decisionThreshold: CGFloat = 40
    }
    
    private weak var browserChrome: BrowserChrome?
    private var lastDecisionTranslationY: CGFloat = 0
    
    /// Consulted on every gesture update. Return `false` while search is
    /// focused, tab overview is presented, fullscreen media is active,
    /// etc. — scroll-driven condensing only makes sense during plain page
    /// browsing.
    var isEnabled: () -> Bool = { true }
    
    /// Consulted before an EXPAND decision. While a pull-to-refresh
    /// drag is held, expanding mid-gesture re-anchors the content
    /// view un-animated and flips the dynamic-toolbar max from 0 to
    /// the full toolbar height - a real ICB resize and reflow under
    /// the user's finger. The pull survives (its engine approval is
    /// latched per touch sequence) but the page visibly jolts, and
    /// the refresh threshold (350pt) sits far past the 40pt decision
    /// threshold, so every refresh-strength pull from the condensed
    /// pill would cross this. The expand is deferred to the end of
    /// the gesture instead. Condensing needs no gate: it requires an
    /// UPWARD drag, which cannot co-occur with a downward pull.
    var isPullToRefreshActive: () -> Bool = { false }
    /// An expand decision that fired mid-pull and is waiting for the
    /// gesture to end.
    private var hasDeferredExpand = false
    
    init(browserChrome: BrowserChrome) {
        self.browserChrome = browserChrome
        super.init()
    }
    
    /// Attaches the observing pan gesture to `view` (typically the
    /// content view hosting the web page). Safe to call once.
    func attach(to view: UIView) {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
    }
    
    /// Forces the chrome back to its expanded state, e.g. after
    /// navigating to a new page or switching tabs, so a condensed state
    /// never persists somewhere it wouldn't make sense.
    func resetVisible(animated: Bool = false) {
        browserChrome?.setScrollCondensed(false, animated: animated)
    }
    
    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let browserChrome else {
            return
        }
        
        switch recognizer.state {
        case .began:
            lastDecisionTranslationY = recognizer.translation(in: recognizer.view).y
            hasDeferredExpand = false
        case .changed:
            guard isEnabled() else {
                return
            }
            
            let currentTranslationY = recognizer.translation(in: recognizer.view).y
            let netMovement = currentTranslationY - lastDecisionTranslationY
            
            // Dragging up (finger moves toward the top, negative
            // translation) is scrolling the page content down.
            if netMovement <= -UX.decisionThreshold, !browserChrome.isScrollCondensed {
                browserChrome.setScrollCondensed(true, animated: true)
                lastDecisionTranslationY = currentTranslationY
            } else if netMovement >= UX.decisionThreshold, browserChrome.isScrollCondensed {
                if isPullToRefreshActive() {
                    // Not while a finger is holding a pull - remember
                    // the decision and act on it at gesture end.
                    hasDeferredExpand = true
                } else {
                    browserChrome.setScrollCondensed(false, animated: true)
                }
                lastDecisionTranslationY = currentTranslationY
            }
        case .ended, .cancelled, .failed:
            guard hasDeferredExpand else {
                break
            }
            hasDeferredExpand = false
            // The finger is up. If the pull triggered a reload, the
            // navigation reset expands the chrome anyway - both
            // paths funnel through setScrollCondensed's state guard,
            // so they compose idempotently. If the pull was
            // cancelled, this honors the drag-down-to-expand the
            // user performed, now that the resize cannot land under
            // a held pull.
            if isEnabled(), browserChrome.isScrollCondensed {
                browserChrome.setScrollCondensed(false, animated: true)
            }
        default:
            break
        }
    }
}

extension ScrollChromeCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Always recognize alongside whatever GeckoView's own touch
        // handling is doing — this recognizer never wins exclusivity and
        // never cancels the page's native scroll/zoom gestures.
        return true
    }
}
