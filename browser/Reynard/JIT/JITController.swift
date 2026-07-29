//
//  JITController.swift
//  Reynard
//
//  Created by Minh Ton on 11/3/26.
//

import Foundation
import Darwin
import UIKit
import os

final class JITController {
    static let shared = JITController()
    
    private let attachQueue = DispatchQueue(label: "com.minh-ton.Reynard.JITController.AttachQueue", qos: .userInitiated)
    private let watchdogQueue = DispatchQueue(label: "com.minh-ton.Reynard.JITController.WatchdogQueue", qos: .userInitiated)
    private var attachedPIDs: Set<Int32> = []
    private var preflightWatchdogs: [Int32: DispatchWorkItem] = [:]
    // Moved here from the Helper Process Attach Delegation extension
    // below - Swift extensions cannot contain stored properties, a
    // real compiler error caught building this for the first time.
    // Guards against redundant, already-queued work piling up during a
    // genuine hang - see fix_helper_attach_queue_guard.py's docstring
    // for the full reasoning. Checked and set synchronously on
    // whichever thread calls processPendingHelperAttachRequests()
    // (always the main thread in practice), cleared back on the main
    // thread too once the queued work finishes, so this flag is only
    // ever touched from one thread - safe without needing a lock.
    private var isProcessingHelperAttachRequests = false
    // Only ever touched from within the watchdog closure below, which
    // always runs on watchdogQueue - single-queue access, no lock
    // needed, consistent with how preflightWatchdogs/attachedPIDs are
    // themselves always touched only from attachQueue.
    private var retriedWatchdogPIDs: Set<Int32> = []
    private var hasHandledFailure = false
    private(set) var isJITLessModeActive = false
    private var pendingFailureAction: (() -> Void)?
    private let preflightTimeoutSeconds: Int = 5
    private let failurePresentationRetryLimit = 12
    
    private init() {}
    
    // For TrollStore or jailbroken devices
    private func usePtraceJIT() -> Bool {
        getEntitlementValue("com.apple.private.security.no-sandbox")
    }
    
