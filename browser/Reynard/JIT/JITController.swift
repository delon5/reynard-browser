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

    // ADDED - fix_foreground_scoped_jit_transport.py. One of the three
    // gates on closing the tunnel: an orphaned call is by definition one
    // that timed out and may still be inside the FFI holding the
    // adapter.
    static var orphanedAttachCount: Int {
        orphanedAttachLock.lock()
        defer { orphanedAttachLock.unlock() }
        return orphanedAttachPIDs.count
    }
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

    // ADDED - fix_defer_helper_attach_until_type_known.py. When each
    // pid's Helper request was first seen with no announced type, so
    // the deferral can be bounded rather than waiting forever on a
    // child nobody ever announces.
    //
    // Touched only from inside processPendingHelperAttachRequests'
    // attachQueue block, which is the same serial queue AttachLedger is
    // confined to.
    private var helperTypeWaitStart: [Int32: CFAbsoluteTime] = [:]
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
    // ADDED - fix_preflight_watchdog_retry.py. Guarded by
    // preflightWatchdogLock, alongside the two collections above.
    //
    // When attachToProcess for this pid actually STARTED - which is
    // after its attachSlots.wait() returned, not when the attach was
    // queued. schedulePreflightWatchdog is called before the
    // attachWorkQueue.async and before that (unbounded) slot wait, so
    // without this the five-second timer measured the QUEUE rather than
    // the attach: fifteen children through three slots at ~1012ms each
    // leaves everything past roughly the twelfth still parked at +5s,
    // and the watchdog fired on healthy attaches that had not begun.
    //
    // Which is not cosmetic. The watchdog's terminal path calls
    // handleJITFailure(ETIMEDOUT), and ETIMEDOUT is not in
    // recoverableTransportCodes - so it latches hasHandledFailure and
    // guard 1 in childProcessDidStart then rejects every content
    // process for the rest of the process lifetime.
    //
    // The timer is DEFERRED rather than moved, so every call site is
    // left exactly as it is.
    private var preflightAttachStarts: [Int32: CFAbsoluteTime] = [:]
    // How many times each pid's watchdog has re-armed itself. Capped,
    // so a pid whose attach never starts at all still reaches a verdict
    // - late and loudly - instead of rescheduling forever and leaking
    // its map entry.
    private var preflightWatchdogDeferrals: [Int32: Int] = [:]
    // 12 x preflightTimeoutSeconds = up to 60s of grace, which covers a
    // pid queued behind one attach burning the full 90s bound better
    // than any smaller number would, without being unbounded.
    private static let preflightWatchdogMaxDeferrals = 12
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
        // ADDED - see fix_prewarm_checks_foreground.py's docstring.
        //
        // JITEnabler.m cannot read the mirror above - it compiles into
        // the Reynard Helper target, which has no Reynard-Swift.h - and
        // prewarmSharedTunnel has to know whether the foreground it was
        // queued in is still the foreground it is running in. Pushed
        // from here because this is the only writer, so the copy can
        // only ever be as stale as this call. Outside the lock: the
        // ObjC setter takes a serial queue of its own and does not need
        // this one.
        JITEnabler.setApplicationForeground(active)
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

    /// Emergency counterpart to the +2s foreground recovery in
    /// SceneDelegate.sceneWillEnterForeground, for the one case where
    /// that recovery can never run: the main thread is parked inside
    /// ExtensionFoundation's synchronous lifecycle XPC to a content
    /// process that a dying debug transport left stopped. The +2s
    /// block sits on the MAIN queue (see
    /// fix_defer_reattach_past_transition.py), so it waits behind the
    /// hang forever while FrontBoard's 10-second scene-update budget
    /// runs out - 0x8BADF00D with 0.1s of CPU used, watched from the
    /// hang watchdog with 8 seconds to spare and, until now, no lever
    /// to pull: kill() on an extension process returns EPERM. See
    /// fix_resume_stopped_children_on_foreground_hang.py.
    ///
    /// Re-attaching IS the resume mechanism, not just a JIT repair: a
    /// fresh session's first action is either a continue (the loop
    /// re-arms) or an immediate clean detach (a teardown request is
    /// still standing and runDebugService joins it) - and both leave
    /// the target RUNNING. Once the stopped child runs, it answers
    /// the parked XPC, the main thread unblocks, and the scene update
    /// completes inside the budget: the watchdog fires at 2.0s and an
    /// attach takes ~1.4s, so recovery lands around +3.5s of the 10s.
    ///
    /// Called from MainThreadHangWatchdog's background queue - never
    /// the main thread, which is the one that is stuck.
    /// The reattach pass for the hang recovery, WITHOUT the
    /// active-state gate. reattachOrphanedProcesses skips its whole
    /// pass while the app is not active - correct for every normal
    /// caller, because vAttach stops its target and a stopped
    /// extension cannot answer lifecycle XPC. But on this path the
    /// gate is closed BY the hang itself: didBecomeActive is
    /// delivered on the main thread after the foreground cascade
    /// completes, and the hang is the cascade failing to complete, so
    /// the cached flag is stale-inactive for as long as the recovery
    /// is needed. Observed on device: the recovery ran, the census
    /// named the stopped child, the teardown request was lifted - and
    /// the gated pass skipped itself with 9 seconds of watchdog
    /// budget left. 0x8BADF00D followed. See
    /// fix_hang_recovery_bypasses_active_gate.py.
    ///
    /// The gate's own reasoning does not apply here: the child this
    /// pass exists to reach is already STOPPED, and the fresh
    /// session's first action resumes it. Healthy orphans re-attached
    /// alongside are stopped ~1s and continued - transient, against
    /// the certain kill this races. The pass cannot run in a settled
    /// background because the hang watchdog pauses itself there.
    ///
    /// Same pipeline and dedup semantics as reattachOrphanedProcesses;
    /// only the gate is gone.
    private func reattachOrphansForHangRecovery() {
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))

            let attached = self.ledger.attachedSnapshot()
            let alive = attached.filter { Self.pidIsAlive($0) }
            let orphaned = alive.filter { pid in
                guard !self.ledger.isAttachInFlight(pid) else {
                    return false
                }
                return !JITEnabler.hasActiveDebugSession(forPID: pid)
            }

            logger(String(format: "hangRecovery: forced reattach pass - %d attached, %d alive, %d in flight, %d orphaned", attached.count, alive.count, self.ledger.attachInFlightCount(), orphaned.count))

            guard !orphaned.isEmpty else {
                return
            }

            for pid in orphaned {
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

    func recoverStoppedChildrenAfterForegroundHang() {
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))

            // No session was ever attached in these modes, so no
            // child can be holding a debugger stop - and the hang,
            // whatever it is, is not one a re-attach can fix.
            guard !self.isJITLessModeActive, !self.hasHandledFailure else {
                logger("hangRecovery: skipped - JIT-less mode or a latched failure, no child holds a debugger stop")
                return
            }

            // The background teardown's standing detach request would
            // make every recovered loop detach on its first
            // iteration. Even that resumes the child - but the
            // watchdog only runs foregrounded (it pauses on
            // didEnterBackground), and the applicationDidBecomeActive
            // that normally lifts the request is parked behind the
            // hang. Lift it here, mirroring that handler's ordering,
            // so the recovered loops re-arm instead of churning.
            JITEnabler.clearDebuggerTeardownRequest()

            logger("hangRecovery: main thread parked - re-attaching orphaned children from the watchdog path")

            // The same census the main-queue recovery runs, then a
            // FORCED reattach pass: reattachOrphanedProcesses gates
            // itself on the app being active, and during this hang
            // the app is provably not yet active - didBecomeActive is
            // parked behind the very hang being recovered from - so
            // the normal pass skipped itself entirely, two seconds
            // before the kill it existed to prevent. Observed exactly
            // that way on device. Idempotence against the main-queue
            // copy running later is unchanged: a pid with a live
            // session is not an orphan, and boundedEnableJIT's
            // per-pid in-flight guard covers the overlap window. See
            // fix_hang_recovery_bypasses_active_gate.py.
            self.dumpChildCensus(labelled: "childCensus at hangRecovery")
            self.reattachOrphansForHangRecovery()
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
        // Before the hop, deliberately - this half needs no queue, so it
        // still prints if attachQueue is wedged. See
        // fix_child_heartbeat_instrument.py.
        JITEnabler.dumpChildHeartbeats(labelled: label)

        attachQueue.async {
            // Prune first: childTypes is purely diagnostic, the dump
            // below only ever showed live children anyway, and without
            // eviction the map grew by one entry per child process for
            // the life of the app.
            let prunedAttached = self.ledger.pruneDeadChildren(alive: Self.pidIsAlive)
            if prunedAttached > 0 {
                logger(String(format: "%@: pruned %ld dead pid(s) from the attach ledger", label, prunedAttached))
            }

            // ADDED - see fix_helper_type_wait_pruned.py's docstring.
            //
            // helperTypeWaitStart is the sixth per-pid collection and
            // the only one the sweep above cannot reach: it lives on
            // the controller, not the ledger. Same liveness test, same
            // queue - this block is already attachQueue-confined, which
            // is where that map is only ever touched.
            //
            // Growth is the small half. The real one is number reuse.
            // The entry written when a Helper request is deferred for
            // an unannounced type is removed on the drain pass that
            // finally attaches the pid - and that pass never comes if
            // the Helper deletes its own request first, which it does
            // 20s in. A stranded timestamp makes the deferral's
            // `waited < 0.5` read false the first time the recycled
            // number is seen, so the new child is attached WITHOUT
            // waiting for its type - the over-attaching the deferral
            // exists to prevent.
            let helperWaitsBefore = self.helperTypeWaitStart.count
            self.helperTypeWaitStart = self.helperTypeWaitStart.filter { Self.pidIsAlive($0.key) }
            let prunedHelperWaits = helperWaitsBefore - self.helperTypeWaitStart.count
            if prunedHelperWaits > 0 {
                logger(String(format: "%@: pruned %ld dead pid(s) from the helper type-wait map", label, prunedHelperWaits))
            }

            let census = self.ledger.childCensus()
            logger("\(label): \(self.ledger.announcedChildTotal()) child(ren) announced this launch, \(census.count) alive")
            for entry in census {
                let session = JITEnabler.hasActiveDebugSession(forPID: entry.pid)
                // ADDED - see fix_report_child_run_state.py's docstring.
                //
                // The missing column. This dump runs at the foreground
                // handshake precisely because that is where the app dies,
                // and until now it could say a child was alive and
                // sessionless without being able to say whether it was
                // RUNNING. STOP here names the extension that is not
                // answering the synchronous XPC.
                let runState = JITEnabler.runState(forPID: entry.pid)
                logger(String(
                    format: "  %@: pid %d type=%@ attached=%@ session=%@ state=%@",
                    label, entry.pid, entry.type,
                    entry.attached ? "yes" : "NO",
                    session ? "yes" : "NO",
                    runState
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

    /// Closes the JIT transport on the way into a suspension, if and
    /// only if nothing can still be using it.
    ///
    /// ADDED - see fix_foreground_scoped_jit_transport.py. Four gates,
    /// because freeing an AdapterHandle another thread is inside an FFI
    /// call with is a use-after-free, and that is exactly what
    /// fix_provider_use_after_free.py was written to end:
    ///
    ///   attachInFlightCount   an attach this app started and is waiting on
    ///   orphanedAttachCount   one that timed out and may still be running
    ///   vAttachInFlightSince  a vAttach actually inside the FFI right now
    ///   liveDebugSessionCount a registered runDebugService loop, which
    ///                         holds a debug_proxy opened off this adapter
    ///
    /// The first three are read on attachQueue, which is also the queue
    /// every attach marks itself in flight on - so no attach can start
    /// between the check and the close.
    ///
    /// The fourth was ADDED - see
    /// fix_tunnel_close_waits_for_debug_loops.py. The other three are all
    /// attach-phase state, so a session that finished attaching is
    /// invisible to them, and the 0.15s between the cancel in
    /// sceneDidEnterBackground and this call is not a substitute: cancel
    /// is not sticky, and a loop's teardown keeps issuing FFI calls -
    /// a detach, a 50ms sleep, a retry - after it logs "Debug loop
    /// ended". It is read on debugSessionStateQueue, the queue every loop
    /// registers and unregisters its proxy on.
    ///
    /// Skip rather than force: the next background gets another go, and a
    /// missed close costs one cycle of JIT, where a wrong one costs a
    /// crash.
    func closeTunnelForSuspension() {
        attachQueue.async {
            let inFlight = self.ledger.attachInFlightCount()
            let orphaned = Self.orphanedAttachCount
            let vAttachRunning = JITEnabler.vAttachInFlightSince() != nil
            // ADDED - see fix_tunnel_close_waits_for_debug_loops.py's
            // docstring. The three counters above are all attach-phase
            // state; this one is the loops that are already running, each
            // holding a debug_proxy carved off the very adapter
            // closeSharedTunnel frees.
            let liveSessions = Int(JITEnabler.liveDebugSessionCount())

            guard inFlight == 0, orphaned == 0, !vAttachRunning, liveSessions == 0 else {
                logger(String(
                    format: "tunnelClose: SKIPPED - %d attach(es) in flight, %d orphaned, vAttach %@, %d live debug session(s) - leaving the tunnel alone",
                    inFlight, orphaned, vAttachRunning ? "RUNNING" : "idle", liveSessions
                ))
                return
            }

            JITEnabler.shared.closeSharedTunnel()
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

        // Re-armed here, ahead of the re-attach pass, deliberately.
        //
        // This was briefly gated on a live session existing
        // (fix_arm_trapping_only_with_a_live_session.py), because the
        // process-wide key alone could not tell a child with a loop from
        // one without, and a surviving CS_DEBUGGED child could trap into
        // nothing. fix_per_pid_debugger_listening.py closed that at the
        // only place that can actually know: a child now also needs
        // com.minh-ton.Reynard.JITDebuggerListening.<its own pid>, which
        // its own runDebugService arms when the loop starts and clears
        // first thing in the teardown.
        //
        // With that gate in place this key is a master switch again, and
        // holding it off until some other pid answers only costs
        // interpreted JavaScript at the moment JIT is most wanted - a
        // foreground, a PiP restore, a CarPlay resume. See
        // revert_arm_trapping_only_with_a_live_session.py.
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

            // ADDED - fix_foreground_scoped_jit_transport.py. The
            // background teardown closed the tunnel, so rebuild it here
            // rather than letting the first child discover it is gone by
            // failing - which is the attach that becomes the "Failed to
            // enable JIT / Error -9" screen on return from background.
            //
            // Cheap when it is not needed: getProviderForPID returns the
            // cached provider and skips both createDeviceProvider and the
            // DDI mount.
            JITEnabler.shared.prewarmSharedTunnel()

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
                    // ADDED - fix_attach_gates_and_helper_guards.py. The
                    // same re-check reattachOrphanedProcesses grew, for
                    // exactly the same reason: attachSlots.wait() above is
                    // UNBOUNDED, so "the app is active" was settled by the
                    // didBecomeActive callback that queued this drain and
                    // has not been asked again since.
                    //
                    // Three slots at ~1.2s each and the 15 children a cold
                    // launch spawns (AttachLedger.swift:77-84) puts the
                    // tail of a drain roughly five seconds past that
                    // decision. The window that killed the app on
                    // 2026-08-12 was 1.04s wide.
                    //
                    // Starting the vAttach is the irreversible step: it
                    // stops the target for ~1013ms, and a stopped
                    // NSExtension cannot answer the synchronous XPC iOS
                    // sends on the next lifecycle transition. 0x8BADF00D.
                    // Nothing downstream will refuse it either -
                    // JITEnabler.m's enableJITForPID: has no foreground
                    // check at all.
                    //
                    // AFTER the defer, deliberately: returning from here
                    // still signals the slot and still clears the
                    // in-flight mark.
                    //
                    // The mirror rather than the ledger flag, for the
                    // reason given at reattachOrphanedProcesses: this runs
                    // on the CONCURRENT attachWorkQueue, and hopping to
                    // attachQueue to ask would block a slot-holding thread
                    // behind a possible 90-second attach.
                    guard Self.isApplicationActiveFromAnyQueue else {
                        logger(String(format: "attachGate: pid %d abandoned at the slot - app went inactive while the deferred drain queued", pid))
                        // Load-bearing. schedulePreflightWatchdog ran above,
                        // and its timeout path retries by calling
                        // attachToProcess directly on attachQueue with no
                        // gate of its own - so leaving it armed would start
                        // the very vAttach this guard just refused, five
                        // seconds from now and still backgrounded. It also
                        // clears retriedWatchdogPIDs, so this pid keeps its
                        // one retry for whenever it is attached for real.
                        //
                        // No deferAttach: markAttached already ran and the
                        // drain skips anything in attachedPIDs. The
                        // recovery is reattachOrphanedProcesses on the next
                        // foreground, which is precisely what a pid marked
                        // attached with no live debug session is for.
                        self.cancelPreflightWatchdog(for: pid)
                        return
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
        attachQueue.async {
            self.ledger.noteChild(pid, type: processType)

            // ADDED - fix_defer_helper_attach_until_type_known.py. The
            // fast retry for a Helper request this pid's own arrival
            // deferred. Posted from INSIDE this block so it cannot run
            // before noteChild has recorded the type, and onto main
            // because processPendingHelperAttachRequests asserts it is
            // called there.
            //
            // Best effort: that function is non-reentrant, so a post
            // landing while a pass is still running is dropped. The
            // polling timer is the backstop, and the 0.5s budget in the
            // deferral falls through to today's behaviour if both miss.
            DispatchQueue.main.async {
                self.processPendingHelperAttachRequests(source: "TYPE ANNOUNCED")
            }
        }

        // ADDED - see fix_child_heartbeat_instrument.py. Recorded
        // synchronously and into the ObjC layer's own map, NOT the
        // ledger: the hang-time dump has to work while attachQueue is
        // blocked, which is exactly when it earns its keep.
        JITEnabler.recordChildForHeartbeat(pid, type: processType)

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
                // ADDED - fix_attach_gates_and_helper_guards.py, the same
                // re-check reattachOrphanedProcesses grew.
                //
                // The gate for this attach was evaluated on attachQueue
                // before the dispatch above, and half of it is not even a
                // real reading: actualStateIsActive is hard-coded true
                // whenever childProcessDidStart is called off the main
                // thread, so off-main the whole decision rests on the
                // cached ledger flag. The slot wait immediately above is
                // UNBOUNDED - the log line right before it exists because
                // this queue is known to back up - so by the time this pid
                // reaches the front that decision can be seconds old.
                //
                // Three slots at ~1.2s each and the 15 children a cold
                // launch spawns (AttachLedger.swift:77-84) puts the tail
                // of that burst roughly five seconds past its own gate.
                // The active-to-background window that killed the app on
                // 2026-08-12 was 1.04s wide.
                //
                // Starting the vAttach is the irreversible step: it stops
                // the target for ~1013ms, and a stopped NSExtension cannot
                // answer the synchronous XPC iOS sends on the next
                // lifecycle transition. 0x8BADF00D. There is no backstop
                // underneath - JITEnabler.m's enableJITForPID: has no
                // foreground check at all.
                //
                // AFTER the defer, deliberately: returning from here still
                // signals the slot and still clears the in-flight mark.
                //
                // The mirror rather than the ledger flag: this runs on the
                // CONCURRENT attachWorkQueue, and hopping to attachQueue to
                // ask would block a slot-holding thread behind a possible
                // 90-second attach.
                guard Self.isApplicationActiveFromAnyQueue else {
                    logger(String(format: "attachGate: pid %d abandoned at the slot - app went inactive while the native attach queued", pid))
                    // Load-bearing. schedulePreflightWatchdog ran before
                    // this dispatch, and its timeout path retries by
                    // calling attachToProcess directly on attachQueue with
                    // no gate of its own - so leaving it armed would start
                    // the very vAttach this guard just refused, five
                    // seconds from now and still backgrounded. It also
                    // clears retriedWatchdogPIDs, so this pid keeps its one
                    // retry for whenever it is attached for real.
                    //
                    // No deferAttach and no ReportJITStatusForChild. The
                    // deferral this mirrors, a few lines up, is silent for
                    // the same reason: the drain skips anything already in
                    // attachedPIDs, and burning the single-use report pipe
                    // with a FALSE would foreclose the real TRUE that the
                    // next foreground's reattach pass can still deliver.
                    self.cancelPreflightWatchdog(for: pid)
                    return
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
        // ADDED - fix_preflight_watchdog_retry.py. Every path into here
        // calls this immediately after attachSlots.wait() returns, so
        // this is the moment "the attach has actually begun" becomes
        // true and the preflight watchdog can start measuring something
        // real.
        //
        // Only for a pid that HAS a watchdog armed: the orphan
        // re-attach passes never arm one and must not leave an entry
        // behind. And only for the first attach to reach here, so a
        // duplicate that boundedEnableJIT is about to bounce with EBUSY
        // cannot push the live attach's deadline out.
        preflightWatchdogLock.lock()
        if preflightWatchdogs[pid] != nil, preflightAttachStarts[pid] == nil {
            preflightAttachStarts[pid] = attachStart
        }
        preflightWatchdogLock.unlock()
        logger(String(format: "attachStall: pid %d entering boundedEnableJIT", pid))
        let (success, error) = boundedEnableJIT(forPID: pid)
        logger(String(format: "attachStall: pid %d boundedEnableJIT returned after %.0fms (success=%@, code=%ld)",
                      pid,
                      (CFAbsoluteTimeGetCurrent() - attachStart) * 1000.0,
                      success ? "YES" : "NO",
                      (error?.code).map { Int($0) } ?? 0))
        
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
        
        // MOVED - fix_preflight_watchdog_retry.py. This used to run
        // twelve lines higher, above the EBUSY test, so a duplicate
        // that boundedEnableJIT bounced in microseconds disarmed the
        // LIVE attach's freshly-scheduled watchdog and cleared its
        // retry mark on the way out. Below the branch, only a call
        // that actually reached the device - a success or a real
        // failure - is allowed to cancel.
        //
        // Still pid-keyed rather than token-scoped, deliberately.
        // The watchdog is a per-pid resource because the pipe it
        // consumes is: ReportJITStatusForChild is single-use per
        // child, so once ANY attempt has resolved the pid no watchdog
        // for it should fire. A token-scoped cancel would leave a
        // watchdog armed by a superseding retry running after this
        // attach reported TRUE, and that watchdog's terminal path
        // calls handleJITFailure(ETIMEDOUT), which latches JIT off
        // for the whole app.
        cancelPreflightWatchdog(for: pid)
        
        if success {
            // ADDED - see fix_no_jit_promise_during_teardown.py's
            // docstring.
            //
            // The attach succeeded, but if a background teardown is
            // standing then runDebugService is about to find it, join it
            // and detach without ever arming this pid - the
            // "attach landed after teardown" path. Telling the child YES
            // here leaves it with the JIT backend enabled and no debugger
            // to mediate its W^X writes, and it then faults on every one
            // until the SIGBUS cap kills it at 4096. Three content
            // processes died that way on 2026-08-13.
            //
            // FALSE drops it to the interpreter instead - slow, alive,
            // and the fallback this codebase already uses everywhere.
            if JITEnabler.isDebuggerTeardownRequested() {
                logger(String(format: "attachToProcess: pid %d attach succeeded but a teardown is standing - reporting FALSE so it does not enable JIT it cannot use", pid))
                ReportJITStatusForChild(pid, false, newJITRuntimeInfo())
                return
            }
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
        // ADDED - fix_preflight_watchdog_retry.py. Arming is also a
        // reset: under THIS token the attach has not started, and the
        // watchdog has not deferred.
        preflightAttachStarts.removeValue(forKey: pid)
        preflightWatchdogDeferrals.removeValue(forKey: pid)
        preflightWatchdogLock.unlock()

        armPreflightWatchdog(for: pid, token: token, after: Double(preflightTimeoutSeconds))
    }

    // ADDED - fix_preflight_watchdog_retry.py. The timer half of
    // schedulePreflightWatchdog, split out so the closure can re-arm
    // ITSELF - same token, shorter deadline - on waking to find that the
    // attach it is timing has not started yet, or has not yet had its
    // full preflightTimeoutSeconds of running time.
    //
    // The same token deliberately: re-arming through
    // schedulePreflightWatchdog would install a new one and reset the
    // deferral count with it, and a pid could then defer forever.
    private func armPreflightWatchdog(for pid: Int32, token: UUID, after seconds: Double) {
        watchdogQueue.asyncAfter(
            deadline: DispatchTime.now() + seconds
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

            // ADDED - fix_preflight_watchdog_retry.py. This timer was
            // armed when the attach was QUEUED, not when it started:
            // schedulePreflightWatchdog runs before the
            // attachWorkQueue.async and before attachSlots.wait(), and
            // that wait is unbounded by design. Three slots at ~1012ms
            // per vAttach means a burst of fifteen children leaves
            // everything past roughly the twelfth still parked when this
            // fires - healthy attaches that have not begun.
            //
            // So measure the ATTACH. If it has not begun, or has begun
            // but has had less than preflightTimeoutSeconds of running
            // time, re-arm for whatever is left and keep the token.
            // Bounded by preflightWatchdogMaxDeferrals so a pid whose
            // attach never starts still reaches a verdict.
            let deferrals = self.preflightWatchdogDeferrals[pid] ?? 0
            let attachStarted = self.preflightAttachStarts[pid]
            let elapsed = attachStarted.map { CFAbsoluteTimeGetCurrent() - $0 } ?? 0.0
            let remaining = Double(self.preflightTimeoutSeconds) - elapsed
            // 0.05 rather than 0: re-arming for a few microseconds is
            // just a wakeup, and the watchdog would fire anyway.
            let windowUnspent = remaining > 0.05
            if windowUnspent, deferrals < Self.preflightWatchdogMaxDeferrals {
                self.preflightWatchdogDeferrals[pid] = deferrals + 1
                // Unlocked BEFORE logging: logger() writes to a file and
                // takes a lock of its own, and the whole point of
                // guarding these maps with a lock rather than confining
                // them to a queue is that a cancel never waits.
                self.preflightWatchdogLock.unlock()
                // Hoisted out of the String(format:) argument list rather
                // than written inline: a ternary in a CVarArg... position
                // is needless work for the type checker.
                let reason: String = attachStarted == nil
                    ? "its attach has not started yet, it is still queued for a slot"
                    : "its attach has not had its full preflight window yet"
                logger(String(format: "preflightWatchdog: pid %d deferring - %@ (deferral %ld of %ld, %.1fs to go)",
                              pid,
                              reason,
                              deferrals + 1,
                              Self.preflightWatchdogMaxDeferrals,
                              remaining))
                self.armPreflightWatchdog(for: pid, token: token, after: remaining)
                return
            }

            self.preflightWatchdogs.removeValue(forKey: pid)
            self.preflightAttachStarts.removeValue(forKey: pid)
            self.preflightWatchdogDeferrals.removeValue(forKey: pid)
            let shouldRetry = !self.retriedWatchdogPIDs.contains(pid)
            if shouldRetry {
                self.retriedWatchdogPIDs.insert(pid)
            } else {
                // Giving up on this pid - drop the mark with it.
                self.retriedWatchdogPIDs.remove(pid)
            }
            self.preflightWatchdogLock.unlock()

            // ADDED - fix_preflight_watchdog_retry.py. Reaching a verdict
            // with the preflight window still unspent means the cap ran
            // out, i.e. the attach never got far enough for ~60 seconds.
            // Worth saying out loud - it is the one way this fix can hide
            // a real failure, and it should be rare.
            if windowUnspent {
                logger(String(format: "preflightWatchdog: pid %d hit the deferral cap (%ld) - proceeding to a verdict with %.1fs of its preflight window unspent", pid, Self.preflightWatchdogMaxDeferrals, remaining))
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
            if shouldRetry {
                // CHANGED - fix_preflight_watchdog_retry.py.
                //
                // This used to call attachToProcess INLINE on the serial
                // attachQueue, with no slot permit and no guards.
                //
                // The permit: without one the documented cap of three
                // concurrent vAttaches became four. And because
                // attachToProcess can sit inside boundedEnableJIT for
                // enableJITMaxWaitSeconds = 90, attachQueue itself was
                // held for up to ninety seconds - taking
                // closeTunnelForSuspension,
                // recoverStoppedChildrenAfterForegroundHang,
                // applicationDidBecomeActive, the
                // isProcessingHelperAttachRequests reset (so Helper
                // attach delivery was suppressed for the duration) and
                // every completing attach's clearAttachInFlight defer -
                // gate 1 of the tunnel close, left stale-non-zero - down
                // with it. The EBUSY fast path does not save it: a pid
                // parked at a slot has no enableJITInFlightByPID entry
                // yet.
                //
                // It now takes exactly the path every other caller takes:
                // bookkeeping on attachQueue, the slow call on
                // attachWorkQueue behind a permit.
                self.attachQueue.async {
                    dispatchPrecondition(condition: .onQueue(self.attachQueue))

                    // The guards every other entry point has and this one
                    // had none of.
                    //
                    // hasActiveDebugSession is the load-bearing one. The
                    // registries in JITSupport.m are pid-keyed and assume
                    // one session per pid - registerDebugSessionProxy
                    // OVERWRITES - so a second attach on a pid that
                    // already has a live loop makes loop 1 invisible:
                    // session 2's teardown unregisters the proxy, so
                    // liveDebugSessionCount() reports 0 while loop 1 is
                    // still issuing FFI calls on provider->adapter. That
                    // count is gate 4 of closeTunnelForSuspension, added
                    // precisely to stop adapter_free running under a live
                    // loop. Session 2's teardown also runs
                    // setDebugSessionListeningForPID(pid, NO), which finds
                    // session 1's notify token and cancels it - disarming
                    // a live loop's target while the child still has JIT
                    // enabled.
                    //
                    // The window is small and real: the first attach can
                    // register its session a few milliseconds after this
                    // watchdog fires.
                    //
                    // isJITLessModeActive/hasHandledFailure are read here
                    // the same way childProcessDidStart's guard 1 reads
                    // them, off their writing queue - deliberately
                    // unchanged, this is not the place to alter that
                    // contract.
                    let rejection: String?
                    if JITEnabler.hasActiveDebugSession(forPID: pid) {
                        rejection = "it already has a live debug session - a second one would make the first invisible to the tunnel close"
                    } else if self.isJITLessModeActive || self.hasHandledFailure {
                        rejection = "JIT is already latched off for this process"
                    } else if !Self.isApplicationActiveFromAnyQueue {
                        rejection = "the app is not active, and vAttach stops its target"
                    } else if !Self.pidIsAlive(pid) {
                        rejection = "it is gone"
                    } else if let type = self.ledger.knownType(pid), !self.shouldAttach(to: type) {
                        rejection = "type=\(type) is not attachable"
                    } else {
                        rejection = nil
                    }

                    if let rejection {
                        // Nothing is reported to the child here, on
                        // purpose. ReportJITStatusForChild is a
                        // single-use pipe: a FALSE from this guard would
                        // burn it, and in the live-session case would
                        // contradict the TRUE the successful attach is
                        // about to send. The child has its own
                        // five-second deadline and falls back to the
                        // interpreter on its own - the same end state,
                        // one beat later.
                        logger(String(format: "preflightWatchdog: pid %d NOT retrying - %@", pid, rejection))
                        // Drop the spent retry mark with it, exactly as
                        // cancelPreflightWatchdog does, so a later attach
                        // on this pid number is not left without its one
                        // retry.
                        self.preflightWatchdogLock.lock()
                        self.retriedWatchdogPIDs.remove(pid)
                        self.preflightWatchdogLock.unlock()
                        return
                    }

                    self.schedulePreflightWatchdog(for: pid)
                    self.ledger.markAttachInFlight(pid)
                    self.attachWorkQueue.async {
                        self.attachSlots.wait()
                        defer {
                            self.attachSlots.signal()
                            self.attachQueue.async { self.ledger.clearAttachInFlight(pid) }
                        }
                        // The slot wait above is unbounded, so both of
                        // the irreversible-step checks are made again
                        // here. Starting the vAttach is what stops the
                        // target, and only the debug loop's continue
                        // resumes it.
                        //
                        // The mirror is read rather than the ledger flag
                        // for the same reason reattachOrphanedProcesses
                        // reads it here: this runs on the CONCURRENT
                        // attachWorkQueue, and hopping to attachQueue to
                        // ask would block a slot-holding thread behind a
                        // possible 90-second attach.
                        //
                        // Both abandon paths cancel the watchdog armed
                        // just above. attachToProcess is what normally
                        // cancels it, and it is not going to run - so
                        // without this the watchdog would stand, defer
                        // its way through the whole cap because no
                        // attach ever starts, and then report FALSE and
                        // latch JIT off for the app a minute later.
                        guard Self.isApplicationActiveFromAnyQueue else {
                            logger(String(format: "preflightWatchdog: pid %d abandoned at the slot - the app went inactive while the retry queued", pid))
                            self.cancelPreflightWatchdog(for: pid)
                            return
                        }
                        guard !JITEnabler.hasActiveDebugSession(forPID: pid) else {
                            logger(String(format: "preflightWatchdog: pid %d abandoned at the slot - a debug session appeared while the retry queued", pid))
                            self.cancelPreflightWatchdog(for: pid)
                            return
                        }
                        self.attachToProcess(pid: pid)
                    }
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

    // CHANGED - fix_preflight_watchdog_retry.py. Returns whether a
    // watchdog was actually armed, so handleTargetDidExitNotification can
    // log only when it cancelled something real. @discardableResult
    // because the attachToProcess caller does not care.
    @discardableResult
    private func cancelPreflightWatchdog(for pid: Int32) -> Bool {
        preflightWatchdogLock.lock()
        // Dropping the token IS the cancel: the scheduled closure wakes,
        // finds the map no longer holds it, and returns.
        let wasArmed = preflightWatchdogs.removeValue(forKey: pid) != nil
        // Cleared with it, so a later attach on a recycled pid number
        // gets its own retry rather than inheriting a spent one.
        retriedWatchdogPIDs.remove(pid)
        // Same reasoning for the deferral bookkeeping: a recycled pid
        // number must not inherit a spent deferral budget or a stale
        // attach start.
        preflightAttachStarts.removeValue(forKey: pid)
        preflightWatchdogDeferrals.removeValue(forKey: pid)
        preflightWatchdogLock.unlock()
        return wasArmed
    }

    private func cancelAllPreflightWatchdogs() {
        preflightWatchdogLock.lock()
        preflightWatchdogs.removeAll()
        retriedWatchdogPIDs.removeAll()
        preflightAttachStarts.removeAll()
        preflightWatchdogDeferrals.removeAll()
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
        retryJITAfterTunnelRecoveryIfNeeded()
    }

    /// One probe at a time; each is user-gesture-bounded (one per
    /// foregrounding), the cadence this codebase prefers over polling.
    private var isTunnelRecoveryProbeInFlight = false

    // ADDED - see fix_jitless_recovers_when_tunnel_returns.py's
    // docstring. JIT-less mode is documented to the user as
    // "temporarily until the next launch", but nothing ever re-checked
    // the condition that forced it: once latched, every content
    // process for the rest of the session ran interpreted, even if the
    // pairing endpoint came back minutes later. Observed on device as
    // a full day of twitch.tv hydrating black -> skeleton -> content
    // over 6-9 seconds, reloads included, each reload's fresh process
    // rejected by guard 1.
    //
    // Each return to foreground while latched runs one silent tunnel
    // probe (the same getProvider call prewarm uses - ~16ms against a
    // refusing endpoint, per the captured log). Only a probe that
    // SUCCEEDS changes anything: both latches clear, so the NEXT
    // content process attaches normally. Processes already running
    // stay interpreted - reloading a tab replaces its process, which
    // is recovery enough, and reattaching live processes is exactly
    // what this file's history warns against. A failed probe leaves
    // the latch exactly as it was: no failure sheet, no nag.
    //
    // Gated off for the conditions a tunnel cannot fix - missing DDI,
    // ptrace mode unavailable - with the same guard start() uses.
    private func retryJITAfterTunnelRecoveryIfNeeded() {
        guard isJITLessModeActive || hasHandledFailure else {
            return
        }
        guard usePtraceJIT() || !isDDIMissing() else {
            return
        }
        guard !isTunnelRecoveryProbeInFlight else {
            return
        }
        isTunnelRecoveryProbeInFlight = true
        logger("jitRecovery: JIT-less or a latched failure at foreground - probing the tunnel")
        JITEnabler.shared.probeSharedTunnel { available in
            self.isTunnelRecoveryProbeInFlight = false
            guard available else {
                logger("jitRecovery: tunnel still unavailable - staying latched")
                return
            }
            logger("jitRecovery: tunnel is back - clearing the JIT-less latch, new content processes will attach")
            self.hasHandledFailure = false
            self.isJITLessModeActive = false
            // The probe's success is the same evidence recordAttachOutcome
            // treats as "tunnel is back"; reset the health counters on
            // their own queue like it does.
            self.attachQueue.async {
                self.consecutiveAttachFailures = 0
                self.isTunnelUnavailable = false
            }
            NotificationCenter.default.post(name: .jitlessModeDidDeactivate, object: nil)
        }
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
        // ADDED - fix_preflight_watchdog_retry.py. Synchronously, on
        // whatever thread the debug loop posted from, and BEFORE the
        // attachQueue hop: the whole reason the watchdog maps are
        // lock-guarded rather than attachQueue-confined is that a cancel
        // must never queue behind a bounded attach.
        //
        // Nothing cancelled this before, so a watchdog for an exited pid
        // fired anyway - reporting FALSE for a child that is already gone
        // and then calling handleJITFailure(ETIMEDOUT), which is not in
        // recoverableTransportCodes and so latches JIT off for the whole
        // app.
        if cancelPreflightWatchdog(for: pid) {
            logger(String(format: "preflightWatchdog: pid %d exited with its watchdog still armed - cancelled, so it cannot report FALSE and latch JIT off for a dead pid", pid))
        }
        attachQueue.async {
            dispatchPrecondition(condition: .onQueue(self.attachQueue))
            self.ledger.forgetChild(pid)
            self.helperTypeWaitStart.removeValue(forKey: pid)
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
    // The Helper stops waiting after 20 seconds.  Five seconds of grace
    // covers a final directory scan without retaining a request forever.
    fileprivate static let jitAttachRequestStaleAgeSeconds: TimeInterval = 25
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
                // ADDED - prewarmSharedTunnel() at willEnterForeground.
                // See fix_prewarm_at_will_enter_foreground.py.
                //
                // The other prewarm is in applicationDidBecomeActive,
                // which is AFTER willEnterForeground - and
                // willEnterForeground is where the app dies:
                // EXConcreteExtension's _hostWillEnterForegroundNote:
                // makes a synchronous XPC call to every hosted
                // extension, and a content process left stopped by a
                // torn-down debug session cannot answer it. The main
                // thread never leaves the notification post, so
                // sceneDidBecomeActive never runs and the tunnel is
                // never rebuilt.
                //
                // Reynard20260821083813: no tunnelPrewarm line at the
                // fatal foreground, one at all nineteen others.
                //
                // This closure is itself an observer of that same
                // notification and its own log line is stamped
                // 08:38:00.990 - two seconds before the observer that
                // blocked, inside the same post. So it is the earliest
                // hook known to run, and prewarmSharedTunnel does its
                // work on a global utility queue, which keeps going
                // while the main thread is parked.
                //
                // Ahead of the guard below deliberately: that guard is
                // about the polling timer and returns early whenever the
                // timer is already running, which says nothing about
                // whether the tunnel needs rebuilding. No self needed.
                //
                // Cheap when unnecessary - getProviderForPID: returns
                // the cached provider and skips both
                // createDeviceProvider and the DDI mount.
                JITEnabler.shared.prewarmSharedTunnel()

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

            // ADDED - fix_defer_helper_attach_until_type_known.py. A
            // deferred request is left on disk on purpose, so without
            // this the very next pass of this same loop would see it
            // again and spin against it until maxPasses ran out. Held
            // across passes, cleared when this call returns.
            var deferredForTypeThisCall: Set<Int32> = []

            for _ in 0..<maxPasses {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: containerURL.path) else {
                    return
                }
                
                self.pruneStaleHelperFiles(contents: contents, containerURL: containerURL, fileManager: fileManager)
                
                // Filename format: jit-attach-request-{pid}_{token} - PID
                // kept in the name for easy debugging/readability, token
                // is what actually makes each attempt unique.
                let pendingRequests = contents
                    .filter { $0.hasPrefix(Self.jitAttachRequestFilePrefix) }
                    // pruneStaleHelperFiles works from the same directory
                    // snapshot, so exclude anything it just removed.
                    .filter {
                        fileManager.fileExists(
                            atPath: containerURL.appendingPathComponent($0).path
                        )
                    }
                    // Deferred this call - see deferredForTypeThisCall.
                    .filter { name in
                        let remainder = name.dropFirst(Self.jitAttachRequestFilePrefix.count)
                        guard let underscoreIndex = remainder.firstIndex(of: "_"),
                              let pid = Int32(remainder[remainder.startIndex..<underscoreIndex]) else {
                            return true
                        }
                        return !deferredForTypeThisCall.contains(pid)
                    }
                
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
                    
                    // ADDED - see
                    // fix_defer_helper_attach_until_type_known.py.
                    //
                    // Deliberately ABOVE the removal below: leaving the
                    // request on disk is what makes the next drain pass
                    // pick it up, once childProcessDidStart has said
                    // what this pid is.
                    //
                    // Without this the isRejected check further down is
                    // asked about a pid nobody has announced yet and
                    // answers "not rejected", so rdd and utility
                    // processes are attached despite shouldAttach
                    // refusing them - 80 of 80 attaches in the
                    // 2026-08-14 capture began 8-77ms before the type
                    // was known, and every rdd in every session with a
                    // working tunnel was attached.
                    //
                    // Bounded: a child nobody ever announces must still
                    // get an answer inside its 5s WaitForJITReadySignal
                    // deadline, so after the budget below this falls
                    // through and attaches exactly as it did before.
                    //
                    // CHANGED from 3.5s - see fix_close_before_suspension.py.
                    // In the 2026-08-14 19:31 capture 90 pids were
                    // deferred, 77 hit the budget, and 76 of those 77 were
                    // never announced by Gecko at all. For those the wait
                    // is pure latency against the child's 5s deadline, and
                    // 3.5s plus a 1.0-1.6s attach lands on it - so a child
                    // that should have got JIT falls back to the
                    // interpreter instead.
                    //
                    // The largest inversion ever measured is 77ms. Half a
                    // second is six times that and leaves 4.5s of the
                    // child's budget intact.
                    if self.ledger.knownType(pid) == nil,
                       !self.ledger.isAttached(pid) {
                        let now = CFAbsoluteTimeGetCurrent()
                        let waitedSince = self.helperTypeWaitStart[pid] ?? now
                        if self.helperTypeWaitStart[pid] == nil {
                            self.helperTypeWaitStart[pid] = now
                        }
                        let waited = now - waitedSince
                        if waited < 0.5 {
                            deferredForTypeThisCall.insert(pid)
                            logger(String(
                                format: "helperAttach: pid %d deferred - type not announced yet (%.0fms so far)",
                                pid, waited * 1000.0
                            ))
                            continue
                        }
                        logger(String(
                            format: "helperAttach: pid %d type never announced after %.0fms - attaching anyway",
                            pid, waited * 1000.0
                        ))
                    }
                    self.helperTypeWaitStart.removeValue(forKey: pid)

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

                    // ADDED - fix_attach_gates_and_helper_guards.py.
                    //
                    // The two guards childProcessDidStart has had all
                    // along and this path never got. Its veto chain is
                    // isRejected / knownType+shouldAttach / isAttached /
                    // isApplicationActive, and neither the JIT-less latch,
                    // nor the failure latch, nor the prefs test appears
                    // anywhere in it. attachToHelperProcess does not check
                    // them either.
                    //
                    // The listener is wired up unconditionally -
                    // startListeningForHelperAttachRequests() is called
                    // from start() with no condition, and it gets there
                    // because isDDIMissing() is false when JIT is off, so
                    // start()'s own guard passes. Two reachable states
                    // followed:
                    //
                    //   (a) a launch with isJITEnabled == false and a
                    //       pairing file installed. Every Helper got a
                    //       real boundedEnableJIT attach and
                    //       ReportJITStatusForChild(pid, true), while
                    //       childProcessDidStart's guard 2 correctly
                    //       reported FALSE for the same pid. The two paths
                    //       handed one child opposite answers.
                    //
                    //   (b) after activateJITLessMode() has latched and run
                    //       clearAllAttached() + detachAllJITSessions(),
                    //       the next Helper request attached again and
                    //       undid the mode - and clearAllAttached() had
                    //       just removed the isAttached dedup below that
                    //       would have suppressed it.
                    //
                    // Replies "failed:", never "success". The skipReason
                    // branch further down replies "success", and its own
                    // comment explains why that must not be used for a
                    // case like this one: telling a child JIT is ready
                    // with nothing attached behind it leaves it enabling
                    // the backend with no W^X mediation, and the first
                    // write into the executable region takes a SIGBUS.
                    //
                    // The flags are read the way the rest of this file
                    // reads them - plainly, no lock. This block runs on
                    // attachQueue (asserted above), which is where
                    // recoverStoppedChildrenAfterForegroundHang reads the
                    // same pair.
                    let jitLessLatched = self.isJITLessModeActive
                    let failureLatched = self.hasHandledFailure
                    let jitEnabled = self.usePtraceJIT() || Prefs.JITSettings.isJITEnabled
                    if jitLessLatched || failureLatched || !jitEnabled {
                        logger(String(format: "helperGate: pid %d refused - JIT is not available on this launch (jitLess=%@, latchedFailure=%@, enabled=%@)",
                                      pid,
                                      jitLessLatched ? "YES" : "NO",
                                      failureLatched ? "YES" : "NO",
                                      jitEnabled ? "YES" : "NO"))
                        let refusedResultFileURL = containerURL.appendingPathComponent("\(Self.jitAttachResultFilePrefix)\(pid)_\(token)")
                        try? "failed:JIT is not available on this launch"
                            .write(to: refusedResultFileURL, atomically: true, encoding: .utf8)
                        CFNotificationCenterPostNotification(
                            CFNotificationCenterGetDarwinNotifyCenter(),
                            CFNotificationName(rawValue: Self.jitAttachReplyNotificationName(forToken: token)),
                            nil,
                            nil,
                            true
                        )
                        continue
                    }

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

                        // ADDED - fix_attach_gates_and_helper_guards.py,
                        // the same re-check reattachOrphanedProcesses grew.
                        //
                        // isApplicationActive was read on attachQueue well
                        // above, before markAttached and before this
                        // dispatch. attachSlots.wait() is UNBOUNDED, so
                        // that answer can be seconds old by the time this
                        // pid reaches the front - three slots at ~1.2s each
                        // against the 15 children a cold launch spawns
                        // (AttachLedger.swift:77-84) puts the tail around
                        // five seconds out, and the window that killed the
                        // app on 2026-08-12 was 1.04s wide.
                        //
                        // Starting the vAttach is the irreversible step: it
                        // stops the target for ~1013ms, and a stopped
                        // NSExtension cannot answer the synchronous XPC iOS
                        // sends on the next lifecycle transition - the
                        // capture quoted a few lines above, at the
                        // isApplicationActive check, is exactly that.
                        //
                        // AFTER the defer, deliberately: returning from
                        // here still signals the slot and still clears the
                        // in-flight mark.
                        //
                        // Unlike the two native sites this one has a
                        // blocked caller, so it answers rather than just
                        // returning: the Helper is inside
                        // requestJITAttachFromMainApp's 20-second wait
                        // (browser/Helper/main.m) and would otherwise sit
                        // out the whole budget for a reply that is never
                        // coming. "failed:" and not "success" - main.m
                        // turns any non-"success" body into NO plus an
                        // error string, which is the fallback this
                        // codebase uses everywhere.
                        //
                        // No preflight watchdog to cancel here: the Helper
                        // path never schedules one.
                        guard Self.isApplicationActiveFromAnyQueue else {
                            logger(String(format: "attachGate: pid %d abandoned at the slot - app went inactive while the Helper attach queued", pid))
                            let deferredResultFileURL = containerURL.appendingPathComponent("\(Self.jitAttachResultFilePrefix)\(pid)_\(token)")
                            try? "failed:deferred - app went inactive while this attach waited for a slot"
                                .write(to: deferredResultFileURL, atomically: true, encoding: .utf8)
                            CFNotificationCenterPostNotification(
                                CFNotificationCenterGetDarwinNotifyCenter(),
                                CFNotificationName(rawValue: Self.jitAttachReplyNotificationName(forToken: token)),
                                nil,
                                nil,
                                true
                            )
                            return
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
    
    fileprivate func pruneStaleHelperFiles(contents: [String], containerURL: URL, fileManager: FileManager) {
        let helperFiles = contents.filter {
            $0.hasPrefix(Self.jitAttachRequestFilePrefix) ||
                $0.hasPrefix(Self.jitAttachResultFilePrefix)
        }
        guard !helperFiles.isEmpty else {
            return
        }

        let now = Date()
        for fileName in helperFiles {
            let isRequest = fileName.hasPrefix(Self.jitAttachRequestFilePrefix)
            let fileURL = containerURL.appendingPathComponent(fileName)
            var requestPID: Int32?

            if isRequest {
                let remainder = fileName.dropFirst(Self.jitAttachRequestFilePrefix.count)
                guard let underscoreIndex = remainder.firstIndex(of: "_") else {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }

                let pidText = remainder[remainder.startIndex..<underscoreIndex]
                let token = String(remainder[remainder.index(after: underscoreIndex)...])
                guard let pid = Int32(pidText), pid > 0, UUID(uuidString: token) != nil else {
                    try? fileManager.removeItem(at: fileURL)
                    continue
                }
                requestPID = pid
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let modificationDate = attributes[.modificationDate] as? Date
            else {
                continue
            }

            let staleAge = isRequest
                ? Self.jitAttachRequestStaleAgeSeconds
                : Self.jitAttachResultStaleAgeSeconds
            if now.timeIntervalSince(modificationDate) > staleAge {
                try? fileManager.removeItem(at: fileURL)
                if let requestPID {
                    helperTypeWaitStart.removeValue(forKey: requestPID)
                }
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

        // Same guard as attachToProcess - see
        // fix_no_jit_promise_during_teardown.py. This path reports for
        // the Helper-claimed pids, and the 2026-08-13 capture has it
        // making the same doomed promise:
        //
        //   19:43:20.458  attachToHelperProcess: reporting JIT status to
        //                 child pid 16731 (success=YES)
        //   19:43:20.458  runDebugService: (pid 16731) attach landed after
        //                 teardown - joining it instead of re-arming
        //   19:43:20.470  detach requested and completed at iteration 1
        //
        // The Helper's own result file still reports the attach's real
        // outcome; only what the CHILD is told about JIT changes, which
        // is the thing that decides whether it enables the backend.
        let reportable = success && !JITEnabler.isDebuggerTeardownRequested()
        if success && !reportable {
            logger(String(format: "attachToHelperProcess: pid %d attach succeeded but a teardown is standing - reporting FALSE so it does not enable JIT it cannot use", pid))
        }
        logger(String(format: "attachToHelperProcess: reporting JIT status to child pid %d (success=%@)", pid, reportable ? "YES" : "NO"))
        ReportJITStatusForChild(pid, reportable, newJITRuntimeInfo())
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
