//
//  SystemProxyBridge.swift
//  Reynard
//
//  Feeds iOS's Wi-Fi proxy configuration to Gecko.
//
//  Gecko reads system proxy settings through nsISystemProxySettings, and
//  toolkit/moz.build only builds a provider for gtk, cocoa, windows and
//  android - MOZ_WIDGET_TOOLKIT here is "uikit", which matches none of
//  them. So no provider is compiled at all, while network.proxy.type
//  defaults to 5 (PROXYCONFIG_SYSTEM): the engine is asking for a system
//  proxy that nothing in the process can answer for. A proxy set in
//  iOS Settings was silently ignored, and the resolved configuration was
//  neither "system" nor an honest "direct".
//
//  Rather than port a provider into the engine, this reads the same
//  settings CFNetwork exposes and writes them to the network.proxy.*
//  prefs, which are plain Necko and entirely platform-neutral.
//
//  LIMITS, inherited from iOS rather than chosen here:
//    * Only the HTTP proxy and PAC keys exist on this platform.
//      CFProxySupport.h marks HTTPS, SOCKS, FTP, the exceptions list and
//      WPAD as CF_AVAILABLE(10_6, NA) - macOS only - so there is nothing
//      to read for them and referencing them would not compile.
//    * iOS applies its single proxy to both HTTP and HTTPS, so both
//      network.proxy.http and network.proxy.ssl are pointed at it.
//    * The setting is per-Wi-Fi-network and does not exist for cellular,
//      so on cellular this correctly resolves to direct.
//

import Foundation
import GeckoView

enum SystemProxyBridge {
    /// Gecko's nsIProtocolProxyService constants.
    private enum ProxyType {
        static let direct: Int = 0
        static let manual: Int = 1
        static let pac: Int = 2
    }

    /// Reads the current system configuration and applies it.
    ///
    /// Every key is written on every pass, including the empty ones. A
    /// proxy that is turned off has to clear the host it left behind,
    /// otherwise switching networks would keep routing through a proxy
    /// that is no longer configured.
    static func apply() {
        var prefs: [String: Any] = [
            "network.proxy.type": ProxyType.direct,
            "network.proxy.http": "",
            "network.proxy.http_port": 0,
            "network.proxy.ssl": "",
            "network.proxy.ssl_port": 0,
            "network.proxy.autoconfig_url": "",
        ]

        let settings = CFNetworkCopySystemProxySettings()?
            .takeRetainedValue() as? [String: Any]

        if let settings {
            let pacEnabled = (settings[kCFNetworkProxiesProxyAutoConfigEnable as String] as? NSNumber)?.boolValue ?? false
            let pacURL = settings[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String

            let httpEnabled = (settings[kCFNetworkProxiesHTTPEnable as String] as? NSNumber)?.boolValue ?? false
            let httpHost = settings[kCFNetworkProxiesHTTPProxy as String] as? String
            let httpPort = (settings[kCFNetworkProxiesHTTPPort as String] as? NSNumber)?.intValue ?? 0

            // PAC first: iOS presents Automatic and Manual as mutually
            // exclusive, and a stale manual host can still be present in
            // the dictionary when Automatic is selected.
            if pacEnabled, let pacURL, !pacURL.isEmpty {
                prefs["network.proxy.type"] = ProxyType.pac
                prefs["network.proxy.autoconfig_url"] = pacURL
                logger("systemProxy: PAC -> \(pacURL)")
            } else if httpEnabled, let httpHost, !httpHost.isEmpty, httpPort > 0 {
                prefs["network.proxy.type"] = ProxyType.manual
                prefs["network.proxy.http"] = httpHost
                prefs["network.proxy.http_port"] = httpPort
                // iOS has one proxy field and applies it to both schemes;
                // Gecko needs each named, and this version has no
                // share_proxy_settings pref to do it for us.
                prefs["network.proxy.ssl"] = httpHost
                prefs["network.proxy.ssl_port"] = httpPort
                logger("systemProxy: manual -> \(httpHost):\(httpPort)")
            } else {
                logger("systemProxy: none configured - direct")
            }
        } else {
            logger("systemProxy: CFNetworkCopySystemProxySettings returned nothing - direct")
        }

        GeckoRuntime.setDefaultPrefs(prefs)
    }
}
