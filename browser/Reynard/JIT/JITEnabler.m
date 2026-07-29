//
//  JITEnabler.m
//  Reynard
//
//  Created by Minh Ton on 11/3/26.
//

#import "JITEnabler.h"
#import "JITErrors.h"
#import "JITSupport.h"
#import "JITUtils.h"
#import "Utils.h"
#include <sys/stat.h>
#include <errno.h>

@interface JITEnabler ()

@property(nonatomic, assign) DeviceProvider *sharedProvider;
@property(nonatomic, strong) dispatch_queue_t providerQueue;
@property(nonatomic, assign) BOOL didEnsureDDIMounted;

- (DeviceProvider *)getProviderForPID:(int32_t)pid error:(NSError **)error;

@end

@implementation JITEnabler

static dispatch_queue_t vAttachStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITEnabler.VAttachStateQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDate *sVAttachInFlightSince = nil;

+ (void)markVAttachStarted {
    dispatch_sync(vAttachStateQueue(), ^{
        sVAttachInFlightSince = [NSDate date];
    });
}

+ (void)markVAttachFinished {
    dispatch_sync(vAttachStateQueue(), ^{
        sVAttachInFlightSince = nil;
    });
}

+ (nullable NSDate *)vAttachInFlightSince {
    __block NSDate *result = nil;
    dispatch_sync(vAttachStateQueue(), ^{
        result = sVAttachInFlightSince;
    });
    return result;
}

+ (JITEnabler *)shared {
    static JITEnabler *sharedEnabler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // DIAGNOSTIC - see
        // fix_enable_idevice_native_logging.py's docstring. Purely
        // additive: enables the underlying idevice Rust library's own
        // internal logging, which this codebase has never once turned
        // on - confirmed by grepping the entire codebase for
        // idevice_init_logger before adding this. StikDebug's own
        // source calls this exact function during its own
        // initialization; this codebase simply never has. Trace
        // (maximum verbosity) for the file output specifically, since
        // the goal here is maximum diagnostic detail into what the
        // library itself is doing internally during a confirmed hang -
        // detail no amount of instrumentation wrapped around the
        // outside of an FFI call can ever see.
        NSArray<NSURL *> *documentDirs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        NSURL *logURL = [documentDirs.firstObject URLByAppendingPathComponent:@"idevice_native_log.txt"];
        if (logURL) {
            const char *logPath = logURL.path.UTF8String;
            enum IdeviceLoggerError loggerResult = idevice_init_logger(IdeviceLogInfo, IdeviceLogTrace, (char *)logPath);
            logger([NSString stringWithFormat:@"idevice_init_logger result: %d, writing to: %@", loggerResult, logURL.path]);
        }
        sharedEnabler = [[self alloc] init];
    });
    return sharedEnabler;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sharedProvider = NULL;
        _providerQueue = dispatch_queue_create("com.minh-ton.Reynard.JITEnabler.ProviderQueue", DISPATCH_QUEUE_SERIAL);
        _didEnsureDDIMounted = NO;
    }
    return self;
}

