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
    [lock unlock];
}

void dumpDebugLoopState(void) {
    NSLock *lock = debugLoopTickLock();
    [lock lock];
    NSDictionary<NSNumber *, NSNumber *> *snapshot = [debugLoopLastTick() copy];
    [lock unlock];

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    logger([NSString stringWithFormat:@"hangDump: %lu session(s) registered", (unsigned long)snapshot.count]);

    for (NSNumber *key in snapshot) {
        int32_t pid = key.intValue;
        double ageMs = (now - snapshot[key].doubleValue) * 1000.0;

        // Anything past a second is already far outside a healthy 30-60ms
        // iteration, so it is worth marking rather than leaving to be
        // eyeballed.
        logger([NSString stringWithFormat:@"hangDump:   pid %d last ticked %.0fms ago%@",
                pid, ageMs, ageMs > 1000.0 ? @"  <<< STALE" : @""]);
