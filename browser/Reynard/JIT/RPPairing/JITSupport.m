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
#include <notify.h>
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

// Sticky counterpart to detachRequestedDebugSessionPIDs, which can only
// ever name the pids that were already attached when the teardown ran.
// An attach still in flight at that moment completes afterwards and is
// in no such set, so without this it starts a loop, re-arms trapping and
// keeps running in the background.
//
// Only ever touched on debugSessionStateQueue().
static BOOL sDebuggerTeardownRequested = NO;

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
        read(fd, data.mutableBytes, (size_t)fileSize);
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

// Runs in every process that loads this translation unit. Gated to the
// Helper extension, which is the debuggee - the main app is the
// debugger and never carries CS_DEBUGGED, so checking there would
// always and correctly read false.
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

void recordDebugLoopWaiting(int32_t pid, BOOL waiting) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
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

        logger([NSString stringWithFormat:@"%@:   pid %d %@ (%.0fms)%@",
                tag, pid,
                isWaiting == nil ? @"UNKNOWN    " : (waiting ? @"WAITING    " : @"NOT WAITING"),
                ageMs,
                (isWaiting != nil && !waiting) ? @"  <<< SUSPECT" : @""]);
    }
}

static void registerDebugSessionPID(int32_t pid) {
    if (pid <= 0) return;
    
    dispatch_sync(debugSessionStateQueue(), ^{
        NSNumber *key = @(pid);
        [activeDebugSessionPIDs() addObject:key];
        [detachRequestedDebugSessionPIDs() removeObject:key];
    });
    
    addPIDToSharedActiveSessions(pid);
    
    // DIAGNOSTIC - the single most informative unmeasured bit. Every
    // other signal so far confirms Reynard's own side of the
    // handshake; this confirms whether the KERNEL agrees the target is
    // actually debugged, which is the hard precondition for JIT.
    logger([NSString stringWithFormat:@"registerDebugSessionPID: pid %d CS_DEBUGGED=%@", pid, processIsDebugged(pid) ? @"YES" : @"NO"]);
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

// ADDED - see fix_interrupt_attaching_sessions.py.
//
// Proxies whose vAttach is still IN FLIGHT. Deliberately separate from
// debugSessionProxies: registering a half-built session there would
// expose it to cancelAllDebugSessionCalls and
// requestDetachForAllDebugSessions, both of which assume a complete
// session.
static NSMutableDictionary<NSNumber *, NSValue *> *attachingDebugSessionProxies(void) {
    static NSMutableDictionary<NSNumber *, NSValue *> *proxies = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxies = [NSMutableDictionary dictionary];
    });
    return proxies;
}

void registerAttachingDebugSessionProxy(int32_t pid, DebugProxyHandle *proxy) {
    if (pid <= 0 || !proxy) return;

    dispatch_sync(debugSessionStateQueue(), ^{
        attachingDebugSessionProxies()[@(pid)] = [NSValue valueWithPointer:proxy];
    });
}

void unregisterAttachingDebugSessionProxy(int32_t pid) {
    if (pid <= 0) return;

    dispatch_sync(debugSessionStateQueue(), ^{
        [attachingDebugSessionProxies() removeObjectForKey:@(pid)];
    });
}

