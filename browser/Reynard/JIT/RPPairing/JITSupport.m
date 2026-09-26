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

// For childProcessRunState - see fix_report_child_run_state.py.
#import <sys/sysctl.h>
// sysctl only. The Reynard Helper target compiles this file and has
// neither libproc.h nor sys/proc_info.h on its header search path, so the
// proc_pidinfo cross-check is not available here. KERN_PROC_PID answers
// the same question - p_stat, and SSTOP is the value that matters.

#include <arpa/inet.h>
#include <notify.h>

// From libxul (toolkit/xre/IOSBootstrap.mm): the per-launch secret both
// listening keys carry - see fix_jit_listening_keys_carry_a_secret.py.
extern const char *JITListeningSecret(void);
#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <sys/file.h>
#include <signal.h>
#include <string.h>
// ADDED - fix_retry_tunnel_create.py, for the teardown generation
// counter the tunnel retry loop polls.
#include <stdatomic.h>

static const uint16_t rppairingPort = 49152;

// CHANGED - fix_delete_dead_transport_code.py dropped heartbeatClient
// and heartbeatRunning. Nothing in the tree ever assigned the former a
// non-NULL value; the latter was only read by a startHeartbeat block
// that had no caller, and only cleared by freeDeviceProvider one line
// before it free()d the struct the block was still polling.
struct DeviceProvider {
    AdapterHandle *adapter;
    RsdHandshakeHandle *handshake;
};

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

// ADDED - see fix_foreground_clear_releases_only_background_pids.py.
//
// The subset of detachRequestedDebugSessionPIDs that a BACKGROUND
// teardown put there and that was not already requested when it did.
// clearDebuggerTeardownRequest releases exactly these on a foreground.
// A pid JIT-less mode asked to detach (JITEnabler.m's
// detachAllJITSessions, which never sets the sticky BOOL) is not here
// and stays requested until its loop drains, which is what that
// request means. Same queue as its parent set: only ever touched on
// debugSessionStateQueue.
static NSMutableSet<NSNumber *> *backgroundDetachRequestedPIDs(void) {
    static NSMutableSet<NSNumber *> *pids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pids = [NSMutableSet set];
    });
    return pids;
}

// Sticky counterpart to detachRequestedDebugSessionPIDs, which can only
// ever name the pids that were already attached when the teardown ran.
// An attach still in flight at that moment completes afterwards and is
// in no such set, so without this it starts a loop, re-arms trapping and
// keeps running in the background.
//
// Only ever touched on debugSessionStateQueue().
static BOOL sDebuggerTeardownRequested = NO;

// ADDED - see fix_retry_tunnel_create.py.
//
// Bumped once per background teardown, SYNCHRONOUSLY at the top of
// requestDetachForAllDebugSessions - deliberately not inside its
// dispatch_async, because debugSessionStateQueue is the busiest queue in
// the process and a delayed bump is a delayed abort.
//
// Read only by the tunnel retry loop, which captures it on entry and
// gives up if it changes. That is the exact hazard: closeSharedTunnel is
// dispatch_async onto providerQueue, so a retry still running when the
// app backgrounds holds the tunnel close past the ~3.6s suspension
// window fix_close_before_suspension.py exists to fit inside.
//
// A generation rather than a boolean on purpose. A call that STARTS
// during a teardown is harmless - the tunnel is already closed and
// nothing is queued behind it - and that is the hang-recovery case,
// which has to be allowed to retry. Only a call that starts and then
// sees a background is dangerous.
static atomic_uint sTunnelTeardownGeneration = 0;

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

// Whether pid is still running, judged the way a sandboxed app has to
// judge its own content-process extensions.
//
// The C counterpart of JITController.pidIsAlive - see
// fix_reattach_treats_eperm_as_alive.py. kill(pid, 0) sends no signal;
// it runs the error checks and reports what a real signal would have
// found. A content process is an app extension in a different
// coalition and the app may not signal it, so for a LIVE child the
// call returns -1 with errno == EPERM. Only ESRCH means the pid is
// genuinely gone.
//
// fb0ee00 fixed the `== 0` test in JITController.swift and left this
// one, so every reader below still pruned live sessions as dead. It
// was masked rather than harmless: hasAnyDebuggedJITSessionAcrossProcesses
// returns early on the debuggedAcquisitionTimestamp fast path in the
// success case, so the under-count rarely surfaced.
static BOOL pidIsAlive(pid_t pid) {
    if (kill(pid, 0) == 0) {
        return YES;
    }
    // errno still refers to the kill above - nothing has run since.
    return errno == EPERM;
}

// Reads the shared file, returns only entries whose PID is still
// genuinely alive right now - no signal sent, just whether a process
// with this PID currently exists. Not a time-based expiry deliberately
// - a JIT session can legitimately run for a tab's entire lifetime, so
// a fixed short window would incorrectly age out a genuinely active
// one. This handles a crashed or force-killed process's stale entry
// without needing that process to have cooperated. PID reuse is a
// rare, brief-window edge case not worth guarding against for an
// informational display row.
static NSArray<NSNumber *> *readLiveJITSessionPIDs(int fd) {
    NSMutableArray<NSNumber *> *live = [NSMutableArray array];
    off_t fileSize = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    if (fileSize > 0 && fileSize < (1024 * 1024)) {
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)fileSize];
        // Exactly the bytes read, and nothing on a failed read - see
        // fix_jit_session_pid_file_io_checked.py. A short read left the
        // tail of the buffer zeroed and could cut a line in two.
        ssize_t got = read(fd, data.mutableBytes, (size_t)fileSize);
        if (got <= 0) {
            return live;
        }
        data.length = (NSUInteger)got;
        NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length == 0) continue;
            NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
            if (parts.count < 1) continue;
            int32_t pid = (int32_t)[parts[0] intValue];
            if (pid <= 0) continue;
            if (pidIsAlive((pid_t)pid)) {
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
    // All of it or none of it - see fix_jit_session_pid_file_io_checked.py.
    // A short write left a clipped last line for the next reader.
    const uint8_t *bytes = newData.bytes;
    NSUInteger written = 0;
    while (written < newData.length) {
        ssize_t n = write(fd, bytes + written, newData.length - written);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            ftruncate(fd, 0);
            return;
        }
        written += (NSUInteger)n;
    }
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

// ADDED - see fix_jit_acquisition_csops_verification.py's docstring.
// Kernel ground truth for whether a process is actually debugged,
// which is the hard precondition for JIT. Mirrors DolphiniOS's
// checkIfProcessIsDebugged (JitManager+Debugger.m), except that this
// passes sizeof(flags) correctly - DolphiniOS writes
// `sizeof(flags) != 0`, which evaluates to 1.
//
// Deliberately takes a pid rather than using getpid(): DolphiniOS can
// check itself because it IS the debuggee, whereas Reynard's main app
// is the DEBUGGER and never attaches to itself. The processes that
// matter are the Helper content processes.
#define REYNARD_CS_OPS_STATUS 0
#define REYNARD_CS_DEBUGGED 0x10000000

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

// ADDED - see fix_report_child_run_state.py's docstring.
//
// Two independent routes to the same field, because a cross-process query
// under the app sandbox may simply be refused - csops already returns
// EPERM here eight times out of eight - and finding that out for one of
// them should not cost the answer from the other. Both results are
// reported, with errno when they fail, so one capture settles which (if
// either) is usable.
static NSString *runStateName(int stat) {
    switch (stat) {
        case SIDL:   return @"IDL";
        case SRUN:   return @"RUN";
        case SSLEEP: return @"SLEEP";
        case SSTOP:  return @"STOP";
        case SZOMB:  return @"ZOMB";
        default:     return [NSString stringWithFormat:@"?%d", stat];
    }
}

NSString *childProcessRunState(int32_t pid) {
    if (pid <= 0) return @"n/a";

    NSString *viaSysctl = nil;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t length = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &length, NULL, 0) == 0 && length > 0) {
        viaSysctl = runStateName(info.kp_proc.p_stat);
    } else {
        viaSysctl = [NSString stringWithFormat:@"sysctl:e%d", errno];
    }

    // One route rather than two - see the include note above. errno is
    // carried in the string on failure, so a sandbox refusal is visible
    // rather than silently reading as "not stopped".
    return viaSysctl;
}

BOOL processIsDebugged(int32_t pid) {
    if (pid <= 0) return NO;

    int flags = 0;
    if (csops((pid_t)pid, REYNARD_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        // Logged with errno so a permission refusal is
        // distinguishable from a genuine "not debugged" - csops on
        // another pid is permitted for a same-uid process, which same-app
        // extensions are, but that is worth confirming rather than
        // assuming.
        logger([NSString stringWithFormat:@"processIsDebugged: csops failed for pid %d, errno=%d (%s)", pid, errno, strerror(errno)]);
        return NO;
    }

    return (flags & REYNARD_CS_DEBUGGED) != 0;
}

// ADDED - see fix_debuggee_self_reports_cs_debugged.py's docstring.
// Separate from active-jit-sessions.txt on purpose: that file is
// written by the main app on its own say-so and cannot verify
// anything, whereas this one only ever contains pids the KERNEL has
// confirmed carry CS_DEBUGGED.
static NSURL *debuggedJITSessionsFileURL(void) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) {
        return nil;
    }
    return [containerURL URLByAppendingPathComponent:@"debugged-jit-sessions.txt" isDirectory:NO];
}

// Records this process's own pid as kernel-confirmed debugged. Called
// only from inside the debuggee, because csops() on another process is
// refused with EPERM under the app sandbox.
// ADDED - see fix_jit_acquisition_sticky_marker.py's docstring.
// Captured in a constructor so it is set before any JIT work runs,
// which is what makes the session comparison below sound.
static NSTimeInterval gReynardProcessStartTime = 0;

__attribute__((constructor))
static void ReynardRecordProcessStartTime(void) {
    gReynardProcessStartTime = [NSDate date].timeIntervalSince1970;
}

// A small marker recording WHEN some process last confirmed
// CS_DEBUGGED. The pid list alone cannot answer "did acquisition
// succeed" because content processes are transient and prune out of it
// within seconds, which is why the row read "Not Acquired" while four
// Helpers had just confirmed.
static NSURL *debuggedAcquisitionMarkerURL(void) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) {
        return nil;
    }
    return [containerURL URLByAppendingPathComponent:@"jit-acquired-at.txt" isDirectory:NO];
}

// Best-effort and deliberately unlocked: one small file, written
// rarely, last-write-wins is correct, and a torn read just fails the
// parse and falls back to the pid check.
static void recordDebuggedAcquisitionTimestamp(void) {
    NSURL *fileURL = debuggedAcquisitionMarkerURL();
    if (!fileURL) return;

    NSString *stamp = [NSString stringWithFormat:@"%f", [NSDate date].timeIntervalSince1970];
    [stamp writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static NSTimeInterval debuggedAcquisitionTimestamp(void) {
    NSURL *fileURL = debuggedAcquisitionMarkerURL();
    if (!fileURL) return 0;

    NSString *stamp = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:NULL];
    if (stamp.length == 0) return 0;

    return stamp.doubleValue;
}

static void addSelfToDebuggedSessions(void) {
    NSURL *fileURL = debuggedJITSessionsFileURL();
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
    NSNumber *selfPID = @(getpid());
    if (![live containsObject:selfPID]) {
        [live addObject:selfPID];
    }
    writeJITSessionPIDs(fd, live);

    flock(fd, LOCK_UN);
    close(fd);

    // Survives this pid being reaped, which the list above does not.
    recordDebuggedAcquisitionTimestamp();
}

BOOL hasAnyDebuggedJITSessionAcrossProcesses(void) {
    // ADDED - the cheap check first. See
    // fix_jit_acquisition_avoids_main_thread_lock.py.
    //
    // This is called from JITSettingsSection on the MAIN THREAD while
    // building a cell, and the PID path below spins on flock for up to
    // half a second. Content processes take that same lock whenever
    // they record themselves as CS_DEBUGGED, so several starting at
    // once could stall the Settings screen for the full deadline.
    //
    // The marker is read without any lock - one small file,
    // deliberately unlocked, last-write-wins - and it alone answers
    // what this row asks: did acquisition succeed this session. So
    // whenever JIT is working, which is also the only time the lock
    // below is contended, this returns without opening the locked file
    // at all.
    NSTimeInterval markerTimestamp = debuggedAcquisitionTimestamp();
    if (markerTimestamp > 0 && markerTimestamp >= gReynardProcessStartTime) {
        return YES;
    }

    NSURL *fileURL = debuggedJITSessionsFileURL();
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

    // Reading also prunes: readLiveJITSessionPIDs drops any pid whose
    // process no longer exists (kill(pid, 0)), so a Helper that has
    // exited needs no explicit cleanup.
    NSArray<NSNumber *> *live = readLiveJITSessionPIDs(fd);
    writeJITSessionPIDs(fd, live);

    flock(fd, LOCK_UN);
    close(fd);

    if (live.count > 0) {
        logger([NSString stringWithFormat:@"hasAnyDebuggedJITSessionAcrossProcesses: %lu kernel-confirmed debugged process(es) currently alive", (unsigned long)live.count]);
        return YES;
    }

    // CHANGED - was `return live.count > 0`, which made the row mean
    // "are there live debugged processes at this instant". Content
    // processes are transient, so they prune out of the list within
    // seconds and the row read "Not Acquired" while acquisition had in
    // fact succeeded - four Helpers confirming CS_DEBUGGED moments
    // earlier. DolphiniOS's equivalent row reports whether acquisition
    // SUCCEEDED, which is what the label claims, so this falls back to
    // the timestamp marker.
    //
    // Scoped to this app session rather than an arbitrary staleness
    // window, so a previous launch can never report success - the same
    // scoping DolphiniOS gets for free by checking its own getpid().
    NSTimeInterval acquiredAt = debuggedAcquisitionTimestamp();
    BOOL acquiredThisSession = acquiredAt > 0 && acquiredAt >= gReynardProcessStartTime;

    logger([NSString stringWithFormat:@"hasAnyDebuggedJITSessionAcrossProcesses: no live debugged process; marker=%.0f, processStart=%.0f, acquiredThisSession=%@", acquiredAt, gReynardProcessStartTime, acquiredThisSession ? @"YES" : @"NO"]);

    return acquiredThisSession;
}

// Polls rather than checking once: CS_DEBUGGED only appears after the
// main app's attach completes, which device logs show landing 1-4
// seconds after process start and later still under queue load. A
// single check at load time would always read false.
static void scheduleSelfDebuggedCheck(int attemptsRemaining) {
    if (attemptsRemaining <= 0) {
        logger([NSString stringWithFormat:@"selfDebuggedCheck: pid %d never became CS_DEBUGGED - giving up", getpid()]);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (processIsDebugged(getpid())) {
            addSelfToDebuggedSessions();
            logger([NSString stringWithFormat:@"selfDebuggedCheck: pid %d IS CS_DEBUGGED - recorded in the App Group", getpid()]);
            return;
        }
        scheduleSelfDebuggedCheck(attemptsRemaining - 1);
    });
}

