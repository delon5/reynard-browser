//
//  main.m
//  Reynard
//
//  Created by Minh Ton on 20/2/26.
//

// https://github.com/LiveContainer/LiveContainer/blob/382fca93abfa01e08b7df6601e6238840aaf3a4a/LiveProcess/main.m

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <os/proc.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <sys/file.h>
#import <fcntl.h>
#import <math.h>
#import "Utils.h"
#import "JITEnabler.h"
#import "JITUtils.h"

static void hook_do_nothing(void) {}

// The main app enables JIT for itself and its own Gecko child processes via
// JITController/JITEnabler before any JS engine code runs (see
// browser/Reynard/main.swift and browser/Reynard/JIT/JITEnabler.m) — but
// this Helper extension is a separate process, launched by launchd, not a
// child of the main app, so it was never covered by that mechanism at all.
// This is the same root cause behind crashes where SpiderMonkey's JIT
// compiler traps trying to allocate executable memory inside this process.
//
// spawnRoot() (browser/Reynard/Shared/Utils.m) is a general, jailbreak-wide
// privilege-escalation technique — it isn't tied to the main app's own
// process identity — and the ptrace_jit binary it runs targets whatever PID
// is passed to it, not specifically a child of the caller. So the same call
// the main app already makes for its own child processes should work
// identically here, targeting this process's own PID instead.
// Duplicated, self-contained version of JITController's own private
// hasTXMSupport() logic (Swift, not reachable from here — private
// methods aren't exposed across the Objective-C bridge even within the
// same target). Small amount of redundancy, but avoids restructuring
// that file's visibility this late, and this specific check is simple
// and self-contained enough that duplicating it carries little real risk.
// Was a hardcoded, device-model/OS-version threshold check only.
// Replaced with DolphiniOS's own, later, corrected approach - their
// real commit history shows this exact threshold-only logic was the
// ORIGINAL version, which they themselves found insufficient and
// specifically fixed for iOS 26.6 (commit "Fix TXM detection for iOS
// 26.6", June 1 2026). The fix: check for the actual, real
// Ap,TrustedExecutionMonitor.img4 firmware file's genuine presence on
// disk first: this is ground truth, not an inference from device
// model/OS version at all. The old, hardcoded-threshold check now
// only serves as a fallback if that real, direct check comes back
// negative on iOS 26.6+, matching DolphiniOS's own current logic
// exactly. This matters directly for this device: iOS 27.0 is past
// the exact threshold where DolphiniOS's own team found the old
// approach was already getting the wrong answer.
static NSString *txmFilePathAtPath(NSString *path, NSUInteger length) {
    NSError *error = nil;
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];
    if (!items) return nil;

    for (NSString *entry in items) {
        if (entry.length == length) {
            return [path stringByAppendingPathComponent:entry];
        }
    }
    return nil;
}

