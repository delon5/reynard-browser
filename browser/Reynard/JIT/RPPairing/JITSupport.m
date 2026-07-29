//
//  JITSupport.m
//  Reynard
//
//  Created by Minh Ton on 11/3/2026.
//

#import "JITSupport.h"
#import "JITErrors.h"
#import "JITUtils.h"
#import "IdeviceFFI.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <sys/file.h>
#include <signal.h>

static const uint16_t rppairingPort = 49152;

struct DeviceProvider {
    AdapterHandle *adapter;
    RsdHandshakeHandle *handshake;
    HeartbeatClientHandle *heartbeatClient;
    BOOL heartbeatRunning;
};

static dispatch_source_t endpointMonitorTimer = nil;
static NSUInteger endpointMonitorCursor = 0;
static BOOL endpointFailureLatched = NO;

dispatch_queue_t debugServiceQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITSupport.DebugServiceQueue", DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

dispatch_queue_t debugSessionStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITSupport.DebugSessionStateQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static dispatch_queue_t endpointMonitorQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITSupport.EndpointMonitorQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

NSMutableSet<NSNumber *> *activeDebugSessionPIDs(void) {
    static NSMutableSet<NSNumber *> *activePIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activePIDs = [NSMutableSet set];
    });
    return activePIDs;
}

NSMutableSet<NSNumber *> *detachRequestedDebugSessionPIDs(void) {
    static NSMutableSet<NSNumber *> *requestedPIDs;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        requestedPIDs = [NSMutableSet set];
    });
    return requestedPIDs;
}

// Shared, cross-process JIT session visibility - see this script's
// docstring for the full reasoning. Small file in the App Group
// container, one "pid:timestamp" entry per line. The brief, bounded
// flock() below is only ever held around this file's own
// read-modify-write - never across anything else - matching the
// pattern already proven in the Helper's concurrency-limiting fix
// tonight.
static NSURL *activeJITSessionsFileURL(void) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) {
        return nil;
    }
    return [containerURL URLByAppendingPathComponent:@"active-jit-sessions.txt" isDirectory:NO];
}

// Reads the shared file, returns only entries whose PID is still
// genuinely alive right now (kill(pid, 0) == 0 - no signal sent, just
// checks whether a process with this PID currently exists). Not a
// time-based expiry deliberately - a JIT session can legitimately run
// for a tab's entire lifetime, so a fixed short window would
// incorrectly age out a genuinely active one. This handles a crashed
// or force-killed process's stale entry without needing that process
// to have cooperated. PID reuse is a rare, brief-window edge case not
// worth guarding against for an informational display row.
static NSArray<NSNumber *> *readLiveJITSessionPIDs(int fd) {
    NSMutableArray<NSNumber *> *live = [NSMutableArray array];
    off_t fileSize = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    if (fileSize > 0 && fileSize < (1024 * 1024)) {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileSize];
        read(fd, data.mutableBytes, (size_t)fileSize);
        NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length == 0) continue;
            NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
            if (parts.count < 1) continue;
            int32_t pid = (int32_t)[parts[0] intValue];
            if (pid <= 0) continue;
            if (kill((pid_t)pid, 0) == 0) {
                [live addObject:@(pid)];
            }
        }
    }
    return live;
}

static void writeJITSessionPIDs(int fd, NSArray<NSNumber *> *pids) {
    NSMutableString *newContents = [NSMutableString string];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (NSNumber *pid in pids) {
        [newContents appendFormat:@"%d:%.0f\n", pid.intValue, now];
    }
    NSData *newData = [newContents dataUsingEncoding:NSUTF8StringEncoding];
    lseek(fd, 0, SEEK_SET);
    ftruncate(fd, 0);
    write(fd, newData.bytes, newData.length);
}

static void addPIDToSharedActiveSessions(int32_t pid) {
    NSURL *fileURL = activeJITSessionsFileURL();
    if (!fileURL) return;
    
    int fd = open(fileURL.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return;
    
    NSTimeInterval lockDeadline = [NSDate date].timeIntervalSince1970 + 0.5;
    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if ([NSDate date].timeIntervalSince1970 > lockDeadline) {
            close(fd);
            return;
        }
        usleep(5000);
    }
    
    NSMutableArray<NSNumber *> *live = [readLiveJITSessionPIDs(fd) mutableCopy];
    if (![live containsObject:@(pid)]) {
        [live addObject:@(pid)];
    }
    writeJITSessionPIDs(fd, live);
    
    flock(fd, LOCK_UN);
    close(fd);
}

static void removePIDFromSharedActiveSessions(int32_t pid) {
    NSURL *fileURL = activeJITSessionsFileURL();
    if (!fileURL) return;
    
    int fd = open(fileURL.fileSystemRepresentation, O_RDWR);
    if (fd < 0) return;
    
    NSTimeInterval lockDeadline = [NSDate date].timeIntervalSince1970 + 0.5;
    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if ([NSDate date].timeIntervalSince1970 > lockDeadline) {
            close(fd);
            return;
        }
        usleep(5000);
    }
    
    NSArray<NSNumber *> *live = readLiveJITSessionPIDs(fd);
    NSMutableArray<NSNumber *> *remaining = [NSMutableArray array];
    for (NSNumber *existingPID in live) {
        if (existingPID.intValue != pid) {
            [remaining addObject:existingPID];
        }
    }
    writeJITSessionPIDs(fd, remaining);
    
    flock(fd, LOCK_UN);
    close(fd);
}

BOOL hasAnyActiveJITSessionAcrossProcesses(void) {
    NSURL *fileURL = activeJITSessionsFileURL();
    if (!fileURL) return NO;
    
    int fd = open(fileURL.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return NO;
    
    NSTimeInterval lockDeadline = [NSDate date].timeIntervalSince1970 + 0.5;
    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if ([NSDate date].timeIntervalSince1970 > lockDeadline) {
            close(fd);
            return NO;
        }
        usleep(5000);
    }
    
    // Read and write the pruned list back - every query also cleans
    // up stale entries, same self-maintaining pattern as the
    // concurrency-limiting mechanism tonight.
    NSArray<NSNumber *> *live = readLiveJITSessionPIDs(fd);
    writeJITSessionPIDs(fd, live);
    
    flock(fd, LOCK_UN);
    close(fd);
    
    return live.count > 0;
}

