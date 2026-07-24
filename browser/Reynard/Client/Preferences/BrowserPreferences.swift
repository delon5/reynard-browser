key("ClearBrowsingData", "clearsOpenedTabs"): true,
            
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