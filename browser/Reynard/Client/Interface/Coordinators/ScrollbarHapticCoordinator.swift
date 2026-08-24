//
//  ScrollbarHapticCoordinator.swift
//  Reynard
//

import UIKit

/// Fires a light haptic when the page's own scrollbar thumb is actually
/// grabbed — the buzz means "you have the scrollbar", so it has to be
/// true.
///
/// The signal is the compositor's own thumb hit test, which is
/// pixel-accurate: APZ thumb hit -> "reynard-scrollbar-touch-begin"
/// observer -> GeckoViewStartup relay -> GeckoView:ScrollbarTouchBegin
/// -> activateFromEngineSignal below.
///
/// History: the engine signal originally never arrived - APZ runs in
/// the GPU process on iOS and notified an observer service no one in
/// that process listened to - so a position heuristic (a 14pt drag
/// starting within 24pt of the right edge) carried the feature and
/// buzzed on ordinary edge scrolling. The signal now crosses on the
/// UiCompositorController channel (device-confirmed 2026-08-24, the
/// full ladder), and the heuristic is gone: the haptic region IS the
/// compositor's thumb hit target, exactly.
///
/// The recognizer stays, doing nothing but spinning up the taptic engine
/// on a touch-down near the edge so the engine signal's buzz lands with
/// no latency. It never consumes or cancels touches -
/// `cancelsTouchesInView = false` and simultaneous recognition are both
/// enabled, so the page's own scrolling is never interfered with.
final class ScrollbarHapticCoordinator: NSObject {
    private enum UX {
        /// Width of the strip along the right edge in which a touch-down
        /// pre-warms the taptic engine. Not an activation test - nothing
        /// fires from position - just where a real thumb grab is about
        /// to happen if one happens at all.
        static let edgeStripWidth: CGFloat = 24
    }
    
    /// Consulted on every touch-down within the strip. Return `false`
    /// during fullscreen media, or whenever there's no real page content
    /// to have a scrollbar at all (e.g. the homepage) — matches
    /// ScrollChromeCoordinator's own isEnabled pattern.
    var isEnabled: () -> Bool = { true }
    
    /// The one haptic source: prepared on any touch-down inside the
    /// strip, fired only by activateFromEngineSignal.
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    /// The pixel-perfect activation. Chain: APZ thumb hit test
    /// (APZCTreeManager patch) -> "reynard-scrollbar-touch-begin"
    /// observer topic -> GeckoViewStartup relay ->
    /// GeckoView:ScrollbarTouchBegin ->
    /// GeckoRuntime.setScrollbarTouchBeginHandler -> here, on main.
    func activateFromEngineSignal() {
        guard isEnabled() else {
            return
        }
        // scrollbarHaptic trace.
        NSLog("scrollbarHaptic: engine haptic (thumb grab)")
        // Usually already prepared by the touch-down below (a thumb grab
        // necessarily begins inside the strip); preparing again is a
        // cheap no-op that covers the remaining cases.
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
            // Pre-warm only: the haptic itself fires from
            // activateFromEngineSignal - the compositor's own thumb
            // hit test, routed from the GPU process (device-proven) -
            // never from touch position. No .changed case: the
            // edge-strip drag heuristic is gone for good.
            feedbackGenerator.prepare()

        default:
            break
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
