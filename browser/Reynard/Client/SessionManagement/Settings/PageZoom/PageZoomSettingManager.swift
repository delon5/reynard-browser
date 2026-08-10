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
        guard let parsedURL = URL(string: url) else {
            return PageZoomSetting(level: Prefs.BrowsingSettings.defaultPageZoomLevel)
        guard let url = URL(string: url),
              let level = siteSettingsStore.settings(for: url)?.pageZoom else {
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
        guard let url = URL(string: url) else {
            return false
        }
        
        return siteSettingsStore.setPageZoom(level, for: url)
    }
}
