//
//  JITUtils.m
//  Reynard
//
//  Created by Minh Ton on 18/3/2026.
//

#import "JITUtils.h"
#import <os/log.h>

// ADDED - see fix_logger_writes_to_documents_file_v2.py's docstring.
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <os/lock.h>

// Was NSLog(@"[Reynard] %@", message) — the ENTIRE composed string can
// get redacted to "<private>" in an exported Console capture, not just
// the interpolated part, unless the dynamic content is explicitly
// marked public. Confirmed directly: a real device capture showed
// "ensureDDIMounted: starting isDDIMounted check" (a plain literal)
// clearly, immediately followed by "[Reynard] <private>" where the
// actual success/failure resolution should have been — losing exactly
// the information this logging exists to capture. main.m's own
// [HelperJIT] logging already uses os_log with an explicit
// "%{public}@" and comes through completely readable in the same
// capture — matching that pattern here instead of guessing why NSLog
// was getting redacted.
// ADDED - file mirror. idevicesyslog capture has been unreliable
// throughout this investigation: grep block-buffers and drops chunks,
// an open Console.app starves the os_trace_relay service, and several
// captures silently missed cold launch, which at one point caused a
// wrong conclusion to be asserted as established fact.
// idevice_native_log.txt already proves file logging is reliable here.
//
// Documents rather than the App Group container: UIFileSharingEnabled
// is already true, so Finder can both retrieve and clear this file.
// The App Group container would let the Helper share one interleaved
// file, but Finder cannot reach it.
//
// The os_log call below is deliberately left exactly as it was - it
// was changed from NSLog because NSLog was being redacted to
// "<private>" in exported Console captures.
// Diagnostic logging toggles - see
// fix_experimental_logging_toggles.py. Default YES so behaviour is
// unchanged until Swift pushes down a different value at startup, and
// so processes that never call the setter keep logging as before.
static BOOL gReynardJITDebugLogEnabled = YES;
static BOOL gReynardIdeviceNativeLogEnabled = YES;
static BOOL gReynardJITHangBacktraceEnabled = YES;

void ReynardSetDiagnosticLoggingEnabled(BOOL jitLog,
                                        BOOL nativeLog,
                                        BOOL hangBacktrace) {
    gReynardJITDebugLogEnabled = jitLog;
    gReynardIdeviceNativeLogEnabled = nativeLog;
    gReynardJITHangBacktraceEnabled = hangBacktrace;
}

BOOL ReynardIsIdeviceNativeLogEnabled(void) {
    return gReynardIdeviceNativeLogEnabled;
}

BOOL ReynardIsJITHangBacktraceEnabled(void) {
    return gReynardJITHangBacktraceEnabled;
}

static int gReynardLogFileDescriptor = -1;

// Rotation. This file had no bound at all: it lives in Documents, is
// appended to for the whole life of the process, and one capture showed
// 7243 polling ticks in a single run - on a device that is routinely
// near full. One previous generation is kept so a crash still has the
// run before it to compare against.
static const off_t kReynardLogMaxBytes = 4 * 1024 * 1024;
static NSURL *gReynardLogURL = nil;
static _Atomic(off_t) gReynardLogBytes = 0;
static os_unfair_lock gReynardLogRotateLock = OS_UNFAIR_LOCK_INIT;