// The "Runs in every process ... Gated to the Helper extension" note
// that stood here has MOVED onto ReynardStartSelfDebuggedReporting,
// the constructor that actually carries that gate - see
// fix_swift_deadcode_and_stale_comments.py. Sitting here it read as
// documenting the child heartbeat below, whose own constructor
// ReynardStartChildHeartbeat is UNGATED and runs in every process that
// links this file.

// ADDED - see fix_child_heartbeat_instrument.py's docstring.
//
// Two keys per process, ticked from two different queues, so a reader can
// tell a STOPPED process (both stale) from one whose MAIN THREAD is
// wedged (main stale, background fresh). A single heartbeat can express
// neither distinction.
//
// The value is milliseconds on the CFAbsoluteTime reference, which both
// sides share, so the reader subtracts without any clock agreement
// beyond that. 0 means never ticked, and is reported as such rather than
// as stale - see the docstring on why that distinction is load-bearing.
static const uint64_t kHeartbeatIntervalMs = 250;
static const double kHeartbeatStaleMs = 1500.0;

static NSString *heartbeatName(int32_t pid, BOOL isMain) {
    return [NSString stringWithFormat:@"com.minh-ton.Reynard.ChildHeartbeat.%@.%d",
            isMain ? @"main" : @"bg", pid];
}

static void scheduleHeartbeatTick(int token, dispatch_queue_t queue) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kHeartbeatIntervalMs * NSEC_PER_MSEC)),
                   queue, ^{
        notify_set_state(token, (uint64_t)(CFAbsoluteTimeGetCurrent() * 1000.0));
        scheduleHeartbeatTick(token, queue);
    });
}

void startChildHeartbeat(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int32_t pid = (int32_t)getpid();

        // Registered but NOT ticked here. The first tick has to come from
        // the queue itself, or a main queue that never drains would look
        // alive purely because registration ran on some other thread.
        int mainToken = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(heartbeatName(pid, YES).UTF8String, &mainToken) == NOTIFY_STATUS_OK) {
            notify_set_state(mainToken, 0);
            scheduleHeartbeatTick(mainToken, dispatch_get_main_queue());
        }

        int bgToken = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(heartbeatName(pid, NO).UTF8String, &bgToken) == NOTIFY_STATUS_OK) {
            notify_set_state(bgToken, 0);
            scheduleHeartbeatTick(bgToken, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        }
    });
}

// pid -> type, owned here rather than read back from AttachLedger. The
// dump has to work while attachQueue is blocked, which is precisely when
// it is worth having.
static NSMutableDictionary<NSNumber *, NSString *> *heartbeatChildTypes(void) {
    static NSMutableDictionary<NSNumber *, NSString *> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = [NSMutableDictionary dictionary];
    });
    return types;
}

static NSLock *heartbeatChildLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

void recordChildForHeartbeat(int32_t pid, NSString *processType) {
    if (pid <= 0) return;

    NSLock *lock = heartbeatChildLock();
    [lock lock];
    heartbeatChildTypes()[@(pid)] = processType ?: @"?";
    [lock unlock];
}

// -1 through ageMsOut means the key exists but has never been ticked.
// NO means the key could not be read at all.
static BOOL readHeartbeatAge(int32_t pid, BOOL isMain, double *ageMsOut) {
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(heartbeatName(pid, isMain).UTF8String, &token) != NOTIFY_STATUS_OK) {
        return NO;
    }

    uint64_t state = 0;
    BOOL ok = notify_get_state(token, &state) == NOTIFY_STATUS_OK;
    notify_cancel(token);
    if (!ok) return NO;

    if (state == 0) {
        *ageMsOut = -1.0;
        return YES;
    }
    *ageMsOut = (CFAbsoluteTimeGetCurrent() * 1000.0) - (double)state;
    return YES;
}

static NSString *heartbeatDescription(int32_t pid) {
    double mainAge = -1.0, bgAge = -1.0;
    BOOL mainRead = readHeartbeatAge(pid, YES, &mainAge);
    BOOL bgRead = readHeartbeatAge(pid, NO, &bgAge);

    NSString *mainDesc = !mainRead ? @"main=?"
        : (mainAge < 0 ? @"main=never" : [NSString stringWithFormat:@"main=%.0fms", mainAge]);
    NSString *bgDesc = !bgRead ? @"bg=?"
        : (bgAge < 0 ? @"bg=never" : [NSString stringWithFormat:@"bg=%.0fms", bgAge]);

    // A verdict only where both sides actually ticked. "never" is an
    // instrument problem, not a process problem, and must not be dressed
    // up as one.
    NSString *verdict = @"";
    if (mainAge >= 0 && bgAge >= 0) {
        BOOL mainStale = mainAge > kHeartbeatStaleMs;
        BOOL bgStale = bgAge > kHeartbeatStaleMs;
        if (mainStale && bgStale) {
            verdict = @"  <<< STOPPED - cannot answer XPC";
        } else if (mainStale) {
            verdict = @"  <<< MAIN THREAD WEDGED";
        }
    }

    return [NSString stringWithFormat:@"%@ %@%@", mainDesc, bgDesc, verdict];
}

// A child both of whose heartbeats have been stale for this long, while
// the process is still alive, is stopped rather than busy. The number is
// deliberately far above kHeartbeatStaleMs: staleness of a second or two
// is an overloaded child, and killing one of those would be a bug. The
// capture that motivated this read main=512619ms.
static const double kHeartbeatUnrecoverableMs = 15000.0;

// Kills children that a supervision session has left stopped.
//
// This is the crash it exists for, from one capture:
//
//   14:06:27  hangHeartbeat: pid 35088 type=tab main=512619ms bg=512618ms
//   14:06:27  interruptLiveDebugSessions: 0 live session(s), interrupted 0
//   14:06:37  0x8BADF00D scene-update watchdog: 10.00 seconds
//
// The tab had been stopped for eight and a half minutes with no live
// debug session left to interrupt, so the one existing escalation lever
// moved nothing. Foregrounding then sent it a SYNCHRONOUS XPC through
// ExtensionFoundation, which cannot time out, and iOS killed the whole
// app for the ten seconds that took.
//
// A stopped child cannot be resumed from here - its debugger transport
// is gone, which is how it got into this state. Killing it is the only
// move, and it is a good one: Gecko rebuilds a dead content process,
// while a watchdog kill loses every tab and the session with them.
//
// Called only from the hang escalation, never speculatively. A
// backgrounded extension is legitimately quiet, and this must not be
// the thing that decides otherwise.
int killStoppedChildren(void) {
    NSLock *lock = heartbeatChildLock();
    [lock lock];
    NSDictionary<NSNumber *, NSString *> *snapshot = [heartbeatChildTypes() copy];
    [lock unlock];

    int killed = 0;
    int refused = 0;
    for (NSNumber *key in snapshot) {
        int32_t pid = key.intValue;
        if (!pidIsAlive((pid_t)pid)) {
            continue;
        }
        double mainAge = -1.0, bgAge = -1.0;
        if (!readHeartbeatAge(pid, YES, &mainAge) ||
            !readHeartbeatAge(pid, NO, &bgAge)) {
            // Could not read the instrument. Never kill on that.
            continue;
        }
        // "never" is an instrument problem, not a process problem - the
        // same distinction heartbeatDescription refuses to blur.
        if (mainAge < 0 || bgAge < 0) {
            continue;
        }
        if (mainAge <= kHeartbeatUnrecoverableMs ||
            bgAge <= kHeartbeatUnrecoverableMs) {
            continue;
        }
        logger([NSString stringWithFormat:
                @"killStoppedChildren: killing pid %d type=%@ - stopped for "
                @"%.0fms/%.0fms, cannot answer the foreground XPC",
                pid, snapshot[key], mainAge, bgAge]);
        if (kill((pid_t)pid, SIGKILL) != 0) {
            refused++;
            logger([NSString stringWithFormat:
                    @"killStoppedChildren: kill(%d) failed, errno=%d",
                    pid, errno]);
            continue;
        }
        killed++;
    }
    // "Nothing stopped long enough" and "found them and was refused" are
    // opposite diagnoses and used to print the same line, because only
    // successful kills were counted. A device capture (0x8BADF00D at
    // 19:46:37) found both stopped children correctly, took EPERM on
    // both kills, and then reported that it had found nothing - which
    // reads as a broken heartbeat and sent the next reader looking in
    // the wrong place entirely.
    //
    // EPERM is the expected answer, not an anomaly: RunningBoard spawns
    // these extensions, so this process is not their parent and has no
    // privilege to signal them. The same errno already turns up on
    // csops. Which means this function cannot do its job at all, and
    // the log has to say so rather than imply the search failed.
    if (refused > 0) {
        logger([NSString stringWithFormat:
                @"killStoppedChildren: found %d stopped child(ren) and was "
                @"REFUSED on every kill - this process cannot signal them "
                @"(errno 1 = EPERM, they are RunningBoard's, not ours). "
                @"The app is now waiting on a foreground XPC they cannot "
                @"answer.", refused]);
    } else if (killed == 0) {
        logger(@"killStoppedChildren: nothing stopped long enough to kill");
    }
    return killed;
}

void dumpChildHeartbeats(const char *label) {
    NSString *tag = [NSString stringWithUTF8String:label ?: "heartbeat"];

    NSLock *lock = heartbeatChildLock();
    [lock lock];
    NSDictionary<NSNumber *, NSString *> *snapshot = [heartbeatChildTypes() copy];
    [lock unlock];

    NSArray<NSNumber *> *pids = [snapshot.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *dead = [NSMutableArray array];
    NSUInteger live = 0;

    for (NSNumber *key in pids) {
        if (!pidIsAlive((pid_t)key.intValue)) {
            [dead addObject:key];
            continue;
        }
        live++;
    }

    logger([NSString stringWithFormat:@"%@: %lu live child(ren), interval %llums, stale over %.0fms",
            tag, (unsigned long)live, (unsigned long long)kHeartbeatIntervalMs, kHeartbeatStaleMs]);

    for (NSNumber *key in pids) {
        if ([dead containsObject:key]) continue;
        int32_t pid = key.intValue;
        logger([NSString stringWithFormat:@"%@:   pid %d type=%@ %@",
                tag, pid, snapshot[key], heartbeatDescription(pid)]);
    }

    if (dead.count > 0) {
        [lock lock];
        [heartbeatChildTypes() removeObjectsForKeys:dead];
        [lock unlock];
    }
}

__attribute__((constructor))
static void ReynardStartChildHeartbeat(void) {
    startChildHeartbeat();
}

// Runs in every process that loads this translation unit. Gated to the
// Helper extension, which is the debuggee - the main app is the
// debugger and never carries CS_DEBUGGED, so checking there would
// always and correctly read false.
//
// MOVED here from above the child-heartbeat block - see
// fix_swift_deadcode_and_stale_comments.py. The bundle-ID suffix test
// below IS the gate it describes.
__attribute__((constructor))
static void ReynardStartSelfDebuggedReporting(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID hasSuffix:@".Helper"]) {
        return;
    }
    scheduleSelfDebuggedCheck(40);
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
    
    // REVERTED - see
    // fix_revert_csops_gate_on_acquisition_row.py's docstring. This
    // briefly required at least one tracked pid to report CS_DEBUGGED,
    // to match DolphiniOS. That cannot work from here: csops() with
    // CS_OPS_STATUS on ANOTHER process is refused with EPERM under the
    // app sandbox, confirmed on device 8 times out of 8
    // ("csops failed for pid NNN, errno=1"). It only works on
    // getpid(). DolphiniOS can use it because DolphiniOS IS the
    // debuggee; Reynard's main app is the DEBUGGER, so every pid it
    // asks about is someone else's. The gate could never pass, making
    // the row read "Not Acquired" permanently.
    //
    // Truthful reporting needs the check to run inside the Helper on
    // its own getpid() after its attach completes, with the result
    // recorded in the App Group for the main app to read. Not done
    // here - that is a new feature, not part of undoing a regression.
    //
    // The count is logged because the row ALSO read "Not Acquired"
    // before the csops change, while eleven runDebugService loops were
    // live - so the bookkeeping path has a separate problem. A count of
    // 0 means registerDebugSessionPID is not running, or
    // activeJITSessionsFileURL() is nil because the App Group
    // container is unavailable to the asking process, so reads and
    // writes both silently no-op.
    logger([NSString stringWithFormat:@"hasAnyActiveJITSessionAcrossProcesses: %lu tracked session(s)", (unsigned long)live.count]);
    
    return live.count > 0;
}

// When each loop last completed an iteration.
//
// A healthy loop ticks every 30-60ms. A stale stamp means the target is
// stopped and nothing is servicing it - which is the process the main
// thread is waiting on when the watchdog fires. See
// fix_dump_loop_state_on_hang.py.
static NSMutableDictionary<NSNumber *, NSNumber *> *debugLoopLastTick(void) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *ticks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ticks = [NSMutableDictionary dictionary];
    });
    return ticks;
}

static NSLock *debugLoopTickLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

// Whether each loop is currently blocked in the continue.
//
// This is the state that discriminates. A healthy loop sits in
// sendDebugCommand(@"c") waiting for its target to trap, however long
// that takes - so time since the last iteration says nothing, which
// three earlier versions of this measurement learned the hard way.
//
// A loop NOT in that wait, whose target is stopped, is the one with
// nobody to continue it. See fix_track_loop_waiting_state.py.
static NSMutableDictionary<NSNumber *, NSNumber *> *debugLoopWaiting(void) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *waiting;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        waiting = [NSMutableDictionary dictionary];
    });
    return waiting;
}

// When each loop last CHANGED waiting state, so the dump can tell "out
// of the wait for 2ms - servicing a trap" from "out of the wait for 4
// seconds - stuck". Guarded by debugLoopTickLock, like its siblings.
static NSMutableDictionary<NSNumber *, NSNumber *> *debugLoopWaitingSince(void) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *since;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        since = [NSMutableDictionary dictionary];
    });
    return since;
}

void recordDebugLoopWaiting(int32_t pid, BOOL waiting) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
    NSNumber *previous = debugLoopWaiting()[@(pid)];
    if (previous == nil || previous.boolValue != waiting) {
        debugLoopWaitingSince()[@(pid)] = @(CFAbsoluteTimeGetCurrent());
    }
    debugLoopWaiting()[@(pid)] = @(waiting);
    [lock unlock];
}

void recordDebugLoopTick(int32_t pid) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
    debugLoopLastTick()[@(pid)] = @(CFAbsoluteTimeGetCurrent());
    [lock unlock];
}

void forgetDebugLoopTick(int32_t pid) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
    [debugLoopLastTick() removeObjectForKey:@(pid)];
    [debugLoopWaiting() removeObjectForKey:@(pid)];
    [debugLoopWaitingSince() removeObjectForKey:@(pid)];
    [lock unlock];
}

void dumpDebugLoopState(void) {
    dumpDebugLoopStateLabelled("hangDump");
}

