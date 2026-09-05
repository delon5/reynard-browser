//
//  AirPlayPolicyController.swift
//  Reynard
//
//  Mirrors the AirPlay preferences into the engine and the AVPlayer host.
//
//  The web-facing half (the Safari AirPlay shim and video.remote) is
//  read by GeckoViewContentChild per document from
//  media.reynard.airplay.*, which have no StaticPrefList entry - so
//  without this push the engine never hears of them and no page gets
//  the API no matter what the UI says. Applied at startup for the same
//  reason the AVPlayer policy is: the engine starts from its own
//  defaults and has to be told. The Swift half (video to the receiver,
//  route detection) is pushed into AVPlayerHost the same way, because
//  the GeckoView framework cannot read Prefs.
//

import Foundation
import GeckoView

enum AirPlayPolicyController {
    @MainActor
    static func apply() {
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.airplay.shim.enabled": Prefs.AirPlaySettings.shimEnabled,
            "media.reynard.airplay.shim.all-hosts": Prefs.AirPlaySettings.shimAllHosts,
            "media.reynard.airplay.shim.extra-hosts": Prefs.AirPlaySettings.shimExtraHosts,
            "media.reynard.airplay.remote-playback.enabled": Prefs.AirPlaySettings.remotePlaybackAPI,
        ])
        AirPlayController.shared.applyPolicy()
    }
}
