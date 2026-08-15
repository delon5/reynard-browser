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
/// APPENDED across launches, not truncated. Truncating meant the
/// force-quit that clears a wedged tab also destroyed the only record of
/// what wedged it - the failure and the evidence were erased by the same
/// action. Bounded instead by rotating at open: past the cap the file
/// becomes reynard_stdout.prev.txt and a fresh one starts, so at most one
/// previous launch's worth is carried plus the current session.
///
/// Rotation only happens here, at open. Gecko writes to this descriptor
/// with write(2) directly, so there is no interception point to count
/// bytes against mid-session - which is also why the cap is generous.
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

    let logURL = documents.appendingPathComponent("reynard_stdout.txt", isDirectory: false)
    let path = logURL.path

    let maximumBytes: UInt64 = 8 * 1024 * 1024
    if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64,
       size > maximumBytes {
        let previousPath = documents
            .appendingPathComponent("reynard_stdout.prev.txt", isDirectory: false).path
        // rename replaces any existing .prev, so exactly two generations
        // survive.
        _ = rename(path, previousPath)
    }

    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard descriptor >= 0 else {
        return
    }

    dup2(descriptor, STDOUT_FILENO)
    dup2(descriptor, STDERR_FILENO)

    if descriptor != STDOUT_FILENO, descriptor != STDERR_FILENO {
        close(descriptor)
    }

    // Appending means a capture can span several launches, so each needs
    // to say where it began - otherwise the pid is the only clue that the
    // lines above came from a different process.
    let banner = "\n===== SESSION START: pid \(getpid()) \(Date()) =====\n"
    FileHandle.standardError.write(Data(banner.utf8))
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
    // One-shot. AVStreamDataParser is the only thing that could
    // originate a FairPlay key request for MSE content - public
    // AVFoundation cannot, because AVURLAsset is the sole
    // AVContentKeyRecipient - so whether it instantiates and accepts
    // addContentKeyRecipient: decides whether Apple TV+, Netflix and
    // HBO Max are reachable at all. It writes to stderr, redirected
    // above, so the answer arrives in the ordinary device capture.
    //
    // Here and not in AppDelegate, which is where it started: a normal
    // launch takes this branch into GeckoRuntime.main below, and Gecko
    // installs its own AppShellDelegate as the UIApplicationDelegate.
    // The Swift AppDelegate is only ever the delegate in the UIKit-only
    // startup modes, and its didFinishLaunching returns early in exactly
    // those modes - so the call was unreachable on every launch. A
    // capture stamped 116f179 carried no probe output at all for that
    // reason, which reads identically to a negative answer.
    //
    // Before GeckoRuntime.main because that does not return.
    //
    // Remove this call once the question is answered.
    ReynardRunAVStreamDataParserProbe()
    GeckoRuntime.main(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
}