static void registerDebugSessionPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_sync(debugSessionStateQueue(), ^{
        NSNumber *key = @(pid);
        [activeDebugSessionPIDs() addObject:key];
        [detachRequestedDebugSessionPIDs() removeObject:key];
    });
    
    addPIDToSharedActiveSessions(pid);
}

static void unregisterDebugSessionPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_sync(debugSessionStateQueue(), ^{
        NSNumber *key = @(pid);
        [activeDebugSessionPIDs() removeObject:key];
        [detachRequestedDebugSessionPIDs() removeObject:key];
    });
    
    removePIDFromSharedActiveSessions(pid);
}

static BOOL shouldDetachDebugSessionPID(int32_t pid) {
    if (pid <= 0) return NO;
    
    __block BOOL shouldDetach = NO;
    dispatch_sync(debugSessionStateQueue(), ^{
        shouldDetach = [detachRequestedDebugSessionPIDs() containsObject:@(pid)];
    });
    return shouldDetach;
}

// TEST - genuinely reverted to minh-ton's original behavior (stop on
// ANY error), not the earlier, flawed test (which set heartbeatRunning
// = NO too late - right before ensureDDIMounted - when the heartbeat
// could already have been mid-call at that exact moment, so the flag
// never actually stopped anything in flight). This is the real,
// precise difference from upstream: our heartbeat retries on any
// error except one specific message, keeping itself alive and
// contending for the connection indefinitely; theirs dies permanently
// on the very first error. Testing whether THAT is what actually
// matters for tonight's isDDIMounted hang specifically - the earlier
// same-change test (noted below, now removed) was against a
// different, later, discrete error (BadBuildManifest), not this
// silent hang, which wasn't even isolated until later in this session.
static void startHeartbeat(DeviceProvider *provider) {
    dispatch_queue_t heartbeatQueue = dispatch_queue_create("com.minh-ton.Reynard.JITSupport.ProviderHeartbeatQueue",DISPATCH_QUEUE_SERIAL);
    provider->heartbeatRunning = YES;
    
    dispatch_async(heartbeatQueue, ^{
        uint64_t currentInterval = 2;
        int iteration = 0;
        while (provider->heartbeatRunning) {
            iteration++;
            uint64_t newInterval = 0;
            // TIMING TEST - heartbeat_get_marco/heartbeat_send_polo
            // both go through the same LOCAL_RUNTIME_GUARD mutex as
            // ensureDDIMounted's own FFI calls. This logging exists
            // to test whether the intermittent lockdownd_connect_rsd
            // stall correlates with heartbeat legitimately holding
            // that guard for a long time - e.g. if the device
            // negotiated a long currentInterval - rather than any
            // call actually being stuck.
            CFAbsoluteTime marcoStart = CFAbsoluteTimeGetCurrent();
            logger([NSString stringWithFormat:@"heartbeat: iteration %d starting heartbeat_get_marco with currentInterval=%llu", iteration, (unsigned long long)currentInterval]);
            IdeviceFfiError *ffiError = heartbeat_get_marco(provider->heartbeatClient, currentInterval, &newInterval);
            CFAbsoluteTime marcoEnd = CFAbsoluteTimeGetCurrent();
            
            if (!provider->heartbeatRunning) break;
            
            if (ffiError) {
                logger([NSString stringWithFormat:@"heartbeat: iteration %d heartbeat_get_marco FAILED after %.0fms, dying permanently (minh-ton behavior)", iteration, (marcoEnd - marcoStart) * 1000.0]);
                idevice_error_free(ffiError);
                break;
            }
            
            logger([NSString stringWithFormat:@"heartbeat: iteration %d heartbeat_get_marco succeeded after %.0fms, device returned newInterval=%llu", iteration, (marcoEnd - marcoStart) * 1000.0, (unsigned long long)newInterval]);
            
            CFAbsoluteTime poloStart = CFAbsoluteTimeGetCurrent();
            ffiError = heartbeat_send_polo(provider->heartbeatClient);
            CFAbsoluteTime poloEnd = CFAbsoluteTimeGetCurrent();
            if (ffiError) {
                logger([NSString stringWithFormat:@"heartbeat: iteration %d heartbeat_send_polo FAILED after %.0fms, dying permanently (minh-ton behavior)", iteration, (poloEnd - poloStart) * 1000.0]);
                idevice_error_free(ffiError);
                break;
            }
            logger([NSString stringWithFormat:@"heartbeat: iteration %d heartbeat_send_polo succeeded after %.0fms", iteration, (poloEnd - poloStart) * 1000.0]);
            
            // currentInterval is deliberately NOT updated from
            // newInterval here - matching the original code exactly,
            // which always reuses the fixed value of 2 for every
            // call. newInterval is logged above for diagnostic
            // purposes only.
        }
    });
}

// MARK: RPPairing JIT enablement on 17.4+

BOOL sendDebugCommand(DebugProxyHandle *debugProxy, NSString *commandString, NSString **responseOut, NSError **error) {
    DebugserverCommandHandle *command = debugserver_command_new(commandString.UTF8String, NULL, 0);
    if (!command) {
        if (error) *error = MakeError(DebugCommandCreateFailed);
        return NO;
    }
    
    char *response = NULL;
    IdeviceFfiError *ffiError = debug_proxy_send_command(debugProxy, command, &response);
    debugserver_command_free(command);
    
    if (ffiError) {
        if (error) *error = MakeError(DebugCommandSendFailed);
        
        idevice_error_free(ffiError);
        if (response) idevice_string_free(response);
        return NO;
    }
    
    if (responseOut) *responseOut = response ? [NSString stringWithUTF8String:response] : nil;
    if (response) idevice_string_free(response);
    
    return YES;
}

static BOOL forwardSignalStop(DebugProxyHandle *debugProxy, NSString *signal, NSString *threadID, NSError **error) {
    NSString *continueCommand = [NSString stringWithFormat:@"vCont;S%@:%@", signal, threadID];
    NSString *stopResponse = nil;
    return sendDebugCommand(debugProxy, continueCommand, &stopResponse, error);
}