- (BOOL)enableJITForPID:(int32_t)pid hasTXMSupport:(BOOL)hasTXMSupport error:(NSError **)error {
    // TrollStore or jailbroken devices
    if (getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *helperPath = [bundle.bundlePath stringByAppendingPathComponent:@"ptrace_jit"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
            NSString *resourceCandidate = [bundle.resourcePath stringByAppendingPathComponent:@"ptrace_jit"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:resourceCandidate]) helperPath = resourceCandidate;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
            NSURL *auxURL = [bundle URLForAuxiliaryExecutable:@"ptrace_jit"];
            if (auxURL.path.length > 0) helperPath = auxURL.path;
        }
        
        int result = spawnRoot(helperPath, @[[NSString stringWithFormat:@"%d", pid]]);
        logger([NSString stringWithFormat:@"ptrace_jit result %d", result]);
        
        if (result != 0 && result != EACCES && result != ENOENT && result != ENOEXEC && result != 126 && result != 127) {
            // keep existing behavior for non-permission failures
        } else if (result == EACCES || result == ENOENT || result == ENOEXEC || result == 126 || result == 127) {
            // Was ReynardDirectoriesBridge.jitTemporaryPath — that
            // required Reynard-Swift.h, the main app target's own
            // private bridging header, unavailable now that this file
            // also compiles into the Reynard Helper target (added
            // tonight, for the Helper's own RPPairing JIT
            // self-enablement). This entire branch only runs on
            // TrollStore/jailbroken devices, a case the Helper's own
            // new call path deliberately never reaches at all — but
            // Objective-C still needs this to resolve at compile time
            // regardless of whether it's ever actually reached at
            // runtime for a given caller. NSTemporaryDirectory() is a
            // standard, always-available equivalent for this specific,
            // rare-edge-case fallback's actual need (a writable temp
            // location to copy a binary to).
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"jit_temp_ptrace"];
            NSError *copyError = nil;
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            if ([[NSFileManager defaultManager] copyItemAtPath:helperPath toPath:tempPath error:&copyError]) {
                chmod(tempPath.UTF8String, 0755);
                if ([[NSFileManager defaultManager] isExecutableFileAtPath:tempPath]) {
                    logger([NSString stringWithFormat:@"Retrying ptrace_jit from temp path %@", tempPath]);
                    result = spawnRoot(tempPath, @[[NSString stringWithFormat:@"%d", pid]]);
                }
            } else {
                logger([NSString stringWithFormat:@"Failed to copy ptrace_jit to temp path: %@", copyError.localizedDescription ?: @"unknown"]);
            }
        }
        if (result >= 128) {
            if (error) *error = MakeError(TSPtraceHelperTerminated);
            return NO;
        }
        
        if (result != 0) {
            if (error) *error = MakeError(TSPtraceHelperAttachFailed);
            return NO;
        }
        
        return YES;
    }
    
    if (@available(iOS 17.4, *)) {
        // For iOS 17.4 and later
        // Thanks StikDebug!
        // https://github.com/StephenDev0/StikDebug
        
        DeviceProvider *provider = [self getProviderForPID:pid error:error];
        if (!provider) return NO;
        
        DebugSession session = {0};
        
        if (!connectDebugSession(provider, &session, @"10.7.0.1", pid, error)) return NO;
        
        // REMOVED process_control_new / process_control_disable_memory_limit /
        // process_control_free entirely - see
        // fix_remove_process_control_new.py's docstring for the full
        // reasoning. This was the exact, sole hang point in every single
        // test tonight, 100% of the time, across every architectural fix
        // built around it (delegation, bounded wait, provider
        // invalidation) - none of which could ever have helped, since the
        // call itself never returned regardless of how it was scheduled
        // or how many times a fresh connection was given to it.
        //
        // Confirmed unnecessary by directly reading all four of
        // StephenDev0/StikDebug's own bundled, proven-working JIT scripts
        // (universal.js, legacy.js, Geode.js, maciOS.js) - every one
        // attaches via vAttach on the debug proxy directly and never
        // touches process_control_new, ProcessControlClient, or DVT/
        // Instruments in any form. Confirmed safe to remove specifically
        // in THIS codebase too, not just by analogy: processControl was
        // used for exactly one thing - process_control_disable_memory_limit
        // - then freed immediately after, before configureNoAckMode or
        // the vAttach command ever ran; both of those already operated
        // directly on session.debugProxy, with zero dependency on
        // processControl at all. Even this code's own error handling
        // already treated disable_memory_limit's own failure as
        // non-fatal - "non-fatal, continuing" - meaning this codebase
        // already considered it optional, not required, before tonight.
        //
        // Trade-off, honestly stated: this drops the memory-limit-disable
        // behavior entirely (which prevents the OS from killing a target
        // process under memory pressure) rather than finding a working
        // replacement for it. Given every attempt to reach this line
        // tonight has hung indefinitely, restoring a genuinely working
        // JIT-enable path takes priority over preserving a best-effort,
        // already-non-fatal memory optimization.
        
        NSError *commandError = nil;
        
        // REMOVED configureNoAckMode entirely - see
        // fix_remove_noackmode.py's docstring for the full reasoning.
        // After removing the heartbeat mechanism, this became the new,
        // single, consistent hang point in every attempt - replacing
        // the earlier, scattered pattern across different steps.
        // QStartNoAckMode is a standard GDB remote protocol
        // optimization (disables the ack handshake to reduce
        // round-trip overhead) - optional by design, not required for
        // the protocol to function. None of StikDebug's four proven-
        // working reference scripts ever send it; all of them attach
        // directly via vAttach with no intermediate step. Confirmed
        // the only call site anywhere in this codebase was the one
        // removed here - vAttach below already operates directly on
        // session.debugProxy with zero dependency on anything this
        // step did or set.
        
        // RESTORED - two priming acks, specifically, not the rest of
        // configureNoAckMode - see fix_restore_priming_acks.py's
        // docstring for the full reasoning. The underlying Rust
        // library's read_response function (used by every
        // sendDebugCommand call, vAttach included) waits for a lone
        // '+' ack byte before reading any response, unless noack_mode
        // was explicitly disabled - which nothing in this codebase
        // does anymore since configureNoAckMode's removal, and
        // correctly so, since none of StikDebug's reference scripts
        // ever send QStartNoAckMode either. But that removal also
        // took these two send-side acks with it, as a side effect,
        // without them being evaluated on their own. If the
        // debugserver sends unsolicited initial state right after
        // debug_proxy_connect_rsd completes, these may be what clears
        // it - restoring them, specifically, tests that directly.
        for (NSUInteger primingAckCount = 0; primingAckCount < 2; primingAckCount++) {
            IdeviceFfiError *primingAckError = debug_proxy_send_ack(session.debugProxy);
            if (primingAckError) {
                logger([NSString stringWithFormat:@"enableJITForPID: priming ack %lu FAILED for pid %d, error: %s", (unsigned long)primingAckCount, pid, primingAckError->message ?: "unknown error"]);
                idevice_error_free(primingAckError);
            }
        }
        
        // RESTORED - QStartNoAckMode + disabling ack mode - see
        // fix_complete_ack_mode_restoration.py's docstring. Confirmed
        // directly against StikDebug's own actual source
        // (JITEnableContext.swift's runDebugServerCommand) that this
        // exact sequence - two priming acks, QStartNoAckMode, then
        // disabling ack mode - runs in BOTH of StikDebug's own code
        // paths before vAttach ever executes. The JS reference scripts
        // never send QStartNoAckMode themselves because the native
        // host already did it for them, before the script ever got
        // control - not because it's unnecessary. Matching StikDebug's
        // own confirmed behavior precisely: a QStartNoAckMode failure
        // here is NOT treated as fatal, unlike this codebase's
        // original version - log and proceed regardless, same as
        // StikDebug's own code does.
        NSString *noAckResponse = nil;
        NSError *noAckError = nil;
        if (sendDebugCommand(session.debugProxy, @"QStartNoAckMode", &noAckResponse, &noAckError)) {
            logger([NSString stringWithFormat:@"enableJITForPID: QStartNoAckMode result for pid %d: %@", pid, noAckResponse ?: @"<no response>"]);
        } else {
            logger([NSString stringWithFormat:@"enableJITForPID: QStartNoAckMode FAILED for pid %d (non-fatal, continuing): %@", pid, noAckError.localizedDescription ?: @"(no error set)"]);
        }
        debug_proxy_set_ack_mode(session.debugProxy, 0);
        
        NSString *attachCommand = [NSString stringWithFormat:@"vAttach;%X", pid];
        NSString *attachResponse = nil;
        CFAbsoluteTime attachCallStart = CFAbsoluteTimeGetCurrent();
        logger([NSString stringWithFormat:@"enableJITForPID: starting attach command for pid %d", pid]);
        [JITEnabler markVAttachStarted];
        BOOL attachSucceeded = sendDebugCommand(session.debugProxy, attachCommand, &attachResponse, &commandError);
        [JITEnabler markVAttachFinished];
        CFAbsoluteTime attachCallEnd = CFAbsoluteTimeGetCurrent();
        if (!attachSucceeded) {
            logger([NSString stringWithFormat:@"enableJITForPID: attach command FAILED for pid %d, call took %.0fms, error: %@", pid, (attachCallEnd - attachCallStart) * 1000.0, commandError.localizedDescription ?: @"(no error set)"]);
            if (error) *error = commandError ?: MakeError(AttachDebugProxyFailed);
            freeDebugSession(&session);
            return NO;
        }
        
        logger([NSString stringWithFormat:@"Attach response for pid %d: %@ (call took %.0fms)", pid, attachResponse.length > 0 ? @"<stop packet>" : @"<no response>", (attachCallEnd - attachCallStart) * 1000.0]);
        
        if (hasTXMSupport) {
            registerJITEndpointForPID(pid, @"10.7.0.1", 49152);
            
            DebugSession *persistentSession = malloc(sizeof(*persistentSession));
            if (!persistentSession) {
                freeDebugSession(&session);
                if (error) *error = MakeError(SessionAllocationFailed);
                return NO;
            }
            
            *persistentSession = session;
            session.adapter = NULL;
            session.handshake = NULL;
            session.remoteServer = NULL;
            session.debugProxy = NULL;
            
            // TXM iOS 26+ workaround
            dispatch_async(debugServiceQueue(), ^{
                runDebugService(pid, persistentSession);
            });
            
            logger([NSString stringWithFormat:@"Debug session started for pid %d", pid]);
        } else {
            // detach immediately
            detachDebuggerSession(session.debugProxy, pid);
            freeDebugSession(&session);
        }
        
        return YES;
    }
    
    return NO;
}