static void ReynardOpenLogFileIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        if (!documentsURL) {
            // Deliberately silent - pairingFilePath() calls logger(),
            // so logging from inside logger()'s own initialiser would
            // recurse. File logging simply stays off; os_log is
            // unaffected.
            return;
        }

        NSURL *logURL = [documentsURL URLByAppendingPathComponent:@"reynard_jit_log.txt" isDirectory:NO];
        gReynardLogURL = logURL;
        gReynardLogFileDescriptor = open(logURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (gReynardLogFileDescriptor < 0) {
            return;
        }

        // Seeded from what is already on disk, not zero, so a file left
        // oversized by an earlier build rotates on this launch rather
        // than being allowed another full cap on top.
        struct stat existing;
        if (fstat(gReynardLogFileDescriptor, &existing) == 0) {
            atomic_store(&gReynardLogBytes, existing.st_size);
        }

        // Session banner - proof that this process's logging began
        // inside the file, which is exactly the question that
        // invalidated several syslog captures.
        struct timeval now;
        gettimeofday(&now, NULL);
        struct tm brokenDown;
        localtime_r(&now.tv_sec, &brokenDown);
        char clockText[32];
        strftime(clockText, sizeof(clockText), "%H:%M:%S", &brokenDown);

        NSString *banner = [NSString stringWithFormat:@"\n===== SESSION START: %@[%d] %s.%06d =====\n",
                            [NSProcessInfo processInfo].processName,
                            getpid(),
                            clockText,
                            now.tv_usec];
        const char *bannerBytes = banner.UTF8String;
        if (bannerBytes) {
            write(gReynardLogFileDescriptor, bannerBytes, strlen(bannerBytes));
        }
    });
}

// Called after each write. The common path is a single atomic load, so
// the lock is only ever taken on the rare tick that actually rotates.
static void ReynardRotateLogIfNeeded(void) {
    if (atomic_load(&gReynardLogBytes) < kReynardLogMaxBytes) {
        return;
    }

    os_unfair_lock_lock(&gReynardLogRotateLock);
    // Re-checked under the lock: many threads log, so several can pass
    // the test above at once and only the first should rotate.
    if (atomic_load(&gReynardLogBytes) >= kReynardLogMaxBytes &&
        gReynardLogFileDescriptor >= 0 && gReynardLogURL) {
        NSString *previousPath = [gReynardLogURL.path stringByAppendingPathExtension:@"1"];
        // rename replaces any existing .1, so exactly two generations
        // survive. Both are closed/reopened rather than truncated, so a
        // reader holding the old file keeps a coherent one.
        if (rename(gReynardLogURL.fileSystemRepresentation, previousPath.fileSystemRepresentation) == 0) {
            close(gReynardLogFileDescriptor);
            gReynardLogFileDescriptor = open(gReynardLogURL.fileSystemRepresentation,
                                             O_WRONLY | O_CREAT | O_APPEND, 0644);
            atomic_store(&gReynardLogBytes, 0);
        } else {
            // Rotation failed - do not retry on every subsequent line.
            atomic_store(&gReynardLogBytes, 0);
        }
    }
    os_unfair_lock_unlock(&gReynardLogRotateLock);
}

void logger(NSString *message) {
    os_log(OS_LOG_DEFAULT, "[Reynard] %{public}@", message);

    // The os_log call above is deliberately NOT gated - system logging
    // keeps working and idevicesyslog captures are unaffected. Only
    // the file mirror below is optional.
    if (!gReynardJITDebugLogEnabled) {
        return;
    }

    ReynardOpenLogFileIfNeeded();
    if (gReynardLogFileDescriptor < 0) {
        return;
    }

    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm brokenDown;
    localtime_r(&now.tv_sec, &brokenDown);
    char clockText[32];
    strftime(clockText, sizeof(clockText), "%H:%M:%S", &brokenDown);

    NSString *line = [NSString stringWithFormat:@"%s.%06d %@[%d] %@\n",
                      clockText,
                      now.tv_usec,
                      [NSProcessInfo processInfo].processName,
                      getpid(),
                      message];

    const char *lineBytes = line.UTF8String;
    if (!lineBytes) {
        return;
    }

    size_t length = strlen(lineBytes);
    write(gReynardLogFileDescriptor, lineBytes, length);
    atomic_fetch_add(&gReynardLogBytes, (off_t)length);
    ReynardRotateLogIfNeeded();
}

// MARK: - App Group Resolution

