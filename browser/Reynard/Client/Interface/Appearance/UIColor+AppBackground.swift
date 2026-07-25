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
    
    /// Same idea as `.appBackground`, but for surfaces (like the
    /// toolbars) that normally use `.systemGray6` rather than
    /// `.systemBackground` — preserves that existing look when the OLED
    /// preference is off, so this doesn't change anything's everyday
    /// appearance, only what happens specifically when OLED mode is on.
    static var toolbarBackground: UIColor {
        return UIColor { traitCollection in
            guard Prefs.AppearanceSettings.usesOLEDBlackBackground,
                  traitCollection.userInterfaceStyle == .dark else {
                return .systemGray6
            }
            return .black
        }
    }
    
    /// Same idea again, for grouped-style table views (Settings
    /// screens), which get `.systemGroupedBackground` implicitly from
    /// UIKit itself rather than any explicit assignment in this app's
    /// own code — preserves that existing grouped look normally, only
    /// going pure black when OLED mode is actually on.
    static var settingsBackground: UIColor {
        return UIColor { traitCollection in
            guard Prefs.AppearanceSettings.usesOLEDBlackBackground,
                  traitCollection.userInterfaceStyle == .dark else {
                return .systemGroupedBackground
            }
            return .black
        }
    }
}