static BOOL deviceUsesTXMClassic(void) {
    if (@available(iOS 14.0, *)) {
        if ([[NSProcessInfo processInfo] isiOSAppOnMac]) {
            return NO;
        }
    }

    // Primary: /System/Volumes/Preboot/<36>/boot/<96>/usr/.../Ap,TrustedExecutionMonitor.img4
    NSString *bootUUID = txmFilePathAtPath(@"/System/Volumes/Preboot", 36);
    if (bootUUID) {
        NSString *bootDir = [bootUUID stringByAppendingPathComponent:@"boot"];
        NSString *ninetySixCharPath = txmFilePathAtPath(bootDir, 96);
        if (ninetySixCharPath) {
            NSString *img = [ninetySixCharPath stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
            return access(img.fileSystemRepresentation, F_OK) == 0;
        }
    }

    // Fallback: /private/preboot/<96>/usr/.../Ap,TrustedExecutionMonitor.img4
    NSString *fallback = txmFilePathAtPath(@"/private/preboot", 96);
    if (fallback) {
        NSString *img = [fallback stringByAppendingPathComponent:@"usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        return access(img.fileSystemRepresentation, F_OK) == 0;
    }

    return NO;
}

static BOOL selfHasTXMSupport(void) {
    if (@available(iOS 26.0, *)) {
        BOOL hasTXMClassic = deviceUsesTXMClassic();

        if (@available(iOS 26.6, *)) {
            if (!hasTXMClassic) {
                struct utsname systemInfo;
                uname(&systemInfo);
                NSString *hardware = [NSString stringWithUTF8String:systemInfo.machine];

                NSString *pattern = [hardware hasPrefix:@"iPad"] ? @"iPad(\\d+),(\\d+)" : @"iPhone(\\d+),(\\d+)";
                double threshold = [hardware hasPrefix:@"iPad"] ? 14.5 : 14.2;

                NSError *regexError = nil;
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&regexError];
                if (!regex) return NO;

                NSTextCheckingResult *match = [regex firstMatchInString:hardware options:0 range:NSMakeRange(0, hardware.length)];
                if (!match || match.numberOfRanges < 3) return NO;

                NSString *majorString = [hardware substringWithRange:[match rangeAtIndex:1]];
                NSString *minorString = [hardware substringWithRange:[match rangeAtIndex:2]];
                double major = majorString.doubleValue;
                double minor = minorString.doubleValue;

                double divisor = pow(10.0, (double)minorString.length);
                double version = major + (minor / divisor);
                return version >= threshold;
            }
        }

        return hasTXMClassic;
    }

    return NO;
}

// Genuinely separate from enableJITForSelfIfNeeded above — deliberately
// not merged into it, since that function is specifically the
// TrollStore/jailbreak (ptrace_jit) path, and this is its own, distinct
// mechanism for the non-jailbroken (RPPairing) case, which the Helper
// previously had no path to at all. The main app's own tab-process JIT
// enablement already goes through JITEnabler for exactly this
// mechanism — this reuses that same, already-linked class, rather than
// building a second, parallel implementation, since JITEnabler is
// already compiled into GeckoView.framework, which this Helper target
// already links against.
// Records the outcome of a self-enable attempt into the shared App
// Group container as a small JSON file, so the main app - which has
// the only user-facing UI in this picture - can read and surface it.
// Uses the same containerURLForSecurityApplicationGroupIdentifier:
// mechanism already proven working for the pairing file and DDI
// (logAppGroupDiagnostics above), not UserDefaults(suiteName:), since
// there's no existing evidence the Swift-side Prefs abstraction is
// backed by that same shared suite from this process.
static void recordHelperJITOutcome(NSString *outcome, NSString *errorDescription) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) {
        return;
    }
    
    NSMutableDictionary *outcomeDict = [NSMutableDictionary dictionary];
    outcomeDict[@"outcome"] = outcome;
    outcomeDict[@"date"] = @([[NSDate date] timeIntervalSince1970]);
    if (errorDescription) {
        outcomeDict[@"errorDescription"] = errorDescription;
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:outcomeDict options:0 error:nil];
    if (!jsonData) {
        return;
    }
    
    NSURL *outcomeFileURL = [containerURL URLByAppendingPathComponent:@"helper-jit-last-outcome.json" isDirectory:NO];
    [jsonData writeToURL:outcomeFileURL atomically:YES];
}

// Delegates the actual JIT attach to the main app instead of this
// Helper opening its own, separate tunnel - see
// fix_helper_delegates_jit_to_main_app_v4.py's docstring for the full
// reasoning. Only ever one such request in flight at a time within a
// single Helper process (the existing retry loop below is sequential,
// never concurrent), so this file-scope static is safe without
// further synchronization.
static dispatch_semaphore_t sJITAttachReplySemaphore = NULL;

static void jitAttachReplyCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (sJITAttachReplySemaphore) {
        dispatch_semaphore_signal(sJITAttachReplySemaphore);
    }
}