- (void)detachAllJITSessions {
    resetJITEndpointMonitor();
    dispatch_sync(debugSessionStateQueue(), ^{
        NSMutableSet<NSNumber *> *active = activeDebugSessionPIDs();
        NSMutableSet<NSNumber *> *detachRequested = detachRequestedDebugSessionPIDs();
        [detachRequested unionSet:active];
    });
}

+ (BOOL)hasActiveJITSession {
    // Cross-process, not process-local - see JITSupport.m for why
    // activeDebugSessionPIDs() alone can't answer this correctly from
    // the main app (where this is called from) when the session in
    // question is running in the separate Helper process.
    return hasAnyActiveJITSessionAcrossProcesses();
}

// Deliberately does NOT call freeDeviceProvider on the current
// sharedProvider before clearing it - see
// fix_invalidate_provider_on_timeout.py's docstring for the full
// reasoning. A timed-out, orphaned background call may still be
// genuinely running and still actively using this exact pointer
// inside its own, still-executing FFI call - freeing memory a
// separate, still-live thread may be using is a real use-after-free
// risk, and there is no reliable way to know from here whether or
// when that orphaned call actually finishes. Accepted trade-off: a
// small, bounded memory leak (one DeviceProvider struct) per timeout
// event, in exchange for guaranteed safety - preferred over risking a
// crash to save that memory. Runs inside the same providerQueue
// getProviderForPID itself uses, so this can never race with a
// concurrent call reading or writing sharedProvider.
- (void)invalidateSharedProviderAfterTimeout {
    dispatch_sync(self.providerQueue, ^{
        self.sharedProvider = NULL;
        self.didEnsureDDIMounted = NO;
    });
}

