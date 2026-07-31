//
//  BrowserUpdates.swift
//  Reynard
//
//  Created by Minh Ton on 21/4/26.
//

import Foundation

final class BrowserUpdates: NSObject {
    static let shared = BrowserUpdates()
    
    // CHANGED - computed rather than stored, so the toggle takes effect
    // immediately. See fix_gate_update_check_at_source.py.
    //
    // BrowserUpdates.shared is a singleton whose init runs
    // fetchUpdates() once at startup, and the toggle deliberately does
    // not prompt for a restart. Without this, turning it on after a
    // check had already completed would leave the result in place and
    // the badges would stay visible until the next launch.
    //
    // Every consumer reads this property or observes
    // .appUpdateAvailable; none of them check a preference, which is
    // why two red badge indicators survived the toggle previously.
    // Reporting false here covers all of them at once, including any
    // added later.
    private(set) var hasUpdateInternal: Bool = false
    
    var hasUpdate: Bool {
        guard !Prefs.ExperimentalSettings.hidesUpdateAvailableBanner else {
            return false
        }
        return hasUpdateInternal
    }
    private(set) var latestVersion: String = ""
    private(set) var sourceData: Data?
    var cachedReleaseNotes: NSAttributedString?
    
    private static let sourceURL = "https://github.com/minh-ton/reynard-browser/releases/download/0.0.1-a1/source.json"
    private override init() {
        super.init()
        
        let sideloadIPA = ReynardDirectories.shared.documents.appendingPathComponent("Reynard.ipa")
        try? FileManager.default.removeItem(at: sideloadIPA)
        
        fetchUpdates()
    }
    
    private func fetchUpdates() {
        // Gated at source rather than at each notification surface -
        // see fix_gate_update_check_at_source.py. No request means no
        // hasUpdate, no .appUpdateAvailable, and nothing for any
        // surface to display. Also avoids a pointless network round
        // trip on every launch.
        guard !Prefs.ExperimentalSettings.hidesUpdateAvailableBanner else {
            return
        }
        
        DispatchQueue.global(qos: .background).async {
            guard let url = URL(string: Self.sourceURL),
                  let data = try? Data(contentsOf: url) else { return }
            
            self.sourceData = data
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let apps = json["apps"] as? [[String: Any]],
                  let firstApp = apps.first,
                  let versions = firstApp["versions"] as? [[String: Any]],
                  let latestEntry = versions.first,
                  let latestVersionStr = latestEntry["version"] as? String,
                  let latestDateStr = latestEntry["date"] as? String else { return }
            
            let currentVersionStr = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
            
            let versionIsNewer = Self.isVersion(latestVersionStr, greaterThan: currentVersionStr)
            guard versionIsNewer else { return }
            
            let formatter = ISO8601DateFormatter()
            guard let latestDate = formatter.date(from: latestDateStr) else { return }
            
            if let currentEntry = versions.first(where: { ($0["version"] as? String) == currentVersionStr }),
               let currentDateStr = currentEntry["date"] as? String,
               let currentDate = formatter.date(from: currentDateStr) {
                guard currentDate < latestDate else { return }
            }
            
            DispatchQueue.main.async {
                self.hasUpdateInternal = true
                self.latestVersion = latestVersionStr
                NotificationCenter.default.post(name: .appUpdateAvailable, object: nil)
            }
        }
    }
    
    private static func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
}