void dumpDebugLoopStateLabelled(const char *label) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
    NSDictionary<NSNumber *, NSNumber *> *snapshot = [debugLoopLastTick() copy];
    NSDictionary<NSNumber *, NSNumber *> *waitingSnapshot = [debugLoopWaiting() copy];
    NSDictionary<NSNumber *, NSNumber *> *sinceSnapshot = [debugLoopWaitingSince() copy];
    [lock unlock];

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *tag = [NSString stringWithUTF8String:label ?: "loopState"];
    logger([NSString stringWithFormat:@"%@: %lu session(s) registered", tag, (unsigned long)snapshot.count]);

    for (NSNumber *key in snapshot) {
        int32_t pid = key.intValue;
        double ageMs = (now - snapshot[key].doubleValue) * 1000.0;

        // Anything past a second is already far outside a healthy 30-60ms
        // iteration, so it is worth marking rather than leaving to be
        // eyeballed.
        // CS_DEBUGGED is not reported: csops returns EPERM for another
        // process, so every answer was a failed read printed as NO.
        //
        // A second past a 30-60ms iteration is already far outside
        // normal, and at backgrounding - where every healthy loop is
        // still running - that makes a stopped one obvious. See
        // fix_dump_loops_at_background.py.
        // WAITING is the healthy resting state, whatever its duration -
        // the loop is blocked waiting for its target to trap. NOT
        // WAITING means the loop has left that wait and not returned,
        // which is what a stopped target with nobody to continue it
        // looks like. See fix_track_loop_waiting_state.py.
        NSNumber *isWaiting = waitingSnapshot[key];
        BOOL waiting = isWaiting != nil && isWaiting.boolValue;
        // How long the loop has been in its CURRENT state. A loop out
        // of the wait for a few milliseconds is healthy - it is between
        // the trap landing and the next continue, exactly where the
        // waiting bracket sits - so the marker requires out-of-wait
        // for longer than the same 1 second the age note above already
        // calls far outside normal. A loop with no transition recorded
        // keeps the old behaviour rather than hiding.
        NSNumber *since = sinceSnapshot[key];
        double stateMs = since != nil ? (now - since.doubleValue) * 1000.0 : -1.0;
        BOOL suspect = isWaiting != nil && !waiting &&
                       (since == nil || stateMs > 1000.0);

        logger([NSString stringWithFormat:@"%@:   pid %d %@ (%.0fms, state %.0fms)%@",
                tag, pid,
                isWaiting == nil ? @"UNKNOWN    " : (waiting ? @"WAITING    " : @"NOT WAITING"),
                ageMs,
                stateMs,
                suspect ? @"  <<< SUSPECT" : @""]);
    }
}

static void registerDebugSessionPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_sync(debugSessionStateQueue(), ^{
        NSNumber *key = @(pid);
        [activeDebugSessionPIDs() addObject:key];
        [detachRequestedDebugSessionPIDs() removeObject:key];
        [backgroundDetachRequestedPIDs() removeObject:key];
    });
    
    addPIDToSharedActiveSessions(pid);
    
    // REMOVED a "registerDebugSessionPID: pid %d CS_DEBUGGED=%@" line
    // - see fix_swift_deadcode_and_stale_comments.py.
    //
    // It called processIsDebugged(pid) on someone else's pid, which is
    // csops(CS_OPS_STATUS) on another process, which the app sandbox
    // refuses with EPERM - "confirmed on device 8 times out of 8", as
    // the revert note at hasAnyActiveJITSessionAcrossProcesses says, and
    // as dumpDebugLoopState already says on its own account ("every
    // answer was a failed read printed as NO").
    //
    // Always someone else's pid: this runs only from runDebugService,
    // which only the main app reaches, and the main app is the DEBUGGER.
    // The Helper's self-enable stopped calling enableJITForPID: when it
    // moved to delegating the attach back to the main app.
    //
    // So it printed NO for every healthy session - a second log line per
    // attach, and the misleading one of the two. The honest version of
    // this measurement is scheduleSelfDebuggedCheck above, which asks
    // about getpid() inside the Helper and records the answer in the App
    // Group.
}

static void unregisterDebugSessionPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_sync(debugSessionStateQueue(), ^{
        NSNumber *key = @(pid);
        [activeDebugSessionPIDs() removeObject:key];
        [detachRequestedDebugSessionPIDs() removeObject:key];
        [backgroundDetachRequestedPIDs() removeObject:key];
    });
    
    removePIDFromSharedActiveSessions(pid);
}

// ADDED - see fix_detach_debug_sessions_on_background.py's docstring.
// Marks every live session for detach so runDebugService drains them
// rather than leaving content processes stopped by the debugger across
// suspension.
//
// That state is fatal: a Helper stopped at a breakpoint cannot answer
// the SYNCHRONOUS XPC that iOS sends every extension on foreground, so
// the main thread blocks in
// __NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__ and the
// watchdog kills the app with 0x8BADF00D. Confirmed from three hang
// reports with lifetimes of 7, 19 and 33 seconds.
//
// Same dispatch_sync(debugSessionStateQueue()) pattern as
// registerDebugSessionPID above, so the sets stay under the single
// serialisation everything else uses.
// ADDED - see fix_cancel_blocked_debug_loops.py's docstring. Maps a
// live pid to its DebugProxyHandle so a blocked call can be cancelled
// directly, rather than only setting a flag the loop cannot reach while
// it is blocked.
//
// Guarded by debugSessionStateQueue, the same serial queue as the pid
// sets, which is what makes cancellation safe against a loop that is
// concurrently exiting and freeing its session.
static NSMutableDictionary<NSNumber *, NSValue *> *debugSessionProxies(void) {
    static NSMutableDictionary<NSNumber *, NSValue *> *proxies = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxies = [NSMutableDictionary dictionary];
    });
    return proxies;
}

static void registerDebugSessionProxy(int32_t pid, DebugProxyHandle *proxy) {
    if (pid <= 0 || !proxy) return;

    dispatch_sync(debugSessionStateQueue(), ^{
        debugSessionProxies()[@(pid)] = [NSValue valueWithPointer:proxy];
    });
}

// Interrupts every LIVE session. See fix_interrupt_before_detach.py.
//
// DELETED alongside this, see fix_delete_dead_transport_code.py: the
// twin this used to be defined by contrast with,
// interruptAttachingDebugSessions, which did the same thing for
// attaches still IN FLIGHT - plus the attachingDebugSessionProxies
// table it read and the register/unregister pair that filled it. A
// repo-wide grep found its definition, its JITSupport.h declaration,
// its JITEnabler class-method declaration and forwarder, its own log
// string and two comments about itself. No call site, in ObjC or Swift.
//
// THIS function is the live one: it walks debugSessionProxies(), and is
// called from JITEnabler.m's forwarder and TabManagerImpl.swift:567.
//
// A loop blocked in sendDebugCommand(@"c") cannot see a detach request,
// because that flag is only read at the top of an iteration. 0x03 makes
// the target stop, the continue return, and the loop come back round to
// where it can act on the request.
//
// Out-of-band by design - unlike cancellation, which aborts the
// in-flight read and desyncs the connection permanently. That was
// measured at 1 successful detach in 10.
void interruptLiveDebugSessions(void) {
    // CHANGED - dispatch_async, not dispatch_sync. See
    // fix_queue_stalls_on_hang_path.py.
    //
    // Exactly the change cancelAllDebugSessionCalls below already
    // carries, for exactly its reasons. The one live caller is the
    // HangWatchdog escalation in TabManagerImpl, which called this
    // synchronously and then waited on a per-proxy BLOCKING
    // debug_proxy_send_raw for every live session - into a transport
    // that is dead by construction on that path, since the escalation
    // only runs because a child is wedged and its debugger transport
    // is gone. Behind that critical section sat the cancel dispatched
    // one statement later, every loop's shouldDetachDebugSessionPID,
    // closeTunnelForSuspension's liveDebugSessionCount, and the hang
    // recovery's own per-pid hasActiveDebugSessionForPID.
    //
    // And that wait could not be broken. debug_proxy_send_raw goes
    // through the Rust run_sync, which blocks on rx.recv() with no
    // timeout and is NOT registered in IN_FLIGHT_CALLS - so the
    // debug_proxy_cancel this escalation issues one statement later
    // cannot abort it (cancel only reaches debug_proxy_send_command
    // and debug_proxy_read_response). Verified in support/idevice
    // @42dd7217, ffi/src/debug_proxy.rs:348 and ffi/src/lib.rs:178.
    //
    // Nothing needs it synchronous: the function is void, and the one
    // caller's next statement is cancelAllDebugSessionCalls, which is
    // itself an async onto THIS queue. Both blocks land on one serial
    // queue in program order, so interrupt-then-cancel is unchanged.
    //
    // The FFI call stays INSIDE the block, deliberately. That is the
    // lifetime invariant documented above debugSessionProxies() and
    // again on cancelAllDebugSessionCalls: unregisterDebugSessionProxy
    // uses this queue and runs before freeDebugSession, so a proxy
    // still in the dictionary has not been freed. The dictionary is
    // read INSIDE the block, at execution time - hoisting the walk or
    // snapshotting the pointers outside would break precisely this.
    logger(@"interruptLiveDebugSessions: dispatched - the send loop runs on the state queue, the caller is not blocked");

    dispatch_async(debugSessionStateQueue(), ^{
        // Plain block locals now rather than __block, and the summary
        // logger moved inside so it still reports real numbers.
        // liveCount is therefore sampled when the block RUNS rather
        // than when the call was made; nothing consumes it but the log.
        NSUInteger liveCount = debugSessionProxies().count;
        NSUInteger interruptedCount = 0;

        for (NSValue *proxyValue in debugSessionProxies().allValues) {
            DebugProxyHandle *proxy = (DebugProxyHandle *)proxyValue.pointerValue;
            if (!proxy) continue;

            uint8_t interruptByte = 0x03;
            IdeviceFfiError *interruptError = debug_proxy_send_raw(proxy, &interruptByte, 1);
            if (interruptError) {
                idevice_error_free(interruptError);
                continue;
            }
            interruptedCount++;
        }

        logger([NSString stringWithFormat:@"interruptLiveDebugSessions: %lu live session(s), interrupted %lu", (unsigned long)liveCount, (unsigned long)interruptedCount]);
    });
}

static void unregisterDebugSessionProxy(int32_t pid) {
    if (pid <= 0) return;

    dispatch_sync(debugSessionStateQueue(), ^{
        [debugSessionProxies() removeObjectForKey:@(pid)];
    });
}

// SPLIT OUT - see fix_split_cancel_from_detach.py's docstring.
//
// Cancelling only. Unblocks any thread parked in a debug proxy read
// without setting the detach flags, so a session is not deliberately
// torn down and a quick return re-attaches naturally.
//
// Called from sceneWillResignActive rather than
// sceneDidEnterBackground, because iOS sends every extension a
// SYNCHRONOUS XPC message on backgrounding and a debugger-stopped
// extension cannot answer it - the app was killed with 0x8BADF00D
// blocked in __NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__
// inside EXConcreteExtension _hostDidEnterBackgroundNote:.
// willResignActive fires before that cascade begins.
//
// Deliberately NOT the full teardown: willResignActive also fires for
// Control Centre, notification pulls and incoming calls, and tearing
// every session down for a two-second glance would cost a re-attach
// per process on return.
//
// Kept inside dispatch_sync(debugSessionStateQueue()) for the same
// reason as the detach below - unregisterDebugSessionProxy uses that
// queue and runs before freeDebugSession, so a registered proxy has
// not been freed and a freed one is no longer registered.
void cancelAllDebugSessionCalls(void) {
    // CHANGED - dispatch_async, not dispatch_sync. See
    // fix_lifecycle_calls_off_main_thread.py.
    //
    // This is called from sceneWillResignActive on the MAIN THREAD, and
    // debugSessionStateQueue is busy - every runDebugService iteration
    // touches it via shouldDetachDebugSessionPID, with fourteen loops
    // running. Worse, debug_proxy_cancel below takes the Rust
    // IN_FLIGHT_CALLS mutex, which run_sync_cancellable holds while
    // registering each task. So the main thread could wait on the queue,
    // which waited on a mutex held by a loop thread mid-registration -
    // an unbounded stall, and the app froze with the screen on.
    //
    // Nothing here needs to be synchronous: no return value, and no
    // caller depends on it having finished.
    dispatch_async(debugSessionStateQueue(), ^{
        NSUInteger cancelledCount = 0;

        for (NSValue *proxyValue in debugSessionProxies().allValues) {
            DebugProxyHandle *proxy = (DebugProxyHandle *)proxyValue.pointerValue;
            if (!proxy) continue;

            IdeviceFfiError *cancelError = debug_proxy_cancel(proxy);
            if (cancelError) {
                idevice_error_free(cancelError);
                continue;
            }
            cancelledCount++;
        }

        logger([NSString stringWithFormat:@"cancelAllDebugSessionCalls: cancelled %lu in-flight call(s)", (unsigned long)cancelledCount]);
    });
}

// CHANGED - the cancellation loop moved to cancelAllDebugSessionCalls
// above, which runs earlier. This is now the deliberate teardown only,
// and still runs from sceneDidEnterBackground.
// Lifts the sticky teardown set by requestDetachForAllDebugSessions.
// Called from applicationDidBecomeActive, so attaches made from here on
// are wanted again. Without it the first background would disable
// trapping for the rest of the launch.
// ADDED - see fix_no_jit_promise_during_teardown.py's docstring.
//
// dispatch_sync rather than async: the caller needs the answer, and this
// touches nothing but a BOOL on the state queue. Every other reader of
// that queue does the same (shouldDetachDebugSessionPID,
// hasActiveDebugSessionForPID).
BOOL debuggerTeardownRequested(void) {
    __block BOOL requested = NO;
    dispatch_sync(debugSessionStateQueue(), ^{
        requested = sDebuggerTeardownRequested;
    });
    return requested;
}

