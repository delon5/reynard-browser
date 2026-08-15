//
//  UserAgentPolicy.swift
//  Reynard
//
//  Created by Minh Ton on 18/6/26.
//

import Foundation
import GeckoView

// MARK: - User Agent Configuration

struct UserAgentConfiguration {
    let override: String?
    let forcesMobileMode: Bool
}

struct UserAgentPolicy {
    // MARK: - FairPlay Streaming

    /// Safari on iPhone, copied verbatim from a device capture rather
    /// than synthesised from the running OS.
    ///
    /// Apple freezes the OS token. Real Safari reports `iPhone OS 18_6`
    /// while `Version/` advances independently - a Charles capture of
    /// this phone playing Apple TV+ in Safari sends exactly:
    ///
    ///   Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X)
    ///   AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0
    ///   Mobile/15E148 Safari/604.1
    ///
    /// Deriving both tokens from operatingSystemVersion produced
    /// "iPhone OS 27_0", which no iPhone has ever sent. Apple TV+
    /// branches on client identity - its playlist request carries
    /// webbrowser=true - and an unrecognised OS token drops us onto the
    /// generic-browser path: MSE + cenc, which ends at
    /// FairPlayCDMProxy::Decrypt and cannot be served. Safari is handed
    /// HLS with KEYFORMAT="com.apple.streamingkeydelivery" and skd://
    /// key URIs, which is the path AVPlayerDecoder owns and the Apple TV
    /// trailer already plays through. That playlist also offers plain
    /// avc1.64001f + mp4a.40.2 ladders, so the HEVC and Dolby rungs we
    /// do not advertise are not required.
    ///
    /// A stale-but-real string beats a live-but-impossible one. Re-capture
    /// from the device rather than computing it when this needs advancing.
    ///
    /// The iPhone form even on iPad, deliberately. It is what makes
    /// MediaSource::VisibleForCurrentGlobal hide window.MediaSource for
    /// these documents - that check tests the override for "iPhone" -
    /// and hiding MSE is the point: a player that finds MSE picks
    /// MSE+FairPlay, which this engine cannot serve. An iPad UA would
    /// leave MSE visible and walk the player into the path that does
    /// not work.
    static let safariMobileUserAgent: String =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/27.0 Mobile/15E148 Safari/604.1"

    /// Services that hand FairPlay over native HLS to Safari on iOS,
    /// and Widevine to anything that looks like Firefox.
    ///
    /// netflix.com is deliberately absent: its player is MSE+EME only
    /// and never offers an HLS URL to a browser, so a Safari user agent
    /// changes nothing there. bitmovin.com is absent too - its DRM demo
    /// works today under the default user agent, and this list should
    /// not perturb the one known-good test.
    ///
    /// Matched by DomainMatcher, so subdomains are covered.
    static let fairPlayStreamingDomains = [
        "primevideo.com",
        "max.com",
        "hbomax.com",
        "disneyplus.com",
        "hulu.com",
        "peacocktv.com",
        "paramountplus.com",
        "tv.apple.com",
    ]

    // MARK: - Policy Resolution

    func configuration(for url: String, prefersDesktopMode: Bool) -> UserAgentConfiguration {
        let host = DomainMatcher.host(from: url)
        let geckoMajorVersion = GeckoRuntime.version.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? "0"
        let chromeMajorVersion = (Int(geckoMajorVersion) ?? 0) + 4

        // It's sad to have the Android UA, because Gecko + iOS
        // is a super weird combination that websites don't expect!
        let androidMobileUserAgent = "Mozilla/5.0 (Android 15; Mobile; rv:\(geckoMajorVersion).0) Gecko/\(geckoMajorVersion).0 Firefox/\(geckoMajorVersion).0"
        let androidDesktopUserAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:\(geckoMajorVersion).0) Gecko/20100101 Firefox/\(geckoMajorVersion).0"
        let googleMobileUserAgent = "Mozilla/5.0 (Linux; Android 15; Nexus 5 Build/MRA58N) FxQuantum/\(geckoMajorVersion).0 AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajorVersion).0.0.0 Mobile Safari/537.36"

