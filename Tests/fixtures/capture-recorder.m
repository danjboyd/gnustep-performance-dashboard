/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <GSPerformance/GSPerformance.h>
#include <errno.h>
#include <stdio.h>

@interface GSPRecorder (CaptureTestSeam)
- (BOOL) captureFilesystemAtDescriptor: (int)fd capacity: (uint64_t *)capacity
                            available: (uint64_t *)available error: (int *)code;
@end
@interface CaptureTestRecorder : GSPRecorder
@property (nonatomic, copy) NSString *mode;
@property (nonatomic) unsigned measurements;
@end
@implementation CaptureTestRecorder
- (BOOL) captureFilesystemAtDescriptor: (int)fd capacity: (uint64_t *)capacity
                            available: (uint64_t *)available error: (int *)code
{
  (void)fd;
  self.measurements++;
  uint64_t gib = UINT64_C(1073741824);
  *capacity = 40 * gib;
  *available = 3 * gib;
  if ([self.mode isEqual: @"preflight"] || ([self.mode isEqual: @"crossing"] && self.measurements > 2))
    *available = gib;
  if ([self.mode isEqual: @"stat-error"] && self.measurements > 2)
    { *code = EIO; return NO; }
  if ([self.mode isEqual: @"late-error"] && self.stopTrigger)
    { *code = EIO; return NO; }
  return YES;
}
@end

int
main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc != 5) return 2;
      GSPRecordingOptions *options = [GSPRecordingOptions new];
      options.executablePath = [NSString stringWithUTF8String: argv[2]];
      options.outputPath = [NSString stringWithUTF8String: argv[3]];
      options.arguments = @[@"loop"];
      options.timeLimit = 0.5;
      options.instrumentIdentifiers = @[@"time-profiler"];
      NSString *mode = [NSString stringWithUTF8String: argv[1]];
      if ([mode isEqual: @"crossing"] || [mode isEqual: @"stat-error"])
        options.timeLimit = 5;
      if ([mode isEqual: @"stdout"])
        {
          options.captureOutput = YES;
          options.maximumTraceBytes = 128 * 1024;
          options.timeLimit = 5;
          options.arguments = @[@"stdout"];
        }
      if ([mode isEqual: @"disabled"] || [mode isEqual: @"override"])
        {
          options.automaticMinimumFreeSpace = NO;
          options.minimumFreeBytes = [mode isEqual: @"disabled"] ? 0 : 1;
        }
      CaptureTestRecorder *recorder = [[CaptureTestRecorder alloc] initWithOptions: options];
      recorder.mode = mode;
      NSError *error = nil;
      BOOL started = [recorder start: &error];
      if (started) [recorder waitUntilFinished];
      NSDictionary *result = @{
        @"started": @(started), @"pid": @(recorder.pid),
        @"measurements": @(recorder.measurements),
        @"floor": @(recorder.effectiveMinimumFreeBytes),
        @"trigger": recorder.stopTrigger ?: @"none",
        @"errorCode": @([(error ?: recorder.recordingError) code]),
        @"error": [(error ?: recorder.recordingError) localizedDescription] ?: @"none"
      };
      NSData *json = [NSJSONSerialization dataWithJSONObject: result options: 0 error: NULL];
      return [json writeToFile: [NSString stringWithUTF8String: argv[4]] atomically: YES] ? 0 : 3;
    }
}