void clearDebuggerTeardownRequest(void) {
    dispatch_async(debugSessionStateQueue(), ^{
        if (!sDebuggerTeardownRequested) {
            return;
        }
        sDebuggerTeardownRequested = NO;

        // ADDED - see fix_detach_disarms_only_its_own_pid.py.
        //
        // The sticky BOOL was the only thing this cleared, and the
        // BOOL is read in exactly one place - runDebugService's entry
        // check, where it decides whether a NEWLY STARTING loop joins
        // a standing teardown. A loop that is ALREADY RUNNING never
        // reads it. It reads the SET, through
        // shouldDetachDebugSessionPID at the top of every iteration,
        // and nothing removed a pid from that set on a foreground.
        //
        // requestDetachForAllDebugSessions deliberately does not
        // interrupt live loops, "so sessions persist across a
        // background rather than draining". Those survivors kept
        // their pid in the set: the app foregrounds, this runs, and
        // on that tab's very next trap shouldDetachDebugSessionPID
        // still says YES - so the loop detaches and exits, killing
        // JIT for the tab the user just came back to. Those same
        // late detaches are the ones that fail on device.
        //
        // JITController's hang-recovery path already assumes this
        // call does exactly this: "Lift it here ... so the recovered
        // loops re-arm instead of churning". It only ever lifted it
        // for loops that had not started yet.
        //
        // INSIDE the sticky-BOOL guard above, deliberately. JIT-less
        // mode's detachAllJITSessions unions pids in WITHOUT setting
        // that BOOL, so the set can be non-empty with the BOOL
        // already NO; clearing above the guard would cancel that
        // request too, and it is meant to stand until those loops
        // drain. Here this only ever undoes what
        // requestDetachForAllDebugSessions did, which is this
        // function's stated job.
        //
        // Same queue, same block: detachRequestedDebugSessionPIDs is
        // only ever touched on debugSessionStateQueue.
        // ONLY THE BACKGROUND'S - see
        // fix_foreground_clear_releases_only_background_pids.py. This
        // used to empty the whole set, which also released a request
        // JIT-less mode had standing underneath the background's. The
        // guard above already protects that request when the BOOL is
        // NO; this protects it when both requests stand at once.
        NSMutableSet<NSNumber *> *stillRequested = detachRequestedDebugSessionPIDs();
        NSMutableSet<NSNumber *> *fromBackground = backgroundDetachRequestedPIDs();
        NSMutableSet<NSNumber *> *released = [stillRequested mutableCopy];
        [released intersectSet:fromBackground];
        if (released.count > 0) {
            NSMutableString *releasedPIDs = [NSMutableString string];
            for (NSNumber *requestedPID in released) {
                if (releasedPIDs.length > 0) [releasedPIDs appendString:@", "];
                [releasedPIDs appendFormat:@"%d", requestedPID.intValue];
            }
            logger([NSString stringWithFormat:@"clearDebuggerTeardownRequest: detachSetCleared - released %lu pid(s) [%@] from the detach set, loops that survived the background keep their JIT", (unsigned long)released.count, releasedPIDs]);
            [stillRequested minusSet:released];
        }
        if (stillRequested.count > 0) {
            logger([NSString stringWithFormat:@"clearDebuggerTeardownRequest: detachSetKept - %lu pid(s) stay requested, JIT-less mode asked for them, not the background", (unsigned long)stillRequested.count]);
        }
        [fromBackground removeAllObjects];

        logger(@"clearDebuggerTeardownRequest: foreground - attaches are wanted again");
    });
}

void requestDetachForAllDebugSessions(void) {
    // ADDED - fix_retry_tunnel_create.py. Before the dispatch_async
    // below, not inside it: this is what tells an in-progress tunnel
    // retry to stop so closeSharedTunnel is not held behind it.
    atomic_fetch_add(&sTunnelTeardownGeneration, 1);

    // CHANGED - dispatch_async for the same reason as
    // cancelAllDebugSessionCalls above. Called from
    // sceneDidEnterBackground on the main thread, onto a queue fourteen
    // debug loops are already using constantly.
    //
    // Blocking never guaranteed promptness anyway - only that the main
    // thread waited, which is the thing that froze.
    dispatch_async(debugSessionStateQueue(), ^{
        NSMutableSet<NSNumber *> *active = activeDebugSessionPIDs();
        // Only what was NOT already requested is the background's to
        // release later - see
        // fix_foreground_clear_releases_only_background_pids.py.
        NSMutableSet<NSNumber *> *newlyRequested = [active mutableCopy];
        [newlyRequested minusSet:detachRequestedDebugSessionPIDs()];
        [backgroundDetachRequestedPIDs() unionSet:newlyRequested];
        [detachRequestedDebugSessionPIDs() unionSet:active];
        // Sticky, so an attach that lands after this point joins the
        // teardown instead of re-arming the debugger behind it.
        sDebuggerTeardownRequested = YES;

        // CHANGED - fix_no_interrupt_at_background.py. The live count
        // used to come from the interrupt line; it is still worth having
        // now that nothing interrupts them. Read here because this block
        // already owns the queue - a dispatch_sync from the caller would
        // re-block the main thread this function was made async to spare.
        logger([NSString stringWithFormat:@"requestDetachForAllDebugSessions: requested detach for %lu active session(s), %lu live session(s) left running", (unsigned long)active.count, (unsigned long)debugSessionProxies().count]);
    });

    // REMOVED - see fix_no_interrupt_at_background.py.
    //
    // This used to call interruptLiveDebugSessions() so a loop blocked in
    // its continue would come back round and see the flag set above. The
    // 0x03 byte does that by making debugserver STOP the target, on the
    // assumption that the detach which follows resumes it.
    //
    // It does not, roughly half the time. Two instrumented captures, with
    // nothing else touching a child in between:
    //
    //   2026-08-13 20:31  interrupted 7, all 7 logged "Detach response
    //                     OK", 4 still stopped 39.6s later
    //   2026-08-13 22:28  interrupted 5, 5 still stopped 28.4s later
    //
    // A stopped extension cannot answer the synchronous XPC iOS sends
    // every hosted extension on the next lifecycle transition, and the
    // watchdog takes the app for it.
    //
    // The cost of not interrupting: a loop parked in a continue will not
    // notice the flag until its target next traps, so sessions persist
    // across a background rather than draining. That is accepted
    // deliberately - a loop sitting in a continue leaves its target
    // RUNNING, and running is the state that answers XPC.
    //
    // setDebuggerListening(false) still runs before this, so nothing
    // traps during or after the teardown; and with the per-pid key a
    // child whose loop is gone cannot trap either, so a session that
    // outlives a dead tunnel degrades to interpreted rather than to
    // stopped. fix_no_teardown_while_system_media_active.py already skips
    // this whole path while PiP or CarPlay audio is live, and that path
    // has produced no stopped child.
    //
    // interruptLiveDebugSessions() itself stays, and is still called from
    // the HangWatchdog escalation - a last resort on an already-hung app,
    // which is a different trade from routine teardown.
    logger(@"backgroundInterrupt: skipped - not stopping live targets to deliver a detach flag they can read on their own");
}

// ADDED - see fix_reattach_orphaned_sessions_on_foreground.py.
// Whether this pid still has a live runDebugService loop.
//
// Deliberately not processIsDebugged: csops on another process returns
// EPERM under the app sandbox, confirmed eight times out of eight on
// device. Only a process can ask about itself, so this bookkeeping is
// the available signal from the main app's side.
BOOL hasActiveDebugSessionForPID(int32_t pid) {
    if (pid <= 0) return NO;

    __block BOOL isActive = NO;
    dispatch_sync(debugSessionStateQueue(), ^{
        isActive = [activeDebugSessionPIDs() containsObject:@(pid)];
    });
    return isActive;
}

// ADDED - see fix_tunnel_close_waits_for_debug_loops.py's docstring.
//
// The count the tunnel close needs. Its three existing gates are all
// attach-phase state, and a loop that finished attaching appears in none
// of them - while still holding a debug_proxy that connectDebugSession
// opened against provider->adapter, the adapter that close frees.
//
// debugSessionProxies() rather than activeDebugSessionPIDs(): the proxies
// are the handles, and handles are what a free can pull out from under a
// caller. Registered at the top of runDebugService and unregistered after
// the loop's detach and its 50ms retry - not at "Debug loop ended".
//
// CORRECTED - see fix_swift_deadcode_and_stale_comments.py. This used to
// claim the unregister happens "after the loop's LAST FFI call ... so
// zero here means no loop is still issuing calls on the adapter". It is
// not the last one. unregisterDebugSessionProxy(pid) runs immediately
// BEFORE freeDebugSession(session), and for a runDebugService session
// that is two more FFI calls - debug_proxy_free and remote_server_free -
// on handles debug_proxy_connect_rsd and remote_server_connect_rsd opened
// off provider->adapter. (session->adapter and session->handshake are
// deliberately left NULL for these sessions, so freeDebugSession's other
// two branches are skipped; see connectDebugSession.)
//
// That order is REQUIRED, not an oversight. cancelAllDebugSessionCalls
// walks this same map under this same queue, and its own comment states
// the invariant it needs: "a registered proxy has not been freed and a
// freed one is no longer registered". Swapping the two would trade this
// window for a use-after-free in the cancel path, which is worse.
//
// So read zero for what it is: no loop is still in its command loop, its
// detach, or the retry. It does NOT mean no loop is inside an FFI call
// at all - those two frees sit outside this gate.
//
// Same dispatch_sync onto debugSessionStateQueue as
// hasActiveDebugSessionForPID above, which is what stops the count being
// read mid-registration. The caller is JITController's attachQueue, a
// private serial queue, never the main thread.
NSUInteger liveDebugSessionCount(void) {
    __block NSUInteger count = 0;
    dispatch_sync(debugSessionStateQueue(), ^{
        count = debugSessionProxies().count;
    });
    return count;
}

static BOOL shouldDetachDebugSessionPID(int32_t pid) {
    if (pid <= 0) return NO;
    
    __block BOOL shouldDetach = NO;
    dispatch_sync(debugSessionStateQueue(), ^{
        shouldDetach = [detachRequestedDebugSessionPIDs() containsObject:@(pid)];
    });
    return shouldDetach;
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
    // CHANGED - no longer creates its own, separate tunnel - see
    // fix_reuse_provider_tunnel_in_connect_debug_session.py's
    // docstring. This function ignored its own provider parameter
    // entirely and stood up a second, completely independent
    // RPPairing tunnel from scratch (its own rp_pairing_file_read +
    // tunnel_create_rppairing, with a separate hardcoded
    // "ReynardDebug" hostname) - meaning every attach attempt opened
    // TWO simultaneous tunnels to the same device for what should be
    // one logical connection, unlike StikDebug's own confirmed-working
    // source, which creates exactly one tunnel per attempt and reuses
    // it for everything. This now reuses provider->adapter and
    // provider->handshake directly - the exact same pattern already
    // used elsewhere in this file for the DDI-mount workflow
    // (image_mounter_connect_rsd, lockdownd_connect_rsd both already
    // take provider->adapter/provider->handshake directly).
    //
    // session->adapter and session->handshake are deliberately never
    // assigned below, and stay NULL - freeDebugSession's own existing
    // NULL-guards correctly skip them as a result, so the shared
    // provider's tunnel can never be freed by a session-level cleanup
    // call. This matches this codebase's own established convention
    // for the same concern, seen in JITEnabler.m (a session handed off
    // to persistentSession has its own adapter/handshake fields
    // explicitly nulled out before freeDebugSession runs on the local
    // copy).
    //
    // The rp_pairing_file_read/tunnel_create_rppairing instrumentation
    // that used to live here is gone along with the calls it measured
    // - that work now already happened once, earlier, inside
    // createDeviceProvider, and is covered by that function's own
    // logging (fix_instrument_create_device_provider_internals.py).
    IdeviceFfiError *ffiError = NULL;
    
    if (!provider || !provider->adapter || !provider->handshake) {
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) called with no valid provider tunnel", pid]);
        if (error) *error = MakeError(TunnelCreateFailed);
        return NO;
    }
    
    CFAbsoluteTime remoteServerCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) starting remote_server_connect_rsd (reusing provider's own tunnel)", pid]);
    
    ffiError = remote_server_connect_rsd(provider->adapter, provider->handshake, &session->remoteServer);
    
    CFAbsoluteTime remoteServerCallEnd = CFAbsoluteTimeGetCurrent();
    
    if (ffiError) {
        NSInteger realCode = ffiError->code;
        NSInteger realSubCode = ffiError->sub_code;
        NSString *realMessage = ffiError->message ? [NSString stringWithUTF8String:ffiError->message] : @"(no message)";
        logger([NSString stringWithFormat:@"connectDebugSession (pid %d) remote_server_connect_rsd REAL failure - code: %ld, sub_code: %ld, message: %@, call took %.0fms", pid, (long)realCode, (long)realSubCode, realMessage, (remoteServerCallEnd - remoteServerCallStart) * 1000.0]);
        if (error) *error = MakeError(RemoteServerConnectFailed);
        idevice_error_free(ffiError);
        freeDebugSession(session);
        return NO;
    }
    
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) remote_server_connect_rsd succeeded, call took %.0fms", pid, (remoteServerCallEnd - remoteServerCallStart) * 1000.0]);
    
    CFAbsoluteTime debugProxyCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"connectDebugSession (pid %d) starting debug_proxy_connect_rsd", pid]);
    ffiError = debug_proxy_connect_rsd(provider->adapter, provider->handshake, &session->debugProxy);
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

// GDB remote framing: $<payload>#<checksum>, checksum being the sum of
// the payload bytes modulo 256. sendDebugCommand gets this from
// debugserver_command_new; raw sends have to do it here. With ack mode
// disabled there is nothing else to negotiate.
static NSString *gdbFramedPacket(NSString *payload) {
    uint8_t checksum = 0;
    const char *bytes = payload.UTF8String;
    for (const char *cursor = bytes; *cursor; cursor++) {
        checksum = (uint8_t)(checksum + (uint8_t)(*cursor));
    }
    return [NSString stringWithFormat:@"$%@#%02x", payload, checksum];
}

// Accepts both framed and bare responses. debug_proxy_send_command
// appears to return bare payloads - existing code slices the first two
// characters directly - but handling both costs nothing and avoids
// relying on undocumented behaviour.
static NSString *gdbUnframedResponse(NSString *response) {
    if (response.length >= 4 && [response hasPrefix:@"$"]) {
        NSRange hashRange = [response rangeOfString:@"#" options:NSBackwardsSearch];
        if (hashRange.location != NSNotFound && hashRange.location > 0) {
            return [response substringWithRange:NSMakeRange(1, hashRange.location - 1)];
        }
    }
    return response;
}

static BOOL readOneDebugResponse(DebugProxyHandle *debugProxy, NSString **responseOut, NSError **error) {
    char *raw = NULL;
    IdeviceFfiError *ffiError = debug_proxy_read_response(debugProxy, &raw);
    if (ffiError) {
        if (error) *error = MakeError(DebugCommandSendFailed);
        idevice_error_free(ffiError);
        if (raw) idevice_string_free(raw);
        return NO;
    }

    NSString *response = raw ? [NSString stringWithUTF8String:raw] : nil;
    if (raw) idevice_string_free(raw);
    if (responseOut) *responseOut = gdbUnframedResponse(response);
    return YES;
}

// A GDB remote error reply is "E" followed by two hex digits. It is three
// characters long, so it survives a `length < 2` check, and its first two
// characters parse as a perfectly good hex byte - which is how error
// replies were being echoed back into the target's own code pages as
// 0xE0. It is not data and must never be treated as such. runDebugService
// already screens the _M allocation response this way.
static BOOL gdbResponseIsError(NSString *response) {
    if (response.length < 3 || ![response hasPrefix:@"E"]) return NO;
    NSCharacterSet *hexDigits =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [hexDigits characterIsMember:[response characterAtIndex:1]] &&
           [hexDigits characterIsMember:[response characterAtIndex:2]];
}