- (DeviceProvider *)getProviderForPID:(int32_t)pid error:(NSError **)error {
    __block DeviceProvider *provider = NULL;
    __block NSError *providerError = nil;
    
    // providerQueue is DISPATCH_QUEUE_SERIAL - every call to this
    // method, for every PID, across the whole process, goes through
    // it. If one call gets stuck inside ensureDDIMounted below, every
    // other concurrent call for a different PID queues up behind it
    // right here. The "entered providerQueue" line makes that visible
    // directly rather than left to infer.
    CFAbsoluteTime getProviderCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"getProvider: (pid %d) starting, waiting for providerQueue", pid]);
    
    dispatch_sync(self.providerQueue, ^{
        CFAbsoluteTime queueEntryTime = CFAbsoluteTimeGetCurrent();
        logger([NSString stringWithFormat:@"getProvider: (pid %d) entered providerQueue after %.0fms wait", pid, (queueEntryTime - getProviderCallStart) * 1000.0]);
        
        if (!self.sharedProvider) {
            CFAbsoluteTime createCallStart = CFAbsoluteTimeGetCurrent();
            logger([NSString stringWithFormat:@"getProvider: (pid %d) starting createDeviceProvider (no cached provider)", pid]);
            self.sharedProvider = createDeviceProvider(pairingFilePath(), @"10.7.0.1", &providerError);
            self.didEnsureDDIMounted = NO;
            CFAbsoluteTime createCallEnd = CFAbsoluteTimeGetCurrent();
            logger([NSString stringWithFormat:@"getProvider: (pid %d) createDeviceProvider %@, call took %.0fms", pid, self.sharedProvider ? @"succeeded" : @"FAILED", (createCallEnd - createCallStart) * 1000.0]);
        } else {
            logger([NSString stringWithFormat:@"getProvider: (pid %d) reusing cached provider, skipping createDeviceProvider", pid]);
        }
        
        if (self.sharedProvider && !self.didEnsureDDIMounted) {
            CFAbsoluteTime ddiCallStart = CFAbsoluteTimeGetCurrent();
            logger([NSString stringWithFormat:@"getProvider: (pid %d) starting ensureDDIMounted (not yet confirmed this session)", pid]);
            BOOL ddiOK = ensureDDIMounted(self.sharedProvider, &providerError);
            CFAbsoluteTime ddiCallEnd = CFAbsoluteTimeGetCurrent();
            logger([NSString stringWithFormat:@"getProvider: (pid %d) ensureDDIMounted %@, call took %.0fms", pid, ddiOK ? @"succeeded" : @"FAILED", (ddiCallEnd - ddiCallStart) * 1000.0]);
            if (!ddiOK) {
                provider = NULL;
                return;
            }
            self.didEnsureDDIMounted = YES;
        } else if (self.sharedProvider) {
            logger([NSString stringWithFormat:@"getProvider: (pid %d) DDI already confirmed mounted this session, skipping ensureDDIMounted", pid]);
        }
        
        provider = self.sharedProvider;
    });
    
    CFAbsoluteTime getProviderCallEnd = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"getProvider: (pid %d) returning %@, total call took %.0fms", pid, provider ? @"a valid provider" : @"NULL", (getProviderCallEnd - getProviderCallStart) * 1000.0]);
    
    if (!provider && error) *error = providerError;
    return provider;
}

- (void)dealloc {
    resetJITEndpointMonitor();
    if (_sharedProvider) {
        freeDeviceProvider(_sharedProvider);
        _sharedProvider = NULL;
    }
}

@end
