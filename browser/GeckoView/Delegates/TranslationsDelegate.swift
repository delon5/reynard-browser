//
//  TranslationsDelegate.swift
//  Reynard
//
//  Embedder surface for the engine's GeckoViewTranslations session
//  module (mobile/shared, stock in Firefox 153). The module registers
//  its listeners in onInit for every session; setting this delegate
//  additionally marks the module enabled, matching how every other
//  delegate-backed module behaves.
//

import Foundation

public protocol TranslationsDelegate: AnyObject {
    /// The engine believes this page is in a language the user would
    /// want translated (TranslationsParent:OfferTranslation).
    func onTranslationOffer(session: GeckoSession)

    /// Translation state for the page changed (detected language,
    /// requested pair, error state...). The payload is the engine's
    /// "GeckoView:Translations:StateChange" bundle, passed through
    /// unmodified.
    func onTranslationStateChange(session: GeckoSession, state: [String: Any?]?)
}

func newTranslationsHandler(_ session: GeckoSession) -> GeckoSessionHandler {
    GeckoSessionHandler(
        moduleName: "GeckoViewTranslations",
        events: [
            "GeckoView:Translations:Offer",
            "GeckoView:Translations:StateChange",
        ],
        session: session
    ) { session, delegate, event, message in
        guard let delegate = delegate as? TranslationsDelegate else {
            return nil
        }
        switch event {
        case "GeckoView:Translations:Offer":
            delegate.onTranslationOffer(session: session)
        case "GeckoView:Translations:StateChange":
            delegate.onTranslationStateChange(session: session, state: message)
        default:
            break
        }
        return nil
    }
}
