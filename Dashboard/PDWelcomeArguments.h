/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeModel.h"

@interface PDWelcomeArguments : NSObject
/* ARGV includes the executable at index zero. Arguments after --launch PATH
   belong to the target, like gstrace. No recognized alias leaves HANDLED NO. */
+ (GSPRecordingOptions *) optionsFromArguments: (NSArray *)argv
                                    provider: (id<PDWelcomeTargetProvider>)provider
                                     handled: (BOOL *)handled
                                       error: (NSError **)error;
@end
