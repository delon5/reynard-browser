//
//  JITUtils.m
//  Reynard
//
//  Created by Minh Ton on 18/3/2026.
//

#import "JITUtils.h"
// This file compiles into three separate targets (Reynard, GeckoView,
// Reynard Helper), each with its own, differently-named auto-generated
// Swift bridging header — a single, fixed #import can't be correct for
// all three at once. __has_include checks, at compile time, which
// header actually exists for whichever target happens to be building
// this file right now.
#if __has_include("Reynard-Swift.h")
#import "Reynard-Swift.h"
#elif __has_include("Reynard_Helper-Swift.h")
#import "Reynard_Helper-Swift.h"
#endif

void logger(NSString *message) {
    NSLog(@"[Reynard] %@", message);
}

NSString *pairingFilePath(void) {
    // Was ReynardDirectoriesBridge.pairingFilePath (this app's own
    // private container) — moved to the shared App Group container so
    // the Helper extension's own RPPairing JIT self-enablement (added
    // tonight) can genuinely reach the same, real pairing file, since
    // app extensions get their own, separate sandbox container by
    // default. A one-time migration moves an existing, already-imported
    // file from the old location into this new one.
    return ReynardDirectoriesBridge.sharedPairingFilePath ?: @"";
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