static BOOL writeRegisterValue(DebugProxyHandle *debugProxy, NSString *registerName, uint64_t value, NSString *threadID, NSError **error) {
    NSString *response = nil;
    NSString *command = [NSString stringWithFormat:@"P%@=%@;thread:%@;", registerName, encodeLittleEndianHex64(value), threadID];
    
    if (!sendDebugCommand(debugProxy, command, &response, error)) return NO;
    if (response.length > 0 && ![response isEqualToString:@"OK"]) {
        if (error) *error = MakeError(UnexpectedRegisterWriteResponse);
        return NO;
    }
    
    return YES;
}

BOOL configureNoAckMode(DebugProxyHandle *debugProxy, NSString **responseOut, NSError **error) {
    for (NSUInteger ackCount = 0; ackCount < 2; ackCount++) {
        IdeviceFfiError *ffiError = debug_proxy_send_ack(debugProxy);
        if (!ffiError) continue;
        
        if (error) *error = MakeError(NoAckConfigureFailed);
        idevice_error_free(ffiError);
        return NO;
    }
    
    NSString *response = nil;
    if (!sendDebugCommand(debugProxy, @"QStartNoAckMode", &response, error)) return NO;
    if (response.length > 0 && ![response isEqualToString:@"OK"]) {
        if (error) *error = MakeError(UnexpectedNoAckResponse);
        return NO;
    }
    
    debug_proxy_set_ack_mode(debugProxy, 0);
    if (responseOut) {
        *responseOut = response;
    }
    return YES;
}

BOOL connectDebugSession(DeviceProvider *provider, DebugSession *session, NSString *targetAddress, int32_t pid, NSError **error) {
    IdeviceFfiError *ffiError = NULL;
    
    NSString *resolvedPairingFilePath = pairingFilePath();
    RpPairingFileHandle *rpPairingFile = NULL;
    CFAbsoluteTime pairingFileReadCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) starting rp_pairing_file_read", pid]);
    ffiError = rp_pairing_file_read(resolvedPairingFilePath.fileSystemRepresentation, &rpPairingFile);
    CFAbsoluteTime pairingFileReadCallEnd = CFAbsoluteTimeGetCurrent();
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) rp_pairing_file_read REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (pairingFileReadCallEnd - pairingFileReadCallStart) * 1000.0]);
        if (error) *error = MakeError(PairingFileReadFailed);
        idevice_error_free(ffiError);
        return NO;
    }
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) rp_pairing_file_read succeeded, call took %.0fms", pid, (pairingFileReadCallEnd - pairingFileReadCallStart) * 1000.0]);
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(rppairingPort);
    inet_pton(AF_INET, targetAddress.UTF8String, &address.sin_addr);
    
    // TIMING TEST - testing whether LOCAL_RUNTIME_GUARD contention
    // (e.g. from heartbeat's own periodic run_sync_local calls on
    // this same process's shared runtime) creates a long enough gap
    // after tunnel creation for a freshly-created tunnel's own
    // background service task to go unserviced and get closed by the
    // device before this function ever gets to use it. Remove once
    // the BrokenPipe/channel-closed pattern is understood.
    CFAbsoluteTime tunnelCallStart = CFAbsoluteTimeGetCurrent();
    
    ffiError = tunnel_create_rppairing(
                                       (const struct sockaddr *)&address,
                                       (socklen_t)sizeof(address),
                                       "ReynardDebug",
                                       rpPairingFile,
                                       NULL, NULL,
                                       &session->adapter, &session->handshake
                                       );
    rp_pairing_file_free(rpPairingFile);
    
    CFAbsoluteTime tunnelCallEnd = CFAbsoluteTimeGetCurrent();
    
    if (ffiError) {
        // TEST - surfacing the real, underlying error here too. This
        // is the FIRST tunnel_create_rppairing call in the entire
        // flow - called directly from JITEnabler.m's
        // enableJITForPID:, before runDebugService() ever runs. The
        // real-error logging added earlier today only covers
        // runDebugService()'s own, separate, later call to this same
        // underlying function - which this specific call site,
        // reached first on every single attempt, was never covered
        // by at all.
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) tunnel_create_rppairing REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (tunnelCallEnd - tunnelCallStart) * 1000.0]);
        if (error) {
            *error = [NSError errorWithDomain:ErrorDomain code:TunnelCreateFailed userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create RPPairing tunnel (real cause code %ld/%ld): %@", (long)realCode, (long)realSubCode, realMessage]
            }];
        }
        idevice_error_free(ffiError);
        return NO;
    }
    
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) tunnel_create_rppairing succeeded, call took %.0fms", pid, (tunnelCallEnd - tunnelCallStart) * 1000.0]);
    
    CFAbsoluteTime remoteServerCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) gap before remote_server_connect_rsd: %.0fms since tunnel ready", pid, (remoteServerCallStart - tunnelCallEnd) * 1000.0]);
    
    ffiError = remote_server_connect_rsd(session->adapter, session->handshake, &session->remoteServer);
    
    CFAbsoluteTime remoteServerCallEnd = CFAbsoluteTimeGetCurrent();
    
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) remote_server_connect_rsd REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms, total elapsed since tunnel ready: %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (remoteServerCallEnd - remoteServerCallStart) * 1000.0, (remoteServerCallEnd - tunnelCallEnd) * 1000.0]);
        if (error) *error = MakeError(RemoteServerConnectFailed);
        idevice_error_free(ffiError);
        freeDebugSession(session);
        return NO;
    }
    
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) remote_server_connect_rsd succeeded, call took %.0fms, total elapsed since tunnel ready: %.0fms", pid, (remoteServerCallEnd - remoteServerCallStart) * 1000.0, (remoteServerCallEnd - tunnelCallEnd) * 1000.0]);
    
    CFAbsoluteTime debugProxyCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) starting debug_proxy_connect_rsd", pid]);
    ffiError = debug_proxy_connect_rsd(session->adapter, session->handshake, &session->debugProxy);
    CFAbsoluteTime debugProxyCallEnd = CFAbsoluteTimeGetCurrent();
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) debug_proxy_connect_rsd REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (debugProxyCallEnd - debugProxyCallStart) * 1000.0]);
        if (error) *error = MakeError(DebugProxyConnectFailed);
        idevice_error_free(ffiError);
        freeDebugSession(session);
        return NO;
    }
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) debug_proxy_connect_rsd succeeded, call took %.0fms", pid, (debugProxyCallEnd - debugProxyCallStart) * 1000.0]);
    
    return YES;
}

