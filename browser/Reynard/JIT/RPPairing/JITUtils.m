//
//  JITUtils.m
//  Reynard
//
//  Created by Minh Ton on 18/3/2026.
//

#import "JITUtils.h"

void logger(NSString *message) {
    NSLog(@"[Reynard] %@", message);
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
