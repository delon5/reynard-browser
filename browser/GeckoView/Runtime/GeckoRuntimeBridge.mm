//
//  GeckoRuntimeBridge.mm
//  Reynard
//
//  Created by Minh Ton on 24/5/26.
//

#import "GeckoRuntimeBridge.h"

#import "mozilla-config.h"

@implementation GeckoRuntimeBridge

+ (NSString *)version {
    return @MOZILLA_VERSION;
}

+ (nullable NSString *)catchExceptionFrom:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
    } @catch (NSException *exception) {
        // Name and reason both: the name says which exception family and
        // the reason is where AVFoundation puts the track id or selector
        // it objected to.
        return [NSString stringWithFormat:@"%@: %@", exception.name,
                                          exception.reason ?: @"no reason"];
    }
    return nil;
}

@end
