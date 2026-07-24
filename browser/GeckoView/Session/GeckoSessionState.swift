//
//  GeckoSessionState.swift
//  Reynard
//
//  Represents a saved GeckoSession state (navigation history, scroll
//  position, and form data) that can be persisted to disk and later
//  restored via GeckoSession.restoreSessionState(_:).
//
//  This mirrors the storage-facing half of GeckoView's own Android
//  GeckoSession.SessionState API (toString()/fromString()), which is
//  designed specifically to be an opaque, serializable blob for
//  embedders to store — Reynard does not need the richer,
//  iterable-history-list behavior that class also provides on Android,
//  since Reynard already tracks its own navigation history separately.
//

import Foundation

public struct GeckoSessionState {
    /// The merged state dictionary, keyed the same way GeckoView's own
    /// engine-side cache keys it: "history", "scrolldata", "formdata".
    /// Kept internal since callers should only ever round-trip this via
    /// jsonString()/init(jsonString:), not inspect individual fields —
    /// the engine, not Reynard, owns what's inside.
    let state: [String: Any?]
    
    init(state: [String: Any?]) {
        self.state = state
    }
    
    /// True when there is nothing meaningful to persist yet — mirrors
    /// the emptiness check GeckoView's own Android delegate performs
    /// before ever notifying the app of a state change, so Reynard
    /// doesn't persist/overwrite a tab's real state with a blank one
    /// during the brief window before the engine reports anything.
    public var isEmpty: Bool {
        state.isEmpty
    }
    
    /// Serializes this state to a JSON string suitable for storage
    /// (e.g. alongside a tab's other persisted metadata).
    public func jsonString() -> String? {
        guard !isEmpty else {
            return nil
        }
        
        // Any? values from the bridged GeckoBundle can contain NSNull
        // for explicit nulls; JSONSerialization only accepts NSNull,
        // not Optional<Any>.none, so normalize before encoding.
        let sanitized = GeckoSessionState.sanitize(state)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
    
    /// Reconstructs a previously-saved state from jsonString()'s output.
    public init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        self.state = dictionary
    }
    
    private static func sanitize(_ value: [String: Any?]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, wrapped) in value {
            result[key] = sanitizeValue(wrapped)
        }
        return result
    }
    
    private static func sanitizeValue(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }
        if let nested = value as? [String: Any?] {
            return sanitize(nested)
        }
        if let array = value as? [Any?] {
            return array.map(sanitizeValue)
        }
        return value
    }
}
