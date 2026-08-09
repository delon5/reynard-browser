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

import Foundation

public struct FindInPageResult {
    public let found: Bool
    public let wrapped: Bool
    public let current: Int
    public let total: Int

    init(response: Any?) {
        let dictionary = response as? [String: Any] ?? [:]
        found = dictionary["found"] as? Bool ?? false
        wrapped = dictionary["wrapped"] as? Bool ?? false
        current = dictionary["current"] as? Int ?? 0
        total = dictionary["total"] as? Int ?? -1
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
