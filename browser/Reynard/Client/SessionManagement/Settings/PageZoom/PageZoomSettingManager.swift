//
//  PageZoomSettingManager.swift
//  Reynard
//
//  Created by Minh Ton on 28/6/26.
//

import Foundation
import GeckoView

final class PageZoomSettingManager {
    private let siteSettingsStore: SiteSettingsStore
    
    init(siteSettingsStore: SiteSettingsStore = .shared) {
        self.siteSettingsStore = siteSettingsStore
    }
    
    func setting(for url: String) -> PageZoomSetting {
        guard let parsedURL = Self.keyURL(from: url) else {
            return PageZoomSetting(level: Prefs.BrowsingSettings.defaultPageZoomLevel)
        }

        let level = siteSettingsStore.settings(for: parsedURL)?.pageZoom
            ?? Prefs.BrowsingSettings.defaultPageZoomLevel
        return PageZoomSetting(
            level: level,
            minimumLayoutWidth: PageZoomCompatibilityPolicy.minimumLayoutWidth(for: url)
        )
    }
    
    @discardableResult
    func save(_ level: Int, for url: String) -> Bool {
        guard let url = Self.keyURL(from: url) else {
            return false
        }
        
        return siteSettingsStore.setPageZoom(level, for: url)
    }

    /// The store keys zoom by host, and Foundation parses a scheme-less
    /// string like "twitch.tv" as a path-only URL whose host is nil -
    /// so the raw typed input from browse() looked the saved zoom up
    /// under no host at all and silently fell back to the default.
    /// That default was then pushed into the session as it started
    /// loading, while the commit re-resolved from the full committed
    /// URL - a guaranteed settings delta on any site with a saved
    /// zoom, which is what armed the mid-navigation settings restart.
    /// Resolve the host the way DomainMatcher does: as typed first,
    /// then with an https:// prefix.
    private static func keyURL(from value: String) -> URL? {
        if let url = URL(string: value), url.host != nil {
            return url
        }
        return URL(string: "https://" + value)
    }
}