static BOOL prepareMemoryRegion(DebugProxyHandle *debugProxy, uint64_t startAddress, uint64_t regionSize, NSError **error) {
    uint64_t size = regionSize == 0 ? 0x4000 : regionSize;
    
    for (uint64_t currentAddress = startAddress; currentAddress < startAddress + size; currentAddress += 0x4000) {
        NSString *existingByte = nil;
        NSString *readCommand = [NSString stringWithFormat:@"m%llx,1", currentAddress];
        if (!sendDebugCommand(debugProxy, readCommand, &existingByte, error)) return NO;
        
        if (!existingByte || existingByte.length < 2) {
            if (error && !*error)
                *error = MakeError(MemoryPrepareReadFailed);
            return NO;
        }
        
        NSString *command = [NSString stringWithFormat:@"M%llx,1:%@", currentAddress, [existingByte substringToIndex:2]];
        NSString *response = nil;
        
        if (!sendDebugCommand(debugProxy, command, &response, error)) return NO;
        if (response.length > 0 && ![response isEqualToString:@"OK"]) {
            if (error) *error = MakeError(UnexpectedPrepareRegionResponse);
            return NO;
        }
    }
    
    return YES;
}

BOOL detachDebuggerSession(DebugProxyHandle *debugProxy, int32_t pid) {
    NSString *detachResponse = nil;
    NSError *detachError = nil;
    if (sendDebugCommand(debugProxy, @"D", &detachResponse, &detachError)) {
        logger([NSString stringWithFormat:@"Detach response for pid %d: %@", pid, detachResponse ?: @"<no response>"]);
        return YES;
    }
    
    if (!isNotConnectedError(detachError)) {
        logger([NSString stringWithFormat:@"Detach failed for pid %d: %@", pid, detachError.localizedDescription ?: @"detach failed"]);
    }
    return NO;
}

void runDebugService(int32_t pid, DebugSession *session) {
    if (!session) return;
    
    registerDebugSessionPID(pid);
    
    // DIAGNOSTIC TEST - this loop runs for the entire lifetime of the
    // target process (self, on the Helper's self-enable path) and was
    // previously completely unlogged beyond the two exit-condition
    // lines below. "Helper JIT: Succeeded" in Settings only reflects
    // that vAttach succeeded - this loop starting, and staying alive,
    // was never actually confirmed by anything built tonight.
    //
    // Not logging every iteration unconditionally - this can run many
    // times during active JIT use and would flood the log. First 3
    // iterations log unconditionally (a hang here would most resemble
    // every other hang found tonight - stuck at startup); iteration 4+
    // only logs a "c" command if it takes over 1 second, catching a
    // genuinely stuck later iteration without spamming normal
    // operation. Breakpoint handling logs unconditionally regardless
    // of iteration count.
    CFAbsoluteTime debugServiceLoopStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"runDebugService: (pid %d) loop starting", pid]);
    NSInteger debugServiceIteration = 0;
    static const NSInteger kUnconditionalLogIterations = 3;
    static const NSTimeInterval kSlowContinueThresholdSeconds = 1.0;
    
    NSError *commandError = nil;
    BOOL exitPacketPresent = NO;
    BOOL detachedByCommand = NO;
    
    while (YES) {
        @autoreleasepool {
            debugServiceIteration++;
            BOOL verboseThisIteration = debugServiceIteration <= kUnconditionalLogIterations;
            
            NSString *stopResponse = nil;
            commandError = nil;
            
            if (shouldDetachDebugSessionPID(pid)) {
                detachedByCommand = detachDebuggerSession(session->debugProxy, pid);
                if (detachedByCommand) {
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) detach requested and completed at iteration %ld", pid, (long)debugServiceIteration]);
                    break;
                }
            }
            
            if (verboseThisIteration) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) starting continue command (iteration %ld)", pid, (long)debugServiceIteration]);
            }
            CFAbsoluteTime continueCallStart = CFAbsoluteTimeGetCurrent();
            BOOL continueOK = sendDebugCommand(session->debugProxy, @"c", &stopResponse, &commandError);
            CFAbsoluteTime continueCallEnd = CFAbsoluteTimeGetCurrent();
            NSTimeInterval continueCallDuration = continueCallEnd - continueCallStart;
            
            if (!continueOK) {
                if (!isNotConnectedError(commandError)) logger([NSString stringWithFormat:@"Debug loop ended for pid %d: %@ (iteration %ld, call took %.0fms)", pid, commandError.localizedDescription ?: @"continue failed", (long)debugServiceIteration, continueCallDuration * 1000.0]);
                break;
            }
            
            if (verboseThisIteration) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) continue command returned, call took %.0fms (iteration %ld)", pid, continueCallDuration * 1000.0, (long)debugServiceIteration]);
            } else if (continueCallDuration > kSlowContinueThresholdSeconds) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) SLOW continue command, call took %.0fms (iteration %ld)", pid, continueCallDuration * 1000.0, (long)debugServiceIteration]);
            }
            
            if ([stopResponse hasPrefix:@"W"] || [stopResponse hasPrefix:@"X"]) {
                exitPacketPresent = YES;
                logger([NSString stringWithFormat:@"Target exited for pid %d with packet %@ (iteration %ld, loop ran %.0fms total)", pid, stopResponse, (long)debugServiceIteration, (continueCallEnd - debugServiceLoopStart) * 1000.0]);
                break;
            }
            
            NSString *threadID = packetField(stopResponse, @"thread");
            NSString *pcField = packetField(stopResponse, @"20");
            NSString *x0Field = packetField(stopResponse, @"00");
            NSString *x1Field = packetField(stopResponse, @"01");
            NSString *x16Field = packetField(stopResponse, @"10");
            
            uint64_t pc = parseLittleEndianHex64(pcField);
            uint64_t x0 = x0Field ? parseLittleEndianHex64(x0Field) : 0;
            uint64_t x1 = x1Field ? parseLittleEndianHex64(x1Field) : 0;
            uint64_t x16 = x16Field ? parseLittleEndianHex64(x16Field) : 0;
            
            NSString *instructionResponse = nil;
            NSString *readInstruction = [NSString stringWithFormat:@"m%llx,4", pc];
            if (!sendDebugCommand(session->debugProxy, readInstruction, &instructionResponse, &commandError)) instructionResponse = nil;
            
            uint32_t instruction = (uint32_t)parseLittleEndianHex64(instructionResponse ?: @"");
            if (instructionResponse.length == 0 || !instructionIsBreakpoint(instruction)) {
                NSString *signal = packetSignal(stopResponse);
                
                // continue with signal
                if (signal && !forwardSignalStop(session->debugProxy, signal, threadID, &commandError)) break;
                continue;
            }
            
            uint16_t breakpointImmediate = (instruction >> 5) & 0xffff;
            
            if (breakpointImmediate == 0xf00d) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) 0xf00d breakpoint hit at iteration %ld - x0=0x%llx x1=0x%llx x16=%llu", pid, (long)debugServiceIteration, x0, x1, x16]);
                if (!x0Field || !x1Field || !x16Field) break;
                if (x16 != 1) continue;
                
                if (x0 == 0 && x1 == 0) {
                    if (!writeRegisterValue(session->debugProxy, @"20", pc + 4, threadID, &commandError)) break;
                    continue;
                }
                
                if (x0 == 0) break;
                
                if (!prepareMemoryRegion(session->debugProxy, x0, x1, &commandError)) break;
                if (!writeRegisterValue(session->debugProxy, @"00", x0, threadID, &commandError)) break;
                
                // jump over breakpoint
                if (!writeRegisterValue(session->debugProxy, @"20", pc + 4, threadID, &commandError)) break;
            } else {
                continue;
            }
        }
    }
    
    logger([NSString stringWithFormat:@"runDebugService: (pid %d) loop exiting after %ld iterations, %.0fms total, exitPacketPresent=%d, detachedByCommand=%d", pid, (long)debugServiceIteration, (CFAbsoluteTimeGetCurrent() - debugServiceLoopStart) * 1000.0, exitPacketPresent, detachedByCommand]);
    
    if (!exitPacketPresent && !detachedByCommand) {
        detachedByCommand = detachDebuggerSession(session->debugProxy, pid);
    }
    
    unregisterDebugSessionPID(pid);
    unregisterJITEndpointForPID(pid);
    freeDebugSession(session);
    free(session);
}

