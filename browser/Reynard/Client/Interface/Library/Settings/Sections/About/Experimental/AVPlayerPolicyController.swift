//
//  AVPlayerPolicyController.swift
//  Reynard
//
//  Mirrors the AVPlayer HLS preference into the engine.
//
//  DecoderTraits asks AVPlayerDecoder::IsSupportedType for every media
//  type, and that returns false unless media.reynard.avplayer.enabled is
//  on - so without this the whole AVPlayer path is unreachable no matter
//  what the UI says. Applied at startup for the same reason the tracking
//  and HTTPS-only policies are: the engine starts from its own defaults
//  and has to be told.
//

import Foundation
import GeckoView

enum AVPlayerPolicyController {
    static func applyAVPlayerHLS() {
        GeckoRuntime.setDefaultPrefs([
            "media.reynard.avplayer.enabled": Prefs.ExperimentalSettings.isAVPlayerHLSEnabled
        ])
    }
}
