//
//  ReynardDirectories.swift
//  Reynard
//

import Foundation

struct ReynardDirectories {
    /// AltStore (and likely other sideloading tools) append a unique,
    /// per-installation suffix to the App Group identifier itself, not
    /// just the app's own bundle ID — confirmed directly from a real,
    /// installed device's actual embedded provisioning profile, which
    /// showed "group.com.minh-ton.Reynard.M3ULXVYRUP" rather than the
    /// plain "group.com.minh-ton.Reynard" this code was previously
    /// hardcoded to use. Deriving from the current process's own,
    /// actual bundle identifier at runtime matches whatever's genuinely
    /// in effect for this specific install instead. The Helper's own
    /// bundle ID ends in ".Helper" — stripped here so both the main app
    /// and the Helper derive the exact same, shared group identifier
    /// despite having different bundle IDs themselves.
    static func sharedAppGroupIdentifier() -> String {
        var bundleID = Bundle.main.bundleIdentifier ?? "com.minh-ton.Reynard"
        let helperSuffix = ".Helper"
        if bundleID.hasSuffix(helperSuffix) {
            bundleID = String(bundleID.dropLast(helperSuffix.count))
        }
        return "group.\(bundleID)"
    }

    let applicationSupport: URL
    let caches: URL
    let documents: URL
    let temporary: URL
    /// nil if the App Group container is genuinely unavailable (e.g.
    /// missing entitlement, provisioning issue) — callers should treat
    /// nil the same as "shared storage isn't available right now"
    /// rather than force-unwrapping.
    let sharedContainer: URL?

    var downloads: URL {
        documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    var appData: URL {
        applicationSupport.appendingPathComponent("AppData", isDirectory: true)
    }

    var ddi: URL {
        applicationSupport.appendingPathComponent("DDI", isDirectory: true)
    }

    var geckoApplicationData: URL {
        applicationSupport
            .appendingPathComponent(".mozilla", isDirectory: true)
            .appendingPathComponent("firefox", isDirectory: true)
    }

    var geckoLocalData: URL {
        caches
            .appendingPathComponent("mozilla", isDirectory: true)
            .appendingPathComponent("firefox", isDirectory: true)
    }

    var pairingFile: URL {
        documents.appendingPathComponent("pairingFile.plist", isDirectory: false)
    }

    var jitTemporary: URL {
        temporary.appendingPathComponent("ptrace_jit", isDirectory: false)
    }
    
    /// New — the Helper extension's own JIT self-enablement (added
    /// tonight, RPPairing path) needs the same pairing file and DDI the
    /// main app uses, but app extensions get their own, separate
    /// sandbox container by default. These live in the shared App
    /// Group container instead of this app's own private one, so both
    /// targets can genuinely reach the same, real files. The plain
    /// pairingFile/ddi properties above are left completely untouched —
    /// still used for migrating an existing, already-imported file into
    /// this new location.
    var sharedPairingFile: URL? {
        sharedContainer?.appendingPathComponent("pairingFile.plist", isDirectory: false)
    }
    
    var sharedDDI: URL? {
        sharedContainer?.appendingPathComponent("DDI", isDirectory: true)
    }

    var migrationRecovery: URL {
        applicationSupport
            .deletingLastPathComponent()
            .appendingPathComponent("ReynardMigration", isDirectory: true)
    }

    static let shared: ReynardDirectories = {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let caches = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Reynard data directories are unavailable")
        }

        return ReynardDirectories(
            applicationSupport: applicationSupport,
            caches: caches,
            documents: documents,
            temporary: fileManager.temporaryDirectory,
            sharedContainer: fileManager.containerURL(forSecurityApplicationGroupIdentifier: ReynardDirectories.sharedAppGroupIdentifier())
        )
    }()

    static func make(
        applicationSupport: URL,
        caches: URL,
        documents: URL,
        temporary: URL,
        sharedContainer: URL? = nil
    ) -> ReynardDirectories {
        ReynardDirectories(
            applicationSupport: applicationSupport,
            caches: caches,
            documents: documents,
            temporary: temporary,
            sharedContainer: sharedContainer
        )
    }
    
    /// One-time migration for existing users who already have a
    /// pairing file and/or DDI downloaded in this app's own, private
    /// container from before the Helper extension's own RPPairing JIT
    /// self-enablement (and the shared App Group container it needs)
    /// existed. Safe to call on every launch — genuinely does nothing
    /// once each item has already been migrated once, or if the old
    /// location never had anything there to begin with. Uses move
    /// rather than copy specifically for the DDI, since that could
    /// genuinely be a large file — avoids doubling disk usage.
    static func migrateJITFilesToSharedContainerIfNeeded() {
        let directories = ReynardDirectories.shared
        let fileManager = FileManager.default
        
        if let sharedPairingFile = directories.sharedPairingFile,
           fileManager.fileExists(atPath: directories.pairingFile.path),
           !fileManager.fileExists(atPath: sharedPairingFile.path) {
            try? fileManager.moveItem(at: directories.pairingFile, to: sharedPairingFile)
        }
        
        if let sharedDDI = directories.sharedDDI,
           fileManager.fileExists(atPath: directories.ddi.path),
           !fileManager.fileExists(atPath: sharedDDI.path) {
            try? fileManager.createDirectory(
                at: sharedDDI.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.moveItem(at: directories.ddi, to: sharedDDI)
        }
    }
}