DeviceProvider *createDeviceProvider(NSString *pairingFilePath, NSString *targetAddress, NSError **error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:pairingFilePath]) {
        if (error) *error = MakeError(PairingFileMissing);
        return NULL;
    }
    
    RpPairingFileHandle *rpPairingFile = NULL;
    IdeviceFfiError *ffiError = rp_pairing_file_read(pairingFilePath.fileSystemRepresentation, &rpPairingFile);
    if (ffiError) {
        if (error) *error = MakeError(PairingFileReadFailed);
        idevice_error_free(ffiError);
        return NULL;
    }
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(rppairingPort);
    
    if (inet_pton(AF_INET, targetAddress.UTF8String, &address.sin_addr) != 1) {
        rp_pairing_file_free(rpPairingFile);
        if (error) *error = MakeError(InvalidTargetAddress);
        return NULL;
    }
    
    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    ffiError = tunnel_create_rppairing((const struct sockaddr *)&address, (socklen_t)sizeof(address), "Reynard", rpPairingFile, NULL, NULL, &adapter, &handshake);
    rp_pairing_file_free(rpPairingFile);
    
    if (ffiError) {
        // Was: silently discarded the real, underlying error and
        // replaced it with the generic MakeError(TunnelCreateFailed)
        // label - meaning the actual, specific reason this call fails
        // has never once been visible tonight, despite hours spent
        // investigating a completely different, wrong function
        // entirely (mistakenly reading Reynard's own error code -28
        // as if it were the Rust library's own, different numbering
        // scheme). Surfacing the real code/sub_code/message here now.
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"tunnel_create_rppairing REAL failure - code: %ld, sub_code: %ld, message: %@", (long)realCode, (long)realSubCode, realMessage]);
        if (error) {
            *error = [NSError errorWithDomain:ErrorDomain code:TunnelCreateFailed userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create RPPairing tunnel (real cause code %ld/%ld): %@", (long)realCode, (long)realSubCode, realMessage]
            }];
        }
        idevice_error_free(ffiError);
        return NULL;
    }
    
    // REMOVED the entire heartbeat_connect_rsd / heartbeat_get_marco /
    // heartbeat_send_polo / startHeartbeat sequence here - see
    // fix_remove_heartbeat_contention.py's docstring. provider's
    // heartbeatClient field is simply never set now (stays NULL from
    // calloc's own zero-init below); freeDeviceProvider's existing
    // `if (provider->heartbeatClient)` cleanup check already safely
    // no-ops on that, without needing any further changes.
    
    DeviceProvider *provider = calloc(1, sizeof(*provider));
    if (!provider) {
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        if (error) *error = MakeError(DeviceProviderAllocationFailed);
        return NULL;
    }
    
    provider->adapter = adapter;
    provider->handshake = handshake;
    
    return provider;
}

void freeDebugSession(DebugSession *session) {
    if (session->debugProxy) { debug_proxy_free(session->debugProxy); session->debugProxy = NULL; }
    if (session->remoteServer) { remote_server_free(session->remoteServer); session->remoteServer = NULL; }
    if (session->handshake) { rsd_handshake_free(session->handshake); session->handshake = NULL; }
    if (session->adapter) { adapter_free(session->adapter); session->adapter = NULL; }
}

void freeDeviceProvider(DeviceProvider *provider) {
    if (!provider) return;
    provider->heartbeatRunning = NO;
    if (provider->heartbeatClient) { heartbeat_client_free(provider->heartbeatClient); provider->heartbeatClient = NULL; }
    if (provider->handshake) { rsd_handshake_free(provider->handshake); provider->handshake = NULL; }
    if (provider->adapter) { adapter_free(provider->adapter); provider->adapter = NULL; }
    free(provider);
}

