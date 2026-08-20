//
//  AutoplayPolicyController.swift
//  Reynard
//

import GeckoView

/// The Autoplay choice, told to the engine.
///
/// It was never told. A search of the tree for media.autoplay finds one
/// hit and it is a comment, so the pref that decides autoplay has always
/// been whatever Gecko shipped - and the three-way setting reached the
/// engine only if Gecko asked for the autoplay-media permission, which no
/// capture has ever shown it doing. Every video in the browser has been
/// running on the built-in default.
///
/// The three values are Gecko's own, and the existing code already
/// speaks them: ContentPermission.Value.blockAll is 5 because that is
/// what BLOCKED_ALL is.
///
///     0  ALLOWED       Allow Audio and Video
///     1  BLOCKED       Block Audio Only. Gecko resolves this to
///                      Allowed_muted: the play is permitted PRECISELY
///                      because the element is believed inaudible.
///     5  BLOCKED_ALL   Block Audio and Video
///
/// Modelled on HTTPSOnlyModePolicyController, and applied from the same
/// two places for the reason its neighbour in BrowserViewController
/// already gives: a pref written only when the switch is toggled
/// silently reverts at the next launch.
enum AutoplayPolicyController {
    static func applyAutoplayPolicy() {
        let action = SiteSettingsUtils.defaultAction(for: .autoplay)
        let value = action.geckoAutoplayDefault
        // Said out loud, and that is not decoration. Without it a
        // capture cannot show whether this fix is in the build - the
        // only other evidence is the autoplay= verdict on the VIDEO
        // line, and that reads "allowed" both when the pref is absent
        // and when it is set but overridden by user activation. One
        // line separates them.
        print("[Reynard] autoplay: media.autoplay.default = \(value) "
              + "(\(action)) - 0 allows, 1 allows muted, 5 blocks both")
        // How Gecko judges activation when nothing has answered the
        // autoplay-media permission outright.
        //
        // ADDED - see
        // mse_fix_92_transient_autoplay_and_a_car_that_cannot_tap.py's
        // docstring. The pref above is set correctly and defeated
        // anyway: blocking_policy 0 is STICKY activation, so one tap on
        // the page - opening a link, dismissing a banner - permits
        // autoplay for the rest of that document's life. IGN starts
        // three videos while scrolling with Block Audio and Video set,
        // and tv.apple.com's hero reads
        //
        //     autoplay=allowed activated=1
        //
        // allowed BECAUSE activated. 1 is TRANSIENT activation - a real
        // gesture in the last few seconds - which is what blocking
        // autoplay is understood to mean.
        //
        // 0 when the setting is Allow, because the pref above already
        // permits everything and a stricter test there would only read
        // as though it did something.
        //
        // CarPlay rides on sticky activation and cannot produce a
        // gesture, so it needs the heartbeat this change also adds -
        // see CarPlaySceneDelegate.startSession. The two halves are one
        // change and must not be built apart.
        let blockingPolicy = action == .allowed ? 0 : 1
        print("[Reynard] autoplay: media.autoplay.blocking_policy = "
              + "\(blockingPolicy) - 0 sticky, 1 transient, 2 input depth")
        GeckoRuntime.setDefaultPrefs([
            "media.autoplay.default": value,
            "media.autoplay.blocking_policy": blockingPolicy,
        ])
    }
}

extension SitePermissionAction {
    /// media.autoplay.default, which is not the same numbering as the
    /// permission value - the permission uses 1/2/5 and the pref uses
    /// 0/1/5. Spelled out rather than derived, because two three-value
    /// scales that agree on one member are exactly the kind of thing a
    /// shared helper gets wrong once and then hides.
    var geckoAutoplayDefault: Int {
        switch self {
        case .allowed:
            return 0
        case .askToAllow:
            return 1
        case .blocked:
            return 5
        }
    }
}
