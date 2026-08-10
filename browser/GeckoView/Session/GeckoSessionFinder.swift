//
//  GeckoSessionFinder.swift
//  Reynard
//
//  Find-in-page over the session dispatcher. The engine side is the
//  stock GeckoViewContent module (mobile/shared, Firefox 153), which
//  handles GeckoView:FindInPage / ClearMatches / DisplayMatches with
//  toolkit's Finder - the same machinery Android's SessionFinder
//  drives. Nothing here is Reynard-patched engine behaviour; only this
//  Swift surface was missing.
//

import CoreGraphics
import Foundation

public struct FindInPageResult {
    public let found: Bool
    public let wrapped: Bool
    public let current: Int
    public let total: Int
    /// The match's bounds in CLIENT coordinates - relative to the visual
    /// viewport, in CSS pixels. Nil when the engine reported no rect.
    ///
    /// Needed because the engine's own scroll-into-view moves the LAYOUT
    /// viewport, and with APZ holding the visual viewport separately that
    /// does not move what is on screen: the selection steps through
    /// matches while the page stays put. Scrolling to this rect through
    /// GeckoView:ScrollBy - which goes via scrollToVisual with
    /// UPDATE_TYPE_MAIN_THREAD - is what actually moves the view.
    public let clientRect: CGRect?

    init(response: Any?) {
        let dictionary = response as? [String: Any] ?? [:]
        found = dictionary["found"] as? Bool ?? false
        wrapped = dictionary["wrapped"] as? Bool ?? false
        current = dictionary["current"] as? Int ?? 0
        total = dictionary["total"] as? Int ?? -1

        if let rect = dictionary["clientRect"] as? [String: Any],
           let left = rect["left"] as? Double,
           let top = rect["top"] as? Double,
           let right = rect["right"] as? Double,
           let bottom = rect["bottom"] as? Double {
            clientRect = CGRect(x: left, y: top,
                                width: right - left, height: bottom - top)
        } else {
            clientRect = nil
        }
    }
}

extension GeckoSession {
    /// Finds `searchString` in the page, moving the selection to the
    /// next match (or previous, with backwards: true). Repeated calls
    /// with the same string step through matches; the engine wraps at
    /// the ends and reports it in the result.
    public func findInPage(
        _ searchString: String,
        backwards: Bool = false,
        matchCase: Bool = false,
        wholeWord: Bool = false,
        linksOnly: Bool = false
    ) async throws -> FindInPageResult {
        let response = try await dispatcher.query(
            type: "GeckoView:FindInPage",
            message: [
                "searchString": searchString,
                "backwards": backwards,
                "matchCase": matchCase,
                "wholeWord": wholeWord,
                "linksOnly": linksOnly,
            ]
        )
        return FindInPageResult(response: response)
    }

    /// Turns match highlighting on or off for the current search.
    public func displayMatches(highlightAll: Bool) {
        dispatcher.dispatch(
            type: "GeckoView:DisplayMatches",
            message: ["highlightAll": highlightAll]
        )
    }

    /// Clears the current search's highlights and selection.
    public func clearMatches() {
        dispatcher.dispatch(type: "GeckoView:ClearMatches")
    }
}
