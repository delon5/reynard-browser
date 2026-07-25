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
#import "Utils.h"

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
