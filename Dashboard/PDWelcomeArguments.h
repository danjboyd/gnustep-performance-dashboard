/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeModel.h"

/* Call before creating NSApplication/defaults. GNUstep otherwise treats target
   -Key/value pairs as application defaults and document-open requests. */
void PDPrepareWelcomeProcessArguments(int argc, const char **argv);

@interface PDWelcomeArguments : NSObject
+ (NSArray *) processArguments;
+ (BOOL) hasRecordingAliases;
/* ARGV includes the executable at index zero. Arguments after --launch PATH
   belong to the target, like gstrace. No recognized alias leaves HANDLED NO. */
+ (GSPRecordingOptions *) optionsFromArguments: (NSArray *)argv
                                    provider: (id<PDWelcomeTargetProvider>)provider
                                     handled: (BOOL *)handled
                                       error: (NSError **)error;
@end