    func start() {
        guard usePtraceJIT() || !isDDIMissing() else {
            hasHandledFailure = true
            presentMissingDDIFailureScreen()
            return
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChildProcessNotification(_:)),
            name: .geckoRuntimeChildProcessDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleJITDisconnectNotification(_:)),
            name: .jitEndpointMonitorDidFail,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        startListeningForHelperAttachRequests()
    }
    
    private func isDDIMissing() -> Bool {
        Prefs.JITSettings.isJITEnabled && !DDIManager.shared.hasRequiredDDIFiles()
    }
    
    private func shouldAttach(to processType: String) -> Bool {
        let normalized = processType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "tab"
    }
    
    private static let txmLog = OSLog(subsystem: "com.minh-ton.Reynard", category: "TXMDetection")
    
    // REVERTED - the file-existence check that was here (matching an
    // older StikDebug commit's detectLocalTXM()) has been removed.
    // StikDebug's own PR #416, "Fix TXM detection on iOS 27" (merged
    // June 17), replaced that exact approach with this device-model /
    // iOS-version-threshold check instead - confirming the older
    // commit this was ported from predated their own fix for this
    // exact problem, which is why it returned false on this device
    // despite DolphiniOS confirming working TXM on the same hardware.
    // "Adapted from StikDebug" was correct the first time; this
    // restores that original logic exactly, keeping it static (needed
    // for the Settings UI row) and adding lightweight logging for
    // future visibility.
    static func hasTXMSupport() -> Bool {
        var systemInfo = utsname()
        uname(&systemInfo)
        let hardware = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        
        if #available(iOS 27.0, *) {
            let result = hardware != "iPad8,11" && hardware != "iPad8,12"
            os_log("hasTXMSupport: hardware=%{public}@, iOS 27+ branch, result=%{public}@", log: txmLog, type: .default, hardware, result ? "true" : "false")
            return result
        }
        
        if #available(iOS 26.0, *) {
            let pattern = hardware.hasPrefix("iPad")
            ? #"iPad(\d+),(\d+)"#
            : #"iPhone(\d+),(\d+)"#
            let threshold: Double = hardware.hasPrefix("iPad") ? 14.5 : 14.2
            
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: hardware,
                    range: NSRange(hardware.startIndex..., in: hardware)
                  ),
                  let majorRange = Range(match.range(at: 1), in: hardware),
                  let minorRange = Range(match.range(at: 2), in: hardware),
                  let major = Double(hardware[majorRange]),
                  let minor = Double(hardware[minorRange])
            else {
                os_log("hasTXMSupport: hardware=%{public}@, iOS 26+ branch, failed to parse version - returning false", log: txmLog, type: .default, hardware)
                return false
            }
            
            let divisor = pow(10.0, Double(String(Int(minor)).count))
            let ver = major + (minor / divisor)
            let result = ver >= threshold
            os_log("hasTXMSupport: hardware=%{public}@, iOS 26+ branch, ver=%{public}f, threshold=%{public}f, result=%{public}@", log: txmLog, type: .default, hardware, ver, threshold, result ? "true" : "false")
            return result
        }
        
        os_log("hasTXMSupport: hardware=%{public}@, pre-iOS-26 - returning false", log: txmLog, type: .default, hardware)
        return false
    }
    
    private func newDeviceOSVersion() -> DeviceOSVersion {
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceOSVersion(
            majorVersion: Int32(operatingSystemVersion.majorVersion),
            minorVersion: Int32(operatingSystemVersion.minorVersion),
            patchVersion: Int32(operatingSystemVersion.patchVersion)
        )
    }
    
    private func newJITRuntimeInfo() -> JITRuntimeInfo {
        return JITRuntimeInfo(
            hasTXMSupport: Self.hasTXMSupport() ? 1 : 0,
            deviceOSVersion: newDeviceOSVersion()
        )
    }
    
    func childProcessDidStart(pid: Int32, processType: String) {
        guard pid > 0 else {
            return
        }
        
        guard !isJITLessModeActive, !hasHandledFailure else {
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        guard usePtraceJIT() || Prefs.JITSettings.isJITEnabled else {
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        guard shouldAttach(to: processType) else {
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        attachQueue.async {
            if self.attachedPIDs.contains(pid) {
                return
            }
            self.attachedPIDs.insert(pid)
            self.schedulePreflightWatchdog(for: pid)
            self.attachToProcess(pid: pid)
        }
    }
    
    // Wraps the actual, synchronous JITEnabler.shared.enableJIT(...)
    // call with a bounded wait - see
    // fix_attach_queue_bounded_wait.py's docstring for the full
    // reasoning. Dispatched to DispatchQueue.global - a separate,
    // CONCURRENT queue, deliberately not attachQueue itself or any
    // other serial queue, which would just relocate the same
    // cascading-jam problem rather than fix it. Shared by
    // attachToProcess below and attachToHelperProcess in the
    // delegation extension - both call the same underlying enableJIT,
    // and both need the same protection, since either one hanging can
    // otherwise jam attachQueue for everyone else queued behind it.
    private func boundedEnableJIT(forPID pid: Int32) -> (Bool, NSError?) {
        // GUARD - see fix_guard_concurrent_vattach.py's docstring. If
        // a previous vAttach call might still genuinely be running in
        // the background (orphaned by an earlier timeout below, never
        // cleared), don't pile a new, concurrent attempt on top of
        // it. A generous 60s staleness window avoids ever blocking
        // permanently if the orphaned call genuinely never returns.
        if let inFlightSince = JITEnabler.vAttachInFlightSince() {
            let age = CFAbsoluteTimeGetCurrent() - inFlightSince.timeIntervalSinceReferenceDate
            if age < 60.0 {
                logger(String(format: "boundedEnableJIT: skipping new attempt for pid %d - a previous vAttach call may still be in flight (started %.0fs ago)", pid, age))
                return (false, NSError(domain: "Reynard.JIT", code: Int(EBUSY), userInfo: [NSLocalizedDescriptionKey: "Skipped: another vAttach call may still be in flight"]))
            }
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Bool, NSError?) = (false, NSError(domain: "Reynard.JIT", code: -1, userInfo: [NSLocalizedDescriptionKey: "Internal error: bounded wait result never set"]))
        let boundedCallStart = CFAbsoluteTimeGetCurrent()
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try JITEnabler.shared.enableJIT(forPID: pid, hasTXMSupport: Self.hasTXMSupport())
                result = (true, nil)
            } catch {
                result = (false, error as NSError)
            }
            // DIAGNOSTIC - see fix_log_orphaned_call_completion.py's
            // docstring. Purely additive: logs whenever this background
            // call actually finishes, including if that happens well
            // after the outer 20s bound below already gave up and
            // returned to the caller - answering whether a hang here
            // is genuinely permanent (like process_control_new was,
            // confirmed by a direct ~3 minute wait) or just slower
            // than 20s.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - boundedCallStart) * 1000.0
            logger(String(format: "boundedEnableJIT: background call for pid %d actually completed after %.0fms (success=%@)", pid, elapsedMs, result.0 ? "YES" : "NO"))
            semaphore.signal()
        }
        
        if semaphore.wait(timeout: .now() + 20.0) == .timedOut {
            // Orphaned - the background call above may still be
            // running and will eventually complete or fail on its
            // own, unobserved. A real, accepted trade-off: this
            // prevents an indefinite jam of attachQueue at the cost of
            // a possible, bounded amount of continued background
            // contention if the orphaned call is itself competing for
            // the same device-side resources as a newer attempt that
            // gets to run in its place. Preferred over the
            // alternative directly observed in testing: total,
            // permanent gridlock for every attach queued behind a
            // single hang.
            //
            // Also invalidates the cached DeviceProvider itself - real
            // capture evidence showed every attempt that reused the
            // same cached provider hanging at the identical step
            // (process_control_new), 100% of the time, not just this
            // one. The next attempt gets a genuinely fresh connection
            // instead of inheriting a possibly-already-poisoned one.
            JITEnabler.shared.invalidateSharedProviderAfterTimeout()
            return (false, NSError(domain: "Reynard.JIT", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "Attach timed out after 20s (may still be running in the background)"]))
        }
        
        return result
    }
    
    private func attachToProcess(pid: Int32) {
        let (success, error) = boundedEnableJIT(forPID: pid)
        cancelPreflightWatchdog(for: pid)
        if success {
            ReportJITStatusForChild(pid, true, newJITRuntimeInfo())
        } else {
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            handleJITFailure(error: error ?? NSError(domain: "Reynard.JIT", code: -1, userInfo: nil))
        }
    }
    
    private func schedulePreflightWatchdog(for pid: Int32) {
        var watchdog: DispatchWorkItem?
        watchdog = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            
            guard let watchdog, !watchdog.isCancelled else {
                return
            }
            
            // One retry before giving up - covers the confirmed,
            // intermittent (~8-10% background rate) stall on
            // lockdownd_connect_rsd inside ensureDDIMounted, which
            // never returns an error at all, just never returns.
            //
            // LIMITATION, deliberately not hidden: attachToProcess
            // runs on the serial attachQueue. If this specific
            // attempt is genuinely, indefinitely stuck (not just
            // slow), queuing a fresh attempt behind it on that same
            // queue won't help - it'll simply wait behind the same
            // stuck call, forever. This only recovers the
            // slow-but-eventually-resolving case, or a different,
            // faster-failing error. Given the measured ~90%
            // single-attempt success rate, that's expected to help in
            // practice - it is not a complete fix for a true
            // indefinite hang.
            guard self.retriedWatchdogPIDs.contains(pid) else {
                self.retriedWatchdogPIDs.insert(pid)
                self.attachQueue.async {
                    self.schedulePreflightWatchdog(for: pid)
                    self.attachToProcess(pid: pid)
                }
                return
            }
            
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            self.handleJITFailure(error: NSError(domain: "Reynard.JIT", code: Int(ETIMEDOUT), userInfo: nil))
        }
        
        guard let watchdog else {
            return
        }
        
        preflightWatchdogs[pid] = watchdog
        watchdogQueue.asyncAfter(deadline: .now() + .seconds(preflightTimeoutSeconds), execute: watchdog)
    }
    
    private func cancelPreflightWatchdog(for pid: Int32) {
        preflightWatchdogs[pid]?.cancel()
        preflightWatchdogs.removeValue(forKey: pid)
    }
    
    private func cancelAllPreflightWatchdogs() {
        for pid in preflightWatchdogs.keys {
            cancelPreflightWatchdog(for: pid)
        }
    }
    
    private func handleJITFailure(error: NSError) {
        DispatchQueue.main.async {
            guard !self.hasHandledFailure else {
                return
            }
            self.hasHandledFailure = true
            self.presentEnablementFailureScreen(
                error: error,
                showsErrorDetails: error.code != Int(ETIMEDOUT)
            )
        }
    }
    
    private func presentEnablementFailureScreen(error: NSError, showsErrorDetails: Bool, retryCount: Int = 0) {
        guard retryCount <= failurePresentationRetryLimit else {
            return
        }
        
        guard Self.canPresentFailureUI() else {
            pendingFailureAction = { [weak self] in
                self?.presentEnablementFailureScreen(error: error, showsErrorDetails: showsErrorDetails)
            }
            return
        }
        
        guard let presenter = UIApplication.shared.topViewController() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                self.presentEnablementFailureScreen(error: error, showsErrorDetails: showsErrorDetails, retryCount: retryCount + 1)
            }
            return
        }
        
        let description = error.localizedDescription.isEmpty ? NSLocalizedString("Unknown error.", comment: "") : error.localizedDescription
        let messageText: String
        if usePtraceJIT() {
            messageText = NSLocalizedString("It's extremely rare that you encounter this issue! Make sure that your TrollStore installation or jailbroken environment is properly configured.\n\nYou may use the browser without JIT temporarily until the next launch by activating JIT-Less Mode.", comment: "Paragraph break intentional")
        } else {
            messageText = NSLocalizedString("Please check that your pairing file is valid, your loopback VPN is on, and you're connected to a stable Wi-Fi network.\n\nYou may use the browser without JIT temporarily until the next launch by activating JIT-Less Mode.", comment: "Paragraph break intentional")
        }
        
        let viewController = JITFailureViewController(
            errorCode: error.code,
            errorDescription: description,
            showsErrorDetails: showsErrorDetails,
            titleText: NSLocalizedString("Failed to enable JIT", comment: ""),
            messageText: messageText,
            actionButtonTitle: NSLocalizedString("Activate JIT-Less Mode", comment: ""),
            onPrimaryAction: { [weak self] in
                self?.activateJITLessMode()
            }
        )
        viewController.modalPresentationStyle = .pageSheet
        viewController.modalTransitionStyle = .coverVertical
        presenter.present(viewController, animated: true)
    }
    
    private func presentMissingDDIFailureScreen(retryCount: Int = 0) {
        guard retryCount <= failurePresentationRetryLimit else {
            return
        }
        
        guard Self.canPresentFailureUI() else {
            pendingFailureAction = { [weak self] in
                self?.presentMissingDDIFailureScreen()
            }
            return
        }
        
        guard let presenter = UIApplication.shared.topViewController() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                self.presentMissingDDIFailureScreen(retryCount: retryCount + 1)
            }
            return
        }
        
        let viewController = JITFailureViewController(
            errorCode: Int(ENOENT),
            errorDescription: NSLocalizedString("Required DDI files are missing.", comment: ""),
            showsErrorDetails: false,
            titleText: NSLocalizedString("Failed to enable JIT", comment: ""),
            messageText: NSLocalizedString("The required Developer Disk Image files for enabling JIT were not found.\n\nJIT has been disabled. Quit the app using the button below, then re-enable JIT from the browser settings.", comment: "Paragraph break intentional"),
            actionButtonTitle: NSLocalizedString("Quit Reynard", comment: ""),
            onPrimaryAction: {
                self.disableJITAndQuit()
            }
        )
        viewController.modalPresentationStyle = .pageSheet
        viewController.modalTransitionStyle = .coverVertical
        presenter.present(viewController, animated: true)
    }
    
    private func disableJITAndQuit() {
        Prefs.JITSettings.isJITEnabled = false
        quitApp()
    }
    
    private func quitApp() {
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
            exit(EXIT_SUCCESS)
        }
    }
    
    private func activateJITLessMode() {
        guard !isJITLessModeActive else {
            return
        }
        
        isJITLessModeActive = true
        attachQueue.async {
            self.cancelAllPreflightWatchdogs()
            self.attachedPIDs.removeAll()
            JITEnabler.shared.detachAllJITSessions()
        }
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .jitlessModeDidActivate, object: nil)
        }
    }
    
    private static func canPresentFailureUI() -> Bool {
        guard UIApplication.shared.applicationState == .active else {
            return false
        }
        
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive }
    }
    
    @objc private func handleApplicationDidBecomeActive() {
        let action = pendingFailureAction
        pendingFailureAction = nil
        action?()
    }
    
    @objc private func handleChildProcessNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let pidNumber = userInfo["pid"] as? NSNumber,
            let processType = userInfo["processType"] as? String
        else {
            return
        }
        
        childProcessDidStart(pid: pidNumber.int32Value, processType: processType)
    }
    
    @objc private func handleJITDisconnectNotification(_ notification: Notification) {
        guard Prefs.JITSettings.isJITEnabled, !isJITLessModeActive else {
            return
        }
        
        // Previously this reported the disconnect to Gecko and went
        // straight to the failure screen, with no attempt to recover —
        // real, observed "no JIT" incidents made clear that's too eager
        // to give up. A tab process's own JIT connection can plausibly
        // be lost transiently (e.g. iOS reclaiming resources under
        // memory pressure) without the underlying ptrace-based grant
        // itself being permanently gone. One retry, reusing the exact
        // same enablement path childProcessDidStart uses originally,
        // costs little and can recover from a transient disconnect
        // without ever bothering the user. attachToProcess already
        // handles both outcomes on its own — success reports back to
        // Gecko silently, failure reports back and falls through to the
        // same failure screen as before — so no separate fallback logic
        // is needed here.
        guard let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value, pid > 0 else {
            return
        }
        
        attachQueue.async {
            self.attachToProcess(pid: pid)
        }
    }
}

