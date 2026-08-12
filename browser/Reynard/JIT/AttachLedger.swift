//
//  AttachLedger.swift
//  Reynard
//

import Foundation

/// Owns the attach bookkeeping that used to be spread across
/// JITController's stored properties (attachedPIDs, rejectedPIDs,
/// pendingAttachPIDs, isApplicationActive), whose thread-safety rested
/// on the comment-level convention "only ever touched on attachQueue".
/// Here the state is private to this type and every accessor asserts
/// the confining queue, so a future call site on the wrong queue trips
/// dispatchPrecondition in a debug build instead of corrupting a Set -
/// the exact failure mode the preflight-watchdog dictionary had before
/// it grew its lock.
///
/// Deliberately a queue-confined class rather than an actor: the attach
/// machinery around it blocks (semaphore slots, a bounded wait on a
/// blocking FFI call), which mixes badly with actor isolation. The
/// owning queue stays JITController's serial attachQueue; only the
/// state moved.
final class AttachLedger {
    private let queue: DispatchQueue

    /// PIDs an attach has been started for. Deliberately never removed
    /// on detach or death - the dedup checks in childProcessDidStart
    /// and the Helper request loop treat "ever claimed" as the guard,
    /// and reattachOrphanedProcesses relies on the full history to
    /// tell "cleared" apart from "died".
    private var attachedPIDs: Set<Int32> = []

    /// Processes shouldAttach(to:) rejected by type - socket, gpu, rdd
    /// and so on, which never execute JavaScript. Remembered so the
    /// Helper path does not wastefully attach them a second later. See
    /// fix_dedupe_attach_paths.py.
    private var rejectedPIDs: Set<Int32> = []

    /// Type of every child ever announced, attached or not.
    ///
    /// socket, gpu and rdd children are rejected by type and never
    /// attached, so they appear in no loopState dump and no hangDump -
    /// they are invisible to every JIT-side instrument. They are equally
    /// valid candidates for the extension that fails to answer the
    /// foreground handshake, and nothing would ever have shown it.
    ///
    /// Pruned of dead pids at each census dump - see pruneDeadChildren.
    private var childTypes: [Int32: String] = [:]
    /// Total announcements this launch, surviving the pruning, so the
    /// census dump still reports how many children were ever seen.
    private var announcedChildCount = 0

    /// PIDs that arrived while the app was not active, held for the
    /// drain on return. No attach is started while inactive: vAttach
    /// stops its target, and a stopped extension cannot answer the
    /// synchronous XPC iOS sends on a lifecycle transition. See
    /// fix_defer_attaches_while_inactive.py.
    private var pendingAttachPIDs: Set<Int32> = []
    private var applicationActive = true

    /// PIDs whose attach has been dispatched but has not finished -
    /// queued behind the attach slots, or running right now.
    ///
    /// Unlike attachedPIDs this IS removed when the attach completes,
    /// because it answers a different question: not "was an attach ever
    /// started for this pid" but "is one outstanding for it at this
    /// instant".
    ///
    /// reattachOrphanedProcesses needs that distinction. Its orphan
    /// test is `!hasActiveDebugSession(forPID:)`, and a pid only enters
    /// that set once its attach COMPLETES - but markAttached runs
    /// before the attach is dispatched, so a pid waiting in the queue
    /// is simultaneously "attached", alive, and sessionless. It was
    /// therefore declared orphaned and given a second, duplicate
    /// attach.
    ///
    /// A device capture caught the whole chain: at cold launch 15
    /// children spawn, attaches serialize three at a time at ~1.2s
    /// each, and the reattach pass fires 3s in - "13 attached, 13
    /// alive, 10 orphaned". The partition was exact: every child whose
    /// attach had completed stayed healthy, every child still in the
    /// queue was doomed. The duplicate vAttach landed on a process the
    /// first attach had already stopped, the second connection died on
    /// its next command ("transport already dead"), the detach was
    /// skipped by design - and the child was left STOPPED with nobody
    /// to continue it. Nine such children then could not answer the
    /// synchronous XPC ExtensionKit sends on the next foreground, and
    /// FrontBoard killed the app with 0x8BADF00D.
    ///
    /// boundedEnableJIT's per-pid in-flight check could not catch it:
    /// the duplicate was not concurrent with the original, it was
    /// queued behind it.
    private var attachInFlightPIDs: Set<Int32> = []

    init(confinedTo queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: - Application activity

    var isApplicationActive: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return applicationActive
    }

    func markApplicationActive() {
        dispatchPrecondition(condition: .onQueue(queue))
        applicationActive = true
    }

    func markApplicationInactive() {
        dispatchPrecondition(condition: .onQueue(queue))
        applicationActive = false
    }

    // MARK: - Deferred attaches

