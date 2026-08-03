//
//  JITSupport.h
//  Reynard
//
//  Created by Minh Ton on 11/3/2026.
//

@import Foundation;

#import "IdeviceFFI.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct DeviceProvider DeviceProvider;

typedef struct {
    AdapterHandle *adapter;
    RsdHandshakeHandle *handshake;
    RemoteServerHandle *remoteServer;
    DebugProxyHandle *debugProxy;
} DebugSession;

dispatch_queue_t debugServiceQueue(void);
dispatch_queue_t debugSessionStateQueue(void);
NSMutableSet<NSNumber *> *activeDebugSessionPIDs(void);
NSMutableSet<NSNumber *> *detachRequestedDebugSessionPIDs(void);

/// Marks every active debug session for detach, so runDebugService
/// drains them on its next iteration rather than leaving content
/// processes stopped by the debugger across suspension - a state that
/// makes them unable to answer the synchronous XPC iOS sends on
/// foreground, which the watchdog then kills the app for. Call when
/// entering the background. See
/// fix_detach_debug_sessions_on_background.py.
void requestDetachForAllDebugSessions(void);

/// Logs every registered debug loop with the age of its last iteration.
/// Called when the hang watchdog fires, to name which process stopped
/// answering. See fix_dump_loop_state_on_hang.py.
void dumpDebugLoopState(void);

/// The same dump under a caller-supplied label, so the hang-time and
/// background-time call sites can be told apart in the log. See
/// fix_dump_loops_at_background.py.
void dumpDebugLoopStateLabelled(const char *label);

/// Records whether a loop is blocked in its continue - the state that
/// tells a healthy loop from one whose target is stopped. See
/// fix_track_loop_waiting_state.py.
void recordDebugLoopWaiting(int32_t pid, BOOL waiting);

/// Tells content processes whether a debugger is listening, so they
/// know whether trapping into one is safe. See
/// fix_stop_trapping_on_background.py.
void setDebuggerListeningState(uint64_t listening);

/// Cancels any in-flight debug proxy call, releasing threads parked in
/// a read, WITHOUT tearing sessions down. Call at willResignActive -
/// see fix_split_cancel_from_detach.py.
void cancelAllDebugSessionCalls(void);

/// Registers a proxy whose vAttach is still in flight, so it can be
/// interrupted if the app resigns active mid-attach. See
/// fix_interrupt_attaching_sessions.py.
void registerAttachingDebugSessionProxy(int32_t pid, DebugProxyHandle *proxy);
void unregisterAttachingDebugSessionProxy(int32_t pid);

/// Sends the GDB interrupt byte (0x03) to every in-flight attach. A
/// target stopped by vAttach cannot answer the synchronous XPC iOS
/// sends every extension on a lifecycle transition, and the watchdog
/// kills the app for it.
void interruptAttachingDebugSessions(void);

/// Whether this pid still has a live runDebugService loop. Used to
/// find processes that lost their session during suspension - see
/// fix_reattach_orphaned_sessions_on_foreground.py.
BOOL hasActiveDebugSessionForPID(int32_t pid);

DeviceProvider *_Nullable createDeviceProvider(
                                               NSString *pairingFilePath, NSString *targetAddress,
                                               NSError *_Nullable *_Nullable error);
BOOL ensureDDIMounted(DeviceProvider *provider,
                      NSError *_Nullable *_Nullable error);

BOOL sendDebugCommand(DebugProxyHandle *debugProxy, NSString *commandString,
                      NSString *_Nullable *_Nullable responseOut,
                      NSError *_Nullable *_Nullable error);
BOOL configureNoAckMode(DebugProxyHandle *debugProxy,
                        NSString *_Nullable *_Nullable responseOut,
                        NSError *_Nullable *_Nullable error);
BOOL connectDebugSession(DeviceProvider *provider, DebugSession *session,
                         NSString *targetAddress, int32_t pid,
                         NSError *_Nullable *_Nullable error);
BOOL detachDebuggerSession(DebugProxyHandle *debugProxy, int32_t pid);

void runDebugService(int32_t pid, DebugSession *session);

void registerJITEndpointForPID(int32_t pid, NSString *targetAddress,
                               uint16_t port);
void unregisterJITEndpointForPID(int32_t pid);
void resetJITEndpointMonitor(void);

// Whether any process - main app OR Helper, not just the calling one -
// currently has a genuinely active JIT debug session. Backed by a
// small shared file in the App Group container, not process-local
// state, since activeDebugSessionPIDs() above is in-memory and
// invisible across the process boundary between the main app (where
// Settings lives) and the Helper (where self-enable runs).
BOOL hasAnyActiveJITSessionAcrossProcesses(void);

/// Kernel ground truth for whether a process carries CS_DEBUGGED, the
/// hard precondition for JIT. Mirrors DolphiniOS's
/// checkIfProcessIsDebugged. Takes a pid rather than checking self,
/// because Reynard's main app is the debugger and never attaches to
/// itself - the Helper content processes are the ones that matter.
BOOL processIsDebugged(int32_t pid);

/// Whether any content process has confirmed to the kernel that it
/// carries CS_DEBUGGED, reported by the debuggee itself into the App
/// Group. Unlike hasAnyActiveJITSessionAcrossProcesses this is kernel
/// ground truth rather than the main app's own bookkeeping - see
/// fix_debuggee_self_reports_cs_debugged.py for why the check cannot
/// be performed from the main app.
BOOL hasAnyDebuggedJITSessionAcrossProcesses(void);

void freeDebugSession(DebugSession *session);
void freeDeviceProvider(DeviceProvider *_Nullable provider);

NS_ASSUME_NONNULL_END