// MARK: - Helper Process Attach Delegation (App Group + Darwin Notifications)
//
// See fix_helper_delegates_jit_to_main_app_v4.py's docstring for the
// full reasoning. Summary: the Helper no longer opens its own,
// separate tunnel to self-enable JIT - it delegates to this process
// instead, via a small App Group file + Darwin notification handshake,
// so every attach attempt (tab-driven AND Helper-driven) funnels
// through this one process's own attachQueue.
//
// Every file/notification name is keyed by a per-attempt UUID token,
// not just the requesting PID - deliberately. The Helper's retry loop
// can make two sequential requests for the same PID; keying by PID
// alone let an old, late-arriving reply for attempt 1 collide with
// attempt 2's own observer for the same PID. The token makes every
// single attempt's coordination channel unique, regardless of how
// many requests the same PID ever makes.
extension JITController {
    fileprivate static let jitAttachRequestPostedNotification = "com.minh-ton.Reynard.JITAttachRequestPosted" as CFString
    fileprivate static let jitAttachRequestFilePrefix = "jit-attach-request-"
    fileprivate static let jitAttachResultFilePrefix = "jit-attach-result-"
    // Comfortably past the Helper's own 20s client-side timeout - any
    // result file older than this can only be an abandoned one nobody
    // is ever coming back to read.
    fileprivate static let jitAttachResultStaleAgeSeconds: TimeInterval = 60
    
