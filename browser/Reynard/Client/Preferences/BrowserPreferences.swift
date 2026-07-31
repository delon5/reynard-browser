//
//  BrowserPreferences.swift
//  Reynard
//
//  Created by Minh Ton on 10/3/26.
//

import Foundation
import UIKit

typealias Prefs = BrowserPreferences

final class BrowserPreferences {
    static var shared = BrowserPreferences()
    static let openLinksInAppsBridgeKey = "Reynard.Browsing.openLinksInApps"
    
    let profile: String
    private(set) var registeredDefaults: [String: Any] = [:]
    
    init(profile: String = "default") {
        self.profile = profile
        registerDefaults()
    }
    
    // Possible future work
    static func useProfile(_ name: String) {
        shared = BrowserPreferences(profile: name)
        UserDefaults.standard.set(
            BrowsingSettings.openLinksInApps,
            forKey: openLinksInAppsBridgeKey
        )
    }
    
    func key(_ setting: String, _ name: String) -> String {
        "\(profile).\(setting).\(name)"
    }
    
    func registerDefaults() {
        migrateToolbarSettingsIfNeeded()
        let donationRecommendationShowTimeKey = key("HomepageSettings", "donationRecommendationShowTime")
        if UserDefaults.standard.object(forKey: donationRecommendationShowTimeKey) == nil {
            let delay = TimeInterval.random(in: (3 * 86_400)...(5 * 86_400))
            UserDefaults.standard.set(Date().addingTimeInterval(delay).timeIntervalSince1970, forKey: donationRecommendationShowTimeKey)
        }
        
        registeredDefaults = [
            // Search
            key("SearchSettings", "searchEngine"): SearchEngine.google.rawValue,
            key("SearchSettings", "customSearchTemplate"): "",
            key("SearchSettings", "searchSuggestionProvider"): SearchCompletion.Provider.google.rawValue,
            key("SearchSettings", "showSearchSuggestions"): true,
            key("SearchSettings", "showSearchSuggestionsInPrivateBrowsing"): true,
            key("SearchSettings", "searchBrowsingHistory"): true,
            key("SearchSettings", "searchBookmarks"): true,
            key("SearchSettings", "searchOpenedTabs"): true,
            
            // JIT
            key("JITSettings", "isJITEnabled"): false,
            
            // Experimental
            key("ExperimentalSettings", "isVideoPictureInPictureEnabled"): false,
            key("ExperimentalSettings", "hidesUpdateAvailableBanner"): false,
            key("PrivacySettings", "requiresAuthenticationForPrivateTabs"): false,
            key("CompatibilitySettings", "enablePerSiteUserAgentOverrides"): true,
            key("BrowsingSettings", "swipeUpForTabSwitcher"): true,
            key("AppearanceSettings", "hidesToolbarOnScroll"): true,
            
            // Compatibility
            key("CompatibilitySettings", "androidUserAgentDomains"): [],
            key("CompatibilitySettings", "useAndroidUserAgent"): true,
            
            // Browsing
            key("BrowsingSettings", "requestDesktopWebsite"): UIDevice.current.userInterfaceIdiom == .pad,
            key("BrowsingSettings", "showLinkPreviews"): true,
            key("BrowsingSettings", "showImagePreviews"): true,
            key("BrowsingSettings", "openLinksInApps"): true,
            
            // New Tab
            key("NewTabSettings", "newTabDisplayOption"): NewTabDisplayOption.homepage.rawValue,
            key("NewTabSettings", "customNewTabURL"): "",
            key("NewTabSettings", "automaticallyOpensKeyboard"): false,
            
            // Homepage
            key("HomepageSettings", "openingScreen"): HomepageOpeningScreen.homepage.rawValue,
            key("HomepageSettings", "showsFavorites"): true,
            key("HomepageSettings", "showsFavoritesInPrivateBrowsing"): false,
            key("HomepageSettings", "favoriteRowCount"): 2,
            key("HomepageSettings", "showsFrequentlyVisited"): true,
            key("HomepageSettings", "showsFrequentlyVisitedInPrivateBrowsing"): false,
            key("HomepageSettings", "frequentlyVisitedSiteCount"): 8,
            key("HomepageSettings", "showsRecentlyClosedTabs"): true,
            key("HomepageSettings", "recentlyClosedTabLimit"): 10,
            key("HomepageSettings", "showsRecommendations"): true,
            key("HomepageSettings", "showsNewUpdates"): true,
            key("HomepageSettings", "donationRecommendationMultiplier"): 1,
            
            // Appearance
            key("AppearanceSettings", "appAppearance"): AppAppearance.system.rawValue,
            key("AppearanceSettings", "addressBarPosition"): BrowserChromePosition.bottom.rawValue,
            key("AppearanceSettings", "showsFullWebsiteAddress"): false,
            key("AppearanceSettings", "showsLandscapeTabBar"): true,
            key("AppearanceSettings", "defaultPageZoomLevel"): PageZoomLevels.defaultLevel,
            key("ToolbarSettings", "bottomToolbarActions"): BottomToolbarAction.defaultActions.map(\.rawValue),
            key("ToolbarSettings", "toolbarButtonHapticsEnabled"): true,
            key("ToolbarSettings", "closeTabLongPressOpensNewTab"): true,
            key("ToolbarSettings", "newTabLongPressClosesTab"): false,
            
            // Languages
            key("LanguageSettings", "websiteLanguages"): (try? JSONEncoder().encode(WebsiteLanguageCatalog.defaultLanguageCodes())) ?? Data(),
            
            // Bookmarks
            key("BookmarkSettings", "placeFoldersOnTop"): true,
            key("BookmarkSettings", "sortOrders"): BookmarkSortOrder.none.rawValue,
            
            // Add-ons
            key("AddonSettings", "showsAddressBarButton"): true,
            key("AddonSettings", "lastGlobalCheckAt"): "",
            key("AddonSettings", "pendingApprovalAddonIDs"): Data(),
            
            // Site Permissions
            key("SitePermissionSettings", "defaultAutoplayPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultCameraPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultMicrophonePermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultLocationPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultPersistentStoragePermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultCrossOriginStorageAccessPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultLocalDeviceAccessPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultLocalNetworkAccessPermission"): SitePermissionAction.askToAllow.rawValue,
            key("SitePermissionSettings", "defaultDeviceSensorsPermission"): SitePermissionAction.askToAllow.rawValue,
            
            // Clear Browsing Data
            key("ClearBrowsingData", "clearsBrowsingHistory"): true,
            key("ClearBrowsingData", "clearsCookiesAndSiteData"): true,
            key("ClearBrowsingData", "clearsCachedImagesAndFiles"): true,
            key("ClearBrowsingData", "clearsDownloadedFiles"): false,
            key("ClearBrowsingData", "clearsSitePermissions"): true,
            key("ClearBrowsingData", "clearsOpenedTabs"): true,
            
            // HTTPS-Only Mode
            key("HTTPSOnlyMode", "enabled"): false,
            key("HTTPSOnlyMode", "scope"): HTTPSOnlyModeScope.allTabs.rawValue,
            
            // Tracking Protection
            key("TrackingProtection", "enhancedTrackingProtectionLevel"): TrackingProtectionLevel.standard.rawValue,
            key("TrackingProtection", "strictBaselineAllowListEnabled"): true,
            key("TrackingProtection", "strictConvenienceAllowListEnabled"): false,
            key("TrackingProtection", "customBaselineAllowListEnabled"): true,
            key("TrackingProtection", "customConvenienceAllowListEnabled"): false,
            key("TrackingProtection", "customCookiePolicy"): CustomCookiePolicy.isolateCrossSite.rawValue,
            key("TrackingProtection", "customTrackingContentScope"): CustomBlockingScope.all.rawValue,
            key("TrackingProtection", "customBlocksCryptominers"): true,
            key("TrackingProtection", "customBlocksKnownFingerprinters"): true,
            key("TrackingProtection", "customBlocksRedirectTrackers"): true,
            key("TrackingProtection", "customSuspectedFingerprinterScope"): CustomBlockingScope.privateOnly.rawValue,
            key("TrackingProtection", "globalPrivacyControlEnabled"): false,
        ]
        UserDefaults.standard.register(defaults: registeredDefaults)
        UserDefaults.standard.set(
            UserDefaults.standard.bool(
                forKey: key("BrowsingSettings", "openLinksInApps")
            ),
            forKey: Self.openLinksInAppsBridgeKey
        )
    }