// Every request gets its own unique token (a UUID), not just the PID -
// deliberately. The retry loop below can make two sequential requests
// for the same PID; keying by PID alone would let an old, late-
// arriving reply for attempt 1 collide with attempt 2's own observer
// for the same PID, since the main app can genuinely still be
// processing attempt 1 after this Helper's own client-side timeout
// already gave up on it. The token makes every attempt's coordination
// channel unique regardless of how many requests the same PID makes.
static BOOL requestJITAttachFromMainApp(int32_t pid, NSString **errorDescriptionOut) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) {
        if (errorDescriptionOut) *errorDescriptionOut = @"No shared App Group container available";
        return NO;
    }
    
    NSString *token = [[NSUUID UUID] UUIDString];
    
    sJITAttachReplySemaphore = dispatch_semaphore_create(0);
    
    NSString *replyNotificationName = [NSString stringWithFormat:@"com.minh-ton.Reynard.JITAttachReply.%@", token];
    // Registered BEFORE the request is posted below, to avoid a race
    // where the main app's reply could arrive before this Helper is
    // actually listening for it.
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        jitAttachReplyCallback,
        (__bridge CFStringRef)replyNotificationName,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    
    NSURL *requestFileURL = [containerURL URLByAppendingPathComponent:[NSString stringWithFormat:@"jit-attach-request-%d_%@", pid, token]];
    NSURL *resultFileURL = [containerURL URLByAppendingPathComponent:[NSString stringWithFormat:@"jit-attach-result-%d_%@", pid, token]];
    BOOL requestFileWritten = [[NSData data] writeToURL:requestFileURL atomically:YES];
    if (!requestFileWritten) {
        // Fail fast instead of waiting the full 20s for a reply that
        // can never arrive - the main app can never see a request that
        // was never actually written (disk pressure, an unexpected
        // permissions issue - rare, but a real, checkable failure mode
        // this was previously silently ignoring).
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            (__bridge CFStringRef)replyNotificationName,
            NULL
        );
        sJITAttachReplySemaphore = NULL;
        if (errorDescriptionOut) *errorDescriptionOut = @"Failed to write JIT attach request file";
        return NO;
    }
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.minh-ton.Reynard.JITAttachRequestPosted"),
        NULL,
        NULL,
        true
    );
    
    // Waits for a reply two ways at once, not just the notification -
    // see fix_helper_attach_polling_fallback.py's docstring. Short
    // (200ms) semaphore waits repeated up to the full 20s budget,
    // checking the result file's own existence directly on every
    // iteration the notification hasn't signaled yet. The notification
    // remains the fast path (near-instant when it fires); the file
    // check is a guaranteed-to-work fallback should it not - App Group
    // file access has been directly, repeatedly confirmed working
    // cross-process in this exact app tonight, unlike Darwin
    // notification delivery for this specific extension type.
    NSTimeInterval waitDeadline = [NSDate date].timeIntervalSince1970 + 20.0;
    BOOL resultReady = NO;
    while ([NSDate date].timeIntervalSince1970 < waitDeadline) {
        long semResult = dispatch_semaphore_wait(sJITAttachReplySemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)));
        if (semResult == 0) {
            resultReady = YES;
            break;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:resultFileURL.path]) {
            resultReady = YES;
            break;
        }
    }
    
    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (__bridge CFStringRef)replyNotificationName,
        NULL
    );
    sJITAttachReplySemaphore = NULL;
    
    // The main app normally consumes the request first.  Removing it
    // here closes the client side of the protocol when the request was never
    // observed, so an abandoned Helper cannot leave work queued forever.
    [[NSFileManager defaultManager] removeItemAtURL:requestFileURL error:nil];

    if (!resultReady) {
        // A result may have raced the final poll without its notification.
        // It no longer has a reader after this function returns.
        [[NSFileManager defaultManager] removeItemAtURL:resultFileURL error:nil];
        if (errorDescriptionOut) *errorDescriptionOut = @"Timed out waiting for main app to process JIT attach request";
        return NO;
    }
    
    NSString *resultContents = [NSString stringWithContentsOfURL:resultFileURL encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:resultFileURL error:nil];
    
    if (!resultContents) {
        if (errorDescriptionOut) *errorDescriptionOut = @"No result file found after reply notification";
        return NO;
    }
    
    if ([resultContents isEqualToString:@"success"]) {
        return YES;
    }
    
    if (errorDescriptionOut) {
        NSString *prefix = @"failed:";
        if ([resultContents hasPrefix:prefix]) {
            *errorDescriptionOut = [resultContents substringFromIndex:prefix.length];
        } else {
            *errorDescriptionOut = resultContents;
        }
    }
    return NO;
}