// MARK: Developer Disk Image Mounting

// There's actually a pretty helpful example from the 'idevice' submodule for this
// at ./support/idevice/cpp/examples/mounter.cpp, so I just ended up copying most
// of the logic from there with only a few modifications here.

static NSURL *ddiDirectoryURL(NSError **error) {
    // Same resolver JITUtils.m's pairingFilePath() uses — see that
    // file for the full explanation of why the group ID can't just be
    // assumed as "group.<bundleID>".
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (containerURL) {
        return [containerURL URLByAppendingPathComponent:@"DDI" isDirectory:YES];
    }

    // Same reasoning as pairingFilePath()'s own fallback in JITUtils.m
    // — logged loudly since whichever process hits this (main app or
    // Helper) silently reading/writing DDI files from its own private
    // container instead of the shared one is exactly the kind of thing
    // that looks like success locally while quietly breaking the other
    // process's own access to the same files.
    logger([NSString stringWithFormat:@"[AppGroup] WARNING: shared container unavailable for groupID=%@ — ddiDirectoryURL() falling back to private Application Support directory. The other process (main app or Helper, whichever this isn't) will NOT see DDI files written or read here.", groupID]);
    NSURL *applicationSupportDirectory = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!applicationSupportDirectory) {
        if (error) *error = MakeError(DDIMountPathResolveFailed);
        return nil;
    }

    return [applicationSupportDirectory URLByAppendingPathComponent:@"DDI" isDirectory:YES];
}

static NSData *ddiFileData(NSURL *ddiDirectory, NSString *fileName, NSError **error) {
    NSURL *fileURL = [ddiDirectory URLByAppendingPathComponent:fileName isDirectory:NO];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:&readError];
    if (!data || data.length == 0) {
        if (error) *error = MakeError(DDIFileReadFailed);
        return nil;
    }
    return data;
}

static BOOL isDDIMounted(ImageMounterHandle *mounterClient, BOOL *mountedOut, NSError **error) {
    plist_t *devices = NULL;
    size_t deviceCount = 0;
    IdeviceFfiError *ffiError = image_mounter_copy_devices(mounterClient, &devices, &deviceCount);
    if (ffiError) {
        if (error) *error = MakeError(DDIMountStateQueryFailed);
        idevice_error_free(ffiError);
        return NO;
    }
    
    if (devices) {
        for (size_t index = 0; index < deviceCount; index++) {
            if (devices[index]) plist_free(devices[index]);
        }
        idevice_data_free((uint8_t *)devices, deviceCount * sizeof(plist_t));
    }
    
    if (mountedOut) *mountedOut = deviceCount > 0;
    return YES;
}

