/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Exercise the actual delegate; observe the public API boundary without a
   sampler. Alerts must see a closed interval; cancelling must emit none. */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "Dashboard/PDAppController.h"
#import "Dashboard/PDTraceWindowController.h"
#include <os/signpost.h>
#include <stdarg.h>
#include <string.h>

static unsigned checks, begins, ends, alerts;
static os_signpost_id_t nextID, activeID;
static const char *lastOutcome;

static void check(BOOL condition, NSString *name)
{
  if (!condition) { NSLog(@"FAIL: %@", name); exit(1); }
  checks++; NSLog(@"ok: %@", name);
}

gsp_log_t gsp_log_create(const char *subsystem, const char *category)
{
  check(strcmp(subsystem, "org.gnustep.PerformanceDashboard") == 0
    && strcmp(category, "PointsOfInterest") == 0, @"stable signpost log identity");
  return (gsp_log_t)(uintptr_t)1;
}
gsp_signpost_id_t gsp_signpost_id_generate(gsp_log_t log) { return ++nextID; }
void gsp_signpost_emit(gsp_log_t log, int kind, gsp_signpost_id_t spid,
                      const char *name, const char *format, ...)
{
  check(strcmp(name, "OpenTrace") == 0, @"OpenTrace interval name");
  if (kind == 1)
    {
      check(activeID == 0 && spid != 0, @"unique non-overlapping interval begin");
      activeID = spid; begins++;
    }
  else
    {
      check(kind == 2 && activeID == spid, @"matching interval end");
      va_list ap; va_start(ap, format); lastOutcome = va_arg(ap, const char *); va_end(ap);
      activeID = 0; ends++;
    }
}

NSInteger NSRunAlertPanel(NSString *title, NSString *message, NSString *def,
                         NSString *alt, NSString *other, ...)
{
  check(activeID == 0 && begins == ends, @"error interval ends before the alert");
  alerts++; return NSOKButton;
}

static NSInteger cancelPanel(id self, SEL cmd, id directory, id file, id types)
{ return NSCancelButton; }
static id throwDuringOpen(id self, SEL cmd, id path, id completion)
{ [NSException raise: @"OpenTraceCheck" format: @"reader exception"]; return nil; }

static IMP originalRead;
static NSCondition *readGate;
static BOOL releasedReader, readerWasOnMain, heartbeatRan;
@interface LoadHeartbeat : NSObject
- (void) releaseReader: (id)sender;
@end
@implementation LoadHeartbeat
- (void) releaseReader: (id)sender
{
  [readGate lock];
  heartbeatRan = YES;
  releasedReader = YES;
  [readGate broadcast];
  [readGate unlock];
}
@end
static id gatedRead(id receiver, SEL selector, id path, NSError **error)
{
  [readGate lock];
  readerWasOnMain = [NSThread isMainThread];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 10];
  while (!releasedReader && [deadline timeIntervalSinceNow] > 0)
    [readGate waitUntilDate: deadline];
  [readGate unlock];
  return ((id (*)(id, SEL, id, NSError **))originalRead)(receiver, selector, path, error);
}

static void waitForEnds(unsigned count)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 10];
  while (ends < count && [deadline timeIntervalSinceNow] > 0)
    [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: .01]];
  check(ends == count, @"asynchronous load completes on the main run loop");
}

int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      PDAppController *controller = [PDAppController new];
      NSString *sample = [NSString stringWithUTF8String: getenv("PD_OPEN_TRACE_SAMPLE")];
      readGate = [NSCondition new];
      Method read = class_getClassMethod([GSPTrace class], @selector(traceWithPath:error:));
      originalRead = method_setImplementation(read, (IMP)gatedRead);
      LoadHeartbeat *heartbeat = [LoadHeartbeat new];
      check([controller openTraceAtPath: sample], @"actual sample reader succeeds");
      PDTraceWindowController *opening = [[controller valueForKey: @"windows"] lastObject];
      check(opening.isLoading, @"loading window and progress are available before parsing finishes");
      [NSTimer scheduledTimerWithTimeInterval: .05 target: heartbeat
                                     selector: @selector(releaseReader:) userInfo: nil repeats: NO];
      waitForEnds(1);
      method_setImplementation(read, originalRead);
      check(heartbeatRan && !readerWasOnMain && !opening.isLoading,
        @"main-loop heartbeat runs while the trace reader is blocked on its worker");
      check(begins == 1 && ends == 1 && strcmp(lastOutcome, "success") == 0,
        @"successful open emits one balanced success interval");
      check([controller openTraceAtPath: [sample stringByAppendingPathComponent: @"missing.gstrace"]],
        @"missing trace request accepted for asynchronous reading");
      waitForEnds(2);
      check(begins == 2 && ends == 2 && alerts == 1 && strcmp(lastOutcome, "error") == 0,
        @"failed open emits one balanced error interval");

      Method modal = class_getInstanceMethod([NSOpenPanel class],
        @selector(runModalForDirectory:file:types:));
      IMP original = method_setImplementation(modal, (IMP)cancelPanel);
      @try { [controller openTrace: nil]; }
      @finally { method_setImplementation(modal, original); }
      check(begins == 2 && ends == 2 && activeID == 0,
        @"cancelled file selection emits no interval");

      Method reader = class_getInstanceMethod([PDTraceWindowController class],
        @selector(initForLoadingTraceAtPath:completion:));
      original = method_setImplementation(reader, (IMP)throwDuringOpen);
      BOOL caught = NO;
      @try { [controller openTraceAtPath: sample]; }
      @catch (NSException *exception) { caught = [exception.name isEqual: @"OpenTraceCheck"]; }
      @finally { method_setImplementation(reader, original); }
      check(caught && begins == 3 && ends == 3 && activeID == 0
        && strcmp(lastOutcome, "error") == 0, @"exception unwinding closes its interval");
      readGate = [NSCondition new];
      releasedReader = NO;
      method_setImplementation(read, (IMP)gatedRead);
      __block BOOL closedCompleted = NO;
      PDTraceWindowController *closed = [[PDTraceWindowController alloc]
        initForLoadingTraceAtPath: sample completion: ^(BOOL success, NSError *error) {
          check([NSThread isMainThread] && !success && error == nil,
            @"closing during loading completes once without an error alert");
          closedCompleted = YES;
        }];
      [[closed window] close];
      [heartbeat releaseReader: nil];
      NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 10];
      while (!closedCompleted && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: .01]];
      method_setImplementation(read, originalRead);
      check(closedCompleted && !closed.isLoading,
        @"closed loading window does not publish the worker's completed model");
      printf("All %u OpenTrace checks passed.\n", checks);
      exit(0);
    }
}
