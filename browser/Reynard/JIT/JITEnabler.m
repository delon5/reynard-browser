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

+ (JITEnabler *)shared {
    static JITEnabler *sharedEnabler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
        IdeviceFfiError *ffiError = NULL;
        
        if (!connectDebugSession(provider, &session, @"10.7.0.1", pid, error)) return NO;
        
        ProcessControlHandle *processControl = NULL;
        CFAbsoluteTime processControlCallStart = CFAbsoluteTimeGetCurrent();
        logger([NSString stringWithFormat:@"enableJITForPID: (pid %d) starting process_control_new", pid]);
        ffiError = process_control_new(session.remoteServer, &processControl);
        CFAbsoluteTime processControlCallEnd = CFAbsoluteTimeGetCurrent();
        if (ffiError) {
            NSInteger realCode = ffiError->code;
            NSInteger realSubCode = ffiError->sub_code;
            NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
            logger([NSString stringWithFormat:@"enableJITForPID: (pid %d) process_control_new REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (processControlCallEnd - processControlCallStart) * 1000.0]);
            if (error) *error = MakeError(ProcessControlCreateFailed);
            idevice_error_free(ffiError);
            freeDebugSession(&session);
            return NO;
        }
        logger([NSString stringWithFormat:@"enableJITForPID: (pid %d) process_control_new succeeded, call took %.0fms", pid, (processControlCallEnd - processControlCallStart) * 1000.0]);
        
        ffiError = process_control_disable_memory_limit(processControl, (uint64_t)pid);
        process_control_free(processControl);
        if (ffiError) {
            logger([NSString stringWithFormat:@"disable_memory_limit failed for pid %d: %s", pid, ffiError->message ?: "unknown error"]);
            idevice_error_free(ffiError);
        }
        
        NSError *commandError = nil;
        NSString *noAckResponse = nil;
        CFAbsoluteTime noAckCallStart = CFAbsoluteTimeGetCurrent();
        logger([NSString stringWithFormat:@"enableJITForPID: starting configureNoAckMode for pid %d", pid]);
        BOOL noAckSucceeded = configureNoAckMode(session.debugProxy, &noAckResponse, &commandError);
        CFAbsoluteTime noAckCallEnd = CFAbsoluteTimeGetCurrent();
        if (!noAckSucceeded) {
            logger([NSString stringWithFormat:@"enableJITForPID: configureNoAckMode FAILED for pid %d, call took %.0fms, error: %@", pid, (noAckCallEnd - noAckCallStart) * 1000.0, commandError.localizedDescription ?: @"(no error set)"]);
            if (error) *error = commandError ?: MakeError(NoAckConfigureFailed);
            freeDebugSession(&session);
            return NO;
        }
        
        logger([NSString stringWithFormat:@"QStartNoAckMode result for pid %d: %@ (call took %.0fms)", pid, noAckResponse ?: @"<no response>", (noAckCallEnd - noAckCallStart) * 1000.0]);
        
        NSString *attachCommand = [NSString stringWithFormat:@"vAttach;%X", pid];
        NSString *attachResponse = nil;
        CFAbsoluteTime attachCallStart = CFAbsoluteTimeGetCurrent();
        logger([NSString stringWithFormat:@"enableJITForPID: starting attach command for pid %d", pid]);
        BOOL attachSucceeded = sendDebugCommand(session.debugProxy, attachCommand, &attachResponse, &commandError);
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
