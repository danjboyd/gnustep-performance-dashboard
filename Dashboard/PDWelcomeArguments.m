/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeArguments.h"
#include <limits.h>

@implementation PDWelcomeArguments
+ (GSPRecordingOptions *) optionsFromArguments: (NSArray *)argv
                                    provider: (id<PDWelcomeTargetProvider>)provider
                                     handled: (BOOL *)handled
                                       error: (NSError **)error
{
  if (handled)
    *handled = NO;
  NSString *path = nil, *recordingTemplate = nil, *problem = nil;
  NSArray *arguments = [NSArray array];
  int pid = 0;
  BOOL seen = NO, targetSeen = NO;
  PDWelcomeTargetMode mode = PDWelcomeLaunch;
  for (NSUInteger i = 1; i < [argv count]; i++)
    {
      NSString *option = [argv objectAtIndex: i];
      if (![option isEqual: @"--launch"] && ![option isEqual: @"--attach"]
          && ![option isEqual: @"--template"])
        continue; /* GNUstep/defaults and document arguments keep their path. */
      seen = YES;
      if (++i == [argv count])
        { problem = [option stringByAppendingString: @" requires a value."]; break; }
      NSString *value = [argv objectAtIndex: i];
      if ([option isEqual: @"--template"])
        { recordingTemplate = value; continue; }
      if (targetSeen)
        { problem = @"Choose one --launch or --attach target."; break; }
      targetSeen = YES;
      if ([option isEqual: @"--launch"])
        {
          path = value;
          arguments = [argv subarrayWithRange: NSMakeRange(i + 1, [argv count] - i - 1)];
          break;
        }
      mode = PDWelcomeAttach;
      NSScanner *scanner = [NSScanner scannerWithString: value];
      long long number = 0;
      if (![scanner scanLongLong: &number] || ![scanner isAtEnd] || number <= 0 || number > INT_MAX)
        { problem = @"--attach requires a positive process ID."; break; }
      pid = (int)number;
    }
  if (handled)
    *handled = seen;
  if (!seen)
    return nil;
  if (!problem && !targetSeen)
    problem = @"--template requires a --launch or --attach target.";
  if (!problem)
    {
      PDWelcomeModel *model = [[PDWelcomeModel alloc] initWithProvider: provider history: nil];
      model.mode = mode;
      model.templateName = recordingTemplate ?: (mode == PDWelcomeAttach ? @"System Time Profiler" : @"Time Profiler");
      model.executablePath = path;
      model.arguments = arguments;
      if (mode == PDWelcomeAttach)
        {
          [model refreshProcesses];
          for (PDWelcomeProcess *process in model.processes)
            if (process.pid == pid)
              { model.selectedProcess = process; break; }
        }
      return [model recordingOptionsWithError: error];
    }
  if (error)
    *error = [NSError errorWithDomain: @"PDWelcomeArgumentsErrorDomain" code: 2
      userInfo: [NSDictionary dictionaryWithObject: problem forKey: NSLocalizedDescriptionKey]];
  return nil;
}
@end
