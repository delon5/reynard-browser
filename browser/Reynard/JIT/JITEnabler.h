//
//  JITEnabler.h
//  Reynard
//
//  Created by Minh Ton on 11/3/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface JITEnabler : NSObject

@property(class, nonatomic, readonly) JITEnabler *shared;

- (BOOL)enableJITForPID:(int32_t)pid
          hasTXMSupport:(BOOL)hasTXMSupport
                  error:(NSError *_Nullable *_Nullable)error

NS_SWIFT_NAME(enableJIT(forPID:hasTXMSupport:));

- (void)detachAllJITSessions NS_SWIFT_NAME(detachAllJITSessions());

// Whether ANY process - main app or Helper - currently has a
// genuinely active, running JIT debug session. A live status, not a
// hardware/OS capability check - matches DolphiniOS's own "JIT
// Acquisition" row, confirmed against their own blog: they check
// whether JIT is currently enabled each time before launching a game,
// not a cached or static capability.
+ (BOOL)hasActiveJITSession NS_SWIFT_NAME(hasActiveJITSession());

/// Asks every active debug session to detach, so content processes are
/// not left stopped by the debugger across suspension - a state in
/// which they cannot answer the synchronous XPC iOS sends every
/// extension on foreground, which the watchdog then kills the app for.
///
/// Wraps the C function of the same name in JITSupport.h, which Swift
/// cannot see directly because that header is not in the bridging
/// header. See fix_expose_detach_to_swift.py.
+ (void)requestDetachForAllDebugSessions NS_SWIFT_NAME(requestDetachForAllDebugSessions());

/// Lifts the sticky teardown requestDetachForAllDebugSessions sets, so
/// attaches are wanted again. Must run when the app becomes active, or
/// runDebugService keeps refusing to re-arm and JIT stays off for the
/// rest of the launch.
///
/// Wraps the C function of the same name in JITSupport.h, which Swift
/// cannot see directly.
+ (void)clearDebuggerTeardownRequest NS_SWIFT_NAME(clearDebuggerTeardownRequest());

/// Whether a background teardown is standing, so the attach paths can
/// avoid promising JIT they are about to withdraw. See
/// fix_no_jit_promise_during_teardown.py.
+ (BOOL)isDebuggerTeardownRequested NS_SWIFT_NAME(isDebuggerTeardownRequested());

/// Cancels in-flight debug proxy calls without tearing sessions down.
/// Wraps the C function in JITSupport.h, which Swift cannot see
/// directly - that header is not in the bridging header.
+ (void)cancelAllDebugSessionCalls NS_SWIFT_NAME(cancelAllDebugSessionCalls());

/// Sends the interrupt byte to every live debug session, so a loop
/// blocked in its continue can act. Wraps the C function in
/// JITSupport.h, which Swift cannot see directly.
+ (void)interruptLiveDebugSessions NS_SWIFT_NAME(interruptLiveDebugSessions());

/// Logs every debug loop and how long since it last ran, so a hang can
/// name the process the main thread is waiting on.
+ (void)dumpDebugLoopState NS_SWIFT_NAME(dumpDebugLoopState());

/// The same dump, labelled - so a background-time dump is not mistaken
/// for a hang-time one.
+ (void)dumpDebugLoopStateLabelled:(NSString *)label NS_SWIFT_NAME(dumpDebugLoopState(labelled:));

/// Records a child for the heartbeat dump. See
/// fix_child_heartbeat_instrument.py.
+ (void)recordChildForHeartbeat:(int32_t)pid type:(NSString *)processType NS_SWIFT_NAME(recordChildForHeartbeat(_:type:));

/// Dumps every live child's two heartbeat ages. Safe from any thread, and
/// deliberately independent of the attach queue - at hang time that queue
/// may be the thing that is blocked.
+ (void)dumpChildHeartbeatsLabelled:(NSString *)label NS_SWIFT_NAME(dumpChildHeartbeats(labelled:));

/// Kills any child a supervision session has left stopped. Only for the
/// hang escalation: a stopped child cannot answer the synchronous XPC
/// the foreground handshake sends, and the app is killed for the wait.
+ (int)killStoppedChildren NS_SWIFT_NAME(killStoppedChildren());

/// Tells content processes whether trapping into the debugger is safe.
///
/// Cleared before a suspension rather than after one has gone wrong: a
/// process that traps while the tunnel is dying stops with nothing able
/// to continue it, and cannot then answer the synchronous XPC iOS sends
/// on the next lifecycle transition. See
/// fix_stop_trapping_on_background.py.
+ (void)setDebuggerListening:(BOOL)listening NS_SWIFT_NAME(setDebuggerListening(_:));

