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
    ///
    /// The engine answers `{ sites: [...] }`, not a bare array.
    public static func neverTranslateSites() async -> [String] {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:GetNeverTranslateSpecifiedSites"
        )
        return (response as? [String: Any])?["sites"] as? [String] ?? []
    }

    /// Removes a site from the never-translate list.
    public static func clearNeverTranslateSite(_ origin: String) async throws {
        _ = try await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:SetNeverTranslateSpecifiedSite",
            message: ["origin": origin, "neverTranslate": false]
        )
    }

    /// One language's treatment, as the engine reports it.
    public struct TranslationLanguageEntry {
        public let langTag: String
        public let displayName: String
        public let setting: TranslationLanguageSetting
    }

    /// Every language the engine can translate FROM, for offering a
    /// choice rather than only listing what has already been chosen.
    ///
    /// GetLanguageSettings cannot serve this: it returns only languages
    /// with a non-default setting, so before anything is set it is empty
    /// - which is exactly when a picker is needed.
    ///
    /// Answers `{ sourceLanguages: [{ langTag, langTagKey, displayName }] }`.
    public static func supportedSourceLanguages() async -> [TranslationLanguageEntry] {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:TranslationInformation"
        )
        let raw = (response as? [String: Any])?["sourceLanguages"] as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let tag = entry["langTag"] as? String else {
                return nil
            }
            let name = entry["displayName"] as? String
                ?? Locale.current.localizedString(forLanguageCode: tag)
                ?? tag
            // The engine reports capability, not preference, so every
            // entry starts at the default treatment.
            return TranslationLanguageEntry(
                langTag: tag, displayName: name, setting: .offer
            )
        }
    }

    /// Every language the engine holds a non-default setting for.
    ///
    /// Answers `{ settings: [{ langTag, displayName, setting }] }`.
    /// Entries at `.offer` are the default and are filtered out - the
    /// point of the list is to show what has been overridden.
    public static func translationLanguageSettings() async -> [TranslationLanguageEntry] {
        let response = try? await GeckoEventDispatcherWrapper.runtimeInstance.query(
            type: "GeckoView:Translations:GetLanguageSettings"
        )
        let raw = (response as? [String: Any])?["settings"] as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let tag = entry["langTag"] as? String,
                  let setting = (entry["setting"] as? String).flatMap({
                      TranslationLanguageSetting(rawValue: $0.lowercased())
                  }),
                  setting != .offer else {
                return nil
            }
            let name = entry["displayName"] as? String
                ?? Locale.current.localizedString(forLanguageCode: tag)
                ?? tag
            return TranslationLanguageEntry(
                langTag: tag, displayName: name, setting: setting
            )
        }
    }
}