// TEST - instrumented throughout. createDeviceProvider() and
// connectDebugSession() have both been directly, empirically ruled
// out tonight (real-error logging added to both, neither ever fired
// across two separate full-timeout tests) - this function is the
// only remaining, unexamined step between them. The app has hit the
// FULL 20s timeout on every attempt, not a fast, discrete failure -
// so a log line before each step starts is added here too, not just
// real-error surfacing on each FFI call, specifically to catch a
// genuine hang inside one specific call, where no error is ever
// returned at all.
BOOL ensureDDIMounted(DeviceProvider *provider, NSError **error) {
    if (!provider || !provider->adapter || !provider->handshake) {
        if (error) *error = MakeError(DeviceProviderCreateFailed);
        return NO;
    }
    
    // (The heartbeat mechanism this comment used to reference has since
    // been removed entirely - see
    // fix_remove_heartbeat_contention.py's docstring.)
    LockdowndClientHandle *lockdownClient = NULL;
    ImageMounterHandle *mounterClient = NULL;
    IdeviceFfiError *ffiError = NULL;
    plist_t chipIDNode = NULL;
    BOOL mounted = NO;
    NSURL *ddiDirectory = nil;
    NSData *imageData = nil;
    NSData *trustCacheData = nil;
    NSData *buildManifestData = nil;
    uint64_t uniqueChipID = 0;
    BOOL success = NO;
    
    logger(@"ensureDDIMounted: starting image_mounter_connect_rsd");
    ffiError = image_mounter_connect_rsd(provider->adapter, provider->handshake, &mounterClient);
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"ensureDDIMounted REAL failure at image_mounter_connect_rsd - code: %ld, sub_code: %ld, message: %@", (long)realCode, (long)realSubCode, realMessage]);
        if (error) *error = MakeError(ImageMounterConnectFailed);
        idevice_error_free(ffiError);
        goto cleanup;
    }
    logger(@"ensureDDIMounted: image_mounter_connect_rsd succeeded");
    
    // FIX - moved here, before isDDIMounted()/copy_devices(). The
    // idevice library's own doc comment on copy_devices(), read
    // directly from source tonight: "A lockdown client must be
    // established and queried after establishing a mounter client,
    // or the device will stop responding to requests." This function
    // was doing exactly that - querying the mounter (copy_devices, via
    // isDDIMounted) before ever establishing/querying a lockdown
    // client, which only happened much later. That ordering violation
    // is the direct, confirmed cause of tonight's indefinite hang -
    // extensively tested and empirically ruled out every other
    // explanation (pairing file, tunnel creation x2, tokio runtime
    // threading model) before finding this.
    logger(@"ensureDDIMounted: starting lockdownd_connect_rsd (must happen before any mounter query, per idevice library docs)");
    ffiError = lockdownd_connect_rsd(provider->adapter, provider->handshake, &lockdownClient);
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"ensureDDIMounted REAL failure at lockdownd_connect_rsd - code: %ld, sub_code: %ld, message: %@", (long)realCode, (long)realSubCode, realMessage]);
        if (error) *error = MakeError(LockdowndConnectFailed);
        idevice_error_free(ffiError);
        goto cleanup;
    }
    logger(@"ensureDDIMounted: lockdownd_connect_rsd succeeded");
    
    logger(@"ensureDDIMounted: starting lockdownd_get_value UniqueChipID (the required query)");
    ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", NULL, &chipIDNode);
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"ensureDDIMounted REAL failure at lockdownd_get_value UniqueChipID - code: %ld, sub_code: %ld, message: %@", (long)realCode, (long)realSubCode, realMessage]);
        if (error) *error = MakeError(UniqueChipIDReadFailed);
        idevice_error_free(ffiError);
        goto cleanup;
    }
    
    plist_get_uint_val(chipIDNode, &uniqueChipID);
    if (uniqueChipID == 0) {
        logger(@"ensureDDIMounted: UniqueChipID resolved to 0 - invalid");
        if (error) *error = MakeError(UniqueChipIDInvalid);
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: UniqueChipID = %llu", uniqueChipID]);
    
    logger(@"ensureDDIMounted: starting isDDIMounted check (now safe - lockdown client already established and queried above)");
    if (!isDDIMounted(mounterClient, &mounted, error)) {
        logger(@"ensureDDIMounted: isDDIMounted check itself failed");
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: isDDIMounted check succeeded, mounted=%d", mounted]);
    
    if (mounted) {
        success = YES;
        goto cleanup;
    }
    
    logger(@"ensureDDIMounted: resolving ddiDirectoryURL");
    ddiDirectory = ddiDirectoryURL(error);
    if (!ddiDirectory) {
        logger(@"ensureDDIMounted: ddiDirectoryURL FAILED to resolve");
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: ddiDirectory resolved to %@", ddiDirectory.path]);
    
    logger(@"ensureDDIMounted: starting Image.dmg read");
    imageData = ddiFileData(ddiDirectory, @"Image.dmg", error);
    if (!imageData) {
        logger(@"ensureDDIMounted: Image.dmg read FAILED");
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: Image.dmg read succeeded, %lu bytes", (unsigned long)imageData.length]);
    
    logger(@"ensureDDIMounted: starting Image.dmg.trustcache read");
    trustCacheData = ddiFileData(ddiDirectory, @"Image.dmg.trustcache", error);
    if (!trustCacheData) {
        logger(@"ensureDDIMounted: Image.dmg.trustcache read FAILED");
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: trustcache read succeeded, %lu bytes", (unsigned long)trustCacheData.length]);
    
    logger(@"ensureDDIMounted: starting BuildManifest.plist read");
    buildManifestData = ddiFileData(ddiDirectory, @"BuildManifest.plist", error);
    if (!buildManifestData) {
        logger(@"ensureDDIMounted: BuildManifest.plist read FAILED");
        goto cleanup;
    }
    logger([NSString stringWithFormat:@"ensureDDIMounted: BuildManifest.plist read succeeded, %lu bytes", (unsigned long)buildManifestData.length]);
    
    logger(@"ensureDDIMounted: starting image_mounter_mount_personalized_rsd (the actual mount)");
    ffiError = image_mounter_mount_personalized_rsd(mounterClient, provider->adapter, provider->handshake, imageData.bytes, imageData.length, trustCacheData.bytes, trustCacheData.length, buildManifestData.bytes, buildManifestData.length, NULL, uniqueChipID);
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"ensureDDIMounted REAL failure at image_mounter_mount_personalized_rsd - code: %ld, sub_code: %ld, message: %@", (long)realCode, (long)realSubCode, realMessage]);
        if (error) *error = MakeError(ModernDDIMountFailed);
        idevice_error_free(ffiError);
        goto cleanup;
    }
    logger(@"ensureDDIMounted: image_mounter_mount_personalized_rsd succeeded - DDI mounted");
    
    success = YES;
    
cleanup:
    if (chipIDNode) plist_free(chipIDNode);
    if (mounterClient) image_mounter_free(mounterClient);
    if (lockdownClient) lockdownd_client_free(lockdownClient);
    return success;
}

// MARK: Endpoint Connectivity Monitoring

static NSMutableDictionary<NSNumber *, NSDictionary<NSString *, id> *> *monitoredEndpointsByPID(void) {
    static NSMutableDictionary<NSNumber *, NSDictionary<NSString *, id> *> *endpoints;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        endpoints = [NSMutableDictionary dictionary];
    });
    return endpoints;
}

static NSMutableDictionary<NSString *, NSNumber *> *endpointFailureCounts(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *failureCounts;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        failureCounts = [NSMutableDictionary dictionary];
    });
    return failureCounts;
}

static void stopEndpointMonitorLocked(void) {
    if (!endpointMonitorTimer) return;
    dispatch_source_cancel(endpointMonitorTimer);
    endpointMonitorTimer = nil;
}

static BOOL probeTCPEndpoint(NSString *targetAddress, uint16_t port, NSTimeInterval timeoutSeconds, int *errorCodeOut) {
    if (errorCodeOut) *errorCodeOut = 0;
    
    int socketFD = socket(AF_INET, SOCK_STREAM, 0);
    if (socketFD < 0) {
        if (errorCodeOut) *errorCodeOut = errno;
        return NO;
    }
    
    int noSigPipe = 1;
    setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    
    int noDelay = 1;
    setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay));
    
    int flags = fcntl(socketFD, F_GETFL, 0);
    if (flags < 0 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(socketFD);
        if (errorCodeOut) *errorCodeOut = errno;
        return NO;
    }
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    
    if (inet_pton(AF_INET, targetAddress.UTF8String, &address.sin_addr) != 1) {
        close(socketFD);
        if (errorCodeOut) *errorCodeOut = EINVAL;
        return NO;
    }
    
    int connectResult = connect(socketFD, (const struct sockaddr *)&address, sizeof(address));
    if (connectResult == 0) {
        close(socketFD);
        return YES;
    }
    
    if (errno != EINPROGRESS) {
        if (errorCodeOut) *errorCodeOut = errno;
        close(socketFD);
        return NO;
    }
    
    struct timeval timeoutValue;
    timeoutValue.tv_sec = (time_t)timeoutSeconds;
    timeoutValue.tv_usec = (suseconds_t)((timeoutSeconds - timeoutValue.tv_sec) * 1000000.0);
    
    fd_set writeSet;
    FD_ZERO(&writeSet);
    FD_SET(socketFD, &writeSet);
    
    int selectResult = select(socketFD + 1, NULL, &writeSet, NULL, &timeoutValue);
    if (selectResult <= 0) {
        if (errorCodeOut) *errorCodeOut = (selectResult == 0 ? ETIMEDOUT : errno);
        close(socketFD);
        return NO;
    }
    
    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);
    if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0) {
        if (errorCodeOut) *errorCodeOut = errno;
        close(socketFD);
        return NO;
    }
    
    close(socketFD);
    
    if (socketError != 0 && errorCodeOut) *errorCodeOut = socketError;
    return socketError == 0;
}

