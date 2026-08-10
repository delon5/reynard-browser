//
//  GeckoRuntime.swift
//  Reynard
//
//  Created by Minh Ton on 1/2/26.
//

import Foundation
import UIKit

public protocol GeckoScreenOrientationDelegate: AnyObject {
    func lockScreenOrientation(
        to requestedOrientations: UIInterfaceOrientationMask,
        completion: @escaping (GeckoOrientationLockResult) -> Void
    )
    func unlockScreenOrientation()
}

public final class GeckoScreenOrientationController {
    public weak var delegate: GeckoScreenOrientationDelegate?
}

class GeckoRuntimeImpl: NSObject, SwiftGeckoViewRuntime {
    func runtimeDispatcher() -> any SwiftEventDispatcher {
        return GeckoEventDispatcherWrapper.runtimeInstance
    }
    
    func dispatcher(byName name: UnsafePointer<CChar>!) -> any SwiftEventDispatcher {
        return GeckoEventDispatcherWrapper.lookup(byName: String(cString: name))
    }
    
    @objc(childProcessDidStartWithPID:processType:)
    func childProcessDidStart(withPID pid: Int32, processType: String) {
        // DIAGNOSTIC - see fix_log_child_process_types.py's
        // docstring. Purely additive: processType was already
        // available here, already used for jetsam control below and
        // an internal notification, but never once logged - this
        // directly answers what each spawned child process actually
        // is (content/gpu/socket/rdd/utility/etc.), rather than
        // inferring it from patch code alone.
        //
        // CORRECTED - see
        // fix_gecko_runtime_log_linker_error.py's docstring. Uses
        // NSLog, not logger() - this file compiles into the separate
        // GeckoView framework target, where logger's own actual
        // implementation (JITUtils.m) isn't linked in, confirmed
        // directly from a real, actual build failure (undefined
        // symbol "_logger" at link time). NSLog needs no cross-target
        // dependency and is captured by idevicesyslog's own process-
        // name filter the same way logger's output is.
        NSLog("childProcessDidStart: pid %d, processType=%@", pid, processType)
        
        // Update jetsam limit for the child process
        updateJetsamControl(pid)
        
        NotificationCenter.default.post(
            name: Notification.Name("GeckoRuntime.ChildProcessDidStart"),
            object: nil,
            userInfo: [
                "pid": NSNumber(value: pid),
                "processType": processType
            ]
        )
    }

    /// Optional SwiftGeckoViewRuntime hook: Gecko's AVPlayerDecoder
    /// reaches the embedder's AVPlayer through this, via
    /// GetSwiftRuntime(), when media.reynard.avplayer.enabled is on.
    /// It runs in whichever process owns the media element — content
    /// processes included — which is exactly why AVPlayerHost lives in
    /// this framework rather than the app target.
    ///
    /// Returns AnyObject rather than id<GeckoAVPlayerHost>: that
    /// protocol only exists in GeckoViewSwiftSupport.h once the
    /// FairPlay engine patches are built in, and the C++ side looks the
    /// method up by selector, so the declared type never matters at
    /// runtime.
    @objc(avPlayerHost)
    func avPlayerHost() -> AnyObject? {
        return AVPlayerHost.shared
    }

    func lockScreenOrientation(
        _ orientationMask: UInt,
        completion: @escaping (GeckoOrientationLockResult) -> Void
    ) {
        let requestedOrientations = UIInterfaceOrientationMask(rawValue: orientationMask)
        DispatchQueue.main.async {
            guard let delegate = GeckoRuntime.orientationController.delegate else {
                completion(.notSupported)
                return
            }
            delegate.lockScreenOrientation(
                to: requestedOrientations,
                completion: completion
            )
        }
    }
    
    func unlockScreenOrientation() {
        DispatchQueue.main.async {
            GeckoRuntime.orientationController.delegate?.unlockScreenOrientation()
        }
    }
}

public class GeckoRuntime {
    static let runtime = GeckoRuntimeImpl()

    public static let orientationController = GeckoScreenOrientationController()
    
    public static var version: String {
        return GeckoRuntimeBridge.version()
    }

    /// One line per process at startup identifying the running build, so
    /// a device capture self-identifies which binary produced it instead
    /// of having to be inferred from which diagnostic strings happen to
    /// appear. CFBundleVersion is the 7-char commit build-app.sh stamps
    /// in - the same value shown on Settings > About - and every target
    /// (app and extensions) carries it, so `Bundle.main` resolves it in
    /// content processes too.
    ///
    /// stderr, not NSLog or logger(): this file is in the GeckoView
    /// framework where logger() does not link (see childProcessDidStart
    /// above), and stderr is the stream device captures pick up from
    /// content processes - the same channel the engine's printf_stderr
    /// output lands in, so the stamp sits with the avPlayer lines rather
    /// than in the parent-only log.
    private static func logBuildStamp(role: String) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info?["CFBundleVersion"] as? String ?? "?"
        fputs("reynardBuild: \(role) \(version) (\(commit))\n", stderr)
        fflush(stderr)
    }
    
    public static func setLocale(acceptLanguages: String) {
        GeckoEventDispatcherWrapper.runtimeInstance.dispatch(
            type: "GeckoView:SetLocale",
            message: [
                "acceptLanguages": acceptLanguages
            ]
        )
    }
    
    public static func setDefaultPrefs(_ preferences: [String: Any]) {
        GeckoEventDispatcherWrapper.runtimeInstance.dispatch(
            type: "GeckoView:SetDefaultPrefs",
            message: preferences
        )
    }
    
    public static func main(
        argc: Int32,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>
    ) {
        logBuildStamp(role: "main")
        MainProcessInit(argc, argv, runtime)
    }

    public static func childMain(
        xpcConnection: xpc_connection_t,
        process: GeckoProcessExtension
    ) {
        logBuildStamp(role: "child")
        ChildProcessInit(xpcConnection, process, runtime)
    }
}
