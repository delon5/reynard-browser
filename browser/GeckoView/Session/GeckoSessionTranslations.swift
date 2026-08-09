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

    /// Whether this site is on the never-translate list.
    public func neverTranslateSite() async -> Bool {
        let response = try? await dispatcher.query(
            type: "GeckoView:Translations:GetNeverTranslateSite"
        )
        return response as? Bool ?? false
    }

    /// Adds or removes this site from the never-translate list.
    ///
    /// Site level is a BLACKLIST only - Gecko models an
    /// always-translate list per LANGUAGE, not per site, so there is no
    /// setNeverTranslateSite(false) equivalent that means "always
    /// translate this site". Clearing it returns the site to being
    /// offered normally.
    public func setNeverTranslateSite(_ neverTranslate: Bool) async throws {
        _ = try await dispatcher.query(
            type: "GeckoView:Translations:SetNeverTranslateSite",
            message: ["neverTranslate": neverTranslate]
        )
    }
}

/// How the engine should treat a language it detects.
public enum TranslationLanguageSetting: String {
    /// Translate it without asking - the whitelist.
    case always
    /// Never offer it - the blacklist.
    case never
    /// Ask, which is the default.
    case offer
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

    /// How the engine currently treats `language` (BCP 47 tag).
    public static func translationLanguageSetting(
        for language: String
    ) async -> TranslationLanguageSetting {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:GetLanguageSetting",
            message: ["language": language]
        )
        return (response as? String).flatMap {
            TranslationLanguageSetting(rawValue: $0.lowercased())
        } ?? .offer
    }

    /// Sets the always/never/offer treatment for a language. The engine
    /// lower-cases and validates the tag, rejecting an invalid one.
    public static func setTranslationLanguageSetting(
        _ setting: TranslationLanguageSetting,
        for language: String
    ) async throws {
        _ = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:SetLanguageSettings",
            message: [
                "language": language,
                "languageSetting": setting.rawValue,
            ]
        )
    }

    /// Every site currently on the never-translate list.
    public static func neverTranslateSites() async -> [String] {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:GetNeverTranslateSpecifiedSites"
        )
        return response as? [String] ?? []
    }
}
