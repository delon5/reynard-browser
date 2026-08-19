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
        GeckoRuntime.setDefaultPrefs([
            "media.autoplay.default": action.geckoAutoplayDefault,
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
