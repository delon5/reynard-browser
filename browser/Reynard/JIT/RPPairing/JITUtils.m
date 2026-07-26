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

NSString *pairingFilePath(void) {
    // Was ReynardDirectoriesBridge.pairingFilePath, then
    // ReynardDirectoriesBridge.sharedPairingFilePath — both required a
    // Swift bridging header, which turned out to be genuinely
    // impossible to reliably resolve across the three separate targets
    // (Reynard, GeckoView, Reynard Helper) this file compiles into,
    // each with its own, differently-named generated header.
    // NSFileManager's own App Group container API is a standard,
    // direct Foundation call — no Swift bridging needed at all,
    // sidestepping that whole problem entirely.
    // Was a hardcoded "group.com.minh-ton.Reynard" — confirmed wrong
    // directly from a real device's own embedded provisioning profile,
    // which showed AltStore genuinely appends a unique, per-install
    // suffix to the App Group identifier itself, not just the bundle
    // ID. Same derivation logic as ReynardDirectories.swift's own
    // sharedAppGroupIdentifier() — duplicated here since this file
    // compiles into three separate targets, some without straightforward
    // access to that Swift type.
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.minh-ton.Reynard";
    NSString *helperSuffix = @".Helper";
    if ([bundleID hasSuffix:helperSuffix]) {
        bundleID = [bundleID substringToIndex:bundleID.length - helperSuffix.length];
    }
    NSString *groupID = [@"group." stringByAppendingString:bundleID];
    NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!containerURL) return @"";
    return [containerURL URLByAppendingPathComponent:@"pairingFile.plist" isDirectory:NO].path;
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
