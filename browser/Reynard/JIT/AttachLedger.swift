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

    /// PIDs that arrived while the app was not active, held for the
    /// drain on return. No attach is started while inactive: vAttach
    /// stops its target, and a stopped extension cannot answer the
    /// synchronous XPC iOS sends on a lifecycle transition. See
    /// fix_defer_attaches_while_inactive.py.
    private var pendingAttachPIDs: Set<Int32> = []
    private var applicationActive = true

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

    // MARK: - Rejections

    func markRejected(_ pid: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        rejectedPIDs.insert(pid)
    }

    func isRejected(_ pid: Int32) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return rejectedPIDs.contains(pid)
    }
}
