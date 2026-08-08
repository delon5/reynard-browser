//
//  Utils.h
//  Reynard
//
//  Created by Minh Ton on 12/4/26.
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

BOOL getEntitlementValue(NSString *key);
void updateJetsamControl(pid_t pid);
// Returns three disjoint ranges: a negative value is -errno from
// posix_spawn/waitpid (the child never ran or was lost), 0-255 is the
// child's own exit status, and 128+N means the child was killed by
// signal N.
int spawnRoot(NSString *path, NSArray<NSString *> *args);

NS_ASSUME_NONNULL_END