// CHANGED - pipelined rather than one serialised round trip per packet.
// See fix_batch_prepare_memory_region.py's docstring. This loop reads
// and rewrites one byte per 16KB page, so a 4MB region is 256 pages and
// 512 commands - previously all serialised through sendDebugCommand,
// which is send-and-wait. That was the dominant cost in W^X mediation,
// and it is also why raising the coalescing chunk 1MB -> 4MB cut trap
// count ~37x without a proportional speedup: coalescing changes how
// often this runs, not the per-page work inside it.
//
// The GDB remote protocol is a strictly ordered stream, so all the
// reads can be written at once and their responses collected as a
// stream, then the same for the writes. StikDebug's handleJITPageWrite
// already does exactly this.
static BOOL prepareMemoryRegion(DebugProxyHandle *debugProxy, uint64_t startAddress, uint64_t regionSize, NSError **error) {
    uint64_t size = regionSize == 0 ? 0x4000 : regionSize;

    NSMutableArray<NSNumber *> *pageAddresses = [NSMutableArray array];
    for (uint64_t currentAddress = startAddress; currentAddress < startAddress + size; currentAddress += 0x4000) {
        [pageAddresses addObject:@(currentAddress)];
    }
    if (pageAddresses.count == 0) {
        return YES;
    }

    // Pass 1 - every read request in a single write.
    NSMutableString *readBatch = [NSMutableString string];
    for (NSNumber *pageAddress in pageAddresses) {
        [readBatch appendString:gdbFramedPacket([NSString stringWithFormat:@"m%llx,1", pageAddress.unsignedLongLongValue])];
    }

    NSData *readBytes = [readBatch dataUsingEncoding:NSUTF8StringEncoding];
    IdeviceFfiError *ffiError = debug_proxy_send_raw(debugProxy, readBytes.bytes, readBytes.length);
    if (ffiError) {
        if (error) *error = MakeError(DebugCommandSendFailed);
        idevice_error_free(ffiError);
        return NO;
    }

    NSMutableArray<NSNumber *> *writablePageAddresses = [NSMutableArray array];
    NSMutableArray<NSString *> *existingBytes = [NSMutableArray array];
    NSUInteger unreadablePageCount = 0;
    for (NSUInteger index = 0; index < pageAddresses.count; index++) {
        NSString *response = nil;
        if (!readOneDebugResponse(debugProxy, &response, error)) return NO;

        // A page that cannot be read is skipped rather than written back.
        // Echoing the "E0" of an "Exx" error reply stores 0xE0 into the
        // first byte of that page, which changes whatever AArch64
        // instruction lives there. Chunks are prepared 4MB at a time
        // regardless of which pages are currently committed, and
        // DecommitPages leaves decommitted pages PROT_NONE - so a failed
        // read here is expected, not exceptional. Skipping one page is
        // also much better than returning NO: that breaks the debug loop
        // and ends W^X mediation for the whole process.
        if (gdbResponseIsError(response)) {
            unreadablePageCount++;
            continue;
        }

        if (response.length < 2) {
            if (error && !*error) *error = MakeError(MemoryPrepareReadFailed);
            return NO;
        }
        [writablePageAddresses addObject:pageAddresses[index]];
        [existingBytes addObject:[response substringToIndex:2]];
    }

    if (unreadablePageCount > 0) {
        logger([NSString stringWithFormat:@"prepareMemoryRegion: %lu of %lu page(s) at 0x%llx+0x%llx were unreadable and were left untouched", (unsigned long)unreadablePageCount, (unsigned long)pageAddresses.count, startAddress, size]);
    }

    if (writablePageAddresses.count == 0) {
        // CHANGED - was `return YES`. See
        // fix_chunk_mask_truthfulness.py's docstring.
        //
        // Reporting success for a batch that touched ZERO pages is what
        // lets Gecko latch a whole 4MB chunk as prepared when nothing
        // was. Tolerating SOME unreadable pages is right, for the reason
        // given above - a chunk is prepared 4MB at a time whatever is
        // currently committed, and DecommitPages leaves the rest
        // PROT_NONE. All of them is a different thing.
        //
        // Every caller has just made its own sub-range
        // PROT_READ|PROT_EXEC before asking: SetAliasProtection runs
        // before PrepareExecutableRegionForWriting in both CommitPages
        // and ReprotectRegion, and the chunk always contains that
        // sub-range. So at least those pages must read back. If none of
        // them do, either the response stream has desynced and these are
        // Exx replies being scanned as data, or the mapping is gone -
        // and the honest answer to both is NO.
        //
        // This costs the debug loop: the caller at runDebugService
        // breaks and detaches. That is the point. The teardown clears
        // this pid's listening key, after which every later
        // PrepareExecutableRegionForWriting takes its notListening guard
        // and returns WITHOUT latching, so the process runs interpreted
        // and truthful instead of fast and wrong. Nothing is left
        // un-drained here either - every read reply was consumed by the
        // loop above - so unlike the other early returns in this
        // function this one does not desync the proxy.
        logger([NSString stringWithFormat:@"prepareMemoryRegion: NOTHING PREPARED - all %lu page(s) at 0x%llx+0x%llx were unreadable, reporting failure rather than success", (unsigned long)pageAddresses.count, startAddress, size]);
        if (error && !*error) *error = MakeError(MemoryPrepareReadFailed);
        return NO;
    }

    // Pass 2 - write each byte straight back, again in a single write.
    NSMutableString *writeBatch = [NSMutableString string];
    for (NSUInteger index = 0; index < writablePageAddresses.count; index++) {
        [writeBatch appendString:gdbFramedPacket([NSString stringWithFormat:@"M%llx,1:%@",
                                                  writablePageAddresses[index].unsignedLongLongValue,
                                                  existingBytes[index]])];
    }

    NSData *writeBytes = [writeBatch dataUsingEncoding:NSUTF8StringEncoding];
    ffiError = debug_proxy_send_raw(debugProxy, writeBytes.bytes, writeBytes.length);
    if (ffiError) {
        if (error) *error = MakeError(DebugCommandSendFailed);
        idevice_error_free(ffiError);
        return NO;
    }

    for (NSUInteger index = 0; index < writablePageAddresses.count; index++) {
        NSString *response = nil;
        if (!readOneDebugResponse(debugProxy, &response, error)) return NO;

        if (response.length > 0 && ![response isEqualToString:@"OK"]) {
            if (error) *error = MakeError(UnexpectedPrepareRegionResponse);
            return NO;
        }
    }

    return YES;
}

// Forward declaration - the definition sits below, after the session
// registry it belongs with, but detachDebuggerSession needs it first.
// See fix_listening_cleared_on_detach_failure.py.
// Declared in JITSupport.h now, so the app side can clear it before a
// suspension rather than only reacting to a failure. See
// fix_stop_trapping_on_background.py.

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
    
    // A failed D packet means the transport is gone, whatever the
    // detach was for. See fix_listening_cleared_on_detach_failure.py.
    //
    // The loop's own connectionFailed check cannot see this: it is
    // !shouldDetachDebugSessionPID(pid), so during a requested teardown
    // it is false by definition and the flag stays set - which is how a
    // session logged thirty-five failed detaches and never once said
    // the debugger had gone.
    //
    // isNotConnectedError is not excluded. That governs whether to log,
    // on the basis that a dead transport is unremarkable during
    // teardown; here it is exactly the thing worth acting on.
    //
    // CHANGED - see fix_detach_disarms_only_its_own_pid.py.
    //
    // Was setDebuggerListeningState(0) - the PROCESS-WIDE key. One
    // pid's failed D disarmed trapping for every content process in
    // the app. The child needs both keys before it executes its brk
    // (ProcessExecutableMemory.cpp.patch, DebuggerIsListening: "Both
    // must say yes"), so every other healthy child went dark until
    // some unrelated attach re-armed the master key in
    // runDebugService - and kept committing RX pages the debugger was
    // never asked to prepare in the meantime.
    //
    // Nothing that reaches here implies the SHARED TRANSPORT died.
    // All four call sites are per-session: the loop-top requested
    // detach, the target's own CMD_DETACH, the post-loop detach and
    // its 50ms retry, and JITEnabler's non-TXM "detach immediately"
    // which never started a loop at all. The two paths that DO know
    // the transport died still clear the process-wide key themselves
    // and are untouched: runDebugService's !continueOK branch, and
    // the background teardown.
    //
    // Per-pid is already the documented contract, JITSupport.h: "a
    // session that ends for a per-process reason and then fails its
    // detach disarms exactly one child".
    //
    // Harmless where it is redundant: the post-loop teardown already
    // ran setDebugSessionListeningForPID(pid, NO) before its detach,
    // so on that path this takes that function's own no-op early
    // return. The loop-top and CMD_DETACH paths are where it bites.
    setDebugSessionListeningForPID(pid, NO);
    logger([NSString stringWithFormat:@"detachDisarm: (pid %d) detach failed - disarmed THIS pid only, process-wide trapping left alone", pid]);
    
    return NO;
}

// Tells content processes whether a debugger is actually listening, as
// opposed to CS_DEBUGGED merely being set on them. See
// fix_debugger_listening_guard.py.
//
// One flag rather than one per process: every session shares a single
// tunnel and they fail together - the logs show six loops ending within
// the same millisecond when it dies.
// ADDED - see fix_per_pid_debugger_listening.py's docstring.
//
// pid -> the notify token for that pid's own listening key. The token is
// held for the whole life of the session rather than registered and
// cancelled around each set: the state lives on the NAME, and a name
// with no registered client can be reaped, which would lose the arm
// between this process setting it and the content process reading it.
static NSMutableDictionary<NSNumber *, NSNumber *> *debugListeningTokens(void) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = [NSMutableDictionary dictionary];
    });
    return tokens;
}

// Its own lock rather than debugSessionStateQueue. That queue is held by
// every runDebugService iteration and is the one cancelAllDebugSessionCalls
// was moved off the main thread to avoid blocking on
// (fix_lifecycle_calls_off_main_thread.py); this is a two-line critical
// section with no FFI inside it and no reason to join that traffic.
static NSLock *debugListeningTokenLock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

void setDebugSessionListeningForPID(int32_t pid, BOOL listening) {
    if (pid <= 0) return;

    NSLock *lock = debugListeningTokenLock();
    [lock lock];

    NSNumber *existing = debugListeningTokens()[@(pid)];
    int token = existing != nil ? existing.intValue : NOTIFY_TOKEN_INVALID;

    if (token == NOTIFY_TOKEN_INVALID) {
        if (!listening) {
            // Never armed, so there is nothing to disarm. The teardown
            // calls this unconditionally, including for loops that
            // joined a standing teardown and never armed at all.
            [lock unlock];
            return;
        }

        // With the per-launch secret - see
        // fix_jit_listening_keys_carry_a_secret.py.
        char name[128];
        int written = snprintf(name, sizeof(name),
                               "com.minh-ton.Reynard.JITDebuggerListening.%s.%d", JITListeningSecret(), pid);
        if (written <= 0 || (size_t)written >= sizeof(name)) {
            [lock unlock];
            return;
        }

        if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
            [lock unlock];
            logger([NSString stringWithFormat:@"jitListening: (pid %d) notify_register_check FAILED - this process will not trap, so it runs interpreted", pid]);
            return;
        }
        debugListeningTokens()[@(pid)] = @(token);
    }

    notify_set_state(token, listening ? 1 : 0);

    if (!listening) {
        notify_cancel(token);
        [debugListeningTokens() removeObjectForKey:@(pid)];
    }
    [lock unlock];

    logger([NSString stringWithFormat:@"jitListening: (pid %d) %@", pid, listening ? @"ARMED - this process may trap" : @"DISARMED - this process will not trap"]);
}

void setDebuggerListeningState(uint64_t listening) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // With the per-launch secret - see
        // fix_jit_listening_keys_carry_a_secret.py.
        char name[128];
        int written = snprintf(name, sizeof(name),
                               "com.minh-ton.Reynard.JITDebuggerListening.%s", JITListeningSecret());
        if (written <= 0 || (size_t)written >= sizeof(name) ||
            notify_register_check(name, &token) != NOTIFY_STATUS_OK) {
            token = NOTIFY_TOKEN_INVALID;
            logger(@"jitListening: notify_register_check FAILED - content processes will not trap, so JIT is degraded");
        }
    });

    if (token == NOTIFY_TOKEN_INVALID) {
        return;
    }

    uint64_t current = 0;
    if (notify_get_state(token, &current) == NOTIFY_STATUS_OK && current == listening) {
        return;
    }

    notify_set_state(token, listening);
    logger([NSString stringWithFormat:@"jitListening: %@", listening ? @"debugger is listening" : @"debugger is GONE - content processes will not trap"]);
}

