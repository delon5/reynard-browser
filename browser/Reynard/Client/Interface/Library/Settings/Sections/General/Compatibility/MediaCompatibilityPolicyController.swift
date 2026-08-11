//
//  MediaCompatibilityPolicyController.swift
//  Reynard
//
//  Applies the Media Source visibility preference to the engine. The
//  Gecko pref gates MediaSource::VisibleForCurrentGlobal, which hides
//  window.MediaSource on documents whose UA override impersonates
//  iPhone Safari - real iPhone Safari has never exposed classic MSE,
//  and players that find it under that UA select MSE+FairPlay, which
//  this engine cannot serve. Same shape as HTTPSOnlyModePolicyController.
//

import GeckoView

enum MediaCompatibilityPolicyController {
    static func applyMediaSourceVisibility() {
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.mediasource.hide-for-iphone-ua":
                Prefs.CompatibilitySettings.hideMediaSourceForSafariUA,
        ])
    }
}