// Free/personal Apple Developer team provisioning appends a unique,
// per-team suffix to App Group identifiers — confirmed directly from a
// real, installed device's own embedded provisioning profile, which
// showed "group.com.minh-ton.Reynard.M3ULXVYRUP" rather than the plain
// "group.com.minh-ton.Reynard" declared in the .entitlements source
// files. Apple does this so free/personal teams, which can't reserve
// globally-unique identifiers, don't collide with each other. Assuming
// the plain, undecorated form (as this code previously did) silently
// resolves to an App Group this process was never actually granted,
// which is exactly why containerURLForSecurityApplicationGroupIdentifier:
// was returning nil for both the pairing file and the DDI. Reading the
// real, granted identifier back out of this process's own embedded
// profile at runtime — whichever of the three targets (Reynard,
// GeckoView, Reynard Helper) happens to be asking — matches whatever's
// genuinely in effect for this specific install instead of guessing.
static NSString * const kReynardExpectedAppGroupPrefix = @"group.com.minh-ton.Reynard";

static NSArray<NSString *> *ReynardEmbeddedProvisioningAppGroups(void) {
    // App Store builds have no embedded.mobileprovision at all — Apple
    // strips it during processing. Returning nil there is fine: the
    // caller falls through to the plain, undecorated group ID, which
    // is the *correct* one for a properly provisioned paid-team App
    // Store build in the first place. This path only matters for
    // ad-hoc/development/enterprise signing, which is what this project
    // actually ships under (AltStore, TrollStore, jailbreak).
    NSURL *profileURL = [[NSBundle mainBundle] URLForResource:@"embedded" withExtension:@"mobileprovision"];
    if (!profileURL) return nil;

    NSData *rawData = [NSData dataWithContentsOfURL:profileURL];
    if (!rawData) return nil;

    // The file is a CMS/PKCS7-signed envelope, not a plain plist —
    // rather than decoding that signature (which needs Security-
    // framework APIs this project already ran into trouble with
    // elsewhere), the plist's own XML text remains directly readable
    // within the raw file bytes regardless of the binary signature
    // wrapped around it. ISO Latin-1 maps every byte to exactly one
    // character and can never fail to decode, unlike UTF-8 — this is
    // deliberately being read as opaque bytes, not validated text.
    NSString *rawString = [[NSString alloc] initWithData:rawData encoding:NSISOLatin1StringEncoding];
    if (!rawString) return nil;

    NSRange xmlStart = [rawString rangeOfString:@"<?xml"];
    NSRange plistEndTag = [rawString rangeOfString:@"</plist>"];
    if (xmlStart.location == NSNotFound || plistEndTag.location == NSNotFound) return nil;

    NSUInteger endLocation = plistEndTag.location + plistEndTag.length;
    if (endLocation <= xmlStart.location) return nil;
    NSString *plistText = [rawString substringWithRange:NSMakeRange(xmlStart.location, endLocation - xmlStart.location)];

    NSData *plistData = [plistText dataUsingEncoding:NSUTF8StringEncoding];
    if (!plistData) return nil;

    id plist = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:NULL error:nil];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *entitlements = ((NSDictionary *)plist)[@"Entitlements"];
    if (![entitlements isKindOfClass:[NSDictionary class]]) return nil;

    id groups = entitlements[@"com.apple.security.application-groups"];
    if (![groups isKindOfClass:[NSArray class]]) return nil;

    return groups;
}

static NSString *ReynardNaiveAppGroupIdentifier(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.minh-ton.Reynard";
    NSString *helperSuffix = @".Helper";
    if ([bundleID hasSuffix:helperSuffix]) {
        bundleID = [bundleID substringToIndex:bundleID.length - helperSuffix.length];
    }
    return [@"group." stringByAppendingString:bundleID];
}

