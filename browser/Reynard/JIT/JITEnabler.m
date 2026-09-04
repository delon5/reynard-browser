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
#include <pthread.h>
#include <mach/mach.h>
#include <execinfo.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

@interface JITEnabler ()

@property(nonatomic, assign) DeviceProvider *sharedProvider;
@property(nonatomic, strong) dispatch_queue_t providerQueue;
@property(nonatomic, assign) BOOL didEnsureDDIMounted;

// ADDED - see fix_retired_provider_freed.py's docstring.
// Providers the invalidate paths retired but deliberately did not
// free, boxed because DeviceProvider * is a raw C pointer. Touched
// only from inside providerQueue, exactly like sharedProvider, so
// it needs no lock of its own. Drained by closeSharedTunnel, which
// is the one place that has established nothing is still inside an
// FFI call holding these adapters.
@property(nonatomic, strong) NSMutableArray<NSValue *> *retiredProviders;

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

// ADDED - see fix_validate_vattach_response.py's docstring.
//
// sendDebugCommand answers YES for ANY reply the transport managed to
// deliver: JITSupport.m only fails on an IdeviceFfiError, so a NULL
// response and a GDB error packet both come back as success. vAttach was
// the one command in this file whose reply was never read -
// QStartNoAckMode logs its reply, QPassSignals compares it to "OK", and
// over in JITSupport.m both the register writes and the prepare-region
// replies check for "OK" - so a refused attach ran the whole success
// path and attachToProcess told the child TRUE. The child then enables
// its JIT backend and executes brk #0xf00d with nothing attached to
// service the trap.
//
// A successful vAttach returns a stop reply and nothing else: 'T' with a
// two-hex signal and semicolon-delimited fields, or the older bare 'S'.
// Both are uppercase on the wire, and this codebase already relies on
// that - packetSignal() in JITUtils.m requires hasPrefix:@"T".
//
// Deliberately conservative in the other direction. Only four shapes are
// treated as a refusal: an empty reply (packet unsupported), 'E' (the
// error packet, e.g. E08 when the target exited between spawn and
// attach, or when the ack-mode change just above desynced the stream),
// and 'W'/'X' (the target already exited - genuine stop replies, but
// runDebugService reads them as "target exited" and breaks out
// immediately, so there is nothing to attach to). Any other first byte -
// including 'O' console output, which read_response could in principle
// hand back ahead of the stop reply - is ACCEPTED and logged loudly
// rather than failing an attach that may well be fine.

// Longest reply this will put in a log line. A real T packet carries
// every register and runs to about a kilobyte; the first 96 characters
// are the signal, the thread and enough fields to identify it.
static const NSUInteger kVAttachReplyLogLimit = 96;

