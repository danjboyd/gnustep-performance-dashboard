/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "Dashboard/PDWelcomeArguments.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, const char **argv)
{
  PDPrepareWelcomeProcessArguments(argc, argv);
  @autoreleasepool
    {
      NSDictionary *domain = [[NSUserDefaults standardUserDefaults] volatileDomainForName: NSArgumentDomain];
      NSArray *raw = [PDWelcomeArguments processArguments];
      BOOL passed = [PDWelcomeArguments hasRecordingAliases]
        && [[domain objectForKey: @"PDAppOnly"] isEqual: @"preserved"]
        && [domain objectForKey: @"GSFilePath"] == nil
        && [domain objectForKey: @"GSTheme"] == nil
        && [[[NSProcessInfo processInfo] arguments] count] == 3
        && [raw containsObject: @"-GSFilePath"] && [raw containsObject: @"target-theme"];
      if (!passed)
        { fprintf(stderr, "FAIL: target arguments reached GUI defaults or were lost\n"); return 1; }
      puts("Welcome argv: GNUstep defaults isolated; original target arguments preserved");
    }
  return 0;
}
