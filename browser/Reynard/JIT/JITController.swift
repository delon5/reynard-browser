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
    
    // ADDED - see fix_concurrent_attach_slots.py's docstring. Each
    // vAttach costs ~1012ms of genuine device time, and running them
    // one at a time meant sixteen processes cost sixteen seconds -
    // long past the five seconds each content process waits before
    // calling JS::DisableJitBackend() permanently.
    //
    // attachQueue stays SERIAL and keeps protecting attachedPIDs,
    // rejectedPIDs, preflightWatchdogs and
    // isProcessingHelperAttachRequests exactly as before. Only the slow
    // enableJIT call moves here, so no locking is needed and no
    // existing invariant changes.
    private let attachWorkQueue = DispatchQueue(label: "com.minh-ton.Reynard.JITController.AttachWorkQueue", qos: .userInitiated, attributes: .concurrent)
    
    // Capped rather than unbounded: the original serial design was
    // deliberately guarding against a cascading jam when calls hung.
    // Three keeps most of that - a stuck attach consumes one slot and
    // two remain - while cutting the serialised cost by roughly a
    // third.
    private let attachSlots = DispatchSemaphore(value: 3)
    
    // Attaches whose bounded wait expired while the underlying call
    // kept running. See fix_log_orphaned_attaches.py.
    //
    // enableJITMaxWaitSeconds bounds the wait, not the call, and the
    // timer is wall-clock - so a suspension expires it immediately on
    // resume while the FFI call carries on unobserved. One such orphan
    // is a documented trade-off; several accumulating and all resuming
    // together is worth being able to see.
    private static var orphanedAttachPIDs: Set<Int32> = []
    private static let orphanedAttachLock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.minh-ton.Reynard.JITController.WatchdogQueue", qos: .userInitiated)
    private var attachedPIDs: Set<Int32> = []
    
    // ADDED - see fix_dedupe_attach_paths.py's docstring. Processes
    // shouldAttach(to:) has rejected by type - socket, gpu, rdd and so
    // on, which never execute JavaScript. The Helper path has no idea
    // what kind of process it is hosting and would otherwise
    // self-enable for them anyway, burning a ~1012ms serialized attach
    // each on processes that have no use for JIT. Only ever touched on
    // attachQueue, same as attachedPIDs.
    private var rejectedPIDs: Set<Int32> = []
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
    
    // ADDED - see fix_defer_attaches_while_inactive.py's docstring.
    //
    // vAttach STOPS its target for the ~1012ms it takes, and a stopped
    // extension cannot answer the synchronous XPC iOS sends every
    // extension on a lifecycle transition. Three hang reports show the
    // main thread blocked in
    // __NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__ - two at
    // willResignActive, one at didEnterBackground - and the watchdog
    // killing the app with 0x8BADF00D.
    //
    // So no attach is STARTED unless the app is active. Pids arriving
    // meanwhile are held here and attached on return.
    //
    // Both are only ever touched on attachQueue, which is serial, so
    // they need no locking - the same as attachedPIDs and rejectedPIDs.
    private var isApplicationActive = true
    private var pendingAttachPIDs = Set<Int32>()
    private(set) var isJITLessModeActive = false
    private var pendingFailureAction: (() -> Void)?
    private let preflightTimeoutSeconds: Int = 5
    private let failurePresentationRetryLimit = 12
    
    private init() {}
    
    // For TrollStore or jailbroken devices
    private func usePtraceJIT() -> Bool {
        getEntitlementValue("com.apple.private.security.no-sandbox")
    }
    
    /// Re-attaches content processes that lost their debug session
    /// during suspension. See
    /// fix_reattach_orphaned_sessions_on_foreground.py.
    ///
    /// An attach is otherwise only ever triggered by a process
    /// STARTING, so a process that survives a suspension with a dead
    /// session runs interpreted for the rest of its life. StikDebug
    /// handles the same reality by expecting the tunnel to die and
    /// reconnecting on return rather than trying to keep it alive; this
    /// applies that to attaches.
    func reattachOrphanedProcesses() {
        attachQueue.async {
            // CHANGED - the three counts are computed and logged
            // separately, unconditionally. See
            // fix_unconditional_reattach_logging.py.
            //
            // Previously this returned early and silently when nothing
            // was found, which made "attachedPIDs was cleared", "the
            // processes died" and "they still hold sessions" all look
            // identical - and only the middle one is benign.
            let alive = self.attachedPIDs.filter { kill($0, 0) == 0 }
            let orphaned = alive.filter { pid in
                // Alive, but its debug loop has gone.
                !JITEnabler.hasActiveDebugSession(forPID: pid)
            }
            
            logger(String(format: "reattachOrphanedProcesses: %d attached, %d alive, %d orphaned", self.attachedPIDs.count, alive.count, orphaned.count))
            
            guard !orphaned.isEmpty else {
                return
            }
            
            for pid in orphaned {
                // attachedPIDs is deliberately left alone. Its dedup
                // check lives in childProcessDidStart and the Helper
                // request loop, neither of which is involved here -
                // attachToProcess is called directly - and the pid
                // genuinely is still attached, so removing it would
                // only misrepresent the state.
                //
                // The real guard against a duplicate is
                // boundedEnableJIT's per-pid in-flight check, which
                // still applies.
                self.attachWorkQueue.async {
                    self.attachSlots.wait()
                    defer { self.attachSlots.signal() }
                    self.attachToProcess(pid: pid)
                }
            }
        }
    }
    
    /// No further attaches are started until the app is active again.
    /// See fix_defer_attaches_while_inactive.py.
    func applicationWillResignActive() {
        attachQueue.async {
            self.isApplicationActive = false
        }
    }
    
    /// Attaches anything that arrived while inactive.
    func applicationDidBecomeActive() {
        attachQueue.async {
            self.isApplicationActive = true
            
            let deferred = self.pendingAttachPIDs
            self.pendingAttachPIDs.removeAll()
            
            // Dead ones are dropped rather than attached - a pid can
            // easily have gone during the interval.
            let stillAlive = deferred.filter { kill($0, 0) == 0 }
            guard !stillAlive.isEmpty else {
                return
            }
            
            logger(String(format: "applicationDidBecomeActive: attaching %d deferred process(es)", stillAlive.count))
            
            for pid in stillAlive {
                guard !self.attachedPIDs.contains(pid) else {
                    continue
                }
                self.attachedPIDs.insert(pid)
                self.schedulePreflightWatchdog(for: pid)
                
                self.attachWorkQueue.async {
                    self.attachSlots.wait()
                    defer { self.attachSlots.signal() }
                    self.attachToProcess(pid: pid)
                }
            }
        }
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
        
        // Push the diagnostic logging toggles down to the ObjC layer
        // before anything can log - see
        // fix_experimental_logging_toggles.py.
        ReynardSetDiagnosticLoggingEnabled(
            Prefs.ExperimentalSettings.isJITDebugLogEnabled,
            Prefs.ExperimentalSettings.isIdeviceNativeLogEnabled,
            Prefs.ExperimentalSettings.isJITHangBacktraceEnabled
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
        // Read here because applicationState is main-thread only, and the
        // decision below runs on the attach queue. See
        // fix_check_real_app_state_before_attach.py.
        // Never blocks. main.sync from the attach queue deadlocks if the
        // main thread is waiting on anything that queue holds - which
        // froze the app on launch. Off the main thread we assume active
        // and let the cached flag decide, which is the behaviour that
        // existed before.
        let actualStateIsActive = Thread.isMainThread
            ? UIApplication.shared.applicationState == .active
            : true
        // DIAGNOSTIC - see fix_log_all_jit_status_reporters.py. This
        // whole function was silent on every path, including three
        // ReportJITStatusForChild(false) exits. Since that pipe is
        // single-use and consumed by the first caller, a silent false
        // report here permanently disables JIT for a child that the
        // Helper path then successfully attaches a moment later.
        // Also the first time processType has ever been observed -
        // shouldAttach compares it against "tab".
        logger(String(format: "childProcessDidStart: ENTRY pid %d, processType=%@", pid, processType))
        
        guard pid > 0 else {
            return
        }
        
        guard !isJITLessModeActive, !hasHandledFailure else {
            logger(String(format: "childProcessDidStart: pid %d reporting FALSE - guard 1 (isJITLessModeActive=%@, hasHandledFailure=%@)", pid, isJITLessModeActive ? "YES" : "NO", hasHandledFailure ? "YES" : "NO"))
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        guard usePtraceJIT() || Prefs.JITSettings.isJITEnabled else {
            logger(String(format: "childProcessDidStart: pid %d reporting FALSE - guard 2 (JIT not enabled in prefs)", pid))
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        guard shouldAttach(to: processType) else {
            logger(String(format: "childProcessDidStart: pid %d reporting FALSE - guard 3 (shouldAttach rejected processType=%@)", pid, processType))
            // Remember the rejection so the Helper path does not
            // wastefully attach this process a second later - see
            // fix_dedupe_attach_paths.py's docstring.
            attachQueue.async {
                self.rejectedPIDs.insert(pid)
            }
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        logger(String(format: "childProcessDidStart: pid %d passed all guards, queueing native attach", pid))
        
        attachQueue.async {
            if self.attachedPIDs.contains(pid) {
                return
            }
            // Held rather than attached: starting one now would stop
            // this process, and if a lifecycle transition follows it
            // cannot answer the synchronous XPC iOS sends every
            // extension. See fix_defer_attaches_while_inactive.py.
            //
            // Deliberately before inserting into attachedPIDs, so the
            // drain on return is not skipped by the dedup check.
            // Both the flag and the real state. See
            // fix_check_real_app_state_before_attach.py.
            //
            // isApplicationActive is set on activate and cleared on
            // resign, but iOS wakes a backgrounded app periodically -
            // background tasks, audio, network - and content processes
            // can start during those wakes with no resign/activate cycle
            // in between. The flag is then stale-true and the attach
            // proceeds while the app is, to iOS, backgrounded.
            //
            // Which is how one attach took 117 seconds with its target
            // stopped throughout, and the app was killed on the next
            // foreground for failing to answer XPC.
            let reallyActive = self.isApplicationActive && actualStateIsActive
            
            guard reallyActive else {
                self.pendingAttachPIDs.insert(pid)
                logger(String(format: "childProcessDidStart: pid %d deferred - app is not active (flag=%@, state=%@), will attach on return", pid, self.isApplicationActive ? "active" : "inactive", actualStateIsActive ? "active" : "inactive"))
                return
            }
            
            self.attachedPIDs.insert(pid)
            self.schedulePreflightWatchdog(for: pid)
            
            // Bookkeeping above stays on the serial queue; only the
            // ~1012ms attach itself runs concurrently. See
            // fix_concurrent_attach_slots.py.
            self.attachWorkQueue.async {
                self.attachSlots.wait()
                defer { self.attachSlots.signal() }
                self.attachToProcess(pid: pid)
            }
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
    // CHANGED - global, whole-call guard replacing the narrower,
    // vAttach-specific one, and a much longer wait replacing the
    // previous 20s bound - see
    // fix_global_enablejit_guard_and_extended_wait.py's docstring.
    // Direct, ground-truth evidence from the underlying idevice
    // library's own internal logging showed the real cause: the
    // shared async runtime itself periodically stalls completely for
    // ~19.5s at a time, repeatedly, then reliably resumes on its own -
    // never observed as permanent. The previous 20s bound was
    // abandoning calls right as the runtime was about to recover
    // anyway, then starting a second call on top of the first,
    // unabandoned one - manufacturing exactly the kind of overlap that
    // starves the runtime further. 90s comfortably covers several full
    // observed stall-and-recover cycles.
    // CHANGED - per-pid rather than a single global timestamp. See
    // fix_per_pid_inflight_guard.py. The global version was written
    // when attaches were strictly serial, so "a call is in flight"
    // reliably meant "something is stuck". Once three attaches run
    // concurrently it rejected two of every three on sight, surfacing
    // as "Error 16: Skipped: another enableJIT call may still be in
    // flight".
    //
    // Every access below is inside enableJITInFlightLock, which is what
    // makes a dictionary safe here - concurrent mutation would
    // otherwise be unsafe in a way a single optional assignment is not.
    private static var enableJITInFlightByPID: [Int32: Date] = [:]
    private static let enableJITInFlightLock = NSLock()
    
    /// How many attaches are running right now.
    ///
    /// Exposed so backgrounding can wait for them: vAttach leaves its
    /// target STOPPED until the debug loop sends continue, and a
    /// suspension landing mid-attach strands it there for minutes. See
    /// fix_hold_background_for_inflight_attach.py.
    static var attachesInFlight: Int {
        enableJITInFlightLock.lock()
        defer { enableJITInFlightLock.unlock() }
        return enableJITInFlightByPID.count
    }
    private static let enableJITMaxWaitSeconds: TimeInterval = 90.0
    
    private func boundedEnableJIT(forPID pid: Int32) -> (Bool, NSError?) {
        // CHANGED - the check and the set are now one critical section.
        // See fix_atomic_inflight_guard.py.
        //
        // The lock used to be released between reading the map and
        // writing to it, so two threads arriving together both read nil,
        // both concluded nothing was in flight, and both attached the
        // same process. reattachOrphanedProcesses and
        // childProcessDidStart are exactly the pair that would do that,
        // and both appear in the stack of a segfault on the attach queue
        // dereferencing 0x8000000000000010.
        //
        // Nothing slow happens under the lock: the decision is made
        // inside, and its logging after.
        var skipAge: Double?
        
        Self.enableJITInFlightLock.lock()
        if let existingInFlightSince = Self.enableJITInFlightByPID[pid] {
            let age = CFAbsoluteTimeGetCurrent() - existingInFlightSince.timeIntervalSinceReferenceDate
            if age < Self.enableJITMaxWaitSeconds {
                skipAge = age
            }
        }
        if skipAge == nil {
            // Claimed in the same critical section that found it free,
            // which is the whole point.
            //
            // An entry older than enableJITMaxWaitSeconds is treated as
            // abandoned and overwritten here, so one hung attach cannot
            // block a process forever.
            Self.enableJITInFlightByPID[pid] = Date()
        }
        Self.enableJITInFlightLock.unlock()
        
        if let skipAge {
            logger(String(format: "boundedEnableJIT: skipping duplicate attempt for pid %d - an enableJIT call for THIS pid is already in flight (started %.0fs ago)", pid, skipAge))
            return (false, NSError(domain: "Reynard.JIT", code: Int(EBUSY), userInfo: [NSLocalizedDescriptionKey: "Skipped: an enableJIT call for this process is already in flight"]))
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
            
            Self.enableJITInFlightLock.lock()
            Self.enableJITInFlightByPID.removeValue(forKey: pid)
            Self.enableJITInFlightLock.unlock()
            
            // DIAGNOSTIC - see fix_log_orphaned_call_completion.py's
            // docstring. Purely additive: logs whenever this background
            // call actually finishes, including if that happens well
            // after the outer bound below already gave up and
            // returned to the caller - answering whether a hang here
            // is genuinely permanent (like process_control_new was,
            // confirmed by a direct ~3 minute wait) or just slower
            // than the bound.
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - boundedCallStart) * 1000.0
            
            // Reported separately when the wait had already given up on
            // this call, so an orphan's eventual completion is not
            // mistaken for an ordinary one arriving late. See
            // fix_log_orphaned_attaches.py.
            Self.orphanedAttachLock.lock()
            let wasOrphaned = Self.orphanedAttachPIDs.remove(pid) != nil
            let stillOutstanding = Self.orphanedAttachPIDs.count
            Self.orphanedAttachLock.unlock()
            
            if wasOrphaned {
                let orphanedForMs = elapsedMs - (Self.enableJITMaxWaitSeconds * 1000.0)
                logger(String(format: "boundedEnableJIT: ORPHANED call for pid %d finally completed after %.0fms (orphaned for %.0fms, success=%@) - %d still outstanding", pid, elapsedMs, orphanedForMs, result.0 ? "YES" : "NO", stillOutstanding))
            } else {
                logger(String(format: "boundedEnableJIT: background call for pid %d actually completed after %.0fms (success=%@)", pid, elapsedMs, result.0 ? "YES" : "NO"))
            }
            semaphore.signal()
        }
        
        if semaphore.wait(timeout: .now() + Self.enableJITMaxWaitSeconds) == .timedOut {
            // Recorded at the moment of the decision, so the completion
            // line that eventually appears can be tied back to it. See
            // fix_log_orphaned_attaches.py.
            Self.orphanedAttachLock.lock()
            Self.orphanedAttachPIDs.insert(pid)
            let orphanCount = Self.orphanedAttachPIDs.count
            Self.orphanedAttachLock.unlock()
            
            logger(String(format: "boundedEnableJIT: ABANDONING pid %d after %.0fs - %d call(s) now orphaned", pid, Self.enableJITMaxWaitSeconds, orphanCount))
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
            // single hang. Deliberately does NOT clear
            // enableJITInFlightSince here - the whole point of this
            // fix is that the guard above must keep blocking new
            // attempts from starting on top of this same,
            // still-potentially-running one until it's genuinely
            // stale, not just until this outer wait gives up.
            //
            // Also invalidates the cached DeviceProvider itself - real
            // capture evidence showed every attempt that reused the
            // same cached provider hanging at the identical step
            // (process_control_new), 100% of the time, not just this
            // one. The next attempt gets a genuinely fresh connection
            // instead of inheriting a possibly-already-poisoned one.
            JITEnabler.shared.invalidateSharedProviderAfterTimeout()
            return (false, NSError(domain: "Reynard.JIT", code: Int(ETIMEDOUT), userInfo: [NSLocalizedDescriptionKey: "Attach timed out after 90s (may still be running in the background)"]))
        }
        
        return result
    }
    
    private func attachToProcess(pid: Int32) {
        let (success, error) = boundedEnableJIT(forPID: pid)
        cancelPreflightWatchdog(for: pid)
        if success {
            logger(String(format: "attachToProcess: pid %d reporting TRUE (native path)", pid))
            ReportJITStatusForChild(pid, true, newJITRuntimeInfo())
        } else {
            logger(String(format: "attachToProcess: pid %d reporting FALSE (native path, attach failed: %@)", pid, error?.localizedDescription ?? "unknown"))
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            
            // CHANGED - see
            // fix_recoverable_jit_failures_do_not_latch.py's docstring.
            // handleJITFailure sets hasHandledFailure permanently, and
            // guard 1 in childProcessDidStart then rejects every
            // subsequent attach for the rest of the process lifetime.
            //
            // That is right for a genuinely unusable setup - missing
            // DDI, bad pairing file - but wrong for a transport failure
            // after the app has been suspended. Observed on device: ten
            // minutes backgrounded, tunnel died with Socket(BrokenPipe),
            // the next attach burned its full 90s bound discovering
            // that, and JIT stayed off until relaunch.
            //
            // Nothing was actually broken. boundedEnableJIT already
            // calls invalidateSharedProviderAfterTimeout() on that same
            // timeout, so the cached provider is discarded and the next
            // attach builds a fresh tunnel - which the following session
            // in that capture did successfully.
            //
            // Reporting FALSE above is still correct: this particular
            // process did not get JIT and must be told rather than left
            // waiting. What changes is that the NEXT one may try.
            let failureCode = Int32(error?.code ?? -1)
            let isRecoverable = failureCode == ETIMEDOUT || failureCode == EBUSY
            
            if isRecoverable {
                logger(String(format: "attachToProcess: pid %d failure is recoverable (code %d) - not latching, the next attach gets a fresh provider", pid, failureCode))
            } else {
                handleJITFailure(error: error ?? NSError(domain: "Reynard.JIT", code: -1, userInfo: nil))
            }
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
            
            // DIAGNOSTIC - prime suspect. cancelPreflightWatchdog is
            // called only from attachToProcess, never from
            // attachToHelperProcess, so when the Helper path performs
            // the attach this watchdog is never cancelled and fires
            // anyway - consuming the single-use pipe with a FALSE
            // report even though the attach itself succeeded.
            logger(String(format: "preflightWatchdog: pid %d reporting FALSE - watchdog timed out and was never cancelled", pid))
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
            // DIAGNOSTIC - see
            // fix_log_helper_request_delivery_path.py. Names this path
            // so it can be told apart from the Darwin notification.
            // If attach bursts consistently follow this line rather
            // than the notification's, Darwin delivery is dead for
            // this extension type and up to 3s of latency is being
            // added to every request - directly relevant to the 5s
            // WaitForJITReadySignal deadline and the 10s preflight
            // watchdog.
            logger("helperRequestDelivery: POLLING TIMER fired (3.0s fallback)")
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
                    
                    // ADDED - see fix_dedupe_attach_paths.py's
                    // docstring. Without these two checks the Helper
                    // path and the native path cannot see each other,
                    // so every tab process is attached twice and
                    // non-tab processes are attached despite having
                    // been correctly rejected. Measured: 21 attaches
                    // for 12 processes, 12.2s of serialized queue time,
                    // only 9 of them necessary.
                    var skipReason: String? = nil
                    if self.rejectedPIDs.contains(pid) {
                        skipReason = "process type was rejected by shouldAttach - does not need JIT"
                    } else if self.attachedPIDs.contains(pid) {
                        skipReason = "already attached by the native path"
                    }
                    
                    if let skipReason {
                        logger(String(format: "processPendingHelperAttachRequests: skipping pid %d - %@", pid, skipReason))
                        let resultFileURL = containerURL.appendingPathComponent("\(Self.jitAttachResultFilePrefix)\(pid)_\(token)")
                        try? "success".write(to: resultFileURL, atomically: true, encoding: .utf8)
                        CFNotificationCenterPostNotification(
                            CFNotificationCenterGetDarwinNotifyCenter(),
                            CFNotificationName(rawValue: Self.jitAttachReplyNotificationName(forToken: token)),
                            nil,
                            nil,
                            true
                        )
                        continue
                    }
                    
                    self.attachedPIDs.insert(pid)
                    
                    // The insert above is the last shared-state access;
                    // everything below is the ~1012ms attach plus file
                    // I/O and a notification post, none of which touch
                    // state protected by attachQueue. pid and token are
                    // value types captured per iteration, so each
                    // dispatched block writes its own result file. See
                    // fix_concurrent_attach_slots.py.
                    self.attachWorkQueue.async {
                        self.attachSlots.wait()
                        defer { self.attachSlots.signal() }
                        
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
    
    // Still deliberately isolated from attachToProcess(pid:) above in
    // one respect: this does NOT call handleJITFailure, which presents
    // a full-screen failure UI. A Helper's own JIT failure is meant to
    // degrade silently, exactly as it already does today.
    //
    // CORRECTED - see fix_report_jit_status_from_helper_path.py's
    // docstring. This previously also withheld ReportJITStatusForChild,
    // on the stated grounds that it is "wrong for a PID Gecko never
    // launched". That premise is false: Reynard Helper.appex IS the
    // Gecko content-process host, so these PIDs are Gecko-launched
    // child processes - precisely the ones blocked in
    // WaitForJITReadySignal waiting to be told whether JIT is
    // available. Since childProcessDidStart never fires (confirmed
    // empirically - NSLog at NotifyChildProcessStarted's entry point
    // produced zero output in a freshly clobbered Gecko build),
    // attachToProcess never runs, so this was the ONLY attach path in
    // the app and NOTHING ever signalled any child. Every content
    // process waited its 5 seconds, heard nothing, and called
    // JS::DisableJitBackend() permanently - while the attach behind it
    // had in fact succeeded.
    //
    // Reported on failure as well as success, deliberately: a child
    // told "no JIT" stops waiting and renders immediately instead of
    // blocking its main thread for the full timeout.
    fileprivate func attachToHelperProcess(pid: Int32) -> (Bool, String?) {
        let (success, error) = boundedEnableJIT(forPID: pid)
        logger(String(format: "attachToHelperProcess: reporting JIT status to child pid %d (success=%@)", pid, success ? "YES" : "NO"))
        ReportJITStatusForChild(pid, success, newJITRuntimeInfo())
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
    // DIAGNOSTIC - see fix_log_helper_request_delivery_path.py. If
    // this line never appears in a capture while attaches still
    // happen, Darwin notification delivery is confirmed non-functional
    // for this extension type and every request is waiting on the
    // 3-second polling timer instead.
    logger("helperRequestDelivery: DARWIN NOTIFICATION received")
    JITController.shared.processPendingHelperAttachRequests()
}