    /// Holds a pid for the drain on return to active. Returns how many
    /// are now pending, for the caller's logging.
    func deferAttach(_ pid: Int32) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingAttachPIDs.insert(pid)
        return pendingAttachPIDs.count
    }

    func drainDeferredPIDs() -> Set<Int32> {
        dispatchPrecondition(condition: .onQueue(queue))
        let deferred = pendingAttachPIDs
        pendingAttachPIDs.removeAll()
        return deferred
    }

    // MARK: - Attach bookkeeping

    func isAttached(_ pid: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return attachedPIDs.contains(pid)
    }

    func markAttached(_ pid: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        attachedPIDs.insert(pid)
    }

    func clearAllAttached() {
        dispatchPrecondition(condition: .onQueue(queue))
        attachedPIDs.removeAll()
    }

    func attachedSnapshot() -> Set<Int32> {
        dispatchPrecondition(condition: .onQueue(queue))
        return attachedPIDs
    }

    // MARK: - Outstanding attaches

    /// Called on the confining queue immediately before an attach is
    /// dispatched to the work queue, and cleared once it returns.
    func markAttachInFlight(_ pid: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        attachInFlightPIDs.insert(pid)
    }

    func clearAttachInFlight(_ pid: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        attachInFlightPIDs.remove(pid)
    }

    func isAttachInFlight(_ pid: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return attachInFlightPIDs.contains(pid)
    }

    func attachInFlightCount() -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return attachInFlightPIDs.count
    }

    // MARK: - Rejections

    func markRejected(_ pid: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        rejectedPIDs.insert(pid)
    }

    func noteChild(_ pid: Int32, type: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if childTypes[pid] == nil {
            announcedChildCount += 1
        }
        childTypes[pid] = type
    }

    /// Drops children that are no longer alive. childTypes is purely
    /// diagnostic - unlike attachedPIDs and rejectedPIDs it feeds no
    /// attach decision - and pids recycle anyway, so an evicted child
    /// that somehow returns is simply re-announced. Without this the
    /// map grew by one entry per child process for the life of the
    /// app: content processes churn on every tab sleep and recovery,
    /// so that is a real, if slow, leak. The census dump already
    /// showed only live children, so pruning costs it nothing.
    /// CHANGED - see fix_prune_attach_ledger.py's docstring. Now prunes
    /// attachedPIDs as well, and reports how many went.
    ///
    /// attachedPIDs is what reattachOrphanedProcesses walks, and it was
    /// the one collection here still growing for the life of the app: 4
    /// entries at 18:37 and 29 at 19:12 against 5 live children, in the
    /// capture whose final fan-out stopped three extensions and got the
    /// app killed.
    ///
    /// Only ESRCH pids go. isAlive is JITController.pidIsAlive, which
    /// reads EPERM as alive because a content process is an app
    /// extension in another coalition and cannot be signalled, so
    /// nothing live is ever dropped. A pid that IS gone can only return
    /// by number reuse, and a reused number is a different process that
    /// should get its own attach - which is the same reasoning the
    /// childTypes prune below already rests on.
    ///
    /// announcedChildCount is untouched, so the lifetime total the
    /// census reports still means what it did.
    func pruneDeadChildren(alive isAlive: (Int32) -> Bool) -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        childTypes = childTypes.filter { isAlive($0.key) }

        let before = attachedPIDs.count
        attachedPIDs = attachedPIDs.filter { isAlive($0) }
        return before - attachedPIDs.count
    }

    /// Every child ever announced this launch, including pruned ones.
    func announcedChildTotal() -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return announcedChildCount
    }

    /// Every announced child, with its type and whether the JIT layer
    /// ever attached it. Ordered by pid so successive dumps diff.
    func childCensus() -> [(pid: Int32, type: String, attached: Bool)] {
        dispatchPrecondition(condition: .onQueue(queue))
        return childTypes.keys.sorted().map {
            (pid: $0, type: childTypes[$0] ?? "?", attached: attachedPIDs.contains($0))
        }
    }

    func isRejected(_ pid: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return rejectedPIDs.contains(pid)
    }

    /// The type this child was announced with, if it was ever announced.
    ///
    /// ADDED - see fix_reattach_respects_process_type.py's docstring.
    /// noteChild records this for EVERY child, before any decision about
    /// attaching, precisely so socket/gpu/rdd/utility are visible - but
    /// until now nothing consulted it outside the census dump, so the
    /// Helper path and the re-attach pass both attached non-tab children
    /// that shouldAttach would have rejected on sight.
    ///
    /// nil means never announced, which is not the same as "not
    /// attachable" and is deliberately left to the caller to decide.
    func knownType(_ pid: Int32) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        return childTypes[pid]
    }
}
