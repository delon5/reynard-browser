//
//  ScrollbarTouchEvents.swift
//  Reynard
//
//  Embedder surface for the engine's scrollbar-thumb touch signal.
//  APZ hit-tests every touch against the compositor's scrollthumb
//  nodes (that is how async thumb dragging works at all); the Reynard
//  APZCTreeManager patch relays a thumb hit as an observer topic,
//  GeckoViewStartup turns it into "GeckoView:ScrollbarTouchBegin",
//  and this listener hands it to the app on the main thread.
//

import Foundation

final class ScrollbarTouchListener: GeckoEventListenerInternal {
    static let shared = ScrollbarTouchListener()

    private var isRegistered = false
    private var handler: (() -> Void)?

    @MainActor
    func handleMessage(type: String, message: [String: Any?]?) async throws -> Any? {
        handler?()
        return nil
    }

    func install(_ handler: (() -> Void)?) {
        self.handler = handler
        guard handler != nil, !isRegistered else {
            return
        }
        isRegistered = true
        GeckoEventDispatcherWrapper.runtimeInstance.addListener(
            type: "GeckoView:ScrollbarTouchBegin",
            listener: self
        )
    }
}

extension GeckoRuntime {
    /// Called on the main thread the moment a touch lands on a page's
    /// scrollbar thumb - the compositor's own hit test, not a
    /// position heuristic. Pass nil to stop receiving it.
    public static func setScrollbarTouchBeginHandler(_ handler: (() -> Void)?) {
        ScrollbarTouchListener.shared.install(handler)
    }
}