void runDebugService(int32_t pid, DebugSession *session) {
    if (!session) return;
    
    registerDebugSessionPID(pid);
    registerDebugSessionProxy(pid, session->debugProxy);
    
    // A loop is running, so traps will be serviced - UNLESS a teardown
    // already ran, in which case this attach was in flight when the app
    // backgrounded and is landing too late to be wanted.
    //
    // Re-arming here is how the app ended up running debug loops in the
    // background: requestDetachForAllDebugSessions can only name pids
    // that were attached when it ran, so a late arrival is in no detach
    // set, starts its loop, calls this unconditionally, and nothing ever
    // re-runs the teardown behind it. Device evidence - two loops
    // (pids 1100 and 1172) that started one second after a teardown and
    // were still alive 547 seconds later, keeping trapping enabled, the
    // tunnel keep-alives flowing and the 3-second timer logging.
    //
    // It also feeds the watchdog kill: the more sessions alive across a
    // transition, the more attach/detach churn on the next foreground,
    // and a process left stopped cannot answer the synchronous XPC in
    // EXConcreteExtension's _hostWillEnterForegroundNote:.
    __block BOOL tornDown = NO;
    dispatch_sync(debugSessionStateQueue(), ^{
        tornDown = sDebuggerTeardownRequested;
        if (tornDown) {
            [detachRequestedDebugSessionPIDs() addObject:@(pid)];
            // Joined for the background's reason, so released with the
            // background's pids - see
            // fix_foreground_clear_releases_only_background_pids.py.
            [backgroundDetachRequestedPIDs() addObject:@(pid)];
        }
    });
    if (tornDown) {
        logger([NSString stringWithFormat:
            @"runDebugService: (pid %d) attach landed after teardown - joining it instead of re-arming", pid]);
    } else {
        setDebuggerListeningState(1);
        // ADDED - see fix_per_pid_debugger_listening.py. The
        // process-wide switch above says the debugger is up; this says
        // that THIS pid has a loop about to service it.
        setDebugSessionListeningForPID(pid, YES);
    }
    
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
    logger([NSString stringWithFormat:@"runDebugService: (pid %d) loop starting on thread %@", pid, [NSThread currentThread]]);
    NSInteger debugServiceIteration = 0;
    static const NSInteger kUnconditionalLogIterations = 3;
    static const NSTimeInterval kSlowContinueThresholdSeconds = 1.0;
    
    NSError *commandError = nil;
    BOOL exitPacketPresent = NO;
    BOOL detachedByCommand = NO;
    // Set when the loop ends because sendDebugCommand failed - i.e.
    // the transport died rather than the target exiting. See
    // fix_chunk_coverage_and_dead_connection_detach.py.
    BOOL connectionFailed = NO;

    // ADDED - fix_advance_pc_past_brk_on_detach.py.
    // Nonzero while the target is stopped at a 0xf00d brk whose PC
    // has NOT yet been advanced. Set the instant such a stop is
    // received, cleared the instant pc+4 is written. If the loop
    // exits with this still set, the detach below advances PC first
    // so the target does not resume onto the brk and re-trap into a
    // debugger that is about to be gone.
    uint64_t stoppedAtUnservicedBrkPC = 0;
    NSString *stoppedAtUnservicedBrkThreadID = nil;

    // ADDED - non-breakpoint stops (real faults in the target) were
    // continued in complete silence past iteration 3. Capture 16: a
    // content process sat in a 100Hz EXC_BAD_ACCESS loop for 2295
    // iterations over 23 seconds and the log's first and only mention
    // was the detach packet at backgrounding. Counted and logged at
    // powers of two, same scheme as the jitSkip counter and for the
    // same reason: unconditional logging would flood, silence already
    // cost a session.
    NSInteger nonBreakpointStops = 0;

    // The generated 0xf00d breakpoint normally has one PC.  Keeping this
    // cache on the loop stack gives it the same lifetime as the DebugSession
    // and avoids a process-global PID/PC dictionary that was never evicted.
    NSMutableDictionary<NSNumber *, NSNumber *> *instructionCacheByPC =
        [NSMutableDictionary dictionary];
    
    while (YES) {
        @autoreleasepool {
            debugServiceIteration++;
            // Stamped at the top of every iteration, so a stale value
            // means this loop is not running. See
            // fix_dump_loop_state_on_hang.py.
            recordDebugLoopTick(pid);
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
            // Bracketed, so the dump can tell a loop resting in the wait
            // from one that has left it. See
            // fix_track_loop_waiting_state.py.
            //
            // Straight-line between the two calls: no branch, no break
            // and no early return sits between them, so the flag cannot
            // be stranded at YES. Every exit path out of the loop runs
            // forgetDebugLoopTick, which drops the pid from both maps.
            recordDebugLoopWaiting(pid, YES);
            BOOL continueOK = sendDebugCommand(session->debugProxy, @"c", &stopResponse, &commandError);
            CFAbsoluteTime continueCallEnd = CFAbsoluteTimeGetCurrent();
            recordDebugLoopWaiting(pid, NO);
            NSTimeInterval continueCallDuration = continueCallEnd - continueCallStart;
            
            if (!continueOK) {
                // ADDED - see
                // fix_chunk_coverage_and_dead_connection_detach.py's
                // docstring. Records that this loop ended because the
                // TRANSPORT failed, not because the target exited, so
                // teardown below can skip a detach that cannot
                // possibly succeed.
                // CHANGED - was unconditionally YES. See
                // fix_cancelled_loop_still_detaches.py.
                //
                // An aborted call surfaces the same error as a genuine
                // transport failure, so a deliberate cancellation was
                // being read as a dead connection and the detach below
                // skipped. On device that left twenty-two processes
                // still CS_DEBUGGED with no loop servicing them, and
                // the app was killed two seconds later.
                //
                // CHANGED - see fix_close_before_suspension.py. Was:
                //
                //   connectionFailed = !shouldDetachDebugSessionPID(pid);
                //
                // whose premise was "a failure on a pid whose detach was
                // requested is ours, the connection is fine, and the
                // detach should still run". That held while cancellation
                // was gated OFF, when the only way to arrive here with a
                // detach pending was a spurious error.
                //
                // With cancellation ungated the premise inverts. The
                // failure is ours AND the connection is not fine: we
                // desynced it deliberately a moment ago and are about to
                // free the adapter behind it.
                //
                // The comment further down already predicted the result -
                // "if the abort desynced the stream, it will fail
                // identically ... which would mean cancellation and clean
                // detach cannot coexist". 2026-08-14 19:23 says exactly
                // that: three detaches, three 50ms retries, all failed,
                // and they took EIGHT MINUTES to return because they sat
                // in flight across the suspension - with closeSharedTunnel
                // freeing the adapter out from under them at 19:23:15.146,
                // inside that window.
                //
                // So: skip it. This routes to the existing "skipping
                // detach - transport already dead" branch below, which is
                // now the truth on both paths.
                connectionFailed = YES;
                
                // The transport died, and since every session shares one
                // tunnel they all have. Stop content processes trapping
                // before one of them freezes waiting for an answer that
                // is not coming.
                //
                // UNWRAPPED - see
                // fix_swift_deadcode_and_stale_comments.py. This was
                // `if (connectionFailed) { ... }` sitting directly under
                // the `connectionFailed = YES` above it.
                // connectionFailed is a stack local of runDebugService
                // and no writer sits between the two statements, so the
                // test was provably always true.
                //
                // The PROCESS-WIDE key deliberately, not
                // setDebugSessionListeningForPID: this is one of the two
                // paths that genuinely know the SHARED transport is gone,
                // which fix_detach_disarms_only_its_own_pid.py names as
                // untouched for exactly that reason.
                setDebuggerListeningState(0);
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
                // ADDED - see fix_forget_child_on_target_exit.py's
                // docstring.
                //
                // The one place the app is reliably told a child has
                // died. NotifyChildProcessStarted has no exited
                // counterpart, so without this the pid stays in
                // attachedPIDs for the life of the app and is handed to
                // reattachOrphanedProcesses on every foreground - and
                // once the number is recycled, pidIsAlive reads the new
                // owner as alive and the pass sends it a vAttach.
                //
                // Posted rather than called: this is the ObjC layer and
                // the ledger is Swift, and this mirrors the existing
                // GeckoRuntime.ChildProcessDidStart path that already
                // drives childProcessDidStart. Delivery is synchronous
                // on this thread, and the observer does nothing but hop
                // to attachQueue.
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"Reynard.JITTargetDidExit"
                                  object:nil
                                userInfo:@{@"pid": @(pid)}];
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
            // CHANGED - see fix_reduce_wx_mediation_cost.py's docstring.
            // This read used to happen on EVERY trap, costing one of
            // four round trips each time. Gecko emits exactly one brk
            // site (the inline asm in RequestDebuggerToPrepareRegion,
            // the only "brk #0xf00d" anywhere in patches/), so pc is
            // identical on every trap and the four bytes read back
            // never change. Cached by pc: first trap reads as before,
            // subsequent traps at the same pc skip the round trip
            // entirely. Falls back to reading on a miss, so a
            // different pc simply produces a new entry.
            uint32_t instruction = 0;
            NSNumber *instructionCacheKey = @(pc);
            NSNumber *cachedInstruction = instructionCacheByPC[instructionCacheKey];
            
            if (cachedInstruction) {
                instruction = cachedInstruction.unsignedIntValue;
                instructionResponse = @"cached";
            } else {
                NSString *readInstruction = [NSString stringWithFormat:@"m%llx,4", pc];
                if (!sendDebugCommand(session->debugProxy, readInstruction, &instructionResponse, &commandError)) instructionResponse = nil;
                
                instruction = (uint32_t)parseLittleEndianHex64(instructionResponse ?: @"");
                
                if (instructionResponse.length > 0) {
                    instructionCacheByPC[instructionCacheKey] = @(instruction);
                }
            }
            if (instructionResponse.length == 0 || !instructionIsBreakpoint(instruction)) {
                NSString *signal = packetSignal(stopResponse);

                // A stop that is not our brk is the target faulting for
                // real. Forwarding the signal to a faulted thread just
                // re-runs the faulting instruction, which re-raises the
                // mach exception straight back here - so a crashed
                // thread becomes a silent ~100Hz stop loop and no crash
                // report is ever generated. Log at powers of two with
                // enough of the packet to diagnose without a detach:
                // metype 1 is EXC_BAD_ACCESS, and on the common
                // message/vtable-through-garbage case x0 IS the bad
                // address.
                nonBreakpointStops++;
                if ((nonBreakpointStops & (nonBreakpointStops - 1)) == 0) {
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) NON-BREAKPOINT stop #%ld signal=%@ metype=%@ medata=%@ pc=0x%llx x0=0x%llx thread=%@ (iteration %ld)",
                            pid, (long)nonBreakpointStops,
                            signal ?: @"<none>",
                            packetField(stopResponse, @"metype") ?: @"<none>",
                            packetField(stopResponse, @"medata") ?: @"<none>",
                            pc, x0, threadID ?: @"<none>",
                            (long)debugServiceIteration]);
                }

                // ADDED - see fix_dont_forward_stop_signals.py's
                // docstring.
                //
                // Never re-deliver a signal that stops or kills the
                // target. The branch above is written for a genuine
                // fault, and forwarding is right for one - but
                // interruptLiveDebugSessions manufactures a stop that is
                // neither our brk nor a fault, and it lands here too.
                //
                // Our own 0x03 interrupt comes back as
                // metype=5 (EXC_SOFTWARE) medata=10003 (EXC_SOFT_SIGNAL)
                // signal=11, and the signal field is HEX - 0x11 is 17,
                // SIGSTOP. forwardSignalStop sends vCont;S11, which
                // DELIVERS it. The loop then detaches on its next
                // iteration and nothing ever sends SIGCONT.
                //
                // Device evidence, 2026-08-12 22:42 (build 1b1f7b4): PiP
                // logs "its content process must stay alive in the
                // background", the teardown 467ms later SIGSTOPs all
                // eight sessions including that one, and the audio
                // stutters for the 18 seconds PiP is up. The second PiP
                // cycle did the same to five processes and the app was
                // killed on the restore - a stopped extension cannot
                // answer the synchronous XPC in
                // _hostWillEnterForegroundNote:.
                //
                // Falling through to the top of the loop is the correct
                // response: shouldDetachDebugSessionPID is set by now, so
                // the detach runs and RESUMES the target, which is what
                // the interrupt existed to enable. With no detach pending
                // it sends a plain continue instead. Both are right.
                // CORRECTED - the signal numbers here were wrong in four
                // of five places. See fix_resume_before_detach.py. On
                // Darwin 0x13 is SIGCONT, which is the signal that
                // UN-stops a process - skipping it was backwards.
                // Inert in practice (only 0x11 and 0x09 have ever
                // appeared) but a list whose job is "never let this stop
                // the target" must not contain the one that starts it.
                NSString *stopMedata = packetField(stopResponse, @"medata");
                BOOL isSoftSignal = [stopMedata isEqualToString:@"10003"];
                BOOL isStopOrKillSignal =
                    [signal isEqualToString:@"11"] ||   // SIGSTOP
                    [signal isEqualToString:@"12"] ||   // SIGTSTP
                    [signal isEqualToString:@"15"] ||   // SIGTTIN
                    [signal isEqualToString:@"16"] ||   // SIGTTOU
                    [signal isEqualToString:@"09"];     // SIGKILL

                if (signal && isSoftSignal && isStopOrKillSignal) {
                    logger([NSString stringWithFormat:@"stopSignalSkip: (pid %d) soft signal 0x%@ would stop the target - NOT forwarding, letting the loop detach or continue instead (iteration %ld)", pid, signal, (long)debugServiceIteration]);
                    continue;
                }

                // continue with signal
                if (signal && !forwardSignalStop(session->debugProxy, signal, threadID, &commandError)) break;
                continue;
            }
            
            uint16_t breakpointImmediate = (instruction >> 5) & 0xffff;
            
            if (breakpointImmediate == 0xf00d) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) 0xf00d breakpoint hit at iteration %ld - x0=0x%llx x1=0x%llx x16=%llu", pid, (long)debugServiceIteration, x0, x1, x16]);
                // ADDED - fix_advance_pc_past_brk_on_detach.py: we are
                // now stopped at a brk whose PC is not yet advanced.
                stoppedAtUnservicedBrkPC = pc;
                stoppedAtUnservicedBrkThreadID = threadID;
                if (!x0Field || !x1Field || !x16Field) break;
                
                // CHANGED - see
                // fix_rundebugservice_allocate_and_dispatch.py's
                // docstring. PC is now advanced past the brk BEFORE
                // dispatching, unconditionally, exactly as
                // universal.js does. Previously an unhandled x16 hit
                // `continue` with PC still pointing at the brk, so the
                // target re-trapped on the identical instruction
                // forever.
                if (!writeRegisterValue(session->debugProxy, @"20", pc + 4, threadID, &commandError)) break;
                // ADDED - fix_advance_pc_past_brk_on_detach.py: PC is
                // now past the brk; the detach path need not advance it.
                stoppedAtUnservicedBrkPC = 0;
                
                // x16 is a COMMAND SELECTOR, not a flag:
                //   0 = CMD_DETACH
                //   1 = CMD_PREPARE_REGION
                //   2 = CMD_NEW_BREAKPOINTS
                if (x16 == 0) {
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) target requested DETACH (x16=0)", pid]);
                    detachedByCommand = detachDebuggerSession(session->debugProxy, pid);
                    break;
                }
                
                if (x16 == 2) {
                    // universal.js reads a script out of target memory
                    // and eval()s it. This loop is native Objective-C
                    // with no JS engine, so that cannot be honoured.
                    // Skipping is safe - PC has already been advanced,
                    // so the target proceeds - and logging it shows
                    // whether SpiderMonkey ever actually uses this.
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) target requested NEW_BREAKPOINTS (x16=2) - not supported by the native loop, skipping", pid]);
                    continue;
                }
                
                if (x16 != 1) {
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) unknown x16 command %llu, skipping", pid, x16]);
                    continue;
                }
                
                // CMD_PREPARE_REGION. x0 == 0 && x1 == 0 is a no-op
                // probe; the target just wants to be resumed.
                if (x0 == 0 && x1 == 0) {
                    continue;
                }
                
                uint64_t jitPageAddress = x0;
                
                if (x0 == 0) {
                    // x0 == 0 means ALLOCATE a new RX region of x1
                    // bytes and return its address - it does NOT mean
                    // failure. This previously did `break`, killing
                    // W^X mediation permanently for this process the
                    // first time its JIT arena needed to grow.
                    //
                    // The _M response is a plain big-endian hex
                    // address per the GDB remote protocol, not
                    // little-endian, so strtoull is correct here -
                    // universal.js likewise uses BigInt("0x" + resp)
                    // with no byte swap, unlike every register read.
                    NSString *allocateCommand = [NSString stringWithFormat:@"_M%llx,rx", x1];
                    NSString *allocateResponse = nil;
                    if (!sendDebugCommand(session->debugProxy, allocateCommand, &allocateResponse, &commandError)) {
                        logger([NSString stringWithFormat:@"runDebugService: (pid %d) RX allocation command failed", pid]);
                        break;
                    }
                    if (allocateResponse.length == 0 || [allocateResponse hasPrefix:@"E"]) {
                        logger([NSString stringWithFormat:@"runDebugService: (pid %d) RX allocation rejected by debugserver, response=%@", pid, allocateResponse ?: @"(empty)"]);
                        break;
                    }
                    
                    jitPageAddress = strtoull(allocateResponse.UTF8String, NULL, 16);
                    if (jitPageAddress == 0) {
                        logger([NSString stringWithFormat:@"runDebugService: (pid %d) RX allocation returned an unparseable address: %@", pid, allocateResponse]);
                        break;
                    }
                    
                    logger([NSString stringWithFormat:@"runDebugService: (pid %d) allocating RX region of 0x%llx bytes -> 0x%llx", pid, x1, jitPageAddress]);
                }
                
                if (!prepareMemoryRegion(session->debugProxy, jitPageAddress, x1, &commandError)) break;
                
                // Return the region address to the caller in x0.
                if (!writeRegisterValue(session->debugProxy, @"00", jitPageAddress, threadID, &commandError)) break;
            } else {
                // A brk that is not ours: __builtin_trap() is brk #1 and
                // SpiderMonkey's masm.breakpoint() is brk #0. PC is still
                // sitting on the trapping instruction here, and debugserver
                // does not step over a target-embedded brk, so a bare
                // `continue` resumes onto the same instruction and traps
                // again - forever.
                //
                // That is strictly worse than the crash it hides. Content
                // processes are app extensions; one spinning like this stops
                // answering the synchronous XPC iOS sends on a lifecycle
                // transition, and the watchdog kills the whole app with
                // nothing in the log to explain it.
                //
                // Forwarding SIGTRAP (0x05 - the signal field is hex) lets
                // the target die exactly the way it would with no debugger
                // attached, so the crash report names the real trap site.
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) foreign breakpoint brk #0x%x at pc=0x%llx - forwarding SIGTRAP", pid, breakpointImmediate, pc]);
                if (!forwardSignalStop(session->debugProxy, @"05", threadID, &commandError)) break;
                continue;
            }
        }
    }
    
    logger([NSString stringWithFormat:@"runDebugService: (pid %d) loop exiting after %ld iterations, %.0fms total, exitPacketPresent=%d, detachedByCommand=%d", pid, (long)debugServiceIteration, (CFAbsoluteTimeGetCurrent() - debugServiceLoopStart) * 1000.0, exitPacketPresent, detachedByCommand]);

    // ADDED - see fix_per_pid_debugger_listening.py's docstring.
    //
    // FIRST thing in the teardown, before the detach below is even
    // attempted. From here on nothing is servicing this pid, and that
    // is true whether the detach succeeds, fails both attempts, or is
    // skipped as transport-already-dead. The old process-wide flag
    // could not say this: it was cleared only for a transport failure
    // or a failed detach, and re-armed by the next attach anywhere in
    // the app - roughly every 24 seconds at the observed churn.
    //
    // The target may still be RUNNING here (a loop whose continue was
    // aborted leaves it running), so this is not merely belt and
    // braces - it is the window in which it would otherwise trap into
    // a debugger with no loop behind it.
    setDebugSessionListeningForPID(pid, NO);
    
    // CHANGED - skips the detach when the connection has already died.
    // After a long background, every loop fails at once on resume with
    // exitPacketPresent=0, and each then attempted a detach over a
    // dead transport that could only time out. Fifteen of those in
    // sequence is the multi-second stall on resume, landing during the
    // exact window tab restoration needs - the most likely trigger for
    // the hang watchdog and the observed total tab loss. See
    // fix_chunk_coverage_and_dead_connection_detach.py.
    if (!exitPacketPresent && !detachedByCommand && !connectionFailed) {
        // ADDED - fix_advance_pc_past_brk_on_detach.py.
        // The loop broke while the target was still stopped at a
        // 0xf00d brk whose PC was never advanced (a malformed stop
        // packet took the field-check break, or the pc+4 write
        // failed). connectionFailed is NO here, so the tunnel is
        // still live - advance PC past the brk before the D so the
        // target resumes onto the next instruction instead of
        // re-trapping into a debugger that is about to be gone.
        if (stoppedAtUnservicedBrkPC != 0 && stoppedAtUnservicedBrkThreadID) {
            NSError *pcAdvanceError = nil;
            if (writeRegisterValue(session->debugProxy, @"20", stoppedAtUnservicedBrkPC + 4, stoppedAtUnservicedBrkThreadID, &pcAdvanceError)) {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) advanced PC past unserviced brk before detach", pid]);
            } else {
                logger([NSString stringWithFormat:@"runDebugService: (pid %d) could not advance PC before detach: %@", pid, pcAdvanceError.localizedDescription ?: @"write failed"]);
            }
            stoppedAtUnservicedBrkPC = 0;
        }

        detachedByCommand = detachDebuggerSession(session->debugProxy, pid);
        
        // ADDED - one retry. See fix_retry_detach_after_cancel.py.
        //
        // The device logs show 28 "Detach failed" against 0 "skipping
        // detach", so this line is reached and the send itself fails.
        // The likely reason is timing: cancelAllDebugSessionCalls
        // aborts the in-flight read, and this D packet goes out
        // microseconds later on a proxy still unwinding from that
        // abort.
        //
        // A process whose detach fails stays CS_DEBUGGED with no live
        // loop, which is exactly the state that leaves an extension
        // unable to answer the synchronous XPC iOS sends on the next
        // lifecycle transition - and the watchdog kills the app for it.
        //
        // If the connection was merely interrupted this should succeed.
        // If the abort desynced the stream, it will fail identically
        // and the log will say so - which is equally worth knowing,
        // since it would mean cancellation and clean detach cannot
        // coexist and the answer lies elsewhere.
        if (!detachedByCommand) {
            usleep(50000);
            detachedByCommand = detachDebuggerSession(session->debugProxy, pid);
            logger([NSString stringWithFormat:@"runDebugService: (pid %d) detach retry after 50ms %@", pid, detachedByCommand ? @"SUCCEEDED" : @"failed again"]);
        }
    } else if (connectionFailed) {
        // The D packet cannot go anywhere: the transport this session
        // would have sent it on is what died. But saying only "skipping
        // detach" understates what is being left behind, and that
        // understatement cost an app kill.
        //
        // If this process trapped before the transport died, it is
        // stopped now and nothing will ever resume it - the debugger
        // that could is gone. It stays alive, registered, and unable to
        // answer the synchronous XPC iOS sends on the next foreground
        // transition, which is a 0x8BADF00D scene-update kill for the
        // whole app. One capture shows exactly that sequence, eight
        // minutes apart.
        //
        // The heartbeat is the thing that can tell stopped from merely
        // busy, and it needs a moment to notice, so the verdict is not
        // made here. What is recorded here is the fact that matters to
        // it: this pid has no debugger left, so if it does look stopped
        // later, it is not going to recover.
        logger([NSString stringWithFormat:
                @"runDebugService: (pid %d) skipping detach - transport already "
                @"dead; process left with no debugger and may be stopped", pid]);
    }
    
    // Before freeDebugSession below, so a concurrent cancellation can
    // never see a freed proxy - see
    // fix_cancel_blocked_debug_loops.py.
    unregisterDebugSessionProxy(pid);
    forgetDebugLoopTick(pid);
    unregisterDebugSessionPID(pid);
    unregisterJITEndpointForPID(pid);
    freeDebugSession(session);
    free(session);
}

