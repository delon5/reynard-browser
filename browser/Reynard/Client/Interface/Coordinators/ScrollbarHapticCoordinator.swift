//
//  ScrollbarHapticCoordinator.swift
//  Reynard
//

import UIKit

/// Fires a light haptic the moment a touch begins near the right edge of
/// the content view, approximating "grabbing the page's own scrollbar
/// thumb" — matching the same feel as tapping a toolbar button.
///
/// GeckoView's Swift bridge exposes no way to know where a page's own
/// scrollbar actually renders, or whether a touch landed on it
/// specifically (see ScrollChromeCoordinator's own doc comment for the
/// same underlying limitation) — so, like that coordinator, this
/// approximates by position instead: a touch beginning within a narrow
/// strip along the right edge, where a scrollbar thumb conventionally
/// sits. It intentionally does **not** consume or cancel touches —
/// `cancelsTouchesInView = false` and simultaneous recognition are both
/// enabled, so the page's own scrolling is never interfered with; this
/// recognizer only ever *observes* the same touch.
final class ScrollbarHapticCoordinator: NSObject {
    private enum UX {
        /// Width of the touch strip along the right edge, in points.
        /// Wide enough to reliably catch a deliberate scrollbar grab,
        /// narrow enough to avoid firing on ordinary taps/scrolls
        /// elsewhere in the content.
        static let edgeStripWidth: CGFloat = 24
        /// Vertical movement (points) that turns a touch-down in the
        /// strip into an "activated the scrollbar" drag. Small enough
        /// to feel instant on a real grab, large enough that a plain
        /// tap's jitter never crosses it.
        static let dragActivationThreshold: CGFloat = 6
    }
    
    /// Consulted on every touch-down within the strip. Return `false`
    /// during fullscreen media, or whenever there's no real page content
    /// to have a scrollbar at all (e.g. the homepage) — matches
    /// ScrollChromeCoordinator's own isEnabled pattern.
    var isEnabled: () -> Bool = { true }
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    /// Set on touch-down inside the strip, cleared once the haptic has
    /// fired (or the touch ends without dragging). Non-nil means armed.
    private var pendingActivationStart: CGPoint?
    /// Latched the first time the engine's scrollbar-touch event
    /// arrives. From then on the drag heuristic in handleTouch stays
    /// silent: the engine signal is the compositor's own thumb hit
    /// test - pixel-accurate and earlier - and double-buzzing is worse
    /// than either signal alone. The heuristic remains as the fallback
    /// for builds whose engine predates the APZCTreeManager haptics
    /// patch.
    private var engineSignalObserved = false

    /// The pixel-perfect activation. Chain: APZ thumb hit test
    /// (APZCTreeManager patch) -> "reynard-scrollbar-touch-begin"
    /// observer topic -> GeckoViewStartup relay ->
    /// GeckoView:ScrollbarTouchBegin ->
    /// GeckoRuntime.setScrollbarTouchBeginHandler -> here, on main.
    func activateFromEngineSignal() {
        guard isEnabled() else {
            return
        }
        engineSignalObserved = true
        pendingActivationStart = nil
        // Usually already prepared by the .began arm below (a thumb
        // grab necessarily begins inside the strip); preparing again
        // is a cheap no-op that covers the remaining cases.
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
    }
    
    /// Attaches the observing gesture recognizer to `view` (typically the
    /// content view hosting the web page). Safe to call once.
    func attach(to view: UIView) {
        // minimumPressDuration = 0 is the standard way to detect a touch
        // beginning immediately via a gesture recognizer, since UIKit has
        // no dedicated "touch down" recognizer of its own.
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleTouch(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
    }
    
    @objc private func handleTouch(_ recognizer: UILongPressGestureRecognizer) {
        guard let view = recognizer.view else {
            return
        }

        switch recognizer.state {
        case .began:
            guard isEnabled() else {
                return
            }
            let location = recognizer.location(in: view)
            guard location.x >= view.bounds.width - UX.edgeStripWidth else {
                return
            }
            // Arm, and spin the taptic engine up NOW - so when the drag
            // engages a few points later the tick lands with zero
            // latency - but do not fire yet: a bare touch-down in the
            // strip is just as likely a tap on nearby content, and the
            // buzz is meant to say "you have activated the scrollbar",
            // which only a drag demonstrates.
            pendingActivationStart = location
            feedbackGenerator.prepare()

        case .changed:
            guard !engineSignalObserved, let start = pendingActivationStart else {
                return
            }
            let location = recognizer.location(in: view)
            guard abs(location.y - start.y) >= UX.dragActivationThreshold else {
                return
            }
            // The touch is dragging vertically from inside the strip -
            // the closest observable signal to "the scrollbar thumb
            // engaged" (see this file's fix script docstring for why
            // the compositor's own thumb-drag state is not reachable).
            // Fire once per touch.
            pendingActivationStart = nil
            feedbackGenerator.impactOccurred()

        default:
            // Ended, cancelled, or failed without ever dragging: an
            // edge tap. Disarm silently - no buzz for taps.
            pendingActivationStart = nil
        }
    }
}

extension ScrollbarHapticCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Always recognize alongside whatever GeckoView's own touch
        // handling (or ScrollChromeCoordinator's own pan recognizer) is
        // doing — this recognizer never wins exclusivity and never
        // cancels the page's native scroll/zoom gestures.
        return true
    }
}