        // Always use the Android mobile user agent for AMO to
        // allow addons installation.
        if host == "addons.mozilla.org" {
            return UserAgentConfiguration(override: androidMobileUserAgent, forcesMobileMode: true)
        }

        // Addon setting pages also require the Android user agent to work properly.
        if url.starts(with: "moz-extension://") {
            return UserAgentConfiguration(override: androidMobileUserAgent, forcesMobileMode: true)
        }

        // A user-entered override for this specific site takes priority
        // over everything below, including the global custom user
        // agent — a per-site choice is more specific than a general one.
        // Matched the same way as the existing Android-UA domain list
        // (exact host, or any subdomain of it) so that e.g. an override
        // entered for "youtube.com" also applies on "www.youtube.com"
        // and "m.youtube.com".
        if Prefs.CompatibilitySettings.enablePerSiteUserAgentOverrides,
           let host,
           let matchedDomain = Prefs.CompatibilitySettings.perSiteUserAgentOverrides.keys.first(where: {
               DomainMatcher.matches(host: host, domain: $0)
           }),
           let siteOverride = Prefs.CompatibilitySettings.perSiteUserAgentOverrides[matchedDomain] {
            let trimmedSiteOverride = siteOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSiteOverride.isEmpty {
                return UserAgentConfiguration(override: trimmedSiteOverride, forcesMobileMode: false)
            }
        }

        // A deliberately-entered global custom user agent takes
        // priority over the general Android/Google compatibility
        // heuristics below — the person picked this string on purpose
        // for every site that doesn't have a more specific override.
        if Prefs.CompatibilitySettings.useCustomUserAgent {
            let trimmedCustomUserAgent = Prefs.CompatibilitySettings.customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCustomUserAgent.isEmpty {
                return UserAgentConfiguration(override: trimmedCustomUserAgent, forcesMobileMode: false)
            }
        }

        // A streaming service will only offer FairPlay to something
        // that looks like Safari on iPhone. Given a Firefox user agent
        // it offers Widevine instead - which has no iOS build and never
        // will - so the request is made, refused, and the site reports
        // the browser as unsupported without either side ever
        // mentioning FairPlay. The AVPlayer pipeline is never reached.
        //
        // Placed BELOW the per-site override and the global custom user
        // agent on purpose: a string entered by hand is more specific
        // than this list and should win. Placed ABOVE the Google and
        // Android heuristics for the same reason in reverse - the
        // compatibility user agent is the general case, and would
        // otherwise stomp the one setting these sites actually need.
        if Prefs.CompatibilitySettings.useSafariUserAgentForStreaming,
           let host,
           Self.fairPlayStreamingDomains.contains(where: {
               DomainMatcher.matches(host: host, domain: $0)
           }) {
            return UserAgentConfiguration(
                override: Self.safariMobileUserAgent,
                forcesMobileMode: false
            )
        }

        // I have so many people reporting broken UI issues, login
        // issues, etc on Google services, so this is a compatibility
        // hack stolen from the Google Search Fixer extension.
        if Prefs.CompatibilitySettings.useAndroidUserAgent && !prefersDesktopMode,
           host?.split(separator: ".").contains("google") == true {
            return UserAgentConfiguration(override: googleMobileUserAgent, forcesMobileMode: false)
        }

        let usesAndroidUserAgent = Prefs.CompatibilitySettings.useAndroidUserAgent || (host.map { host in
            Prefs.CompatibilitySettings.androidUserAgentDomains.contains { DomainMatcher.matches(host: host, domain: $0) }
        } ?? false)

        guard usesAndroidUserAgent else {
            return UserAgentConfiguration(override: nil, forcesMobileMode: false)
        }
        return UserAgentConfiguration(
            override: prefersDesktopMode ? androidDesktopUserAgent : androidMobileUserAgent,
            forcesMobileMode: false
        )
    }
}