static void enableRPPairingJITForSelfIfNeeded(void) {
    if (getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        // TrollStore/jailbroken devices are handled entirely by
        // enableJITForSelfIfNeeded above instead — this path is
        // specifically for everyone else.
        return;
    }

    if (@available(iOS 17.4, *)) {
        // RETRY TEST - test26 found four separate Helper processes (no
        // shared client-side state between them at all - different OS
        // processes, different memory) all starting process_control_new
        // within ~10 microseconds of each other, none of which ever
        // resolved. That was the original evidence for device-side
        // contention under concurrent tunnel-opening - since resolved
        // architecturally: the Helper no longer opens a tunnel at all,
        // delegating instead to the main app's single, serial
        // attachQueue (see fix_helper_delegates_jit_to_main_app_v4.py).
        // Every attempt now genuinely does go through attachQueue, via
        // that delegation - unlike the earlier, pre-delegation version
        // of this comment claimed.
        //
        // LIMITATION, not hidden: retrying here cannot help a genuine,
        // already-in-flight hang on the main app's own side - if the
        // delegated attach itself hangs, this only helps once
        // requestJITAttachFromMainApp's own bounded wait (20s) gives up
        // and returns, at which point attempt 2 gets a fresh token and
        // a fresh shot, never colliding with attempt 1's coordination
        // channel even if attempt 1 is technically still being
        // processed somewhere on the main app's queue.
        // WATCHDOG - unlike the old direct enableJITForPID: call this
        // replaced, requestJITAttachFromMainApp always returns within
        // its own bounded ~20s wait - success, explicit failure, or
        // timeout - never blocks indefinitely. This independent timer
        // remains valuable anyway: with two sequential attempts each
        // possibly taking up to ~20s, the retry loop itself could still
        // take up to ~40s worst case before this function's own final
        // recordHelperJITOutcome call below runs. This timer surfaces
        // "timed_out" to the UI at the 20s mark regardless, rather than
        // making Settings wait for the full, worst-case retry sequence
        // to finish before showing anything at all. If the retry loop
        // does finish first - fast or slow - it overwrites this with
        // the real, final outcome.
        pid_t selfPID = getpid();
        
        // Includes selfPID (declared just above, so the block below
        // captures its already-set value) specifically so a single
        // capture can match this line up with the retry loop's own
        // "(pid %d) attempt..." lines below and show the real gap
        // between when the watchdog gave up waiting and when (if
        // ever) the underlying call actually returned - the open
        // question of whether process_control_new is a genuinely
        // permanent hang or just very slow.
        dispatch_queue_t watchdogRecordQueue = dispatch_queue_create("com.minh-ton.Reynard.HelperJIT.WatchdogRecordQueue", DISPATCH_QUEUE_SERIAL);
        __block BOOL didFinish = NO;
        // WIDENED to 20s (was 15s) - the delegation architecture means
        // a request's total wait now includes time queued behind other
        // requests on the main app's own serial queue, not just its
        // own attach attempt's duration. See this script's docstring
        // for the full reasoning and honest caveats on this figure.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), watchdogRecordQueue, ^{
            if (!didFinish) {
                os_log(OS_LOG_DEFAULT, "[HelperJIT] Watchdog: self-enable (pid %d) exceeded 20s budget, recording timeout (underlying call may still be running)", selfPID);
                recordHelperJITOutcome(@"timed_out", nil);
            }
        });
        
        // hasTXM is no longer computed here - the main app computes its
        // own hasTXMSupport() independently when it processes the
        // delegated request below, since that's now where the actual
        // attach happens. selfHasTXMSupport() itself is left in place,
        // unused, rather than also removing its definition here -
        // minimizing the size of an already large change.
        BOOL success = NO;
        NSString *lastErrorDescription = nil;
        
        for (int attempt = 1; attempt <= 2; attempt++) {
            NSString *attemptErrorDescription = nil;
            // Delegates to the main app instead of opening a separate
            // tunnel from this process - see
            // fix_helper_delegates_jit_to_main_app_v4.py's docstring.
            // Each call generates its own unique token internally, so
            // attempt 1 and attempt 2 here never share a coordination
            // channel even though both target the same selfPID.
            success = requestJITAttachFromMainApp(selfPID, &attemptErrorDescription);
            os_log(OS_LOG_DEFAULT, "[HelperJIT] RPPairing enableJIT for self (pid %d) attempt %d/2 success: %d, error: %{public}@", selfPID, attempt, success, attemptErrorDescription ?: @"none");
            lastErrorDescription = attemptErrorDescription;
            
            if (success || attempt == 2) {
                break;
            }
            
            // Small, FIXED (not random) pause - the wide random jitter
            // this replaces existed to spread out concurrent tunnel
            // opens, which no longer happens; this is just ordinary
            // "do not immediately hammer a retry" practice.
            [NSThread sleepForTimeInterval:0.5];
        }
        
        dispatch_sync(watchdogRecordQueue, ^{
            didFinish = YES;
        });
        recordHelperJITOutcome(success ? @"succeeded" : @"failed", success ? nil : lastErrorDescription);
    } else {
        os_log(OS_LOG_DEFAULT, "[HelperJIT] RPPairing JIT requires iOS 17.4+, unavailable on this OS version");
    }
}

