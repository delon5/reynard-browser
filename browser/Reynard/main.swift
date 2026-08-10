//
//  main.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import Foundation
import GeckoView
import UIKit
import Darwin

@available(iOS, introduced: 13.0, obsoleted: 14.0)
private func configureUnsandboxedAppDataDirectories(_ directories: ReynardDirectories) {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
        return
    }
    
    let appDataDirectory = directories.caches
        .appendingPathComponent(bundleIdentifier, isDirectory: true)
        .appendingPathComponent(".mozilla", isDirectory: true)
        .appendingPathComponent("firefox", isDirectory: true)
    
    do {
        try FileManager.default.createDirectory(
            at: appDataDirectory,
            withIntermediateDirectories: true
        )
    } catch {
        return
    }
    
    setenv("MOZ_APP_DATA", appDataDirectory.path, 1)
    setenv("MOZ_LOCAL_APP_DATA", appDataDirectory.path, 1)
}

/// Points stdout and stderr at a real file.
///
/// Gecko's JS dump() is a blocking fputs to stdout. When stdout is a
/// pipe that nothing drains - which is what a sideloaded app gets - a
/// full buffer makes write(2) block indefinitely, and if that happens on
/// the main thread the scene-update watchdog kills the app ten seconds
/// later. That is the 2026-08-06 17:54 crash exactly.
///
/// A regular file cannot block that way, and unlike /dev/null it keeps
/// the output, which is currently the only route to finding out what is
/// calling dump() in the first place - the crash report carries no
/// symbolicated JS frames.
///
/// Truncated per launch so it stays bounded.
///
/// The Experimental "Standard Output Log" toggle chooses the DESTINATION,
/// never whether to redirect: with it off the streams go to /dev/null.
/// Leaving them pointed at the inherited pipe is the hang above, so
/// "off" has to mean discard rather than skip.
///
/// The preference is read from a flat bridge key rather than through
/// Prefs: this runs before UIApplicationMain, so registerDefaults() has
/// not happened and the profile-scoped key may not exist yet. Absent
/// means enabled, matching the registered default.
private func redirectStandardStreamsToFile() {
    let defaults = UserDefaults.standard
    let wantsLogFile = defaults.object(forKey: BrowserPreferences.stdoutLogBridgeKey) == nil
        ? true
        : defaults.bool(forKey: BrowserPreferences.stdoutLogBridgeKey)

    guard wantsLogFile else {
        let discard = open("/dev/null", O_WRONLY)
        guard discard >= 0 else {
            return
        }
        dup2(discard, STDOUT_FILENO)
        dup2(discard, STDERR_FILENO)
        if discard != STDOUT_FILENO, discard != STDERR_FILENO {
            close(discard)
        }
        return
    }

    guard let documents = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        return
    }

    let path = documents.appendingPathComponent("reynard_stdout.txt", isDirectory: false).path
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else {
        return
    }

    dup2(descriptor, STDOUT_FILENO)
    dup2(descriptor, STDERR_FILENO)

    if descriptor != STDOUT_FILENO, descriptor != STDERR_FILENO {
        close(descriptor)
    }
}

// First, before anything can write to stdout.
redirectStandardStreamsToFile()

let recoveryFailed: Bool
do {
    try ReynardMigrationRecovery().recoverPendingTransactions()
    recoveryFailed = false
} catch {
    recoveryFailed = true
}

let startupMode = ReynardStartupMode.resolve(recoveryFailed: recoveryFailed)
ReynardStartupMode.current = startupMode
let directories = ReynardDirectories.shared

if startupMode.usesUIKitOnlyStartup {
    _ = UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(AppDelegate.self)
    )
} else {
    UserDataMigration.shared.run()
    ReynardDirectories.migrateJITFilesToSharedContainerIfNeeded()
    JITController.shared.start()
    if #unavailable(iOS 14.0),
       getEntitlementValue("com.apple.private.security.no-sandbox") {
        configureUnsandboxedAppDataDirectories(directories)
    }
    GeckoRuntime.main(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
}