// Ack bytes and $...#xx framing are stripped by the idevice layer before
// this point - every other reader in this tree compares bare payloads
// ("OK", hasPrefix:@"W"). Stripped again here so a leftover '+', '-' or
// '$' can only ever widen what is accepted, never narrow it. nil-safe:
// a nil reply normalises to an empty string, which is a refusal.
static NSString *normalisedVAttachReply(NSString *reply) {
    NSString *trimmed = [reply stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger index = 0;
    while (index < trimmed.length) {
        unichar character = [trimmed characterAtIndex:index];
        if (character != '+' && character != '-' && character != '$') {
            break;
        }
        index++;
    }
    return [trimmed substringFromIndex:index] ?: @"";
}

// YES only for a genuine stop reply - attached, and the target is
// stopped waiting for us.
static BOOL vAttachReplyIsStopPacket(NSString *normalisedReply) {
    if (normalisedReply.length == 0) {
        return NO;
    }
    unichar first = [normalisedReply characterAtIndex:0];
    return first == 'T' || first == 'S';
}

// YES for the shapes that positively mean "not attached". Anything that
// is neither this nor a stop packet is unknown, and unknown is accepted.
static BOOL vAttachReplyIsRefusal(NSString *normalisedReply) {
    if (normalisedReply.length == 0) {
        return YES;
    }
    unichar first = [normalisedReply characterAtIndex:0];
    return first == 'E' || first == 'W' || first == 'X';
}

// Bounded and single-line, because a refusal is only diagnosable if the
// actual bytes reach the log. Printing "<stop packet>" for an E08 is
// exactly what kept this hidden.
static NSString *vAttachReplySummary(NSString *reply) {
    if (reply.length == 0) {
        return @"<no response>";
    }
    NSString *oneLine = [[reply stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
                         stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    if (oneLine.length > kVAttachReplyLogLimit) {
        oneLine = [[oneLine substringToIndex:kVAttachReplyLogLimit] stringByAppendingString:@"..."];
    }
    return [NSString stringWithFormat:@"\"%@\"", oneLine];
}

// DIAGNOSTIC - hung-thread backtrace capture, see
// fix_combined_tunnel_reuse_and_notify_instrumentation.py. Runs ON
// the stuck thread when signalled, so the frames it walks are that
// thread's own, including whatever the idevice library is parked in.
// Only async-signal-safe calls: backtrace() and backtrace_symbols_fd()
// do not allocate. backtrace_symbols() would, and is not used.
static int gJITHangBacktraceFD = -1;

static void jitHangBacktraceHandler(int signalNumber) {
    (void)signalNumber;
    if (gJITHangBacktraceFD == -1) {
        return;
    }
    void *frames[64];
    int frameCount = backtrace(frames, 64);
    const char *header = "\n=== JIT hang backtrace (captured on the stuck thread) ===\n";
    write(gJITHangBacktraceFD, header, strlen(header));
    backtrace_symbols_fd(frames, frameCount, gJITHangBacktraceFD);
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
        
        // ADDED - see fix_gate_native_log_and_backtrace.py's docstring.
        // The flags default to YES and are overwritten when
        // JITController pushes the preferences down at startup. If
        // anything touched JITEnabler.shared before that call, this
        // block would run with the defaults still in place and both
        // files would be written despite their toggles being off. That
        // failure is invisible without this line, and it distinguishes
        // "the gate is wrong" from "the push happened too late".
        logger([NSString stringWithFormat:@"diagnosticLogging: nativeLog=%@, hangBacktrace=%@ at JITEnabler init",
                ReynardIsIdeviceNativeLogEnabled() ? @"ON" : @"OFF",
                ReynardIsJITHangBacktraceEnabled() ? @"ON" : @"OFF"]);
        
        // nil when the toggle is off, so the existing guard below skips
        // the whole block - no new control flow needed.
        NSURL *logURL = ReynardIsIdeviceNativeLogEnabled()
            ? [documentDirs.firstObject URLByAppendingPathComponent:@"idevice_native_log.txt"]
            : nil;
        if (logURL) {
            const char *logPath = logURL.path.UTF8String;
            // File level is Info, NOT Trace. At Trace the idevice layer
            // prints the decoded pairing record, and the pairing
            // record's private_key bytes land verbatim in a file under
            // Documents that exists to be handed to someone for support.
            // Anyone holding that log can impersonate the pairing.
            //
            // Confirmed in a shared capture: `private_key": Data(` in
            // idevice_native_log.txt. The second argument is the FILE
            // level and it is ours to choose, so this is fixable here
            // even though the printing itself is submodule behaviour.
            //
            // Info keeps everything the log is actually read for - the
            // tunnel RST storms, RemoteServer exits, connection
            // lifecycle. What Trace added beyond that was per-packet
            // keep-alive noise and the pairing dump.
            enum IdeviceLoggerError loggerResult = idevice_init_logger(IdeviceLogInfo, IdeviceLogInfo, (char *)logPath);
            logger([NSString stringWithFormat:@"idevice_init_logger result: %d, writing to: %@", loggerResult, logURL.path]);
        }
        
        // Open the backtrace file and install the handler once, here,
        // outside any signal context - the handler itself must never
        // do either.
        // nil when the toggle is off. Note this also skips installing
        // the SIGUSR1 handler, so nothing can be captured even if a
        // probe fires - the toggle disables the mechanism, not just the
        // file, which is the intended behaviour.
        NSURL *backtraceURL = ReynardIsJITHangBacktraceEnabled()
            ? [documentDirs.firstObject URLByAppendingPathComponent:@"jit_hang_backtrace.txt"]
            : nil;
        if (backtraceURL) {
            gJITHangBacktraceFD = open(backtraceURL.path.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
            
            struct sigaction backtraceAction;
            memset(&backtraceAction, 0, sizeof(backtraceAction));
            backtraceAction.sa_handler = jitHangBacktraceHandler;
            sigemptyset(&backtraceAction.sa_mask);
            backtraceAction.sa_flags = SA_RESTART;
            sigaction(SIGUSR1, &backtraceAction, NULL);
            
            logger([NSString stringWithFormat:@"jit hang backtrace fd=%d, writing to: %@", gJITHangBacktraceFD, backtraceURL.path]);
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
        // ADDED - see fix_retired_provider_freed.py.
        _retiredProviders = [NSMutableArray array];
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
        
        // spawnRoot returns -errno when the helper could not be launched
        // at all - the only failures a copy-to-temp retry can help with.
        // 126/127 are kept for the shell convention ("found but not
        // executable" / "not found"). Positive child exit codes that
        // merely collide with errno values (a helper exiting 2 or 13)
        // no longer land here.
        if (result == -EACCES || result == -ENOENT || result == -ENOEXEC || result == 126 || result == 127) {
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
        // 128+N is spawnRoot's encoding for "killed by signal N" -
        // previously this read WEXITSTATUS of a signaled child, which is
        // undefined and usually 0, so a signal-killed helper could be
        // reported as success.
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
        
        // ADDED - @try/@finally wrapping from here through every exit
        // point of this function below - see
        // fix_free_orphaned_provider_safely.py's docstring. Ensures
        // the specific provider THIS call obtained gets safely freed
        // if (and only if) it's since been superseded by a newer one,
        // regardless of which return statement below is actually hit.
        @try {
        DebugSession session = {0};
        
        if (!connectDebugSession(provider, &session, @"10.7.0.1", pid, error)) {
            // A transport failure means this tunnel is dead, not that
            // this process is unattachable. Left cached it fails every
            // later attach in the same 1-3ms for the rest of the
            // session, which is the state a long suspension leaves
            // behind.
            NSInteger failureCode = error && *error ? (*error).code : 0;
            if (failureCode == RemoteServerConnectFailed ||
                failureCode == DebugProxyConnectFailed) {
                if ([self invalidateSharedProviderIfCurrent:provider]) {
                    logger([NSString stringWithFormat:
                        @"tunnelRecovery: (pid %d) transport failure %ld - dropped the cached provider, rebuilding and retrying now",
                        pid, (long)failureCode]);
                    // Retry immediately, once, against a rebuilt tunnel.
                    //
                    // Invalidating alone only helps the NEXT attach; this
                    // one still returns NO, and that failure becomes the
                    // "Failed to enable JIT / Error -9" screen - deferred
                    // by pendingFailureAction until didBecomeActive, so it
                    // is shown on RETURN from background even though the
                    // tunnel died during it. Backgrounding kills the
                    // tunnel every time, so a first-attach-after-resume
                    // failure is expected, recoverable, and already known
                    // to be recoverable at this exact point - reporting it
                    // to the user is simply wrong.
                    //
                    // One retry, not a loop: if the rebuilt tunnel fails
                    // too, the failure is real and belongs on screen.
                    NSError *retryError = nil;
                    DeviceProvider *rebuilt = [self getProviderForPID:pid error:&retryError];
                    if (rebuilt && connectDebugSession(rebuilt, &session, @"10.7.0.1", pid, error)) {
                        logger([NSString stringWithFormat:
                            @"tunnelRecovery: (pid %d) retry on the rebuilt tunnel SUCCEEDED", pid]);
                        provider = rebuilt;
                        goto sessionConnected;
                    }
                    logger([NSString stringWithFormat:
                        @"tunnelRecovery: (pid %d) retry on the rebuilt tunnel FAILED - reporting", pid]);
                } else {
                    // The provider was already replaced by whichever
                    // attach lost the race to report this same dead
                    // tunnel. Retry too - this branch is BETTER placed
                    // than the one above, because a good provider
                    // already exists and needs no rebuild.
                    //
                    // Without this, a resume with N processes attaching
                    // at once recovered exactly ONE of them: the first
                    // failure invalidated and retried, every other
                    // failure landed here and simply returned NO. The
                    // device log is unambiguous - 8158 SUCCEEDED while
                    // 8164 and 8149 returned success=NO code=-9 in the
                    // same millisecond - and that is what "losing JIT
                    // after sleep" actually was.
                    logger([NSString stringWithFormat:
                        @"tunnelRecovery: (pid %d) transport failure %ld against an already-replaced provider - retrying on it",
                        pid, (long)failureCode]);
                    NSError *retryError = nil;
                    DeviceProvider *current = [self getProviderForPID:pid error:&retryError];
                    if (current && connectDebugSession(current, &session, @"10.7.0.1", pid, error)) {
                        logger([NSString stringWithFormat:
                            @"tunnelRecovery: (pid %d) retry on the replacement tunnel SUCCEEDED", pid]);
                        provider = current;
                        goto sessionConnected;
                    }
                    logger([NSString stringWithFormat:
                        @"tunnelRecovery: (pid %d) retry on the replacement tunnel FAILED - reporting", pid]);
                }
            }
            return NO;
        }
        
    sessionConnected:
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
        // DIAGNOSTIC - thread-state probe, see
        // fix_combined_tunnel_reuse_and_notify_instrumentation.py.
        // Fires at +15s and +45s only if the ack phase below has not
        // finished, and reports what the OS says this exact thread is
        // doing while it is still stuck.
        mach_port_t ackThreadPort = pthread_mach_thread_np(pthread_self());
        pthread_t ackPthread = pthread_self();
        __block BOOL ackPhaseComplete = NO;
        dispatch_queue_t ackProbeQueue = dispatch_queue_create("com.minh-ton.Reynard.JITEnabler.AckProbe", DISPATCH_QUEUE_SERIAL);
        
        for (int probeDelaySeconds = 15; probeDelaySeconds <= 45; probeDelaySeconds += 30) {
            int delaySeconds = probeDelaySeconds;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delaySeconds * NSEC_PER_SEC), ackProbeQueue, ^{
                if (ackPhaseComplete) {
                    return;
                }
                
                struct thread_basic_info probeInfo;
                mach_msg_type_number_t probeInfoCount = THREAD_BASIC_INFO_COUNT;
                kern_return_t probeResult = thread_info(ackThreadPort, THREAD_BASIC_INFO, (thread_info_t)&probeInfo, &probeInfoCount);
                if (probeResult != KERN_SUCCESS) {
                    logger([NSString stringWithFormat:@"ackProbe: (pid %d) after %ds - thread_info failed, kr=%d", pid, delaySeconds, probeResult]);
                    return;
                }
                
                const char *runState = "UNKNOWN";
                switch (probeInfo.run_state) {
                    case TH_STATE_RUNNING: runState = "RUNNING"; break;
                    case TH_STATE_STOPPED: runState = "STOPPED"; break;
                    case TH_STATE_WAITING: runState = "WAITING"; break;
                    case TH_STATE_UNINTERRUPTIBLE: runState = "UNINTERRUPTIBLE"; break;
                    case TH_STATE_HALTED: runState = "HALTED"; break;
                    default: break;
                }
                
                logger([NSString stringWithFormat:@"ackProbe: (pid %d) after %ds - ack thread STILL IN FLIGHT, state=%s, cpu_usage=%d/1000, user=%d.%06ds, system=%d.%06ds, sleep_time=%d, suspend_count=%d",
                        pid, delaySeconds, runState, probeInfo.cpu_usage,
                        probeInfo.user_time.seconds, probeInfo.user_time.microseconds,
                        probeInfo.system_time.seconds, probeInfo.system_time.microseconds,
                        probeInfo.sleep_time, probeInfo.suspend_count]);
                
                if (gJITHangBacktraceFD != -1) {
                    logger([NSString stringWithFormat:@"ackProbe: (pid %d) after %ds - signalling the stuck thread for a backtrace into Documents/jit_hang_backtrace.txt", pid, delaySeconds]);
                    pthread_kill(ackPthread, SIGUSR1);
                }
            });
        }
        
        for (NSUInteger primingAckCount = 0; primingAckCount < 2; primingAckCount++) {
            // DIAGNOSTIC - see fix_log_priming_ack_progress.py's
            // docstring. Previously only the failure path logged
            // anything here, meaning a genuine hang inside
            // debug_proxy_send_ack itself produced zero output -
            // indistinguishable from this code never having run at
            // all. Start/success logging now makes that directly
            // visible either way.
            logger([NSString stringWithFormat:@"enableJITForPID: starting priming ack %lu for pid %d on thread %@", (unsigned long)primingAckCount, pid, [NSThread currentThread]]);
            IdeviceFfiError *primingAckError = debug_proxy_send_ack(session.debugProxy);
            if (primingAckError) {
                logger([NSString stringWithFormat:@"enableJITForPID: priming ack %lu FAILED for pid %d, error: %s", (unsigned long)primingAckCount, pid, primingAckError->message ?: "unknown error"]);
                idevice_error_free(primingAckError);
            } else {
                logger([NSString stringWithFormat:@"enableJITForPID: priming ack %lu succeeded for pid %d", (unsigned long)primingAckCount, pid]);
            }
        }
        
        // Serialised against the probes above on the same serial
        // queue - safe, and correctly never reached if an ack hangs.
        dispatch_sync(ackProbeQueue, ^{
            ackPhaseComplete = YES;
        });
        
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
        
        // Visible to interruptAttachingDebugSessions for exactly the
        // duration of the call - see
        // fix_interrupt_attaching_sessions.py. The target is stopped
        // throughout, and that is the window in which a lifecycle
        // transition kills the app.
        registerAttachingDebugSessionProxy(pid, session.debugProxy);
        
        BOOL attachSucceeded = sendDebugCommand(session.debugProxy, attachCommand, &attachResponse, &commandError);
        
        unregisterAttachingDebugSessionProxy(pid);
        [JITEnabler markVAttachFinished];
        CFAbsoluteTime attachCallEnd = CFAbsoluteTimeGetCurrent();
        if (!attachSucceeded) {
            logger([NSString stringWithFormat:@"enableJITForPID: attach command FAILED for pid %d, call took %.0fms, error: %@", pid, (attachCallEnd - attachCallStart) * 1000.0, commandError.localizedDescription ?: @"(no error set)"]);
            if (error) *error = commandError ?: MakeError(AttachDebugProxyFailed);
            freeDebugSession(&session);
            return NO;
        }
        
        // ADDED - see fix_validate_vattach_response.py's docstring.
        //
        // attachSucceeded above only means the transport delivered a
        // reply. This is where the reply is finally read.
        //
        // The refusal path is the one already twelve lines above, reused
        // verbatim: MakeError(AttachDebugProxyFailed), freeDebugSession,
        // return NO. No commandError exists here - sendDebugCommand
        // returned YES - so this is the `?:` half of that line. Returning
        // NO is what makes attachToProcess report FALSE, which the child
        // needs promptly: its WaitForJITReadySignal is one-shot with a
        // 5000ms budget and permanently disables the JIT backend on
        // timeout, so a hang here is worse than a clean FALSE.
        NSString *normalisedAttachReply = normalisedVAttachReply(attachResponse);
        if (!vAttachReplyIsStopPacket(normalisedAttachReply)) {
            if (vAttachReplyIsRefusal(normalisedAttachReply)) {
                logger([NSString stringWithFormat:@"vAttachReject: (pid %d) attach REFUSED - reply %@ is not a stop packet, call took %.0fms; reporting failure rather than arming a debugger-less JIT backend", pid, vAttachReplySummary(attachResponse), (attachCallEnd - attachCallStart) * 1000.0]);
                if (error) *error = MakeError(AttachDebugProxyFailed);
                freeDebugSession(&session);
                return NO;
            }
        
            // Not a stop packet, but not positively a refusal either.
            // Accepted on purpose - rejecting a working attach would be
            // the worse bug - and named in the log so the bytes come back.
            logger([NSString stringWithFormat:@"vAttachReject: (pid %d) attach reply %@ is neither a stop packet nor a refusal - accepting it, call took %.0fms", pid, vAttachReplySummary(attachResponse), (attachCallEnd - attachCallStart) * 1000.0]);
        }
        
        // CHANGED - was `attachResponse.length > 0 ? @"<stop packet>" :
        // @"<no response>"`, which printed "<stop packet>" for an E08.
        logger([NSString stringWithFormat:@"Attach response for pid %d: %@ (call took %.0fms)", pid, vAttachReplySummary(attachResponse), (attachCallEnd - attachCallStart) * 1000.0]);
        
        // ADDED - see fix_pass_fault_signals_through.py's docstring.
        //
        // Sent once, immediately after the attach, before any continue.
        // 0x0a is SIGBUS and 0x0b is SIGSEGV - the two an EXC_BAD_ACCESS
        // arrives as. It tells debugserver to deliver them to the child
        // and keep it RUNNING instead of stopping it and waiting for us.
        //
        // Not a behaviour change in the normal case: the non-breakpoint
        // branch already answers these with vCont;S<sig>, which is step
        // DELIVERING that signal, so the child's own handler runs either
        // way. What this removes is the stop, the round trip, and - the
        // reason it is here - the dependency on this app being alive and
        // connected at the instant the child faults.
        //
        // A child stopped by a fault while the app is suspended is
        // stopped for good: the tunnel dies during the suspension
        // (measured, 45s background, 5 sockets NotConnected), the detach
        // never lands, and debugserver is torn down without lifting the
        // stop. That child cannot answer the synchronous XPC on the next
        // foreground, and the watchdog takes the app for it. 2026-08-14
        // 07:02, pid 21688, frozen 230s with five healthy siblings and
        // zero debug sessions registered.
        //
        // SIGTRAP is deliberately absent. That is brk #0xf00d, and the
        // W^X mediation needs it to keep stopping the target.
        //
        // Unsupported is safe AND expected. QPassSignals is a gdbserver
        // packet; Apple's debugserver does not implement it and answers
        // an unknown Q packet with an empty response. This is still
        // asked because a stub that DOES support it would save a round
        // trip per fault, and the answer costs one packet at attach.
        //
        // The empty answer is not a missing capability, and the line
        // this used to print - "faults will still stop this process" -
        // read like one. It cost real time: that line was taken as the
        // root cause of both a Reddit tab that would not paint and a
        // 0x8BADF00D watchdog kill, and it is neither.
        //
        // Faults ARE delivered, by the other mechanism. A stop that is
        // not our brk #0xf00d is resumed with vCont;S<sig> in
        // runDebugService, which continues the target AND delivers the
        // signal, so the process's own handler runs. QPassSignals would
        // only avoid the stop-and-resume round trip, not enable the
        // delivery.
        //
        // What does leave a process stopped for good is a transport that
        // dies while it is stopped - there is then nothing to resume it
        // over. That is a different fault with a different fix; see
        // killStoppedChildren.
        {
            NSString *passSignalsResponse = nil;
            NSError *passSignalsError = nil;
            if (sendDebugCommand(session.debugProxy, @"QPassSignals:0a;0b;", &passSignalsResponse, &passSignalsError)) {
                if ([passSignalsResponse isEqualToString:@"OK"]) {
                    logger([NSString stringWithFormat:@"jitPassSignals: (pid %d) QPassSignals accepted - faults pass through without a stop", pid]);
                } else {
                    logger([NSString stringWithFormat:@"jitPassSignals: (pid %d) QPassSignals not implemented by debugserver (response %@) - expected; faults are delivered by vCont;S instead, one round trip each", pid, passSignalsResponse.length > 0 ? passSignalsResponse : @"<empty>"]);
                }
            } else {
                logger([NSString stringWithFormat:@"jitPassSignals: (pid %d) QPassSignals send FAILED: %@", pid, passSignalsError.localizedDescription ?: @"(no error set)"]);
            }
        }
        
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
        } @finally {
            // Safe to free THIS call's own, specific provider pointer
            // if and only if it's no longer the current
            // self.sharedProvider - meaning a newer attempt has
            // already invalidated-and-replaced it since this call
            // started, confirming nothing else still reaches for this
            // exact, old pointer. Relies on the global, whole-call
            // guard (fix_global_enablejit_guard_and_extended_wait.py)
            // to guarantee only one enableJITForPID: call is ever
            // genuinely in flight at a time - without that guarantee,
            // a second, concurrent call could still be legitimately
            // using this same provider even after a third one
            // supersedes it, which this check alone couldn't detect.
            // CHANGED - no longer frees. See
            // fix_provider_use_after_free.py.
            //
            // The comment above states the precondition: this free is
            // only safe while a global in-flight guard guarantees one
            // enableJITForPID: call at a time. That guard is now
            // per-pid, so concurrent attaches share this provider and
            // one could free a pointer another is still using -
            // observed as EXC_BAD_ACCESS on ProviderQueue at address
            // 0x7466654c, the ASCII bytes "Left".
            //
            // invalidateSharedProviderAfterTimeout below already makes
            // exactly this trade for exactly this reason: "a small,
            // bounded memory leak (one DeviceProvider struct) ... in
            // exchange for guaranteed safety - preferred over risking a
            // crash to save that memory."
            dispatch_sync(self.providerQueue, ^{
                if (self.sharedProvider != provider) {
                    logger([NSString stringWithFormat:@"enableJITForPID: (pid %d) provider was superseded during this call - leaking it deliberately, another concurrent attach may still hold it", pid]);
                }
            });
        }
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
    //
    // CHANGED - see fix_debuggee_self_reports_cs_debugged.py's
    // docstring. Now reports kernel ground truth: pids that the
    // debuggee itself confirmed carry CS_DEBUGGED, via csops(getpid())
    // from inside the Helper where that call is actually permitted.
    // Previously reported hasAnyActiveJITSessionAcrossProcesses, which
    // is the main app's own bookkeeping and was observed reading
    // "Not Acquired" while eleven runDebugService loops were live.
    return hasAnyDebuggedJITSessionAcrossProcesses();
}

// Thin forwarder so Swift can reach the C function in JITSupport.h,
// which is not in the bridging header. See
// fix_expose_detach_to_swift.py.
+ (void)requestDetachForAllDebugSessions {
    requestDetachForAllDebugSessions();
}

+ (void)clearDebuggerTeardownRequest {
    clearDebuggerTeardownRequest();
}

+ (BOOL)isDebuggerTeardownRequested {
    return debuggerTeardownRequested();
}

+ (void)cancelAllDebugSessionCalls {
    cancelAllDebugSessionCalls();
}

+ (void)interruptLiveDebugSessions {
    interruptLiveDebugSessions();
}

+ (void)dumpDebugLoopState {
    dumpDebugLoopState();
}

+ (void)dumpDebugLoopStateLabelled:(NSString *)label {
    dumpDebugLoopStateLabelled(label.UTF8String);
}

+ (void)recordChildForHeartbeat:(int32_t)pid type:(NSString *)processType {
    recordChildForHeartbeat(pid, processType);
}

+ (void)dumpChildHeartbeatsLabelled:(NSString *)label {
    dumpChildHeartbeats(label.UTF8String);
}

+ (int)killStoppedChildren {
    return killStoppedChildren();
}

+ (void)setDebuggerListening:(BOOL)listening {
    setDebuggerListeningState(listening ? 1 : 0);
}

+ (NSString *)runStateForPID:(int32_t)pid {
    return childProcessRunState(pid);
}

+ (void)interruptAttachingDebugSessions {
    interruptAttachingDebugSessions();
}

+ (BOOL)hasActiveDebugSessionForPID:(int32_t)pid {
    return hasActiveDebugSessionForPID(pid);
}

// ADDED - see fix_tunnel_close_waits_for_debug_loops.py's docstring.
// Another thin forwarder, for closeTunnelForSuspension's fourth gate.
+ (NSUInteger)liveDebugSessionCount {
    return liveDebugSessionCount();
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
        // CHANGED - still does not free here, for every reason the
        // comment above gives, but no longer drops the pointer
        // either. It is retired instead, and closeSharedTunnel frees
        // it once the gates establish nothing can still be inside
        // its adapter. See fix_retired_provider_freed.py.
        if (self.sharedProvider) {
            [self.retiredProviders addObject:[NSValue valueWithPointer:self.sharedProvider]];
            logger([NSString stringWithFormat:@"tunnelRetire: timeout invalidated the cached provider - retired, %lu now waiting for a tunnel close", (unsigned long)self.retiredProviders.count]);
        }
        self.sharedProvider = NULL;
        self.didEnsureDDIMounted = NO;
    });
}

// Invalidates only if the caller's provider is still the cached one.
//
// When the tunnel dies, every content process attaching at that moment
// fails against the same provider. Without this check the first failure
// invalidates, the next attach rebuilds, and the remaining failures -
// which happened against the OLD provider and know nothing of the new
// one - throw the rebuild away too.
//
// Runs inside providerQueue, like invalidateSharedProviderAfterTimeout,
// so the comparison and the clear cannot race a concurrent
// getProviderForPID. Also inherits its deliberate refusal to call
// freeDeviceProvider: an orphaned background call may still be inside
// an FFI call holding this exact pointer.
- (BOOL)invalidateSharedProviderIfCurrent:(DeviceProvider *)provider {
    __block BOOL invalidated = NO;
    dispatch_sync(self.providerQueue, ^{
        if (provider && self.sharedProvider == provider) {
            // CHANGED - retire rather than drop, so the pointer
            // survives to be freed by closeSharedTunnel. Still not
            // freed here. See fix_retired_provider_freed.py.
            [self.retiredProviders addObject:[NSValue valueWithPointer:provider]];
            logger([NSString stringWithFormat:@"tunnelRetire: transport failure invalidated the cached provider - retired, %lu now waiting for a tunnel close", (unsigned long)self.retiredProviders.count]);
            self.sharedProvider = NULL;
            self.didEnsureDDIMounted = NO;
            invalidated = YES;
        }
    });
    return invalidated;
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

// ADDED - see fix_foreground_scoped_jit_transport.py.
//
// The only caller is the background teardown, and only after it has
// established that no attach is in flight, no orphaned call is
// outstanding, and no vAttach is running - so nothing can still be
// inside an FFI call holding this adapter. That is the whole difference
// from invalidateSharedProviderAfterTimeout, which cannot know any of
// those things and therefore must not free.
//
// dispatch_async rather than sync: providerQueue can be occupied by a
// createDeviceProvider for many seconds, and the caller is a lifecycle
// path that must not block on it.
- (void)closeSharedTunnel {
    dispatch_async(self.providerQueue, ^{
        // ADDED - drain the retired providers. See
        // fix_retired_provider_freed.py. Deliberately ahead of the
        // "nothing to close" return below: the usual shape is a
        // tunnel that already died, so sharedProvider is NULL by the
        // time we get here and the retired list is the only thing
        // left holding an adapter. Draining after that return would
        // free nothing in exactly the case that leaks.
        //
        // Safe here and only here for the reason in the comment
        // above: this method runs only once closeTunnelForSuspension
        // has read attachInFlightCount, orphanedAttachCount and
        // vAttachInFlightSince all clear, which is what rules out an
        // orphaned call still being inside one of these adapters.
        NSUInteger retiredCount = self.retiredProviders.count;
        for (NSValue *boxedProvider in self.retiredProviders) {
            freeDeviceProvider((DeviceProvider *)boxedProvider.pointerValue);
        }
        [self.retiredProviders removeAllObjects];
        if (retiredCount > 0) {
            logger([NSString stringWithFormat:@"tunnelClose: freed %lu retired provider(s) - their adapters and sockets to the pairing endpoint are released", (unsigned long)retiredCount]);
        }

        DeviceProvider *doomed = self.sharedProvider;
        if (!doomed) {
            logger(@"tunnelClose: nothing to close - no shared tunnel");
            return;
        }
        self.sharedProvider = NULL;
        self.didEnsureDDIMounted = NO;
        freeDeviceProvider(doomed);
        logger(@"tunnelClose: shared tunnel closed, adapter freed - the socket to the pairing endpoint is released");
    });
}

// ADDED - see fix_prewarm_checks_foreground.py's docstring.
//
// A copy of JITController.isApplicationActiveFromAnyQueue, not a second
// opinion about it: setApplicationActiveMirror is the only writer of
// that flag and it pushes every write through here. Nothing in this
// file can read the Swift property directly - JITEnabler.m compiles
// into the Reynard Helper target too, and Reynard-Swift.h is not
// available there. The ptrace_jit temp-path fallback above hit the
// same wall.
//
// A serial queue rather than a lock, to match vAttachStateQueue.
// Starts YES: the Helper never writes it and never calls the prewarm,
// and in the app sceneWillResignActive writes it on the main thread
// well before any background teardown runs.
static dispatch_queue_t applicationForegroundStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITEnabler.ForegroundStateQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL sApplicationForeground = YES;

+ (void)setApplicationForeground:(BOOL)foreground {
    dispatch_sync(applicationForegroundStateQueue(), ^{
        sApplicationForeground = foreground;
    });
}

static BOOL applicationForegroundFromAnyQueue(void) {
    __block BOOL foreground = YES;
    dispatch_sync(applicationForegroundStateQueue(), ^{
        foreground = sApplicationForeground;
    });
    return foreground;
}

// ADDED - fix_foreground_scoped_jit_transport.py. Deliberately routed
// through getProviderForPID: rather than calling createDeviceProvider
// directly, so the DDI mount and the caching behave exactly as they do
// for a real attach. pid 0 is not a process, it is a label for this
// call in the getProvider logs.
- (void)prewarmSharedTunnel {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // ADDED - see fix_prewarm_checks_foreground.py's docstring.
        //
        // This block captures nothing, re-checks nothing, and is the
        // only creator of a tunnel that closeTunnelForSuspension's
        // three gates cannot see - they guard a free, not a create. So
        // the foreground it was queued in has to be re-established
        // where it actually runs, or a backgrounding between the two
        // leaves a fresh socket open across the suspension with
        // nothing left to close it.
        if (!applicationForegroundFromAnyQueue()) {
            logger(@"tunnelPrewarm: SKIPPED - app left the foreground while this was queued, not building a tunnel into a suspension");
            return;
        }
        NSError *prewarmError = nil;
        DeviceProvider *provider = [self getProviderForPID:0 error:&prewarmError];
        logger([NSString stringWithFormat:@"tunnelPrewarm: %@ at foreground%@",
                provider ? @"tunnel ready" : @"FAILED",
                provider ? @"" : [NSString stringWithFormat:@" - %@", prewarmError.localizedDescription ?: @"(no error set)"]]);
    });
}

// The recovery counterpart to prewarm: same build attempt, same
// utility queue, same left-the-foreground guard - but the caller
// learns the outcome, which prewarm's fire-and-forget shape cannot
// provide. JITController's JIT-less recovery probe is the intended
// caller: it needs "did a provider come back" as a fact it can
// un-latch on. See fix_jitless_recovers_when_tunnel_returns.py.
- (void)probeSharedTunnelWithCompletion:(void (^)(BOOL available))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!applicationForegroundFromAnyQueue()) {
            logger(@"tunnelProbe: app left the foreground while this was queued - reporting unavailable");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
            });
            return;
        }
        NSError *probeError = nil;
        DeviceProvider *provider = [self getProviderForPID:0 error:&probeError];
        logger([NSString stringWithFormat:@"tunnelProbe: %@%@",
                provider ? @"tunnel available" : @"tunnel unavailable",
                provider ? @"" : [NSString stringWithFormat:@" - %@", probeError.localizedDescription ?: @"(no error set)"]]);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(provider != NULL);
        });
    });
}

- (void)dealloc {
    resetJITEndpointMonitor();
    // ADDED - see fix_retired_provider_freed.py. Unreachable in
    // practice, since JITEnabler is a dispatch_once singleton; kept
    // so the retired list is freed in both places sharedProvider is.
    // Direct ivar access with no queue hop, matching the existing
    // free below - dealloc means nothing else holds a reference.
    for (NSValue *boxedProvider in _retiredProviders) {
        freeDeviceProvider((DeviceProvider *)boxedProvider.pointerValue);
    }
    [_retiredProviders removeAllObjects];
    if (_sharedProvider) {
        freeDeviceProvider(_sharedProvider);
        _sharedProvider = NULL;
    }
}

@end
