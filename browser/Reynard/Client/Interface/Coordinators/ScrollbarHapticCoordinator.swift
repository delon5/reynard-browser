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
    }
    
    /// Consulted on every touch-down within the strip. Return `false`
    /// during fullscreen media, or whenever there's no real page content
    /// to have a scrollbar at all (e.g. the homepage) — matches
    /// ScrollChromeCoordinator's own isEnabled pattern.
    var isEnabled: () -> Bool = { true }
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    
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
        guard recognizer.state == .began, isEnabled(), let view = recognizer.view else {
            return
        }
        
        let location = recognizer.location(in: view)
        guard location.x >= view.bounds.width - UX.edgeStripWidth else {
            return
        }
        
        // Prepare right before firing, not earlier — keeps the taptic
        // engine from staying spun up between touches for no reason.
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
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