NSString *ReynardResolveAppGroupIdentifier(void) {
    static NSString *cachedGroupID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *groups = ReynardEmbeddedProvisioningAppGroups();

        NSString *resolved = nil;
        for (NSString *candidate in groups) {
            if ([candidate isKindOfClass:[NSString class]] && [candidate hasPrefix:kReynardExpectedAppGroupPrefix]) {
                resolved = candidate;
                break;
            }
        }
        if (!resolved && groups.count > 0 && [groups.firstObject isKindOfClass:[NSString class]]) {
            // Provisioning granted *some* app group, just not one that
            // matched the expected prefix (e.g. entitlements were
            // edited without updating this constant) — use what's
            // actually granted rather than a guess that's certain to
            // be wrong.
            resolved = groups.firstObject;
        }
        if (!resolved) {
            resolved = ReynardNaiveAppGroupIdentifier();
        }
        cachedGroupID = resolved;
    });
    return cachedGroupID;
}

NSString *pairingFilePath(void) {
    NSString *groupID = ReynardResolveAppGroupIdentifier();
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (containerURL) {
        return [containerURL URLByAppendingPathComponent:@"pairingFile.plist" isDirectory:NO].path;
    }

    // Shared container genuinely unavailable (missing entitlement,
    // provisioning issue) — fall back to this process's own private
    // Documents directory instead of returning "" and failing outright.
    // A Helper reading from here would still find nothing, since it's
    // a separate sandbox, but this keeps the main app's own tab JIT
    // working in that degraded case rather than failing completely.
    // Logged loudly (not just silently falling through) since this
    // fallback succeeding for the main app can otherwise mask the
    // Helper's own, separate access to this same file being broken —
    // "JIT works in tabs" would look fine while the Helper silently
    // never got a working pairing file at all.
    logger([NSString stringWithFormat:@"[AppGroup] WARNING: shared container unavailable for groupID=%@ — pairingFilePath() falling back to private Documents directory. The Helper extension will NOT be able to read this file from its own, separate sandbox.", groupID]);
    NSURL *documentsDirectory = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!documentsDirectory) return @"";
    return [[documentsDirectory URLByAppendingPathComponent:@"pairingFile.plist"] path] ?: @"";
}

uint64_t parseLittleEndianHex64(NSString *hexString) {
    uint64_t value = 0;
    NSUInteger length = hexString.length;
    for (NSUInteger index = 0; index + 1 < length; index += 2) {
        NSString *byteString = [hexString substringWithRange:NSMakeRange(index, 2)];
        unsigned byteValue = 0;
        [[NSScanner scannerWithString:byteString] scanHexInt:&byteValue];
        value |= ((uint64_t)(byteValue & 0xff)) << ((index / 2) * 8);
    }
    return value;
}

NSString *encodeLittleEndianHex64(uint64_t value) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (NSUInteger index = 0; index < 8; index++) [hex appendFormat:@"%02llx", (value >> (index * 8)) & 0xffull];
    return hex;
}

NSString *packetField(NSString *packet, NSString *fieldName) {
    NSString *needle = [fieldName stringByAppendingString:@":"];
    NSRange startRange = [packet rangeOfString:needle];
    if (startRange.location == NSNotFound) return nil;
    
    NSUInteger valueStart = NSMaxRange(startRange);
    NSRange searchRange = NSMakeRange(valueStart, packet.length - valueStart);
    NSRange endRange = [packet rangeOfString:@";" options:0 range:searchRange];
    if (endRange.location == NSNotFound) return nil;
    
    return [packet substringWithRange:NSMakeRange(valueStart, endRange.location - valueStart)];
}

NSString *packetSignal(NSString *packet) {
    if (packet.length < 3 || ![packet hasPrefix:@"T"]) return nil;
    return [packet substringWithRange:NSMakeRange(1, 2)];
}

BOOL instructionIsBreakpoint(uint32_t instruction) {
    return (instruction & 0xFFE0001Fu) == 0xD4200000u;
}

BOOL isNotConnectedError(NSError *error) {
    NSString *description = error.localizedDescription;
    if (!description) return NO;
    return [description containsString:@"NotConnected"] || [description containsString:@"not connected"];
}