/// Sends the GDB interrupt byte to every in-flight attach. Gated on
/// the Experimental toggle by the caller.
+ (void)interruptAttachingDebugSessions NS_SWIFT_NAME(interruptAttachingDebugSessions());

/// Whether this pid still has a live debug loop. Wraps the C function
/// in JITSupport.h, which Swift cannot see directly.
+ (BOOL)hasActiveDebugSessionForPID:(int32_t)pid NS_SWIFT_NAME(hasActiveDebugSession(forPID:));

/// How many runDebugService loops are registered right now. Wraps the C
/// function in JITSupport.h, which Swift cannot see directly.
///
/// The fourth gate on closeSharedTunnel below: every live loop holds a
/// debug_proxy opened off the shared adapter, and freeing that adapter
/// while a loop is inside an FFI call on it is the use-after-free the
/// other three gates exist to prevent. See
/// fix_tunnel_close_waits_for_debug_loops.py.
+ (NSUInteger)liveDebugSessionCount NS_SWIFT_NAME(liveDebugSessionCount());

/// What the kernel says this child is doing - RUN, SLEEP, STOP, ZOMB, or
/// why it could not be read. See fix_report_child_run_state.py.
+ (NSString *)runStateForPID:(int32_t)pid NS_SWIFT_NAME(runState(forPID:));

// Clears the cached DeviceProvider (getProviderForPID's own
// sharedProvider) so the next call is forced to establish a fresh
// connection instead of reusing one that may be poisoned by a timed-
// out attempt. Deliberately does NOT free the old provider's memory -
// see fix_invalidate_provider_on_timeout.py's docstring for the full,
// important safety reasoning (a still-orphaned background call may
// still be using it).
- (void)invalidateSharedProviderAfterTimeout NS_SWIFT_NAME(invalidateSharedProviderAfterTimeout());

/// Closes the shared tunnel and FREES its adapter, which is what
/// actually releases the socket to the pairing endpoint.
///
/// ADDED - see fix_foreground_scoped_jit_transport.py. The invalidate
/// methods above deliberately never free, to avoid a use-after-free
/// against an orphaned FFI call. That is correct on a failure path,
/// where we cannot know what is still running - but it means the socket
/// is never released, so no rebuild has ever succeeded in a running
/// process. This is the deliberate counterpart, called only from the
/// background teardown once the caller has established that nothing is
/// in flight.
- (void)closeSharedTunnel NS_SWIFT_NAME(closeSharedTunnel());

/// Builds the shared tunnel if there is not one, so a child does not
/// have to discover its absence by failing. See the same docstring.
///
/// The build happens asynchronously, and returns without building at
/// all if setApplicationForeground: below says the app has left the
/// foreground in the meantime. See fix_prewarm_checks_foreground.py.
- (void)prewarmSharedTunnel NS_SWIFT_NAME(prewarmSharedTunnel());

/// The recovery counterpart to prewarmSharedTunnel: attempts the same
/// build (or reuse) of the shared tunnel, and reports whether a
/// provider is available. The heavy work happens off the calling
/// thread; the completion is delivered on the main queue. A probe
/// queued while the app is leaving the foreground reports NO rather
/// than skipping silently (the check runs when the block starts), so
/// a probe that never ran can never un-latch anything. Added for
/// JITController's JIT-less recovery - see
/// fix_jitless_recovers_when_tunnel_returns.py.
- (void)probeSharedTunnelWithCompletion:(void (^)(BOOL available))completion NS_SWIFT_NAME(probeSharedTunnel(completion:));

/// Mirrors JITController's own application-active flag into this file,
/// which cannot see it: JITEnabler.m compiles into the Reynard Helper
/// target as well, and Reynard-Swift.h is the app target's private
/// bridging header.
///
/// Call this from every write of that flag and from nowhere else - it
/// is a copy of a decision made in Swift, not an independent judgement
/// about the application state. prewarmSharedTunnel is the only
/// reader. See fix_prewarm_checks_foreground.py.
+ (void)setApplicationForeground:(BOOL)foreground NS_SWIFT_NAME(setApplicationForeground(_:));

// Timestamp of when the most recent vAttach FFI call started, if it
// might still genuinely be running - nil if none is currently thought
// to be in flight. Set immediately before the call, cleared
// immediately after it returns via the normal, synchronous code path
// (success or failure) - deliberately NOT cleared by
// boundedEnableJIT's own 20s timeout, since the call may genuinely
// still be running past that point. See
// fix_guard_concurrent_vattach.py's docstring for the full reasoning.
+ (nullable NSDate *)vAttachInFlightSince NS_SWIFT_NAME(vAttachInFlightSince());

@end

NS_ASSUME_NONNULL_END
