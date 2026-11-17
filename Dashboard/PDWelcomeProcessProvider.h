/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeModel.h"

/* Linux process discovery. The model itself has no /proc or platform policy;
   other platforms can supply their own PDWelcomeTargetProvider. */
@interface PDWelcomeProcessProvider : NSObject <PDWelcomeTargetProvider>
@end
