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

    /// Extra hosts the WebKit media-keys shim should install on.
    ///
    /// The shim's host list is hard-coded in the actor because those four
    /// are the ones this pipeline has been exercised against. This adds to
    /// it at runtime so trying another site costs a reload, not a build.
    static func applyWebKitShimExtraHosts() {
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.eme.webkitmediakeys-shim.extra-hosts":
                Prefs.CompatibilitySettings.webKitShimExtraHosts,
        ])
    }

    /// audioTracks and videoTracks, which Gecko does not ship.
    ///
    /// ADDED - see mse_fix_89_ship_the_track_lists.py's docstring.
    /// media.track.enabled is false upstream, so
    /// HTMLMediaElement.audioTracks is undefined and a page's audio
    /// language picker calls into nothing. tv.apple.com's did, and the
    /// capture said so on every element:
    ///
    ///     TRACKS el#N audioTracks=absent videoTracks=absent
    ///
    /// Not a setting, unlike its three neighbours here. Those are
    /// choices - which user agent to present, which init data types to
    /// serve - and this is not one: a browser that cannot change audio
    /// language is broken, and there is no version of that a user would
    /// choose.
    static func applyMediaTrackSupport() {
        GeckoRuntime.setDefaultPrefs([
            "media.track.enabled": true,
        ])
    }

    /// The other half of the same decision. Hiding MSE steers a player
    /// away from MSE+FairPlay; this stops the engine advertising the
    /// init data types that mean MSE+FairPlay in the first place, so
    /// the player is refused rather than misled.
    static func applyFairPlayInitDataPolicy() {
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.fairplay.hls-only-initdata":
                Prefs.CompatibilitySettings.fairPlayHLSOnlyInitData,
        ])
    }
}