    fileprivate static func jitAttachReplyNotificationName(forToken token: String) -> CFString {
        "com.minh-ton.Reynard.JITAttachReply.\(token)" as CFString
    }
    
    fileprivate func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ReynardDirectories.sharedAppGroupIdentifier())
    }
    
    func startListeningForHelperAttachRequests() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            jitAttachRequestPostedCallback,
            Self.jitAttachRequestPostedNotification,
            nil,
            .deliverImmediately
        )
        
        // Fallback safety net alongside the notification observer
        // above - see fix_helper_attach_polling_fallback.py's
        // docstring. Periodically scans for pending requests directly,
        // independent of whether the "request posted" notification
        // ever actually arrives - symmetric with the Helper's own
        // polling fallback for the reply side. A relatively infrequent
        // interval since this is purely a backstop for the app's
        // entire lifetime, not bounded to one request's own window -
        // the notification remains the fast path in the common case.
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.processPendingHelperAttachRequests()
        }
    }
    
    // Called on the main thread (the run loop this observer was
    // registered on) - immediately dispatches to attachQueue so the
    // actual enableJIT call, which can take up to the full 20s
    // watchdog budget, never blocks it. Processes every pending
    // request file found, not just one - Darwin notifications can
    // coalesce multiple posts under load, so this scans rather than
    // assumes exactly one request is waiting. Also opportunistically
    // prunes stale, abandoned result files every time it runs.
    fileprivate func processPendingHelperAttachRequests() {
        if isProcessingHelperAttachRequests {
            return
        }
        isProcessingHelperAttachRequests = true
        
        attachQueue.async { [weak self] in
            defer {
                DispatchQueue.main.async {
                    self?.isProcessingHelperAttachRequests = false
                }
            }
            
            guard let self, let containerURL = self.appGroupContainerURL() else {
                return
            }
            
            let fileManager = FileManager.default
            
            // CHANGED - loops until a full scan finds nothing pending,
            // instead of processing one fixed snapshot and stopping -
            // see fix_reprocess_requests_until_drained.py's docstring.
            // isProcessingHelperAttachRequests stays true for this
            // entire loop, exactly as before - the fix is that a
            // request written WHILE this loop is still running now
            // gets picked up on the loop's very next iteration,
            // instead of being invisible to both the notification
            // handler and the next timer tick until this whole pass
            // finishes and something separately triggers another call.
            // Defensive cap, not expected to ever actually matter in
            // practice - rules out any pathological, runaway scenario
            // rather than looping genuinely unbounded.
            let maxPasses = 50
            for _ in 0..<maxPasses {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: containerURL.path) else {
                    return
                }
                
                self.pruneStaleResultFiles(contents: contents, containerURL: containerURL, fileManager: fileManager)
                
                // Filename format: jit-attach-request-{pid}_{token} - PID
                // kept in the name for easy debugging/readability, token
                // is what actually makes each attempt unique.
                let pendingRequests = contents.filter { $0.hasPrefix(Self.jitAttachRequestFilePrefix) }
                
                guard !pendingRequests.isEmpty else {
                    return
                }
                
                for requestFileName in pendingRequests {
                    let remainder = requestFileName.dropFirst(Self.jitAttachRequestFilePrefix.count)
                    guard let underscoreIndex = remainder.firstIndex(of: "_") else {
                        continue
                    }
                    let pidString = remainder[remainder.startIndex..<underscoreIndex]
                    let token = String(remainder[remainder.index(after: underscoreIndex)...])
                    guard let pid = Int32(pidString), !token.isEmpty else {
                        continue
                    }
                    
                    // Removed first, before the attach attempt itself - if
                    // this process were to crash mid-attach, a stale
                    // request file would otherwise sit here forever,
                    // silently never retried and never cleaned up either.
                    let requestFileURL = containerURL.appendingPathComponent(requestFileName)
                    try? fileManager.removeItem(at: requestFileURL)
                    
                    let (success, errorDescription) = self.attachToHelperProcess(pid: pid)
                    
                    let resultFileURL = containerURL.appendingPathComponent("\(Self.jitAttachResultFilePrefix)\(pid)_\(token)")
                    let resultContents = success ? "success" : "failed:\(errorDescription ?? "unknown error")"
                    try? resultContents.write(to: resultFileURL, atomically: true, encoding: .utf8)
                    
                    CFNotificationCenterPostNotification(
                        CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName(rawValue: Self.jitAttachReplyNotificationName(forToken: token)),
                        nil,
                        nil,
                        true
                    )
                }
            }
        }
    }
    
    fileprivate func pruneStaleResultFiles(contents: [String], containerURL: URL, fileManager: FileManager) {
        let staleResultFiles = contents.filter { $0.hasPrefix(Self.jitAttachResultFilePrefix) }
        guard !staleResultFiles.isEmpty else {
            return
        }
        
        let now = Date()
        for resultFileName in staleResultFiles {
            let resultFileURL = containerURL.appendingPathComponent(resultFileName)
            guard let attributes = try? fileManager.attributesOfItem(atPath: resultFileURL.path),
                  let modificationDate = attributes[.modificationDate] as? Date
            else {
                continue
            }
            if now.timeIntervalSince(modificationDate) > Self.jitAttachResultStaleAgeSeconds {
                try? fileManager.removeItem(at: resultFileURL)
            }
        }
    }
    
    // Deliberately isolated from attachToProcess(pid:) above - that
    // method calls ReportJITStatusForChild (GeckoView-specific,
    // informs Gecko's own child-process tracking - wrong for a PID
    // Gecko never launched) and handleJITFailure (presents a
    // full-screen failure UI - wrong here, a Helper's own JIT failure
    // is meant to degrade silently, exactly as it already does today).
    // Returns success/error directly to the caller instead.
    fileprivate func attachToHelperProcess(pid: Int32) -> (Bool, String?) {
        let (success, error) = boundedEnableJIT(forPID: pid)
        return (success, error?.localizedDescription)
    }
}

// Top-level, matching CFNotificationCallback's C function pointer
// signature exactly - a context-free closure could technically work
// too, but a named top-level function removes any ambiguity about
// Swift's capture rules in a C function pointer context.
private func jitAttachRequestPostedCallback(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    JITController.shared.processPendingHelperAttachRequests()
}
