//
//  GeckoRuntimeBridge.h
//  Reynard
//
//  Created by Minh Ton on 24/5/26.
//

#ifndef GeckoRuntimeBridge_h
#define GeckoRuntimeBridge_h

#import <Foundation/Foundation.h>

@interface GeckoRuntimeBridge : NSObject

+ (NSString *)version;

/// Run a block, returning nil, or the description of the Objective-C
/// exception it raised.
///
/// Swift has no catch for NSException, so an AVFoundation SPI that
/// throws takes the process with it - which is what
/// setShouldProvideMediaData:forTrackID: did when it was handed a track
/// id the parser did not have. The MSE FairPlay route is establishing
/// this interface's behaviour by experiment, and a wrong guess should
/// cost a log line rather than the app.
+ (nullable NSString *)catchExceptionFrom:(NS_NOESCAPE void (^)(void))block;

@end

#endif /* GeckoRuntimeBridge_h */