static NSDictionary<NSString *, id> *endpointEntryForKey(NSString *endpointKey, NSNumber **pidOut) {
    __block NSDictionary<NSString *, id> *matchedEntry = nil;
    __block NSNumber *matchedPID = nil;
    
    [monitoredEndpointsByPID()
     enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull pid, NSDictionary<NSString *, id> * _Nonnull entry, BOOL * _Nonnull stop) {
        NSString *candidateKey = entry[@"key"];
        if (![candidateKey isEqualToString:endpointKey]) return;
        matchedEntry = entry;
        matchedPID = pid;
        *stop = YES;
    }];
    
    if (pidOut) *pidOut = matchedPID;
    return matchedEntry;
}

static void postEndpointConnectivityFailure(NSNumber *pid, NSString *targetAddress, NSNumber *portNumber, NSError *error) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:4];
    if (pid) userInfo[@"pid"] = pid;
    if (targetAddress) userInfo[@"address"] = targetAddress;
    if (portNumber) userInfo[@"port"] = portNumber;
    if (error) userInfo[@"error"] = error;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"me-minh-ton.jit.endpoint-monitor-failed" object:nil userInfo:userInfo];
    });
}

static void performEndpointMonitorTick(void) {
    NSDictionary<NSNumber *, NSDictionary<NSString *, id> *> *entriesByPID = monitoredEndpointsByPID();
    if (entriesByPID.count == 0) {
        [endpointFailureCounts() removeAllObjects];
        endpointMonitorCursor = 0;
        stopEndpointMonitorLocked();
        return;
    }
    
    NSMutableOrderedSet<NSString *> *uniqueEndpointKeys = [NSMutableOrderedSet orderedSet];
    for (NSDictionary<NSString *, id> *entry in entriesByPID.allValues) {
        NSString *endpointKey = entry[@"key"];
        if (endpointKey.length > 0) [uniqueEndpointKeys addObject:endpointKey];
    }
    
    if (uniqueEndpointKeys.count == 0) return;
    if (endpointMonitorCursor >= uniqueEndpointKeys.count) endpointMonitorCursor = 0;
    
    NSString *endpointKey = uniqueEndpointKeys[endpointMonitorCursor];
    endpointMonitorCursor = (endpointMonitorCursor + 1) % uniqueEndpointKeys.count;
    
    NSNumber *samplePID = nil;
    NSDictionary<NSString *, id> *endpointEntry = endpointEntryForKey(endpointKey, &samplePID);
    NSString *targetAddress = endpointEntry[@"address"];
    NSNumber *portNumber = endpointEntry[@"port"];
    
    if (targetAddress.length == 0 || !portNumber) return;
    
    uint16_t port = (uint16_t)portNumber.unsignedShortValue;
    BOOL endpointHealthy = probeTCPEndpoint(targetAddress, port, 0.35, NULL);
    
    if (endpointHealthy) {
        [endpointFailureCounts() removeObjectForKey:endpointKey];
        return;
    }
    
    NSMutableDictionary<NSString *, NSNumber *> *failureCounts = endpointFailureCounts();
    NSUInteger failureCount = [failureCounts[endpointKey] unsignedIntegerValue] + 1;
    failureCounts[endpointKey] = @(failureCount);
    
    if (failureCount < 2) return;
    
    endpointFailureLatched = YES;
    stopEndpointMonitorLocked();
    
    NSError *connectivityError = MakeError(EndpointConnectivityLost);
    postEndpointConnectivityFailure(samplePID, targetAddress, portNumber, connectivityError);
}

static void startEndpointMonitorLocked(void) {
    if (endpointMonitorTimer || endpointFailureLatched) return;
    
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, endpointMonitorQueue());
    if (!timer) return;
    
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)NSEC_PER_SEC, NSEC_PER_MSEC * 100);
    dispatch_source_set_event_handler(timer, ^{
        performEndpointMonitorTick();
    });
    
    endpointMonitorTimer = timer;
    dispatch_resume(timer);
}

void registerJITEndpointForPID(int32_t pid, NSString *targetAddress, uint16_t port) {
    if (pid <= 0 || targetAddress.length == 0 || port == 0) return;
    
    dispatch_async(endpointMonitorQueue(), ^{
        NSString *endpointKey = [NSString stringWithFormat:@"%@:%u", targetAddress, port];
        monitoredEndpointsByPID()[@(pid)] = @{
            @"key": endpointKey,
            @"address": [targetAddress copy],
            @"port": @(port),
        };
        
        [endpointFailureCounts() removeObjectForKey:endpointKey];
        // Previously, once any single endpoint failure latched this
        // flag, the entire monitoring system stayed permanently
        // disabled for the rest of the app's session — every future
        // tab, including ones with a perfectly healthy connection,
        // silently lost this safety net for good. A genuinely new PID
        // registering here means a fresh JIT attachment just succeeded,
        // which deserves its own real chance at being monitored rather
        // than staying blocked by a past failure that may have been
        // specific to a since-closed tab's own, now-irrelevant
        // connection.
        endpointFailureLatched = NO;
        startEndpointMonitorLocked();
    });
}

void unregisterJITEndpointForPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_async(endpointMonitorQueue(), ^{
        [monitoredEndpointsByPID() removeObjectForKey:@(pid)];
        
        if (monitoredEndpointsByPID().count == 0) {
            [endpointFailureCounts() removeAllObjects];
            endpointMonitorCursor = 0;
            stopEndpointMonitorLocked();
        }
    });
}

void resetJITEndpointMonitor(void) {
    dispatch_sync(endpointMonitorQueue(), ^{
        [monitoredEndpointsByPID() removeAllObjects];
        [endpointFailureCounts() removeAllObjects];
        endpointMonitorCursor = 0;
        endpointFailureLatched = NO;
        stopEndpointMonitorLocked();
    });
}
