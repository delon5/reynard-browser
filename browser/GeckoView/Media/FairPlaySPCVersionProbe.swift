//
//  FairPlaySPCVersionProbe.swift
//  GeckoView
//
//  A deliberately narrow diagnostic seam for FairPlay SPC versions.
//

import Foundation

public enum FairPlaySPCVersionProbe {
    public static let environmentKey = "REYNARD_FAIRPLAY_SPC_VERSION"
    public static let fallbackVersion = 1

    /// The version SPC generation will ask for, read fresh for every
    /// request so a change takes effect on the next key request rather
    /// than the next launch.
    ///
    /// Seeded from the environment so an Xcode scheme still works, then
    /// overridden by Prefs.CompatibilitySettings.fairPlaySPCProtocolVersion,
    /// which is what a sideloaded build can actually set: a home-screen
    /// launch has no environment, and nothing else in browser/ reads
    /// ProcessInfo.environment.
    public static var configuredVersion: Int = selectedVersion(
        from: ProcessInfo.processInfo.environment[environmentKey]
    )

    /// Accept one explicit protocol version. Invalid input fails closed to
    /// the existing version-1 behaviour.
    public static func selectedVersion(from rawValue: String?) -> Int {
        switch rawValue {
        case "1": return 1
        case "2": return 2
        case "3": return 3
        default: return fallbackVersion
        }
    }

    /// Decode only the four-byte field this diagnostic is testing and return
    /// only supported values. No SPC bytes are formatted or exposed to logs.
    public static func encodedVersion(in spc: Data) -> UInt32? {
        guard spc.count >= 4 else { return nil }
        let version = spc.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard (UInt32(1)...UInt32(3)).contains(version) else { return nil }
        return version
    }

    /// What to print for a decoded version. A value outside 1...3 is
    /// the single most interesting thing this probe could ever see, so
    /// it is reported rather than folded into "unavailable" along with
    /// "the SPC was too short to have one".
    public static func describeEncodedVersion(in spc: Data) -> String {
        if let version = encodedVersion(in: spc) {
            return String(version)
        }
        guard spc.count >= 4 else { return "unavailable" }
        let raw = spc.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return "unexpected \(raw)"
    }
}
