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

private func configureSandboxExtension() {
    guard let documentsDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        return
    }
    
    typealias IssueFileExtension = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
    
    // I can't seem to find any public documentation for these stuff on iOS?
    // Also I'm surprised that this works on iOS
    // https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/spi/darwin/SandboxSPI.h
    // https://github.com/WebKit/WebKit/blob/main/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm
    guard let sandboxHandle = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_LAZY),
          let symbol = dlsym(sandboxHandle, "sandbox_extension_issue_file") else {
        return
    }
    
    let issueFileExtension = unsafeBitCast(symbol, to: IssueFileExtension.self)
    let extensionClass = "com.apple.app-sandbox.read"
    
    guard let token = extensionClass.withCString({ extensionClassPointer in
        documentsDirectoryURL.path.withCString { pathPointer in
            issueFileExtension(extensionClassPointer, pathPointer, 0)
        }
    }) else {
        return
    }
    
    let tokenString = String(cString: token)
    free(UnsafeMutableRawPointer(token))
    setenv("MOZ_DOCUMENTS_SANDBOX_EXTENSION", tokenString, 1)
}

// First, before anything can write to stdout.
redirectStandardStreamsToFile()

// WHY THE VIDEO LOST ITS COMPOSITOR SURFACE - see mse_fix_160c's
// docstring, and mse_fix_160's for what this is asking.
//
// Top level, not inside configureUnsandboxedAppDataDirectories, which
// is @available(obsoleted: 14.0) and gated on the no-sandbox
// entitlement - it has never run on this device, and neither had this.
//
// After redirectStandardStreamsToFile above, so what it prints reaches
// the capture rather than the streams' pre-redirect destination.
//
// The whole crate rather than one module: the warning is in
// webrender::tile_cache, picture.rs carries no log macros at all, and
// a filter that matches nothing is indistinguishable from a clean run.
if getenv("RUST_LOG") == nil {
    setenv("RUST_LOG", "webrender=warn", 1)
}
if let reynardRustLog = getenv("RUST_LOG") {
    fputs("reynardWR: RUST_LOG=\(String(cString: reynardRustLog))\n", stderr)
} else {
    fputs("reynardWR: RUST_LOG is NOT SET\n", stderr)
}
// A second, independent route for the same warning: GeckoLogger tries
// Gecko's own logging first and only falls back to env_logger.
if getenv("MOZ_LOG") == nil {
    setenv("MOZ_LOG", "webrender:4", 1)
}
if let reynardMozLog = getenv("MOZ_LOG") {
    fputs("reynardWR: MOZ_LOG=\(String(cString: reynardMozLog))\n", stderr)
}
fflush(stderr)

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
    configureSandboxExtension()
    // ReynardRunAVStreamDataParserProbe() ran here and is done. It
    // answered the question it was written for, on device:
    // AVStreamDataParser exists, declares AVContentKeyRecipient, accepts
    // addContentKeyRecipient:, and - fed Apple's encrypted MSE init
    // segment - raised a key request through
    // streamDataParser:didProvideContentKeySpecifier:forTrackID: with no
    // AVURLAsset anywhere. MSE+FairPlay has a route.
    //
    // AVStreamDataParserProbe.m stays for whoever builds that route, but
    // do not call it again as it stands: it crashed the app on every
    // launch at exactly that callback, because its synthesised method
    // signature types forTrackID: - a CMPersistentTrackID - as an object
    // and then sends it isKindOfClass:. Fix that before re-enabling.
    //
    // The rendering half is still open, and FairPlayStreamParser's probe
    // asks what can be asked without a key server. Gated on a MARKER file
    // rather than on the segment, and that is the whole point: the last
    // probe ran unconditionally, crashed before the first frame, and the
    // only way out was another build. Deleting fps-render-probe.on in
    // Files recovers this one, so a bad result costs a file rather than a
    // cycle. The segment is Apple's, from the FPS Server SDK.
    // directories, not ReynardDirectories.shared: on iOS 13 unsandboxed
    // builds configureUnsandboxedAppDataDirectories above has already
    // repointed these, and the probe must read the same Documents the
    // user dropped the segment into.
    let documents = directories.documents
    let renderProbeMarker = documents.appendingPathComponent("fps-render-probe.on")
    if FileManager.default.fileExists(atPath: renderProbeMarker.path) {
        let segment = documents
            .appendingPathComponent("elementary-stream-video-header-keyid-1.m4v")
        if let initSegment = try? Data(contentsOf: segment) {
            FairPlayStreamParser.shared.runRenderProbe(initSegment: initSegment)
        } else {
            FileHandle.standardError.write(Data(
                "fpsParser: render probe marker present but no init segment beside it\n".utf8))
        }
    }
    GeckoRuntime.main(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
}
