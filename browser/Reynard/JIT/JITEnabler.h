//
//  JITEnabler.h
//  Reynard
//
//  Created by Minh Ton on 11/3/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface JITEnabler : NSObject

@property(class, nonatomic, readonly) JITEnabler *shared;

- (BOOL)enableJITForPID:(int32_t)pid
          hasTXMSupport:(BOOL)hasTXMSupport
                  error:(NSError *_Nullable *_Nullable)error

NS_SWIFT_NAME(enableJIT(forPID:hasTXMSupport:));

- (void)detachAllJITSessions NS_SWIFT_NAME(detachAllJITSessions());

// Whether ANY process - main app or Helper - currently has a
// genuinely active, running JIT debug session. A live status, not a
// hardware/OS capability check - matches DolphiniOS's own "JIT
// Acquisition" row, confirmed against their own blog: they check
// whether JIT is currently enabled each time before launching a game,
// not a cached or static capability.
+ (BOOL)hasActiveJITSession NS_SWIFT_NAME(hasActiveJITSession());

// Clears the cached DeviceProvider (getProviderForPID's own
// sharedProvider) so the next call is forced to establish a fresh
// connection instead of reusing one that may be poisoned by a timed-
// out attempt. Deliberately does NOT free the old provider's memory -
// see fix_invalidate_provider_on_timeout.py's docstring for the full,
// important safety reasoning (a still-orphaned background call may
// still be using it).
- (void)invalidateSharedProviderAfterTimeout NS_SWIFT_NAME(invalidateSharedProviderAfterTimeout());

@end

NS_ASSUME_NONNULL_END
