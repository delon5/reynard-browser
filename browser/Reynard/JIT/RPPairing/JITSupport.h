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
