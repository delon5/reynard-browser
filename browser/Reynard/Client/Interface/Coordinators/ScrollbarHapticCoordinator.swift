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
/// This class ALSO approximates the same thing by POSITION - a vertical
/// drag of dragActivationThreshold beginning within edgeStripWidth of
/// the right edge - because the engine signal above is not currently
/// arriving (see 0ec7277: with the heuristic removed there was no buzz
/// at all, so the heuristic is the whole working feature today). It
/// still buzzes on ordinary scrolling near the right edge; the 14pt
/// threshold mitigates that, it does not fix it. The real fix remains
/// finding why GeckoView:ScrollbarTouchBegin never reaches
/// activateFromEngineSignal - and the moment it does,
/// engineSignalObserved silences the heuristic for good, so the
/// accurate signal and the guess can never buzz the same grab twice.
///
/// The recognizer stays, doing nothing but spinning up the taptic engine
/// on a touch-down near the edge so the engine signal's buzz lands with
/// no latency. It never consumes or cancels touches -
/// `cancelsTouchesInView = false` and simultaneous recognition are both
/// enabled, so the page's own scrolling is never interfered with.
final class ScrollbarHapticCoordinator: NSObject {
    private enum UX {
        /// Width of the strip along the right edge in which a touch is
        /// worth warming the taptic engine for. Not an activation test -
        /// nothing fires from position any more - just where a real
        /// thumb grab is about to happen if one happens at all.
        static let edgeStripWidth: CGFloat = 24
        /// Vertical movement (points) before a touch in the strip counts
        /// as a scrollbar grab. Larger than the original 6: that fired on
        /// ordinary scrolling near the right edge, which is most
        /// scrolling.
        static let dragActivationThreshold: CGFloat = 14
    }
    
    /// Consulted on every touch-down within the strip. Return `false`
    /// during fullscreen media, or whenever there's no real page content
    /// to have a scrollbar at all (e.g. the homepage) — matches
    /// ScrollChromeCoordinator's own isEnabled pattern.
    var isEnabled: () -> Bool = { true }
    
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    /// Set on touch-down inside the strip, cleared once the haptic has
    /// fired or the touch ends. Non-nil means armed.
    private var pendingActivationStart: CGPoint?
    /// Latched the first time the engine's thumb hit test delivers.
    /// From then on the position heuristic stays silent: the engine
    /// signal is pixel-accurate and fires at touch-down, so letting
    /// the heuristic fire too would buzz the same grab twice, ~14pt
    /// apart. The latch 8b07bbf removed along with the heuristic;
    /// 0ec7277 restored the heuristic without it.
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
        // The engine's verdict supersedes the heuristic: disarm the
        // touch in flight and silence the heuristic from here on, so
        // one grab can never buzz twice.
        engineSignalObserved = true
        pendingActivationStart = nil
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
            pendingActivationStart = nil
            feedbackGenerator.impactOccurred()

        default:
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
