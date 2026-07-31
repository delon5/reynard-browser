//
//  JITUtils.h
//  Reynard
//
//  Created by Minh Ton on 18/3/2026.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

void logger(NSString *message);

/// Enables or disables each diagnostic log file independently - see
/// fix_experimental_logging_toggles.py. Pushed down from Swift at
/// startup rather than having Objective-C read BrowserPreferences,
/// which would couple it to the profile-prefixed UserDefaults key
/// format. All three default to YES, so any process that never calls
/// this - notably the Helper extension, which has its own separate
/// UserDefaults and never registers defaults - keeps logging exactly
/// as it does today.
void ReynardSetDiagnosticLoggingEnabled(BOOL jitLog,
                                        BOOL nativeLog,
                                        BOOL hangBacktrace);

/// Read back by the JIT layer to gate its own file writes.
BOOL ReynardIsIdeviceNativeLogEnabled(void);
BOOL ReynardIsJITHangBacktraceEnabled(void);
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