    private func migrateToolbarSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        for name in [
            "bottomToolbarActions",
            "toolbarButtonHapticsEnabled",
            "closeTabLongPressOpensNewTab",
            "newTabLongPressClosesTab",
        ] {
            let destinationKey = key("ToolbarSettings", name)
            guard defaults.object(forKey: destinationKey) == nil,
                  let existingValue = defaults.object(forKey: key("AppearanceSettings", name)) else {
                continue
            }
            defaults.set(existingValue, forKey: destinationKey)
        }
    }
    
    func bool(forSetting setting: String, key name: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(setting, name))
    }
    
    func string(forSetting setting: String, key name: String) -> String? {
        UserDefaults.standard.string(forKey: key(setting, name))
    }
    
    func data(forSetting setting: String, key name: String) -> Data? {
        UserDefaults.standard.data(forKey: key(setting, name))
    }

    func stringArray(forSetting setting: String, key name: String) -> [String]? {
        UserDefaults.standard.stringArray(forKey: key(setting, name))
    }
    
    func double(forSetting setting: String, key name: String) -> Double {
        UserDefaults.standard.double(forKey: key(setting, name))
    }
    
    func integer(forSetting setting: String, key name: String) -> Int {
        UserDefaults.standard.integer(forKey: key(setting, name))
    }
    
    func set(_ value: Bool, forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }
    
    func set(_ value: String?, forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }
    
    func set(_ value: Data?, forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }

    func set(_ value: [String], forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }
    
    func set(_ value: Double, forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }
    
    func set(_ value: Int, forSetting setting: String, key name: String) {
        UserDefaults.standard.set(value, forKey: key(setting, name))
    }
    
    // MARK: - Search
    struct SearchSettings {
        static var searchEngine: SearchEngine {
            get {
                let rawValue = prefs.string(forSetting: "SearchSettings", key: "searchEngine") ?? SearchEngine.google.rawValue
                return SearchEngine(rawValue: rawValue) ?? .google
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SearchSettings", key: "searchEngine")
            }
        }
        
        static var customSearchTemplate: String {
            get {
                return prefs.string(forSetting: "SearchSettings", key: "customSearchTemplate") ?? ""
            }
            set {
                prefs.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forSetting: "SearchSettings", key: "customSearchTemplate")
            }
        }
        
        static var searchSuggestionProvider: SearchCompletion.Provider {
            get {
                let rawValue = prefs.string(forSetting: "SearchSettings", key: "searchSuggestionProvider") ?? SearchCompletion.Provider.google.rawValue
                return SearchCompletion.Provider(rawValue: rawValue) ?? .google
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SearchSettings", key: "searchSuggestionProvider")
            }
        }
        
        static var showSearchSuggestions: Bool {
            get {
                return prefs.bool(forSetting: "SearchSettings", key: "showSearchSuggestions")
            }
            set {
                prefs.set(newValue, forSetting: "SearchSettings", key: "showSearchSuggestions")
            }
        }
        
        static var showSearchSuggestionsInPrivateBrowsing: Bool {
            get {
                return prefs.bool(forSetting: "SearchSettings", key: "showSearchSuggestionsInPrivateBrowsing")
            }
            set {
                prefs.set(newValue, forSetting: "SearchSettings", key: "showSearchSuggestionsInPrivateBrowsing")
            }
        }
        
        static var searchBrowsingHistory: Bool {
            get {
                return prefs.bool(forSetting: "SearchSettings", key: "searchBrowsingHistory")
            }
            set {
                prefs.set(newValue, forSetting: "SearchSettings", key: "searchBrowsingHistory")
            }
        }
        
        static var searchBookmarks: Bool {
            get {
                return prefs.bool(forSetting: "SearchSettings", key: "searchBookmarks")
            }
            set {
                prefs.set(newValue, forSetting: "SearchSettings", key: "searchBookmarks")
            }
        }
        
        static var searchOpenedTabs: Bool {
            get {
                return prefs.bool(forSetting: "SearchSettings", key: "searchOpenedTabs")
            }
            set {
                prefs.set(newValue, forSetting: "SearchSettings", key: "searchOpenedTabs")
            }
        }
    }
    
    // MARK: - Browsing
    struct BrowsingSettings {
        static var requestDesktopWebsite: Bool {
            get {
                return prefs.bool(forSetting: "BrowsingSettings", key: "requestDesktopWebsite")
            }
            set {
                prefs.set(newValue, forSetting: "BrowsingSettings", key: "requestDesktopWebsite")
            }
        }
        
        static var showLinkPreviews: Bool {
            get {
                return prefs.bool(forSetting: "BrowsingSettings", key: "showLinkPreviews")
            }
            set {
                prefs.set(newValue, forSetting: "BrowsingSettings", key: "showLinkPreviews")
            }
        }
        
        static var showImagePreviews: Bool {
            get {
                return prefs.bool(forSetting: "BrowsingSettings", key: "showImagePreviews")
            }
            set {
                prefs.set(newValue, forSetting: "BrowsingSettings", key: "showImagePreviews")
            }
        }
        
        /// Whether swiping up from the toolbar opens the tab switcher.
        /// On by default.
        static var swipeUpForTabSwitcher: Bool {
            get {
                return prefs.bool(forSetting: "BrowsingSettings", key: "swipeUpForTabSwitcher")
            }
            set {
                prefs.set(newValue, forSetting: "BrowsingSettings", key: "swipeUpForTabSwitcher")
            }
        }

        static var openLinksInApps: Bool {
            get {
                return prefs.bool(forSetting: "BrowsingSettings", key: "openLinksInApps")
            }
            set {
                prefs.set(newValue, forSetting: "BrowsingSettings", key: "openLinksInApps")
                UserDefaults.standard.set(
                    newValue,
                    forKey: BrowserPreferences.openLinksInAppsBridgeKey
                )
            }
        }
    }
    
    // MARK: - Clear Browsing Data
    struct ClearBrowsingData {
        static var clearsBrowsingHistory: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsBrowsingHistory")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsBrowsingHistory")
            }
        }
        
        static var clearsCookiesAndSiteData: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsCookiesAndSiteData")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsCookiesAndSiteData")
            }
        }
        
        static var clearsCachedImagesAndFiles: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsCachedImagesAndFiles")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsCachedImagesAndFiles")
            }
        }
        
        static var clearsDownloadedFiles: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsDownloadedFiles")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsDownloadedFiles")
            }
        }
        
        static var clearsSitePermissions: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsSitePermissions")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsSitePermissions")
            }
        }
        
        static var clearsOpenedTabs: Bool {
            get {
                return prefs.bool(forSetting: "ClearBrowsingData", key: "clearsOpenedTabs")
            }
            set {
                prefs.set(newValue, forSetting: "ClearBrowsingData", key: "clearsOpenedTabs")
            }
        }
    }
    
    // MARK: - HTTPS-Only Mode
    struct HTTPSOnlyModePreferences {
        static var enabled: Bool {
            get {
                return prefs.bool(forSetting: "HTTPSOnlyMode", key: "enabled")
            }
            set {
                prefs.set(newValue, forSetting: "HTTPSOnlyMode", key: "enabled")
            }
        }
        
        static var scope: HTTPSOnlyModeScope {
            get {
                let rawValue = prefs.string(forSetting: "HTTPSOnlyMode", key: "scope") ?? HTTPSOnlyModeScope.allTabs.rawValue
                return HTTPSOnlyModeScope(rawValue: rawValue) ?? .allTabs
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "HTTPSOnlyMode", key: "scope")
            }
        }
    }
    
    // MARK: - Tracking Protection
    struct TrackingProtectionPreferences {
        static var level: TrackingProtectionLevel {
            get {
                let rawValue = prefs.string(forSetting: "TrackingProtection", key: "enhancedTrackingProtectionLevel") ?? TrackingProtectionLevel.standard.rawValue
                return TrackingProtectionLevel(rawValue: rawValue) ?? .standard
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "TrackingProtection", key: "enhancedTrackingProtectionLevel")
            }
        }
        
        static var strictBaselineAllowListEnabled: Bool {
            get {
                return prefs.bool(forSetting: "TrackingProtection", key: "strictBaselineAllowListEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "TrackingProtection", key: "strictBaselineAllowListEnabled")
            }
        }
        
        static var strictConvenienceAllowListEnabled: Bool {
            get {
                return prefs.bool(forSetting: "TrackingProtection", key: "strictConvenienceAllowListEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "TrackingProtection", key: "strictConvenienceAllowListEnabled")
            }
        }
        
        static var customBaselineAllowListEnabled: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "customBaselineAllowListEnabled") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "customBaselineAllowListEnabled") }
        }
        
        static var customConvenienceAllowListEnabled: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "customConvenienceAllowListEnabled") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "customConvenienceAllowListEnabled") }
        }
        
        static var customCookiePolicy: CustomCookiePolicy {
            get {
                return CustomCookiePolicy(rawValue: prefs.integer(forSetting: "TrackingProtection", key: "customCookiePolicy")) ?? .isolateCrossSite
            }
            set { prefs.set(newValue.rawValue, forSetting: "TrackingProtection", key: "customCookiePolicy") }
        }
        
        static var customTrackingContentScope: CustomBlockingScope {
            get {
                let rawValue = prefs.string(forSetting: "TrackingProtection", key: "customTrackingContentScope") ?? CustomBlockingScope.all.rawValue
                return CustomBlockingScope(rawValue: rawValue) ?? .all
            }
            set { prefs.set(newValue.rawValue, forSetting: "TrackingProtection", key: "customTrackingContentScope") }
        }
        
        static var customBlocksCryptominers: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "customBlocksCryptominers") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "customBlocksCryptominers") }
        }
        
        static var customBlocksKnownFingerprinters: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "customBlocksKnownFingerprinters") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "customBlocksKnownFingerprinters") }
        }
        
        static var customBlocksRedirectTrackers: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "customBlocksRedirectTrackers") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "customBlocksRedirectTrackers") }
        }
        
        static var customSuspectedFingerprinterScope: CustomBlockingScope {
            get {
                let rawValue = prefs.string(forSetting: "TrackingProtection", key: "customSuspectedFingerprinterScope") ?? CustomBlockingScope.privateOnly.rawValue
                return CustomBlockingScope(rawValue: rawValue) ?? .privateOnly
            }
            set { prefs.set(newValue.rawValue, forSetting: "TrackingProtection", key: "customSuspectedFingerprinterScope") }
        }
        
        static var globalPrivacyControlEnabled: Bool {
            get { return prefs.bool(forSetting: "TrackingProtection", key: "globalPrivacyControlEnabled") }
            set { prefs.set(newValue, forSetting: "TrackingProtection", key: "globalPrivacyControlEnabled") }
        }
    }
    
    // MARK: - New Tab
    struct NewTabSettings {
        static var newTabDisplayOption: NewTabDisplayOption {
            get {
                let rawValue = prefs.string(forSetting: "NewTabSettings", key: "newTabDisplayOption") ?? NewTabDisplayOption.homepage.rawValue
                return NewTabDisplayOption(rawValue: rawValue) ?? .homepage
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "NewTabSettings", key: "newTabDisplayOption")
                NotificationCenter.default.post(name: .newTabDisplayOptionDidChange, object: nil)
            }
        }
        
        static var customNewTabURL: String {
            get {
                return prefs.string(forSetting: "NewTabSettings", key: "customNewTabURL") ?? ""
            }
            set {
                prefs.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forSetting: "NewTabSettings", key: "customNewTabURL")
            }
        }

        static var automaticallyOpensKeyboard: Bool {
            get {
                return prefs.bool(forSetting: "NewTabSettings", key: "automaticallyOpensKeyboard")
            }
            set {
                prefs.set(newValue, forSetting: "NewTabSettings", key: "automaticallyOpensKeyboard")
            }
        }
    }
    
    // MARK: - Homepage
    struct HomepageSettings {
        static var openingScreen: HomepageOpeningScreen {
            get {
                let rawValue = prefs.string(forSetting: "HomepageSettings", key: "openingScreen") ?? HomepageOpeningScreen.homepage.rawValue
                return HomepageOpeningScreen(rawValue: rawValue) ?? .homepage
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "HomepageSettings", key: "openingScreen")
            }
        }
        
        static var showsFavorites: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsFavorites")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsFavorites")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var favoriteRowCount: Int {
            get {
                return prefs.integer(forSetting: "HomepageSettings", key: "favoriteRowCount")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "favoriteRowCount")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsFavoritesInPrivateBrowsing: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsFavoritesInPrivateBrowsing")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsFavoritesInPrivateBrowsing")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsFrequentlyVisited: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsFrequentlyVisited")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsFrequentlyVisited")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsFrequentlyVisitedInPrivateBrowsing: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsFrequentlyVisitedInPrivateBrowsing")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsFrequentlyVisitedInPrivateBrowsing")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var frequentlyVisitedSiteCount: Int {
            get {
                return prefs.integer(forSetting: "HomepageSettings", key: "frequentlyVisitedSiteCount")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "frequentlyVisitedSiteCount")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsRecentlyClosedTabs: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsRecentlyClosedTabs")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsRecentlyClosedTabs")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var recentlyClosedTabLimit: Int {
            get {
                return prefs.integer(forSetting: "HomepageSettings", key: "recentlyClosedTabLimit")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "recentlyClosedTabLimit")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsRecommendations: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsRecommendations")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsRecommendations")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var showsNewUpdates: Bool {
            get {
                return prefs.bool(forSetting: "HomepageSettings", key: "showsNewUpdates")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "showsNewUpdates")
                NotificationCenter.default.post(name: .homepageSettingsDidChange, object: nil)
            }
        }
        
        static var donationRecommendationShowTime: Date {
            get {
                return Date(timeIntervalSince1970: prefs.double(forSetting: "HomepageSettings", key: "donationRecommendationShowTime"))
            }
            set {
                prefs.set(newValue.timeIntervalSince1970, forSetting: "HomepageSettings", key: "donationRecommendationShowTime")
            }
        }
        
        static var donationRecommendationMultiplier: Int {
            get {
                return prefs.integer(forSetting: "HomepageSettings", key: "donationRecommendationMultiplier")
            }
            set {
                prefs.set(newValue, forSetting: "HomepageSettings", key: "donationRecommendationMultiplier")
            }
        }
    }
    
    // MARK: - Site Permissions
    struct SitePermissionSettings {
        static var defaultAutoplayPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultAutoplayPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultAutoplayPermission")
            }
        }
        
        static var defaultCameraPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultCameraPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultCameraPermission")
            }
        }
        
        static var defaultMicrophonePermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultMicrophonePermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultMicrophonePermission")
            }
        }
        
        static var defaultLocationPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultLocationPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultLocationPermission")
            }
        }
        
        static var defaultPersistentStoragePermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultPersistentStoragePermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultPersistentStoragePermission")
            }
        }
        
        static var defaultCrossOriginStorageAccessPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultCrossOriginStorageAccessPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultCrossOriginStorageAccessPermission")
            }
        }
        
        static var defaultLocalDeviceAccessPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultLocalDeviceAccessPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultLocalDeviceAccessPermission")
            }
        }
        
        static var defaultLocalNetworkAccessPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultLocalNetworkAccessPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultLocalNetworkAccessPermission")
            }
        }

        static var defaultDeviceSensorsPermission: SitePermissionAction {
            get {
                let rawValue = prefs.string(forSetting: "SitePermissionSettings", key: "defaultDeviceSensorsPermission")
                guard let rawValue,
                      let action = SitePermissionAction(rawValue: rawValue) else {
                    return .askToAllow
                }
                return action
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "SitePermissionSettings", key: "defaultDeviceSensorsPermission")
            }
        }
    }
    
    // MARK: - Compatibility
    struct CompatibilitySettings {
        static var androidUserAgentDomains: [String] {
            get {
                guard let data = prefs.data(forSetting: "CompatibilitySettings", key: "androidUserAgentDomains"),
                      let list = try? JSONDecoder().decode([String].self, from: data) else {
                    return []
                }
                return list
            }
            set {
                let data = try? JSONEncoder().encode(newValue)
                prefs.set(data, forSetting: "CompatibilitySettings", key: "androidUserAgentDomains")
            }
        }
        
        static var useAndroidUserAgent: Bool {
            get {
                prefs.bool(forSetting: "CompatibilitySettings", key: "useAndroidUserAgent")
            }
            set {
                prefs.set(newValue, forSetting: "CompatibilitySettings", key: "useAndroidUserAgent")
            }
        }
        
        static var useCustomUserAgent: Bool {
            get {
                prefs.bool(forSetting: "CompatibilitySettings", key: "useCustomUserAgent")
            }
            set {
                prefs.set(newValue, forSetting: "CompatibilitySettings", key: "useCustomUserAgent")
            }
        }
        
        static var customUserAgent: String {
            get {
                prefs.string(forSetting: "CompatibilitySettings", key: "customUserAgent") ?? ""
            }
            set {
                prefs.set(newValue, forSetting: "CompatibilitySettings", key: "customUserAgent")
            }
        }
        
        /// Whether per-site user agent overrides are applied at all.
        /// Separate from useCustomUserAgent/useAndroidUserAgent, since
        /// per-site overrides are additive to whichever global mode (if
        /// any) is active, not a third mutually-exclusive global mode.
        static var enablePerSiteUserAgentOverrides: Bool {
            get {
                prefs.bool(forSetting: "CompatibilitySettings", key: "enablePerSiteUserAgentOverrides")
            }
            set {
                prefs.set(newValue, forSetting: "CompatibilitySettings", key: "enablePerSiteUserAgentOverrides")
            }
        }
        
        /// Per-site user agent overrides, keyed by host. Takes priority
        /// over both the global custom user agent and the Android
        /// compatibility heuristics for any host present in this map.
        static var perSiteUserAgentOverrides: [String: String] {
            get {
                guard let data = prefs.data(forSetting: "CompatibilitySettings", key: "perSiteUserAgentOverrides"),
                      let map = try? JSONDecoder().decode([String: String].self, from: data) else {
                    return [:]
                }
                return map
            }
            set {
                let data = try? JSONEncoder().encode(newValue)
                prefs.set(data, forSetting: "CompatibilitySettings", key: "perSiteUserAgentOverrides")
            }
        }
    }
    
    // MARK: - Appearance
    struct AppearanceSettings {
        static var appAppearance: AppAppearance {
            get {
                let rawValue = prefs.string(forSetting: "AppearanceSettings", key: "appAppearance") ?? AppAppearance.system.rawValue
                return AppAppearance(rawValue: rawValue) ?? .system
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "AppearanceSettings", key: "appAppearance")
            }
        }
        
        /// Uses pure black instead of the standard system background
        /// color while in dark mode, for better contrast and battery
        /// savings on OLED screens.
        static var usesOLEDBlackBackground: Bool {
            get {
                prefs.bool(forSetting: "AppearanceSettings", key: "usesOLEDBlackBackground")
            }
            set {
                prefs.set(newValue, forSetting: "AppearanceSettings", key: "usesOLEDBlackBackground")
            }
        }
        
        /// Condenses the toolbars into a small floating pill while
        /// scrolling down a page, matching Safari's behavior. On by
        /// default.
        static var hidesToolbarOnScroll: Bool {
            get {
                prefs.bool(forSetting: "AppearanceSettings", key: "hidesToolbarOnScroll")
            }
            set {
                prefs.set(newValue, forSetting: "AppearanceSettings", key: "hidesToolbarOnScroll")
            }
        }
        
        static var addressBarPosition: BrowserChromePosition {
            get {
                let rawValue = prefs.string(forSetting: "AppearanceSettings", key: "addressBarPosition") ?? BrowserChromePosition.bottom.rawValue
                return BrowserChromePosition(rawValue: rawValue) ?? .bottom
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "AppearanceSettings", key: "addressBarPosition")
                NotificationCenter.default.post(name: .addressBarPositionDidChange, object: nil)
            }
        }
        
        static var showsLandscapeTabBar: Bool {
            get {
                prefs.bool(forSetting: "AppearanceSettings", key: "showsLandscapeTabBar")
            }
            set {
                prefs.set(newValue, forSetting: "AppearanceSettings", key: "showsLandscapeTabBar")
                NotificationCenter.default.post(name: .landscapeTabBarDidChange, object: nil)
            }
        }
        
        static var showsFullWebsiteAddress: Bool {
            get {
                prefs.bool(forSetting: "AppearanceSettings", key: "showsFullWebsiteAddress")
            }
            set {
                prefs.set(newValue, forSetting: "AppearanceSettings", key: "showsFullWebsiteAddress")
                NotificationCenter.default.post(name: .showFullWebsiteAddressDidChange, object: nil)
            }
        }
        
        static var defaultPageZoomLevel: Int {
            get {
                let level = prefs.integer(forSetting: "AppearanceSettings", key: "defaultPageZoomLevel")
                return PageZoomLevels.all.contains(level) ? level : PageZoomLevels.defaultLevel
            }
            set {
                guard PageZoomLevels.all.contains(newValue) else {
                    return
                }
                prefs.set(newValue, forSetting: "AppearanceSettings", key: "defaultPageZoomLevel")
            }
        }

    }

    // MARK: - Toolbar
    struct ToolbarSettings {
        static var bottomToolbarActions: [BottomToolbarAction] {
            get {
                let rawValues = prefs.stringArray(
                    forSetting: "ToolbarSettings",
                    key: "bottomToolbarActions"
                ) ?? BottomToolbarAction.defaultActions.map(\.rawValue)
                let actions = rawValues.compactMap { rawValue in
                    rawValue == "library" ? BottomToolbarAction.bookmarks : BottomToolbarAction(rawValue: rawValue)
                }
                return BottomToolbarAction.normalized(actions)
            }
            set {
                prefs.set(
                    BottomToolbarAction.normalized(newValue).map(\.rawValue),
                    forSetting: "ToolbarSettings",
                    key: "bottomToolbarActions"
                )
                NotificationCenter.default.post(name: .bottomToolbarActionsDidChange, object: nil)
            }
        }

        static var toolbarButtonHapticsEnabled: Bool {
            get {
                prefs.bool(forSetting: "ToolbarSettings", key: "toolbarButtonHapticsEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "ToolbarSettings", key: "toolbarButtonHapticsEnabled")
            }
        }

        static var closeTabLongPressOpensNewTab: Bool {
            get {
                prefs.bool(forSetting: "ToolbarSettings", key: "closeTabLongPressOpensNewTab")
            }
            set {
                prefs.set(newValue, forSetting: "ToolbarSettings", key: "closeTabLongPressOpensNewTab")
                NotificationCenter.default.post(name: .bottomToolbarShortcutsDidChange, object: nil)
            }
        }

        static var newTabLongPressClosesTab: Bool {
            get {
                prefs.bool(forSetting: "ToolbarSettings", key: "newTabLongPressClosesTab")
            }
            set {
                prefs.set(newValue, forSetting: "ToolbarSettings", key: "newTabLongPressClosesTab")
                NotificationCenter.default.post(name: .bottomToolbarShortcutsDidChange, object: nil)
            }
        }
    }
    
    // MARK: - JIT
    struct JITSettings {
        /// Was ReynardDirectories.shared.pairingFile (this app's own
        /// private container) — same reasoning as
        /// JITSettingsSection.swift's own updated comment on
        /// installPairingFile(from:). Both needed fixing together,
        /// since fixing only the import location while this still
        /// checked the old one would have left the "Enable JIT" switch
        /// permanently unable to turn on at all.
        static var hasPairingFile: Bool {
            guard let sharedPairingFile = ReynardDirectories.shared.sharedPairingFile else {
                return false
            }
            return FileManager.default.fileExists(atPath: sharedPairingFile.path)
        }
        
        static var isJITEnabled: Bool {
            get {
                guard hasPairingFile else {
                    return false
                }
                return prefs.bool(forSetting: "JITSettings", key: "isJITEnabled")
            }
            set {
                prefs.set(hasPairingFile && newValue, forSetting: "JITSettings", key: "isJITEnabled")
            }
        }
    }
    
    // MARK: - Experimental
    struct ExperimentalSettings {
        static var isVideoPictureInPictureEnabled: Bool {
            get {
                return prefs.bool(forSetting: "ExperimentalSettings", key: "isVideoPictureInPictureEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "ExperimentalSettings", key: "isVideoPictureInPictureEnabled")
            }
        }
        
        // Gates SettingsViewController.Section.updates - the "Update
        // Available" section header, release notes, and Update Now
        // button shown at the top of the main Settings screen itself.
        // Distinct from Prefs.HomepageSettings.showsNewUpdates, which
        // gates a completely separate homepage card - these two have
        // nothing to do with each other beyond both being update
        // notifications, hence two separate toggles rather than one.
        static var hidesUpdateAvailableBanner: Bool {
            get {
                return prefs.bool(forSetting: "ExperimentalSettings", key: "hidesUpdateAvailableBanner")
            }
            set {
                prefs.set(newValue, forSetting: "ExperimentalSettings", key: "hidesUpdateAvailableBanner")
            }
        }
        
        // Diagnostic log files, all defaulting to true so behaviour is
        // unchanged until deliberately switched off. Pushed down to the
        // Objective-C layer at startup by JITController rather than
        // read there directly - see
        // fix_experimental_logging_toggles.py.
        //
        // isJITDebugLogEnabled gates the whole of
        // Documents/reynard_jit_log.txt, which carries both the JIT
        // pipeline and the tab lifecycle counts - hence the generic
        // "Debug Log File" label rather than a JIT-specific one.
        static var isJITDebugLogEnabled: Bool {
            get {
                return prefs.bool(forSetting: "ExperimentalSettings", key: "isJITDebugLogEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "ExperimentalSettings", key: "isJITDebugLogEnabled")
            }
        }
        
        static var isIdeviceNativeLogEnabled: Bool {
            get {
                return prefs.bool(forSetting: "ExperimentalSettings", key: "isIdeviceNativeLogEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "ExperimentalSettings", key: "isIdeviceNativeLogEnabled")
            }
        }
        
        static var isJITHangBacktraceEnabled: Bool {
            get {
                return prefs.bool(forSetting: "ExperimentalSettings", key: "isJITHangBacktraceEnabled")
            }
            set {
                prefs.set(newValue, forSetting: "ExperimentalSettings", key: "isJITHangBacktraceEnabled")
            }
        }
    }
    
    // MARK: - Privacy
    struct PrivacySettings {
        static var requiresAuthenticationForPrivateTabs: Bool {
            get {
                return prefs.bool(forSetting: "PrivacySettings", key: "requiresAuthenticationForPrivateTabs")
            }
            set {
                prefs.set(newValue, forSetting: "PrivacySettings", key: "requiresAuthenticationForPrivateTabs")
            }
        }
    }
    
    // MARK: - Bookmarks
    struct BookmarkSettings {
        static var placeFoldersOnTop: Bool {
            get {
                prefs.bool(forSetting: "BookmarkSettings", key: "placeFoldersOnTop")
            }
            set {
                prefs.set(newValue, forSetting: "BookmarkSettings", key: "placeFoldersOnTop")
            }
        }
        
        static var sortOrders: BookmarkSortOrder {
            get {
                let rawValue = prefs.string(forSetting: "BookmarkSettings", key: "sortOrders") ?? BookmarkSortOrder.none.rawValue
                return BookmarkSortOrder(rawValue: rawValue) ?? .none
            }
            set {
                prefs.set(newValue.rawValue, forSetting: "BookmarkSettings", key: "sortOrders")
            }
        }
    }
    
    // MARK: - Languages
    struct LanguageSettings {
        static var websiteLanguages: [String] {
            get {
                guard let data = prefs.data(forSetting: "LanguageSettings", key: "websiteLanguages"),
                      let values = try? JSONDecoder().decode([String].self, from: data) else {
                    return WebsiteLanguageCatalog.defaultLanguageCodes()
                }
                return WebsiteLanguageCatalog.sanitizedLanguageCodes(values)
            }
            set {
                let values = WebsiteLanguageCatalog.sanitizedLanguageCodes(newValue)
                let data = try? JSONEncoder().encode(values)
                prefs.set(data, forSetting: "LanguageSettings", key: "websiteLanguages")
            }
        }
    }
    
    // MARK: - Add-ons
    struct AddonSettings {
        static var showsAddressBarButton: Bool {
            get {
                prefs.bool(forSetting: "AddonSettings", key: "showsAddressBarButton")
            }
            set {
                prefs.set(newValue, forSetting: "AddonSettings", key: "showsAddressBarButton")
                NotificationCenter.default.post(name: .addonAddressBarButtonDidChange, object: nil)
            }
        }

        static var lastGlobalCheckAt: Date? {
            get {
                guard let value = prefs.string(forSetting: "AddonSettings", key: "lastGlobalCheckAt"),
                      !value.isEmpty else {
                    return nil
                }
                return ISO8601DateFormatter().date(from: value)
            }
            set {
                prefs.set(newValue.map { ISO8601DateFormatter().string(from: $0) }, forSetting: "AddonSettings", key: "lastGlobalCheckAt")
            }
        }
        
        static var pendingApprovalAddonIDs: [String] {
            get {
                guard let data = prefs.data(forSetting: "AddonSettings", key: "pendingApprovalAddonIDs"),
                      !data.isEmpty,
                      let values = try? JSONDecoder().decode([String].self, from: data) else {
                    return []
                }
                return values
            }
            set {
                let data = try? JSONEncoder().encode(newValue)
                prefs.set(data, forSetting: "AddonSettings", key: "pendingApprovalAddonIDs")
            }
        }
    }
}

private var prefs: BrowserPreferences { BrowserPreferences.shared }