static void enableJITForSelfIfNeeded(void) {
  if (!getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
    return;
  }

  // This process's own bundle is the Helper.appex itself
  // (App.app/PlugIns/Reynard Helper.appex/) — the ptrace_jit binary lives
  // two levels up, in the main app's own bundle.
  NSURL *helperBundleURL = NSBundle.mainBundle.bundleURL;
  NSURL *pluginsURL = helperBundleURL.URLByDeletingLastPathComponent;
  NSURL *appBundleURL = pluginsURL.URLByDeletingLastPathComponent;
  NSString *ptraceJitPath =
      [appBundleURL.path stringByAppendingPathComponent:@"ptrace_jit"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:ptraceJitPath]) {
    os_log(OS_LOG_DEFAULT, "[HelperJIT] ptrace_jit not found at expected path: %{public}@", ptraceJitPath);
    return;
  }

  pid_t selfPID = getpid();
  int result = spawnRoot(ptraceJitPath, @[[NSString stringWithFormat:@"%d", selfPID]]);
  os_log(OS_LOG_DEFAULT, "[HelperJIT] spawnRoot(ptrace_jit) for self (pid %d) result: %d", selfPID, result);
}

// DIAGNOSTIC — logs whether this process (the Helper) resolves the same
// shared App Group container the main app does, and whether it can
// actually see a file the main app wrote there. containerURL resolving
// non-nil on both sides only proves each process independently thinks
// *some* group is granted — it doesn't prove they're the same group
// unless the resolved identifier strings match, and it doesn't prove
// the files are genuinely visible cross-process unless something
// written by one side is actually read back by the other. This checks
// both, not just the first.
//
// To use: trigger "Live App Group check" from AddonCoordinator's
// diagnostic menu in the main app first (writes the marker), then open
// any tab that spins up this Helper process and check Console.app for
// "[HelperJIT AppGroup]" — the main app's own equivalent log line uses
// the same resolved group ID and containerURL result, so the two can
// be compared directly.
static void logAppGroupDiagnostics(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    os_log(OS_LOG_DEFAULT, "[HelperJIT AppGroup] bundleID=%{public}@ groupID=%{public}@ containerURL=%{public}@",
           bundleID, groupID, containerURL ? containerURL.path : @"(nil)");

    if (!containerURL) {
        return;
    }

    NSURL *markerURL = [containerURL URLByAppendingPathComponent:@"appgroup-healthcheck.txt" isDirectory:NO];
    NSError *readError = nil;
    NSString *markerContents = [NSString stringWithContentsOfURL:markerURL encoding:NSUTF8StringEncoding error:&readError];
    if (markerContents) {
        os_log(OS_LOG_DEFAULT, "[HelperJIT AppGroup] found marker written by main app: %{public}@", markerContents);
    } else {
        os_log(OS_LOG_DEFAULT, "[HelperJIT AppGroup] no marker found at %{public}@ (%{public}@) — either the main app hasn't written one yet, or this process genuinely can't see what the main app wrote", markerURL.path, readError.localizedDescription ?: @"no error");
    }
}

