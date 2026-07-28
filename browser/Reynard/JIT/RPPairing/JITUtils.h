//
//  JITUtils.h
//  Reynard
//
//  Created by Minh Ton on 18/3/2026.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

void logger(NSString *message);
NSString *pairingFilePath(void);

/// Resolves the App Group identifier actually granted to this process by
/// its own embedded provisioning profile, falling back to the plain
/// "group.<bundleID>" form only when no profile is available (e.g. App
/// Store builds, which don't embed one). Single source of truth for
/// JITUtils.m, JITSupport.m, and (via the bridging header)
/// ReynardDirectories.swift — see the implementation in JITUtils.m for
/// why the plain form alone isn't reliable under this project's actual
/// signing setup.
NSString *ReynardResolveAppGroupIdentifier(void);

uint64_t parseLittleEndianHex64(NSString *hexString);
NSString *encodeLittleEndianHex64(uint64_t value);
NSString *_Nullable packetField(NSString *packet, NSString *fieldName);
NSString *_Nullable packetSignal(NSString *packet);
BOOL instructionIsBreakpoint(uint32_t instruction);
BOOL isNotConnectedError(NSError *error);

NS_ASSUME_NONNULL_END
