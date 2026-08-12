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
    // attachQueue stays SERIAL and remains the confining queue for the
    // attach bookkeeping (now owned by AttachLedger, which asserts it)
    // and isProcessingHelperAttachRequests exactly as before. Only the
    // slow enableJIT call moves here, so no locking is needed and no
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

    // The attach bookkeeping - attached, rejected and deferred pids
    // plus the application-active flag - lives in AttachLedger, which
    // is confined to attachQueue and asserts that on every access. The
    // per-set reasoning (fix_dedupe_attach_paths.py,
    // fix_defer_attaches_while_inactive.py) is documented on the
    // ledger's own fields.
    private let ledger: AttachLedger
    // Guarded by preflightWatchdogLock, NOT attachQueue: scheduling
    // happens on attachQueue but cancellation happens from
    // attachToProcess, which mostly runs on the CONCURRENT
    // attachWorkQueue - an unsynchronized Dictionary mutated from both
    // is a data race. A lock rather than hopping the cancel onto
    // attachQueue, deliberately: the watchdog-retry path can block
    // attachQueue for a full bounded attach, and a cancel queued
    // behind that would arrive after the watchdog had already fired
    // and burned the single-use ReportJITStatusForChild pipe with a
    // false FALSE. The lock keeps cancellation synchronous from any
    // queue, and now also covers retriedWatchdogPIDs, which the
    // scheduled closure reads and writes in the same critical section.
    private let preflightWatchdogLock = NSLock()
    // Generation tokens, not DispatchWorkItems - see
    // schedulePreflightWatchdog for why the work-item version leaked one
    // item-plus-closure pair per scheduled watchdog.
    private var preflightWatchdogs: [Int32: UUID] = [:]
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
    // The 3-second helper-attach fallback, stored so the lifecycle
    // observers can stop it while the app is backgrounded. It used to be
    // created anonymously and never invalidated, so it woke the CPU
    // every 3 seconds for the entire process lifetime - which, whenever
    // something is preventing suspension (an active audio session, PiP,
    // CarPlay, the keep-alive), means every backgrounded hour.
    private var helperAttachPollingTimer: Timer?
    private var helperAttachPollingLifecycleTokens: [NSObjectProtocol] = []
    // Guarded by preflightWatchdogLock, alongside preflightWatchdogs.
    //
    // Previously watchdogQueue-confined and insert-only. Cancellation
    // runs from any queue and now has to clear this too: a pid whose
    // attach succeeded kept its "already retried" mark forever, so when
    // the number was recycled onto a new process that process silently
    // lost its one retry. The two collections are written together
    // under one lock so they cannot disagree about a pid.
    private var retriedWatchdogPIDs: Set<Int32> = []
    private var hasHandledFailure = false
    
    // The deferred-attach state (see
    // fix_defer_attaches_while_inactive.py: vAttach STOPS its target,
    // and a stopped extension cannot answer the synchronous XPC iOS
    // sends on a lifecycle transition - observed as 0x8BADF00D kills)
    // also lives in the ledger: no attach is STARTED unless the app is
    // active, and pids arriving meanwhile are held and attached on
    // return.
    private(set) var isJITLessModeActive = false
    
    /// Whether the debugger tunnel currently looks dead.
    ///
    /// Deliberately separate from isJITLessModeActive, which is a
    /// one-way latch that also detaches everything. This is reporting
    /// only, and it clears itself the moment an attach succeeds - a
    /// tunnel that dies over a suspension comes back on its own.
    private(set) var isTunnelUnavailable = false
    private var consecutiveAttachFailures = 0
    
    /// How many consecutive failures before saying so. Three is past
    /// any single unlucky process and still well inside the burst of
    /// content processes a single page load creates.
    private static let tunnelFailureThreshold = 3
    private var pendingFailureAction: (() -> Void)?
    private let preflightTimeoutSeconds: Int = 5
    private let failurePresentationRetryLimit = 12
    
    // ADDED - see fix_reattach_requires_active_app.py's docstring.
    //
    // A mirror of the ledger's applicationActive flag that ANY queue can
    // read, written synchronously on the thread iOS calls us on.
    //
    // The ledger's own flag is authoritative and stays so - it is set
    // through attachQueue.async, and attachQueue is held for a full
    // 90-second bounded attach whenever the preflight-watchdog retry
    // path runs attachToProcess there. A flag that can lag the real
    // application state by minutes is fine as bookkeeping and unfit as
    // the thing that decides whether starting a vAttach is safe, which
    // is what reattachOrphanedProcesses needs it for.
    private static let applicationActiveLock = NSLock()
    private static var applicationActiveMirror = true

    static var isApplicationActiveFromAnyQueue: Bool {
        applicationActiveLock.lock()
        defer { applicationActiveLock.unlock() }
        return applicationActiveMirror
    }

    private static func setApplicationActiveMirror(_ active: Bool) {
        applicationActiveLock.lock()
        applicationActiveMirror = active
        applicationActiveLock.unlock()
    }

    private init() {
        ledger = AttachLedger(confinedTo: attachQueue)
    }
    
    // For TrollStore or jailbroken devices
    private func usePtraceJIT() -> Bool {
        getEntitlementValue("com.apple.private.security.no-sandbox")
    }
    
    /// Whether `pid` is still running, judged the way a sandboxed app
    /// has to judge its own content-process extensions.
    ///
    /// kill(pid, 0) delivers no signal - it runs only the error checks
    /// and reports what a real signal would have found. A content
    /// process is an app extension in a different coalition, and the
    /// app is not permitted to signal it, so for a LIVE child the call
    /// returns -1 with errno == EPERM. Only ESRCH means the pid is
    /// genuinely gone.
    ///
    /// The previous `kill(pid, 0) == 0` test therefore read every live
    /// tab as dead: reattachOrphanedProcesses logged "0 alive" for 25
    /// running processes and re-attached none of them, leaving them to
    /// run with no W^X mediation. See
    /// fix_reattach_treats_eperm_as_alive.py.
    private static func pidIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        // errno still refers to the kill above - nothing has run since.
        return errno == EPERM
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
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            // ADDED - see fix_reattach_requires_active_app.py's
            // docstring for the capture this comes from.
            //
            // The only attach path that never had this guard, and the
            // one that fans out. On 2026-08-12 the scene backgrounded
            // 1.04s after becoming active, the 2-second reattach timer
            // fired anyway, and this pass started five vAttaches into a
            // backgrounding app. vAttach stops its target; the calls did
            // not return for 165 seconds because the app was suspended
            // underneath them; the transport was reset by then so every
            // detach and every retry failed. Three hosted extensions
            // were left STOPPED with nothing able to resume them, and a
            // stopped extension cannot answer the synchronous XPC in
            // _hostWillEnterForegroundNote:. 0x8BADF00D.
            //
            // Skipped rather than deferred: drainDeferredPIDs is
            // consumed by applicationDidBecomeActive, which skips any
            // pid already in attachedPIDs - and every orphan is one by
            // definition. This pass is idempotent and re-runs on the
            // next foreground.
            guard Self.isApplicationActiveFromAnyQueue else {
                logger("reattachOrphanedProcesses: app is not active - skipping this pass entirely")
                return
            }
            // CHANGED - the three counts are computed and logged
            // separately, unconditionally. See
            // fix_unconditional_reattach_logging.py.
            //
            // Previously this returned early and silently when nothing
            // was found, which made "attachedPIDs was cleared", "the
            // processes died" and "they still hold sessions" all look
            // identical - and only the middle one is benign.
            let attached = self.ledger.attachedSnapshot()
            let alive = attached.filter { Self.pidIsAlive($0) }
            // ADDED - see fix_reattach_respects_process_type.py.
            //
            // This pass re-attaches straight out of attachedPIDs and
            // never consulted a type, so any non-tab child that got into
            // the ledger through the Helper path was re-attached on
            // every foreground - and every re-attach is a fresh vAttach,
            // which stops it. pid 8804 (type=utility) was one of the
            // three left stopped by the 19:12:34 fan-out on 2026-08-12,
            // and so one of the extensions that could not answer the
            // foreground XPC.
            let notAttachable = alive.filter { pid in
                guard let type = self.ledger.knownType(pid) else {
                    // Never announced. Left alone rather than guessed
                    // at - this filter only ever removes work.
                    return false
                }
                return !self.shouldAttach(to: type)
            }
            for pid in notAttachable.sorted() {
                logger(String(format: "reattachOrphanedProcesses: pid %d type=%@ is not attachable - not re-attaching", pid, self.ledger.knownType(pid) ?? "?"))
            }
            let orphaned = alive.filter { pid in
                guard !notAttachable.contains(pid) else {
                    return false
                }
                // An attach that has been dispatched but has not
                // finished is NOT an orphan - it is a pid partway
                // through the very thing this pass would start again.
                //
                // markAttached runs before the attach is dispatched and
                // hasActiveDebugSession only becomes true once it
                // completes, so every pid queued behind the attach
                // slots sits in that gap: attached, alive, sessionless.
                // Re-attaching one lands a second vAttach on a process
                // the first attach has already stopped; the second
                // connection dies on its next command, the detach is
                // skipped as "transport already dead", and the child is
                // left STOPPED forever. A frozen extension cannot
                // answer the synchronous XPC ExtensionKit sends on the
                // next foreground, which is a guaranteed 0x8BADF00D
                // watchdog kill - the crash this filter exists to stop.
                guard !self.ledger.isAttachInFlight(pid) else {
                    return false
                }
                // Alive, but its debug loop has gone.
                return !JITEnabler.hasActiveDebugSession(forPID: pid)
            }

            logger(String(format: "reattachOrphanedProcesses: %d attached, %d alive, %d in flight, %d orphaned", attached.count, alive.count, self.ledger.attachInFlightCount(), orphaned.count))
            
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
                self.ledger.markAttachInFlight(pid)
                self.attachWorkQueue.async {
                    self.attachSlots.wait()
                    defer {
                        self.attachSlots.signal()
                        self.attachQueue.async { self.ledger.clearAttachInFlight(pid) }
                    }
                    // ADDED - the slot wait above is UNBOUNDED, so the
                    // guard at the top of this pass can be arbitrarily
                    // stale by the time this pid reaches the front. In
                    // the 2026-08-12 capture five orphans queued behind
                    // three slots and trickled out over ~450ms. Starting
                    // the vAttach is the irreversible step - it stops
                    // the target and only the debug loop's continue
                    // resumes it - so it is checked here too.
                    //
                    // The mirror is read rather than the ledger flag:
                    // this runs on the CONCURRENT attachWorkQueue, and
                    // hopping to attachQueue to ask would block a
                    // slot-holding thread behind a possible 90-second
                    // attach.
                    guard Self.isApplicationActiveFromAnyQueue else {
                        logger(String(format: "reattachOrphanedProcesses: pid %d abandoned at the slot - app went inactive while it queued", pid))
                        return
                    }
                    self.attachToProcess(pid: pid)
                }
            }
        }
    }

    /// Logs every child the app knows about, with its type, whether the
    /// JIT layer attached it, and whether it is still alive.
    ///
    /// Called at the foreground handshake because that is where the app
    /// dies: ExtensionFoundation sends one synchronous XPC per hosted
    /// extension INSTANCE, and if any of them fails to answer the main
    /// thread parks forever. The crash report never names the peer, and
    /// three child types were invisible to every existing instrument, so
    /// this is the list to diff against a hang.
    func dumpChildCensus(labelled label: String) {
        attachQueue.async {
            // Prune first: childTypes is purely diagnostic, the dump
            // below only ever showed live children anyway, and without
            // eviction the map grew by one entry per child process for
            // the life of the app.
            let prunedAttached = self.ledger.pruneDeadChildren(alive: Self.pidIsAlive)
            if prunedAttached > 0 {
                logger(String(format: "%@: pruned %ld dead pid(s) from the attach ledger", label, prunedAttached))
            }
            let census = self.ledger.childCensus()
            logger("\(label): \(self.ledger.announcedChildTotal()) child(ren) announced this launch, \(census.count) alive")
            for entry in census {
                let session = JITEnabler.hasActiveDebugSession(forPID: entry.pid)
                logger(String(
                    format: "  %@: pid %d type=%@ attached=%@ session=%@",
                    label, entry.pid, entry.type,
                    entry.attached ? "yes" : "NO",
                    session ? "yes" : "NO"
                ))
            }
        }
    }

    /// No further attaches are started until the app is active again.
    /// See fix_defer_attaches_while_inactive.py.
    func applicationWillResignActive() {
        // Set BEFORE the queue hop, on the caller's thread. The async
        // below can sit behind a 90-second attach; this cannot.
        Self.setApplicationActiveMirror(false)
        attachQueue.async {
            self.ledger.markApplicationInactive()
        }
    }
    
    /// Runs the foreground re-attach steps in order, off the main
    /// thread. See fix_reattach_off_main_queue.py.
    ///
    /// dumpChildCensus and reattachOrphanedProcesses each hop to
    /// attachQueue themselves, so calling all three from the main queue
    /// runs setDebuggerListening first and leaves the census describing
    /// a tree trapping has already been re-armed on - the opposite of
    /// the documented order. Enqueueing them here puts them on the one
    /// serial queue in written order, and keeps the vAttach fan-out
    /// they trigger off the thread the scene-update watchdog times.
    ///
    /// The completion is delivered back on the main queue: the caller's
    /// background-task identifier is also touched by UIKit's expiration
    /// handler, which runs on the main thread.
    func performForegroundReattach(completion: @escaping () -> Void) {
        dumpChildCensus(labelled: "childCensus at foreground")

        attachQueue.async {
            JITEnabler.setDebuggerListening(true)
        }

        reattachOrphanedProcesses()

        attachQueue.async {
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    /// Attaches anything that arrived while inactive.
    func applicationDidBecomeActive() {
        Self.setApplicationActiveMirror(true)
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            self.ledger.markApplicationActive()
            // Before anything is attached: runDebugService refuses to
            // re-arm while the teardown is standing, so the deferred
            // attaches below would start loops that immediately detach.
            JITEnabler.clearDebuggerTeardownRequest()

            let deferred = self.ledger.drainDeferredPIDs()

            // Dead ones are dropped rather than attached - a pid can
            // easily have gone during the interval.
            let stillAlive = deferred.filter { Self.pidIsAlive($0) }
            guard !stillAlive.isEmpty else {
                return
            }

            logger(String(format: "applicationDidBecomeActive: attaching %d deferred process(es)", stillAlive.count))

            for pid in stillAlive {
                guard !self.ledger.isAttached(pid) else {
                    continue
                }
                self.ledger.markAttached(pid)
                self.schedulePreflightWatchdog(for: pid)

                self.ledger.markAttachInFlight(pid)
                self.attachWorkQueue.async {
                    self.attachSlots.wait()
                    defer {
                        self.attachSlots.signal()
                        self.attachQueue.async { self.ledger.clearAttachInFlight(pid) }
                    }
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
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        // ADDED - see fix_forget_child_on_target_exit.py's docstring.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTargetDidExitNotification(_:)),
            name: .jitTargetDidExit,
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
        // Recorded for EVERY child, before any decision about
        // attaching - socket/gpu/rdd are rejected below and would
        // otherwise never appear in any diagnostic.
        attachQueue.async { self.ledger.noteChild(pid, type: processType) }

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
                self.ledger.markRejected(pid)
            }
            ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
            return
        }
        
        logger(String(format: "childProcessDidStart: pid %d passed all guards, queueing native attach", pid))
        
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            if self.ledger.isAttached(pid) {
                // Silent until now, and the liveness check that made it
                // safe was reverted in f795d87, so a reused pid lands
                // here and is dropped without ever being signalled.
                // Usually benign: the Helper delegation path claims the
                // pid first and inserts it, then childProcessDidStart
                // arrives and lands here. Only a concern if no attach for
                // this pid appears anywhere in the capture.
                logger(String(format: "attachStall: pid %d already claimed - skipping the native attach", pid))
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
            let flagActive = self.ledger.isApplicationActive
            let reallyActive = flagActive && actualStateIsActive

            guard reallyActive else {
                let pendingCount = self.ledger.deferAttach(pid)
                logger(String(format: "attachStall: pid %d DEFERRED, %ld now pending", pid, pendingCount))
                logger(String(format: "childProcessDidStart: pid %d deferred - app is not active (flag=%@, state=%@), will attach on return", pid, flagActive ? "active" : "inactive", actualStateIsActive ? "active" : "inactive"))
                return
            }

            self.ledger.markAttached(pid)
            self.schedulePreflightWatchdog(for: pid)
            self.ledger.markAttachInFlight(pid)

            // Bookkeeping above stays on the serial queue; only the
            // ~1012ms attach itself runs concurrently. See
            // fix_concurrent_attach_slots.py.
            self.attachWorkQueue.async {
                // The slot wait is unbounded. Three attaches parked on a
                // dead tunnel hold every slot and everything behind them
                // waits here, silently.
                let slotWaitStart = CFAbsoluteTimeGetCurrent()
                logger(String(format: "attachStall: pid %d waiting for an attach slot (%ld already in flight)", pid, Self.attachesInFlight))
                self.attachSlots.wait()
                let slotWaited = (CFAbsoluteTimeGetCurrent() - slotWaitStart) * 1000.0
                logger(String(format: "attachStall: pid %d got a slot after %.0fms, starting attachToProcess", pid, slotWaited))
                defer {
                    logger(String(format: "attachStall: pid %d releasing its attach slot", pid))
                    self.attachSlots.signal()
                    self.attachQueue.async { self.ledger.clearAttachInFlight(pid) }
                }
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
            self.recordAttachOutcome(success: result.0, error: result.1)
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
        let attachStart = CFAbsoluteTimeGetCurrent()
        logger(String(format: "attachStall: pid %d entering boundedEnableJIT", pid))
        let (success, error) = boundedEnableJIT(forPID: pid)
        logger(String(format: "attachStall: pid %d boundedEnableJIT returned after %.0fms (success=%@, code=%ld)",
                      pid,
                      (CFAbsoluteTimeGetCurrent() - attachStart) * 1000.0,
                      success ? "YES" : "NO",
                      (error?.code).map { Int($0) } ?? 0))
        cancelPreflightWatchdog(for: pid)
        
        // EBUSY means another attach for this PID is already running -
        // not a failure, and reporting FALSE for it tells the child to
        // give up while the real attach is a second from succeeding.
        // The in-flight call signals when it finishes.
        //
        // The old dedup on attachedPIDs caught duplicates before they
        // reached here, because it was set before the attach began.
        // hasActiveDebugSession only becomes true after, so duplicates
        // now get this far. See
        // fix_dont_report_false_when_in_flight.py.
        if !success, (error?.code).map({ $0 == Int(EBUSY) }) == true {
            logger(String(format: "attachToProcess: pid %d already in flight - leaving the signal to that call", pid))
            return
        }
        
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
        // A generation token, not a DispatchWorkItem.
        //
        // The work-item version tested its own cancellation by reading
        // the `var watchdog` it was assigned to, from inside its own
        // closure. That read is what leaked it: with no capture-list
        // entry the closure captured the variable's box strongly, the
        // box held the item, and a DispatchWorkItem holds its block for
        // its whole lifetime because it can be perform()ed again. One
        // item-plus-closure pair leaked per scheduled watchdog -
        // including every cancelled one, so the leak was at its worst
        // when nothing was going wrong. Assigning nil at the end of the
        // block would not have helped: a cancelled item never runs it.
        //
        // This closure captures a UUID and an Int32 by value and self
        // weakly, so there is no cycle to break. "Cancelled" becomes
        // "the map no longer holds my token", which covers being
        // superseded by the retry below as well as a real cancel.
        let token = UUID()

        preflightWatchdogLock.lock()
        preflightWatchdogs[pid] = token
        preflightWatchdogLock.unlock()

        watchdogQueue.asyncAfter(
            deadline: .now() + .seconds(preflightTimeoutSeconds)
        ) { [weak self] in
            guard let self else {
                return
            }
            dispatchPrecondition(condition: .onQueue(self.watchdogQueue))

            // Claim the entry and remove it on the way through. The old
            // timeout path returned without removing anything, so a
            // timed-out pid sat in the map until that number came round
            // again - the only bulk cleanup is
            // cancelAllPreflightWatchdogs, which runs solely from
            // activateJITLessMode.
            self.preflightWatchdogLock.lock()
            guard self.preflightWatchdogs[pid] == token else {
                self.preflightWatchdogLock.unlock()
                return
            }
            self.preflightWatchdogs.removeValue(forKey: pid)
            let shouldRetry = !self.retriedWatchdogPIDs.contains(pid)
            if shouldRetry {
                self.retriedWatchdogPIDs.insert(pid)
            } else {
                // Giving up on this pid - drop the mark with it.
                self.retriedWatchdogPIDs.remove(pid)
            }
            self.preflightWatchdogLock.unlock()

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
            if shouldRetry {
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
    }

    private func cancelPreflightWatchdog(for pid: Int32) {
        preflightWatchdogLock.lock()
        // Dropping the token IS the cancel: the scheduled closure wakes,
        // finds the map no longer holds it, and returns.
        preflightWatchdogs.removeValue(forKey: pid)
        // Cleared with it, so a later attach on a recycled pid number
        // gets its own retry rather than inheriting a spent one.
        retriedWatchdogPIDs.remove(pid)
        preflightWatchdogLock.unlock()
    }

    private func cancelAllPreflightWatchdogs() {
        preflightWatchdogLock.lock()
        preflightWatchdogs.removeAll()
        retriedWatchdogPIDs.removeAll()
        preflightWatchdogLock.unlock()
    }
    
    /// Transport failures the tunnel recovery already handles. Codes from
    /// JITErrors.h: RemoteServerConnectFailed and DebugProxyConnectFailed.
    private static let recoverableTransportCodes: Set<Int> = [9, 10, -9, -10]

    private func handleJITFailure(error: NSError) {
        // A dead tunnel is not a JIT failure. Backgrounding kills it every
        // time, so the first attach after resume fails at
        // remote_server_connect_rsd - and JITEnabler already drops the
        // cached provider and retries on a rebuilt one, which the device
        // log confirms works ("retry on the rebuilt tunnel SUCCEEDED").
        // Presenting the full-screen "Failed to enable JIT / Error -9" for
        // a condition that self-heals is simply wrong, and because
        // pendingFailureAction defers it to didBecomeActive it appears on
        // RETURN from background, blaming the resume for something that
        // happened during the sleep.
        //
        // Left to the enablement path only: a genuine failure (bad pairing
        // file, VPN off, DDI missing) has its own code and still presents.
        if Self.recoverableTransportCodes.contains(error.code) {
            logger("jitFailure: transport error \(error.code) suppressed - the tunnel rebuild handles it")
            return
        }
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
    
    /// Called from boundedEnableJIT's completion, which both the native
    /// and the Helper-delegation paths funnel through, so neither can
    /// report a healthy tunnel the other knows is dead.
    private func recordAttachOutcome(success: Bool, error: NSError?) {
        // EBUSY means another attach for the same pid is already
        // running. Not a tunnel failure, and counting it would trip the
        // threshold on a burst of duplicates.
        if !success, (error?.code).map({ $0 == Int(EBUSY) }) == true {
            return
        }
        
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            if success {
                if self.isTunnelUnavailable {
                    logger("tunnelHealth: an attach succeeded - tunnel is back, clearing the degraded state")
                }
                self.consecutiveAttachFailures = 0
                self.isTunnelUnavailable = false
                return
            }
            
            self.consecutiveAttachFailures += 1
            guard self.consecutiveAttachFailures >= Self.tunnelFailureThreshold,
                  !self.isTunnelUnavailable else {
                return
            }
            
            self.isTunnelUnavailable = true
            logger(String(format: "tunnelHealth: %d consecutive attach failures - reporting the tunnel as unavailable", self.consecutiveAttachFailures))
        }
    }
    
    private func activateJITLessMode() {
        guard !isJITLessModeActive else {
            return
        }
        
        isJITLessModeActive = true
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            self.cancelAllPreflightWatchdogs()
            self.ledger.clearAllAttached()
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
    
    /// A debug loop saw its target exit. Delivered on that loop's own
    /// thread, so nothing is done here beyond enqueueing.
    @objc private func handleTargetDidExitNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let pidNumber = userInfo["pid"] as? NSNumber
        else {
            return
        }

        let pid = pidNumber.int32Value
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            self.ledger.forgetChild(pid)
            logger(String(format: "childExit: pid %d exited - dropped from the attach ledger", pid))
        }
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
        // Stopped entirely while backgrounded. Nothing is lost: the
        // Darwin observer above stays registered and is the fast path
        // (confirmed alive on device - DARWIN NOTIFICATION appears in
        // every capture), new attaches are deferred while the app is
        // inactive anyway, and the foreground resume runs an immediate
        // scan before restarting the timer, so anything that did arrive
        // is picked up without waiting out an interval.
        helperAttachPollingLifecycleTokens = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.helperAttachPollingTimer != nil else {
                    return
                }
                self.helperAttachPollingTimer?.invalidate()
                self.helperAttachPollingTimer = nil
                logger("helperRequestDelivery: polling timer PAUSED for background")
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.helperAttachPollingTimer == nil else {
                    return
                }
                logger("helperRequestDelivery: polling timer RESUMED for foreground")
                self.processPendingHelperAttachRequests(source: "FOREGROUND RESUME")
                self.startHelperAttachPollingTimer()
            },
        ]
        startHelperAttachPollingTimer()
    }

    private func startHelperAttachPollingTimer() {
        // Deliberately silent. This fires for the app's entire
        // foreground lifetime and almost always finds nothing - 235
        // lines of a 3256-line capture. The path is named where it
        // actually carries a request instead, which is the only place
        // the distinction matters.
        helperAttachPollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.processPendingHelperAttachRequests(source: "POLLING TIMER")
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
    fileprivate func processPendingHelperAttachRequests(source: String) {
        // isProcessingHelperAttachRequests is unsynchronized and relies
        // on every caller being on the main thread - enforce that
        // instead of assuming it.
        dispatchPrecondition(condition: .onQueue(.main))
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

            dispatchPrecondition(condition: .onQueue(self.attachQueue))

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

                // The delivery-path diagnostic, moved here from the two
                // call sites so it costs a line per actual request
                // rather than one per tick. If POLLING TIMER starts
                // carrying requests that DARWIN NOTIFICATION used to,
                // Darwin delivery has died for this extension type and
                // up to 3s of latency is being added to every attach -
                // which matters against the 5s WaitForJITReadySignal
                // deadline and the 10s preflight watchdog.
                logger(String(format: "helperRequestDelivery: %@ delivered %d request(s)",
                              source, pendingRequests.count))
                
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
                    if self.ledger.isRejected(pid) {
                        skipReason = "process type was rejected by shouldAttach - does not need JIT"
                    } else if let type = self.ledger.knownType(pid), !self.shouldAttach(to: type) {
                        // ADDED - see
                        // fix_reattach_respects_process_type.py.
                        //
                        // isRejected above is only ever populated by
                        // childProcessDidStart's shouldAttach guard, and
                        // when the Helper claims a pid first that guard
                        // is never reached - childProcessDidStart lands
                        // in the already-claimed branch and returns. So
                        // gpu, rdd, socket and utility children arrived
                        // here with nothing to stop them, and the
                        // request file carries only a pid and a token.
                        //
                        // The ledger has known the type since
                        // noteChild ran. Marked rejected as well as
                        // skipped, so the answer is cached and the next
                        // request for this pid short-circuits above.
                        self.ledger.markRejected(pid)
                        skipReason = "processType " + type + " is not attachable - does not need JIT"
                    } else if self.ledger.isAttached(pid) {
                        skipReason = "already attached by the native path"
                    }

                    // NOT folded into skipReason above: that branch replies
                    // "success", and telling a child JIT is ready when
                    // nothing attached is worse than telling it no. It would
                    // keep JIT enabled with no W^X mediation behind it, and
                    // the first write into the executable region would take
                    // a SIGBUS. A failure reply drops the child to the
                    // interpreter, which is the fallback this code already
                    // uses everywhere else - slow, but alive.
                    if skipReason == nil, !self.ledger.isApplicationActive {
                        // The guard childProcessDidStart has had since
                        // fix_defer_attaches_while_inactive.py, which this
                        // path never got - and this is the path that
                        // actually performs the attach when the Helper
                        // claims a pid first.
                        //
                        // Captured end to end on device, 0x8BADF00D at
                        // 19:47:52 (Reynard-2026-08-08-194754):
                        //
                        //   :19.955  requestDetachForAllDebugSessions: 13
                        //   :20.242  tabRecovery: content process kill
                        //   :20.567  getProvider: (pid 61314) starting
                        //   :20.578  childProcessDidStart: ENTRY pid 61314
                        //   :20.580  attachStall: already claimed - skipping
                        //   :42.725  Attach response: <stop packet> (22062ms)
                        //   :42.726  continue -> Failed to send debug command
                        //   :42.726  skipping detach - transport already dead
                        //
                        // The attach landed a stop packet 22 seconds later,
                        // by which time the tunnel was gone, so the continue
                        // failed and the detach was skipped. pid 61314 was
                        // left STOPPED with nothing able to resume it, and a
                        // stopped extension cannot answer the synchronous XPC
                        // in _hostWillEnterForegroundNote:. The watchdog took
                        // the app on the next foreground.
                        //
                        // The backgrounding drain cannot help here: this
                        // request arrived 600ms AFTER the teardown ran,
                        // because killing the media tab's content process
                        // makes tabRecovery spawn a replacement, which asks
                        // for JIT on the way up.
                        //
                        // Deferred rather than dropped - drainDeferredPIDs
                        // picks it up on the next activate.
                        let pendingCount = self.ledger.deferAttach(pid)
                        logger(String(
                            format: "processPendingHelperAttachRequests: pid %d DEFERRED - app is not active, %ld now pending",
                            pid, pendingCount
                        ))
                        let resultFileURL = containerURL.appendingPathComponent("\(Self.jitAttachResultFilePrefix)\(pid)_\(token)")
                        try? "failed:deferred - app is not active"
                            .write(to: resultFileURL, atomically: true, encoding: .utf8)
                        CFNotificationCenterPostNotification(
                            CFNotificationCenterGetDarwinNotifyCenter(),
                            CFNotificationName(rawValue: Self.jitAttachReplyNotificationName(forToken: token)),
                            nil,
                            nil,
                            true
                        )
                        continue
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
                    
                    self.ledger.markAttached(pid)
                    self.ledger.markAttachInFlight(pid)

                    // The inserts above are the last shared-state
                    // access; everything below is the ~1012ms attach
                    // plus file I/O and a notification post, none of
                    // which touch state protected by attachQueue. pid
                    // and token are value types captured per iteration,
                    // so each dispatched block writes its own result
                    // file. See fix_concurrent_attach_slots.py.
                    self.attachWorkQueue.async {
                        self.attachSlots.wait()
                        defer {
                            self.attachSlots.signal()
                            self.attachQueue.async { self.ledger.clearAttachInFlight(pid) }
                        }

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
    JITController.shared.processPendingHelperAttachRequests(source: "DARWIN NOTIFICATION")
}
