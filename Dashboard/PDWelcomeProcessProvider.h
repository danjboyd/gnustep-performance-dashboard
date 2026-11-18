/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeModel.h"

/* Linux process discovery. The model itself has no /proc or platform policy;
   other platforms can supply their own PDWelcomeTargetProvider. */
@interface PDWelcomeProcessProvider : NSObject <PDWelcomeTargetProvider>
+ (NSString *) identityFromStatData: (NSData *)data;
+ (NSString *) processNameFromData: (NSData *)data;
+ (NSNumber *) realUIDFromStatusData: (NSData *)data;
+ (NSString *) attachProblemForRealUID: (NSNumber *)uid currentUID: (unsigned)currentUID
                       helperAvailable: (BOOL)available;
/* The reader is overridable for isolated cache tests; classification and
   incarnation checks remain the production implementation. */
- (NSData *) processMapsDataForPID: (int)pid;
- (PDGNUstepIdentity) GNUstepIdentityForPID: (int)pid identity: (NSString *)identity;
@end