// Sends the GDB interrupt byte to every target whose vAttach has not
// yet returned.
//
// vAttach stops its target for the ~1012ms the call takes, and iOS
// messages every extension SYNCHRONOUSLY on a lifecycle transition. A
// stopped extension cannot reply, so the main thread blocks and the
// watchdog kills the app - confirmed from a log ending mid-attach with
// two attaches in flight and neither reply ever arriving.
//
// 0x03 is out-of-band: handled outside the request/response sequence,
// so unlike injecting a "$c#63" packet it cannot desync a connection
// another thread is parked reading. StikDebug sends exactly this byte
// to interrupt a running target.
//
// It may well do nothing here, since our target is already stopped
// rather than running - hence the toggle.
void interruptAttachingDebugSessions(void) {
    __block NSUInteger interruptedCount = 0;
    __block NSUInteger attachingCount = 0;

    dispatch_sync(debugSessionStateQueue(), ^{
        attachingCount = attachingDebugSessionProxies().count;

        for (NSValue *proxyValue in attachingDebugSessionProxies().allValues) {
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
    });

    logger([NSString stringWithFormat:@"interruptAttachingDebugSessions: %lu attach(es) in flight, interrupted %lu", (unsigned long)attachingCount, (unsigned long)interruptedCount]);
}

// Interrupts every LIVE session, as opposed to
// interruptAttachingDebugSessions which handles attaches still in
// flight. See fix_interrupt_before_detach.py.
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
    __block NSUInteger liveCount = 0;
    __block NSUInteger interruptedCount = 0;

    dispatch_sync(debugSessionStateQueue(), ^{
        liveCount = debugSessionProxies().count;

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
    });

    logger([NSString stringWithFormat:@"interruptLiveDebugSessions: %lu live session(s), interrupted %lu", (unsigned long)liveCount, (unsigned long)interruptedCount]);
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
void clearDebuggerTeardownRequest(void) {
    dispatch_async(debugSessionStateQueue(), ^{
        if (!sDebuggerTeardownRequested) {
            return;
        }
        sDebuggerTeardownRequested = NO;
        logger(@"clearDebuggerTeardownRequest: foreground - attaches are wanted again");
    });
}

void requestDetachForAllDebugSessions(void) {
    // CHANGED - dispatch_async for the same reason as
    // cancelAllDebugSessionCalls above. Called from
    // sceneDidEnterBackground on the main thread, onto a queue fourteen
    // debug loops are already using constantly.
    //
    // Blocking never guaranteed promptness anyway - only that the main
    // thread waited, which is the thing that froze.
    dispatch_async(debugSessionStateQueue(), ^{
        NSMutableSet<NSNumber *> *active = activeDebugSessionPIDs();
        [detachRequestedDebugSessionPIDs() unionSet:active];
        // Sticky, so an attach that lands after this point joins the
        // teardown instead of re-arming the debugger behind it.
        sDebuggerTeardownRequested = YES;

        logger([NSString stringWithFormat:@"requestDetachForAllDebugSessions: requested detach for %lu active session(s)", (unsigned long)active.count]);
    });

    // After the flag is set, so every interrupted loop finds the request
    // waiting when it comes back round. See
    // fix_interrupt_before_detach.py.
    //
    // Without this the request sits unread against loops blocked in a
    // continue, which for an idle page may be minutes away from
    // returning on its own.
    interruptLiveDebugSessions();
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
        return YES;
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
    setDebuggerListeningState(0);
    
    return NO;
}

// Tells content processes whether a debugger is actually listening, as
// opposed to CS_DEBUGGED merely being set on them. See
// fix_debugger_listening_guard.py.
//
// One flag rather than one per process: every session shares a single
// tunnel and they fail together - the logs show six loops ending within
// the same millisecond when it dies.
void setDebuggerListeningState(uint64_t listening) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (notify_register_check("com.minh-ton.Reynard.JITDebuggerListening", &token) != NOTIFY_STATUS_OK) {
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
        }
    });
    if (tornDown) {
        logger([NSString stringWithFormat:
            @"runDebugService: (pid %d) attach landed after teardown - joining it instead of re-arming", pid]);
    } else {
        setDebuggerListeningState(1);
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
                // Cancellation and detach always happen together, in
                // sceneDidEnterBackground. So a failure on a pid whose
                // detach was requested is ours, the connection is fine,
                // and the detach should still run. A genuine transport
                // failure has no detach pending and still skips it.
                connectionFailed = !shouldDetachDebugSessionPID(pid);
                
                // The transport died, and since every session shares one
                // tunnel they all have. Stop content processes trapping
                // before one of them freezes waiting for an answer that
                // is not coming.
                if (connectionFailed) {
                    setDebuggerListeningState(0);
                }
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
            static NSMutableDictionary<NSString *, NSNumber *> *cachedInstructionByPC = nil;
            static dispatch_once_t instructionCacheOnce;
            dispatch_once(&instructionCacheOnce, ^{
                cachedInstructionByPC = [NSMutableDictionary dictionary];
            });
            
            uint32_t instruction = 0;
            // Keyed by pid as well as pc. This dictionary is a file-scope
            // static shared by every runDebugService loop for every pid and
            // never evicted, and on a hit the loop advances PC and writes x0
            // WITHOUT reading target memory - so a pc-only key lets one
            // process's classification drive register writes into another.
            NSString *instructionCacheKey = [NSString stringWithFormat:@"%d:%llx", pid, pc];
            NSNumber *cachedInstruction = nil;
            @synchronized (cachedInstructionByPC) {
                cachedInstruction = cachedInstructionByPC[instructionCacheKey];
            }
            
            if (cachedInstruction) {
                instruction = cachedInstruction.unsignedIntValue;
                instructionResponse = @"cached";
            } else {
                NSString *readInstruction = [NSString stringWithFormat:@"m%llx,4", pc];
                if (!sendDebugCommand(session->debugProxy, readInstruction, &instructionResponse, &commandError)) instructionResponse = nil;
                
                instruction = (uint32_t)parseLittleEndianHex64(instructionResponse ?: @"");
                
                if (instructionResponse.length > 0) {
                    @synchronized (cachedInstructionByPC) {
                        cachedInstructionByPC[instructionCacheKey] = @(instruction);
                    }
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
        logger([NSString stringWithFormat:@"runDebugService: (pid %d) skipping detach - transport already dead", pid]);
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

DeviceProvider *createDeviceProvider(NSString *pairingFilePath, NSString *targetAddress, NSError **error) {
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
    // DISABLED - see fix_disable_unconsumed_endpoint_monitor.py.
    //
    // This monitor's entire output is one NSNotification,
    // "me-minh-ton.jit.endpoint-monitor-failed", and nothing anywhere
    // in the codebase observes it - the recovery it was built to
    // trigger was never wired up. Its cost is real, though: a dispatch
    // timer opening a TCP probe socket every single second for as long
    // as any endpoint is registered, foreground and background alike.
    // Flip the constant once a consumer actually registers for the
    // notification; until then, starting the timer buys nothing.
    static const BOOL kEndpointMonitorHasConsumer = NO;
    if (!kEndpointMonitorHasConsumer) return;
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
