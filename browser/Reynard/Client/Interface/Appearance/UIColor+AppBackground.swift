//
//  UIColor+AppBackground.swift
//  Reynard
//

import UIKit

extension UIColor {
    /// Drop-in replacement for `.systemBackground`. Behaves identically
    /// unless `Prefs.AppearanceSettings.usesOLEDBlackBackground` is on,
    /// in which case it resolves to pure black specifically in dark
    /// mode — better contrast and real battery savings on OLED screens,
    /// where black pixels are actually powered off rather than lit at a
    /// low level like the standard system background is.
    ///
    /// This only re-resolves automatically when the system's own
    /// light/dark appearance changes, the same as any other dynamic
    /// color — it does not react live to the OLED preference itself
    /// changing while already displayed. Settings that toggle this
    /// should prompt for an app restart, the same pattern already used
    /// elsewhere (e.g. Experimental Features), so every screen picks up
    /// the change cleanly and consistently.
    static var appBackground: UIColor {
        return UIColor { traitCollection in
            guard Prefs.AppearanceSettings.usesOLEDBlackBackground,
                  traitCollection.userInterfaceStyle == .dark else {
                return .systemBackground
            }
            return .black
        }
    }
}
