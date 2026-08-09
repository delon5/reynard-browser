//
//  GeckoSessionTranslations.swift
//  Reynard
//
//  Imperative side of the translations surface; the event side lives
//  in TranslationsDelegate.swift. Everything here speaks to the stock
//  Firefox 153 translations endpoints verified in
//  GeckoViewTranslations.sys.mjs / GeckoViewStartup.sys.mjs.
//

import Foundation

extension GeckoSession {
    /// Translates the current page fully on-device. BCP 47 language
    /// tags ("en", "de", ...). The generous timeout is deliberate: the
    /// first translation of a language pair downloads its model via
    /// Remote Settings before translating.
    public func translatePage(fromLanguage: String, toLanguage: String) async throws {
        _ = try await dispatcher.query(
            type: "GeckoView:Translations:Translate",
            message: [
                "fromLanguage": fromLanguage,
                "toLanguage": toLanguage,
            ],
            timeout: 120
        )
    }

    /// Restores the page's original, untranslated content.
    public func restoreOriginalPage() async throws {
        _ = try await dispatcher.query(type: "GeckoView:Translations:RestorePage")
    }
}

extension GeckoRuntime {
    /// Whether this device can run the translation engine at all.
    public static func isTranslationSupported() async -> Bool {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:IsTranslationEngineSupported"
        )
        return response as? Bool ?? false
    }

    /// The user's preferred translation target languages, most
    /// preferred first (BCP 47 tags).
    public static func translationPreferredLanguages() async -> [String] {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:PreferredLanguages"
        )
        return response as? [String] ?? []
    }
}