// RENAMED from createDeviceProvider - see fix_retry_tunnel_create.py.
// The body is unchanged; this is now one ATTEMPT, and the wrapper
// below is what the rest of the process calls.
static DeviceProvider *createDeviceProviderOnce(NSString *pairingFilePath, NSString *targetAddress, NSError **error) {
    // ADDED - granular, step-by-step logging throughout this entire
    // function - see
    // fix_instrument_create_device_provider_internals.py's docstring.
    // This function never had any internal logging at all before -
    // everything visible came from its caller, before and after,
    // leaving everything in between (this exact function's own body)
    // completely invisible. Confirmed as a real, direct gap: a
    // genuinely isolated attempt (confirmed via idevice_init_logger's
    // own timestamp as the true start-of-logging boundary) produced
    // zero native-library output for its entire ~89s duration, with
    // no way to tell which specific step inside this function that
    // silence actually began at.
    CFAbsoluteTime fileCheckStart = CFAbsoluteTimeGetCurrent();
    logger(@"createDeviceProvider: starting fileExistsAtPath check");
    BOOL pairingFileExists = [[NSFileManager defaultManager] fileExistsAtPath:pairingFilePath];
    logger([NSString stringWithFormat:@"createDeviceProvider: fileExistsAtPath %@, call took %.0fms", pairingFileExists ? @"succeeded" : @"FAILED (file missing)", (CFAbsoluteTimeGetCurrent() - fileCheckStart) * 1000.0]);
    if (!pairingFileExists) {
        if (error) *error = MakeError(PairingFileMissing);
        return NULL;
    }
    
    RpPairingFileHandle *rpPairingFile = NULL;
    CFAbsoluteTime pairingReadStart = CFAbsoluteTimeGetCurrent();
    logger(@"createDeviceProvider: starting rp_pairing_file_read");
    IdeviceFfiError *ffiError = rp_pairing_file_read(pairingFilePath.fileSystemRepresentation, &rpPairingFile);
    logger([NSString stringWithFormat:@"createDeviceProvider: rp_pairing_file_read %@, call took %.0fms", ffiError ? @"FAILED" : @"succeeded", (CFAbsoluteTimeGetCurrent() - pairingReadStart) * 1000.0]);
    if (ffiError) {
        if (error) *error = MakeError(PairingFileReadFailed);
        idevice_error_free(ffiError);
        return NULL;
    }
    
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(rppairingPort);
    
    logger(@"createDeviceProvider: starting inet_pton");
    if (inet_pton(AF_INET, targetAddress.UTF8String, &address.sin_addr) != 1) {
        logger(@"createDeviceProvider: inet_pton FAILED");
        rp_pairing_file_free(rpPairingFile);
        if (error) *error = MakeError(InvalidTargetAddress);
        return NULL;
    }
    logger(@"createDeviceProvider: inet_pton succeeded");
    
    AdapterHandle *adapter = NULL;
    RsdHandshakeHandle *handshake = NULL;
    
    // CHANGED - unique per-call hostname instead of the single,
    // static "Reynard" string every process and every attempt used to
    // share - see fix_unique_tunnel_hostname.py's docstring. This
    // hostname is sent to the device as part of the RPPairing
    // handshake itself, not just a local label - StikDebug's own
    // confirmed source uses distinct hostnames per purpose
    // ("StikDebug", "StikDebugDebug", "StikDebugHeartbeat"), never
    // reusing one across simultaneous connections the way every
    // single tunnel this codebase has ever created did.
    NSString *uniqueHostname = [NSString stringWithFormat:@"Reynard-%d-%llu", getpid(), (unsigned long long)(CFAbsoluteTimeGetCurrent() * 1000.0)];
    CFAbsoluteTime ownTunnelCallStart = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"createDeviceProvider: starting tunnel_create_rppairing (hostname=%@) on thread %@", uniqueHostname, [NSThread currentThread]]);
    ffiError = tunnel_create_rppairing((const struct sockaddr *)&address, (socklen_t)sizeof(address), uniqueHostname.UTF8String, rpPairingFile, NULL, NULL, &adapter, &handshake);
    logger([NSString stringWithFormat:@"createDeviceProvider: tunnel_create_rppairing %@, call took %.0fms", ffiError ? @"FAILED" : @"succeeded", (CFAbsoluteTimeGetCurrent() - ownTunnelCallStart) * 1000.0]);
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
    // fix_remove_heartbeat_contention.py's docstring.
    //
    // CORRECTED - fix_delete_dead_transport_code.py. The rest of this
    // comment used to point at DeviceProvider's heartbeatClient field,
    // and at the guard on it that freeDeviceProvider used to open
    // with, as what made that removal safe. Neither exists any more:
    // the field, the heartbeatRunning flag beside it, startHeartbeat
    // itself and the four heartbeat_* FFI declarations are all gone,
    // so there is nothing left here to keep NULL.
    
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

// ADDED - see fix_retry_tunnel_create.py's docstring for the measurement.
//
// Short version: across the 2026-08-21 capture, six tunnel runs
// connected and five of them needed one to seven further attempts,
// 3.0-8.4s after the first. Nothing retried, so those repeats were
// unrelated callers arriving by chance. The run that killed the app made
// two attempts 1.2ms apart and stopped, with nine seconds of watchdog
// budget left and a content process stopped at a trap that only a
// re-attached debugger could release.
static const double kTunnelRetryBudgetSeconds = 9.0;
static const double kTunnelRetrySliceSeconds = 0.1;

// Only the failure actually observed on device. Anything else - pairing
// file missing, unreadable, bad target address - is permanent, and must
// keep failing on the first attempt exactly as before.
static BOOL tunnelFailureIsTransient(NSError *failure) {
    if (!failure || failure.code != TunnelCreateFailed) {
        return NO;
    }
    NSString *reason = failure.localizedDescription ?: @"";
    return [reason containsString:@"Connection refused"];
}

// Sleeps in slices so a teardown is noticed within one slice rather than
// at the end of a whole backoff. NO means the wait was cut short.
static BOOL tunnelRetryWait(double seconds, unsigned int generationAtEntry) {
    double remaining = seconds;
    while (remaining > 0.0) {
        if (atomic_load(&sTunnelTeardownGeneration) != generationAtEntry) {
            return NO;
        }
        double slice = remaining < kTunnelRetrySliceSeconds
            ? remaining : kTunnelRetrySliceSeconds;
        // NSThread rather than usleep: no cast, no feature-test macro,
        // and Foundation is already imported here.
        [NSThread sleepForTimeInterval:slice];
        remaining -= slice;
    }
    return atomic_load(&sTunnelTeardownGeneration) == generationAtEntry;
}

// ADDED - see fix_tunnel_retry_cooloff.py.
//
// The budget above is per CALL and shared nothing with the next one, so
// against an endpoint that is simply refusing, every caller paid the
// whole 9.0s over again on the same serial providerQueue. One foreground
// sends six at it - prewarm at willEnterForeground, prewarm at
// didBecomeActive, the JIT-less probe, and up to three slot-holding
// attaches - which is 54 seconds of retry to establish a fact the first
// nine seconds already established.
//
// And an attempt is not confined to this queue. tunnel_create_rppairing
// goes through run_sync_local (idevice ffi/src/lib.rs:265-272), which
// holds the process-global LOCAL_RUNTIME_GUARD mutex (:174) for the
// whole call - the same lock every attach's remote_server_connect_rsd
// and debug_proxy_connect_rsd and the DDI mount take. So each attempt
// blocks attaches that were never behind providerQueue at all. The lock
// is released between attempts (the backoff sleeps here hold nothing),
// so what these repeated budgets really cost is repeated windows of
// process-wide FFI contention.
//
// WHO PAYS WHAT, because getting this backwards would delete the rescue
// path: the FIRST caller still runs the complete budget, every attempt
// and every backoff. That is the caller the 2026-09-01 capture shows
// rescuing a foreground ("tunnelRetry: succeeded on attempt 6 after
// 3.2s"). This is a note it LEAVES BEHIND once it has been refused on
// every attempt of the full budget, and only the SECOND through Nth
// caller reads it.
//
// 3.0s because that is the lower edge of the 3.0-8.4s reconnect band
// this endpoint has actually been measured at - the fastest it has ever
// been seen to go from refusing to accepting. Below that the suppressed
// window contains no observed recovery at all; above it the next real
// arrival waits longer than it should for its own full budget, which is
// the thing that actually finds a returning endpoint. The first caller's
// 9.0s already spans the whole band, so a note only ever means "refused
// across more than the widest reconnect on record".
static const double kTunnelRefusalCoolOffSeconds = 3.0;

