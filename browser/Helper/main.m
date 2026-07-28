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
#import <sys/utsname.h>
#import <unistd.h>
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
static void enableRPPairingJITForSelfIfNeeded(void) {
    if (getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        // TrollStore/jailbroken devices are handled entirely by
        // enableJITForSelfIfNeeded above instead — this path is
        // specifically for everyone else.
        return;
    }

    if (@available(iOS 17.4, *)) {
        // RETRY + JITTER TEST - test26 found four separate Helper
        // processes (no shared client-side state between them at
        // all - different OS processes, different memory, different
        // LOCAL_RUNTIME_GUARD instances) all starting
        // process_control_new within ~10 microseconds of each other,
        // none of which ever resolved. No client-side bug explains
        // four unrelated processes stalling in that kind of sync -
        // this points at device-side contention when several Helper
        // instances launch in a tight burst and all race through the
        // same sequence in near-lockstep, landing on the same
        // contended step at close to the same moment. A small random
        // jitter before the first attempt spreads out when each
        // instance actually reaches the device.
        //
        // LIMITATION, not hidden: this cannot help a genuine,
        // already-in-flight hang. enableJITForPID: is a single
        // blocking call with no internal timeout - if it hangs (as
        // process_control_new currently does under the burst pattern
        // above), this function simply never returns far enough to
        // attempt a retry at all. It only helps a fast-failing
        // attempt, or cases where jitter alone avoids the contention
        // in the first place. Safe to retry here specifically because
        // this runs on dispatch_get_global_queue (concurrent), not a
        // dedicated serial queue - unlike JITController's attachQueue,
        // this can't get stuck queued behind other pending work.
        NSTimeInterval initialJitter = ((double)arc4random_uniform(300)) / 1000.0;
        [NSThread sleepForTimeInterval:initialJitter];
        
        pid_t selfPID = getpid();
        BOOL hasTXM = selfHasTXMSupport();
        
        for (int attempt = 1; attempt <= 2; attempt++) {
            NSError *jitError = nil;
            // Test complete: directly, empirically ruled out. Bypassing
            // this call to a hardcoded value produced the exact same
            // ConnectionReset result, confirming the sandbox-denied
            // /private/preboot read is unrelated to the tunnel failure.
            // Restoring the genuine, real check.
            BOOL success = [JITEnabler.shared enableJITForPID:selfPID
                                                 hasTXMSupport:hasTXM
                                                         error:&jitError];
            os_log(OS_LOG_DEFAULT, "[HelperJIT] RPPairing enableJIT for self (pid %d) attempt %d/2 success: %d, error: %{public}@", selfPID, attempt, success, jitError.localizedDescription ?: @"none");
            
            if (success || attempt == 2) {
                break;
            }
            
            NSTimeInterval retryJitter = 0.3 + (((double)arc4random_uniform(400)) / 1000.0);
            [NSThread sleepForTimeInterval:retryJitter];
        }
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