__attribute__((used, visibility("default"))) int NSExtensionMain(int argc,
                                                                 char *argv[]) {
  logAppGroupDiagnostics();

  // What the memory entitlements actually bought, if anything. Apple's
  // documentation for increased-memory-limit says to call this rather
  // than assume. See fix_memory_entitlements.py.
  //
  // Logged before JIT is enabled, so the number is the ceiling this
  // process starts with rather than one already eaten into.
  logger([NSString stringWithFormat:@"helperMemory: %llu MB available to this content process",
                                    (unsigned long long)(os_proc_available_memory() / (1024 * 1024))]);

  enableJITForSelfIfNeeded();
  // Was a direct, synchronous call here - a real, confirmed bug found
  // from an actual crash log tonight. This attempts a genuine network
  // operation (establishing the RPPairing tunnel) with no timeout at
  // all, directly inside the Helper's own startup path. The main app
  // synchronously waits for the Helper to finish starting via XPC - if
  // this call ever hangs instead of failing quickly (confirmed
  // possible, regardless of the exact underlying cause), the entire
  // app's launch hangs with it, eventually hit by iOS's own 20-second
  // launch watchdog (0x8BADF00D) and killed outright - exactly
  // matching a real "hard lock blackscreen" crash log from tonight.
  // Moving this off the startup path entirely onto a background queue
  // means a hang here can genuinely, structurally never block the
  // Helper's own startup, or the main app's, ever again.
  // TEST - re-enabled. The earlier slowdown (confirmed real: two
  // competing tunnels, main app + Helper, caused general web browsing
  // to lag during JIT enablement) is a separate, already-understood
  // issue from tonight's actual blocker - now testing the shared App
  // Group fix (ReynardResolveAppGroupIdentifier, reading the real
  // group ID from this process's own embedded provisioning profile
  // instead of guessing "group.<bundleID>") specifically against the
  // Helper's own, separate attempt at this same RPPairing flow.
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    enableRPPairingJITForSelfIfNeeded();
  });

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
  method_setImplementation(
      class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector
                              (_validateAllowedClass:
                                              forKey:allowingInvocations:)),
      (IMP)hook_do_nothing);
#pragma clang diagnostic pop

  int (*origNSExtensionMain)(int, char **) =
      (int (*)(int, char **))dlsym(RTLD_NEXT, "NSExtensionMain");
  return origNSExtensionMain(argc, argv);
}
