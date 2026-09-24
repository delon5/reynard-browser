//
//  JITErrors.h
//  Reynard
//
//  Created by Minh Ton on 22/3/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ErrorDomain;

// REMOVED ErrorGroup, ErrorGroupForCode and the ErrorCategory userInfo
// key - see fix_delete_dead_errors_and_helper_code.py. A repo-wide grep
// for either name found seventeen hits and not one reader: MakeError
// computed the group, stored it under userInfo[ErrorCategory], and
// nothing ever asked for it back.
typedef NS_ERROR_ENUM(ErrorDomain, ErrorCode){
    // -6 (HeartbeatConnectFailed) and -8 (ProcessControlCreateFailed)
    // were removed by the same script - neither was ever passed to
    // MakeError, so neither could reach a log or a user. The two numbers
    // are retired rather than recycled, so an old capture's "Error -6"
    // can never come to mean something new.
    
    // Pairing and bootstrap setup
    PairingFileMissing = -1,
    InvalidTargetAddress = -2,
    DeviceProviderAllocationFailed = -3,
    DeviceProviderCreateFailed = -4,
    PairingFileReadFailed = -5,
    
    // RSD service bootstrap
    LockdowndConnectFailed = -7,
    
    // Attach
    RemoteServerConnectFailed = -9,
    DebugProxyConnectFailed = -10,
    NoAckConfigureFailed = -11,
    AttachDebugProxyFailed = -12,
    SessionAllocationFailed = -13,
    
    // Protocol handling and command execution
    DebugCommandCreateFailed = -14,
    DebugCommandSendFailed = -15,
    UnexpectedRegisterWriteResponse = -16,
    UnexpectedNoAckResponse = -17,
    MemoryPrepareReadFailed = -18,
    UnexpectedPrepareRegionResponse = -19,
    
    // Developer Disk Image mounting
    DDIMountPathResolveFailed = -20,
    DDIFileReadFailed = -21,
    ImageMounterConnectFailed = -22,
    DDIMountStateQueryFailed = -23,
    UniqueChipIDReadFailed = -24,
    UniqueChipIDInvalid = -25,
    ModernDDIMountFailed = -26,
    
    // Runtime connectivity monitoring
    EndpointConnectivityLost = -27,
    
    // RPPairing tunnel
    TunnelCreateFailed = -28,
    
    // TrollStore ptrace attach path
    TSPtraceHelperMissing = -29,
    TSPtraceHelperAttachFailed = -30,
    TSPtraceHelperTerminated = -31,
};

NSString *ErrorDescription(ErrorCode code);
NSError *MakeError(ErrorCode code);

NS_ASSUME_NONNULL_END