// Serial and private to the three accessors below, so the deadline and
// the generation it belongs to are always read and written together.
// Same idiom as debugSessionStateQueue above rather than a second kind
// of lock in this file.
static dispatch_queue_t tunnelRefusalStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.minh-ton.Reynard.JITSupport.TunnelRefusalStateQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// 0.0 means no cool-off stands. Only ever touched on the queue above.
static CFAbsoluteTime sTunnelRefusedUntil = 0.0;
static unsigned int sTunnelRefusedAtGeneration = 0;

// Seconds of cool-off left, or 0.0 when the caller should run the whole
// budget. Clears a note that can no longer apply as it goes, so a stale
// one is never examined twice.
//
// The generation is what ties a note to one foreground. Every background
// teardown bumps it (requestDetachForAllDebugSessions, synchronously),
// so a note taken before a background can never be honoured after one -
// which is the "clear it on a foreground transition" this needs, out of
// the counter that is already here instead of new lifecycle state. The
// app cannot foreground without having backgrounded, and nothing calls
// createDeviceProvider in between: prewarmSharedTunnel and
// probeSharedTunnelWithCompletion both return early when
// applicationForegroundFromAnyQueue() is NO.
static double tunnelRefusalCoolOffRemaining(unsigned int currentGeneration, CFAbsoluteTime now) {
    __block double remaining = 0.0;
    dispatch_sync(tunnelRefusalStateQueue(), ^{
        if (sTunnelRefusedUntil <= 0.0) {
            return;
        }
        if (sTunnelRefusedAtGeneration != currentGeneration || now >= sTunnelRefusedUntil) {
            sTunnelRefusedUntil = 0.0;
            return;
        }
        remaining = sTunnelRefusedUntil - now;
    });
    return remaining;
}

// Written ONLY where a caller has been refused on every attempt of a
// complete budget. Never on a teardown abort - that call proved nothing
// about the endpoint, it only got out of closeSharedTunnel's way - and
// never on a permanent failure, which returns on attempt 1 and never
// reaches the loop's exits.
static void noteTunnelRefusedForWholeBudget(unsigned int generation, CFAbsoluteTime now) {
    dispatch_sync(tunnelRefusalStateQueue(), ^{
        sTunnelRefusedUntil = now + kTunnelRefusalCoolOffSeconds;
        sTunnelRefusedAtGeneration = generation;
    });
}

// Any success retires the note at once: the endpoint is answering, so
// nothing queued behind this call should be failing fast on it.
static void clearTunnelRefusalCoolOff(void) {
    dispatch_sync(tunnelRefusalStateQueue(), ^{
        sTunnelRefusedUntil = 0.0;
    });
}

DeviceProvider *createDeviceProvider(NSString *pairingFilePath, NSString *targetAddress, NSError **error) {
    static const double backoff[] = { 0.15, 0.30, 0.50, 0.75, 1.00 };
    static const size_t backoffCount = sizeof(backoff) / sizeof(backoff[0]);

    const unsigned int generationAtEntry =
        atomic_load(&sTunnelTeardownGeneration);
    const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    const CFAbsoluteTime deadline = started + kTunnelRetryBudgetSeconds;
    unsigned long attempt = 0;
    NSError *lastAttemptError = nil;

    // ADDED - fix_tunnel_retry_cooloff.py, part (a).
    //
    // The ONLY early exit, and it fires only on a note another call left
    // behind after being refused across a whole budget. A first caller
    // cannot take this branch: there is nothing to read until some call
    // has already spent the full 9.0s. That asymmetry is the entire
    // point - the first caller is the one that rescues the foreground,
    // and it still pays every attempt and every backoff below.
    const double coolOffLeft = tunnelRefusalCoolOffRemaining(generationAtEntry, started);
    if (coolOffLeft > 0.0) {
        logger([NSString stringWithFormat:
            @"tunnelRetry: coolOff - a caller ahead of this one was refused for the whole %.1fs budget, %.1fs of cool-off left; failing fast instead of re-running it",
            kTunnelRetryBudgetSeconds, coolOffLeft]);
        if (error) {
            // Same domain and code the budget-exhausted path returns, so
            // callers see one kind of tunnel failure. Deliberately does
            // NOT say "Connection refused": that is the string
            // tunnelFailureIsTransient matches, and this is not an
            // attempt result.
            *error = [NSError errorWithDomain:ErrorDomain code:TunnelCreateFailed userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create RPPairing tunnel: the endpoint refused every attempt of a full %.1fs budget moments ago, %.1fs of cool-off left", kTunnelRetryBudgetSeconds, coolOffLeft]
            }];
        }
        return NULL;
    }

    for (;;) {
        // ADDED - fix_tunnel_retry_cooloff.py, part (b).
        //
        // The budget bounds when an attempt may START, and an attempt's
        // own duration is unbounded - this file records a
        // tunnel_create_rppairing that ran ~89s - so an attempt entered
        // at or past the deadline spends budget that is already spent.
        //
        // It does not only cost this queue. That call holds the idevice
        // crate's process-global LOCAL_RUNTIME_GUARD for its whole
        // duration (ffi/src/lib.rs:174, taken in run_sync_local at
        // :265-272), which is the same mutex every other pid's
        // remote_server_connect_rsd and debug_proxy_connect_rsd need -
        // on the CONCURRENT attachWorkQueue, inside a 10s scene-update
        // budget.
        //
        // The scheduling check further down stops one being planned;
        // this is the invariant, and it is what catches a backoff whose
        // slices overslept. The attempt > 0 guard says out loud that the
        // FIRST attempt is never affected - it could not be, since the
        // deadline is 9.0s past the CFAbsoluteTimeGetCurrent() that set
        // `started`, but this loop must not have to be re-derived to see
        // that.
        if (attempt > 0) {
            const CFAbsoluteTime beforeAttempt = CFAbsoluteTimeGetCurrent();
            if (beforeAttempt >= deadline) {
                logger([NSString stringWithFormat:
                    @"tunnelRetry: giving up after %lu attempt(s) over %.1fs - the %.1fs budget was already spent when attempt %lu came up, not starting it; %.1fs cool-off armed",
                    attempt, beforeAttempt - started, kTunnelRetryBudgetSeconds, attempt + 1, kTunnelRefusalCoolOffSeconds]);
                noteTunnelRefusedForWholeBudget(generationAtEntry, beforeAttempt);
                if (error) *error = lastAttemptError;
                return NULL;
            }
        }

        NSError *attemptError = nil;
        DeviceProvider *provider =
            createDeviceProviderOnce(pairingFilePath, targetAddress, &attemptError);
        attempt++;
        // ADDED - hoisted so the pre-attempt exit above can report the
        // real reason the last attempt failed rather than a bare NULL.
        lastAttemptError = attemptError;

        if (provider) {
            // ADDED - the endpoint is answering. Retire any note left by
            // an earlier call so nothing behind this one fails fast on
            // it.
            clearTunnelRefusalCoolOff();
            if (attempt > 1) {
                logger([NSString stringWithFormat:
                    @"tunnelRetry: succeeded on attempt %lu after %.1fs",
                    attempt, CFAbsoluteTimeGetCurrent() - started]);
            }
            return provider;
        }

        if (!tunnelFailureIsTransient(attemptError)) {
            if (error) *error = attemptError;
            return NULL;
        }

        // The app backgrounded while this call was running.
        // closeSharedTunnel is queued behind us on providerQueue and has
        // a suspension deadline to meet.
        if (atomic_load(&sTunnelTeardownGeneration) != generationAtEntry) {
            logger([NSString stringWithFormat:
                @"tunnelRetry: aborting after attempt %lu - a background teardown started, and closeSharedTunnel is queued behind this call",
                attempt]);
            if (error) *error = attemptError;
            return NULL;
        }

        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now >= deadline) {
            logger([NSString stringWithFormat:
                @"tunnelRetry: giving up after %lu attempt(s) over %.1fs - still refused; %.1fs cool-off armed",
                attempt, now - started, kTunnelRefusalCoolOffSeconds]);
            // ADDED - fix_tunnel_retry_cooloff.py. Here and at the two
            // other budget-exhausted exits only: this call was refused
            // on every attempt of a complete budget, which is the one
            // fact worth handing to the callers queued behind it.
            noteTunnelRefusedForWholeBudget(generationAtEntry, now);
            if (error) *error = attemptError;
            return NULL;
        }

        double wait = backoff[attempt - 1 < backoffCount ? attempt - 1 : backoffCount - 1];
        // CHANGED - fix_tunnel_retry_cooloff.py, part (b). Was:
        //
        //     if (now + wait > deadline) { wait = deadline - now; }
        //
        // which slept exactly to the deadline and then started one more
        // attempt from it, making the real worst case the 9.0s budget
        // PLUS a whole attempt of unbounded duration - and that attempt
        // holds LOCAL_RUNTIME_GUARD (see the pre-attempt check above)
        // against every other attach in the process while it runs.
        //
        // The cost is the tail: the loop stops at the last point a whole
        // backoff still fits, giving up at most one backoff earlier than
        // before - <=1.0s worst case, 216ms at the 7ms attempt cost the
        // capture shows. With those numbers the twelfth attempt starts
        // at +8.777s and the loop ends at +8.784s; the only attempt lost
        // is the one the old clamp started at exactly +9.000s. The
        // observed reconnect band tops out at 8.4s, so an endpoint
        // coming back anywhere in it is still caught. And a caller
        // arriving after the cool-off runs a fresh FULL budget, which is
        // a better use of those seconds than one clamped attempt at the
        // wire.
        if (now + wait >= deadline) {
            logger([NSString stringWithFormat:
                @"tunnelRetry: giving up after %lu attempt(s) over %.1fs - %.0fms of the %.1fs budget left, too little to start attempt %lu; %.1fs cool-off armed",
                attempt, now - started, (deadline - now) * 1000.0, kTunnelRetryBudgetSeconds, attempt + 1, kTunnelRefusalCoolOffSeconds]);
            noteTunnelRefusedForWholeBudget(generationAtEntry, now);
            if (error) *error = attemptError;
            return NULL;
        }
        logger([NSString stringWithFormat:
            @"tunnelRetry: attempt %lu refused, retrying in %.0fms (%.1fs of budget left)",
            attempt, wait * 1000.0, deadline - now]);

        if (!tunnelRetryWait(wait, generationAtEntry)) {
            logger([NSString stringWithFormat:
                @"tunnelRetry: aborting mid-backoff after attempt %lu - a background teardown started",
                attempt]);
            if (error) *error = attemptError;
            return NULL;
        }
    }
}

void freeDebugSession(DebugSession *session) {
    if (session->debugProxy) { debug_proxy_free(session->debugProxy); session->debugProxy = NULL; }
    if (session->remoteServer) { remote_server_free(session->remoteServer); session->remoteServer = NULL; }
    if (session->handshake) { rsd_handshake_free(session->handshake); session->handshake = NULL; }
    if (session->adapter) { adapter_free(session->adapter); session->adapter = NULL; }
}

void freeDeviceProvider(DeviceProvider *provider) {
    // CHANGED - fix_delete_dead_transport_code.py removed the two
    // heartbeat lines that used to open this body. heartbeatClient was
    // never assigned a non-NULL value anywhere in the tree - the
    // provider is calloc'd and only adapter and handshake are ever set -
    // so that guard could not fire. heartbeatRunning was the latch a
    // startHeartbeat block polled, and clearing it here was never a
    // synchronisation: the block held the raw provider pointer and this
    // function free()s it three lines later.
    if (!provider) return;
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

// MARK: JIT endpoint registration
//
// DELETED - see fix_delete_dead_transport_code.py.
//
// What lived here was a TCP connectivity monitor: a 1Hz dispatch timer
// on its own serial queue that round-robined the registered endpoints,
// opened a non-blocking probe socket to one of them per tick with a
// 350ms select() timeout, counted consecutive failures, and on the
// second one latched itself off and posted the notification
// "me-minh-ton.jit.endpoint-monitor-failed".
//
// Two independent reasons it was already dead:
//
//   1. startEndpointMonitorLocked opened with
//          static const BOOL kEndpointMonitorHasConsumer = NO;
//          if (!kEndpointMonitorHasConsumer) return;
//      so the timer was never created, endpointMonitorTimer stayed nil
//      for the life of the process, and the tick never ran.
//   2. Nothing observes the notification. A repo-wide grep for
//      "me-minh-ton.jit.endpoint-monitor-failed" across .m .h .mm .c
//      .swift .patch .plist .pbxproj found the postNotificationName
//      call and the comment recording (1). There is no addObserver for
//      it anywhere - the recovery it was built to trigger was never
//      written.
//
// With the tick gone the two tables had no reader left. Every surviving
// reference to endpointFailureCounts and monitoredEndpointsByPID only
// REMOVED entries; the one line that ever inserted a failure count was
// inside the tick, so the table was provably always empty and the
// removals were no-ops on nothing. endpointMonitorCursor,
// endpointFailureLatched, endpointMonitorTimer and endpointMonitorQueue
// followed for the same reason, one grep at a time.
//
// The three entry points below are KEPT, deliberately, even though
// their bodies are now empty. They have four real call sites -
// runDebugService here in this file, and JITEnabler.m's attach path and
// detachAllJITSessions - and removing a public function is a wider
// blast radius than emptying one. What actually cost something is gone:
// register and unregister each paid a dispatch_async hop onto
// endpointMonitorQueue on EVERY attach and EVERY teardown, and reset
// paid a dispatch_sync, all to maintain a table nothing read.
//
// If a consumer is ever written, git history has the whole thing - but
// note what comes back with it. probeTCPEndpoint did
//
//      fd_set writeSet;
//      FD_ZERO(&writeSet);
//      FD_SET(socketFD, &writeSet);
//
// with no check that socketFD < FD_SETSIZE. fd_set is a fixed 1024-bit
// bitmap and FD_SET is an unchecked store into it, so the first probe
// taken once this process held 1024 or more descriptors would have
// written past writeSet into the adjacent stack. It never fired only
// because the timer never started. Fix that before re-enabling anything.

void registerJITEndpointForPID(int32_t pid, NSString *targetAddress, uint16_t port) {
    (void)pid;
    (void)targetAddress;
    (void)port;
}

void unregisterJITEndpointForPID(int32_t pid) {
    (void)pid;
}

void resetJITEndpointMonitor(void) {
}
