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
#import "Utils.h"
#import "JITEnabler.h"

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
static BOOL selfHasTXMSupport(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *hardware = [NSString stringWithUTF8String:systemInfo.machine];

    if (@available(iOS 27.0, *)) {
        return ![hardware isEqualToString:@"iPad8,11"] && ![hardware isEqualToString:@"iPad8,12"];
    }

    if (@available(iOS 26.0, *)) {
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
        pid_t selfPID = getpid();
        NSError *jitError = nil;
        BOOL success = [JITEnabler.shared enableJITForPID:selfPID
                                             hasTXMSupport:selfHasTXMSupport()
                                                     error:&jitError];
        os_log(OS_LOG_DEFAULT, "[HelperJIT] RPPairing enableJIT for self (pid %d) success: %d, error: %{public}@", selfPID, success, jitError.localizedDescription ?: @"none");
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

__attribute__((used, visibility("default"))) int NSExtensionMain(int argc,
                                                                 char *argv[]) {
  enableJITForSelfIfNeeded();
  enableRPPairingJITForSelfIfNeeded();

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
