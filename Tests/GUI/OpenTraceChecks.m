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
static id throwDuringOpen(id self, SEL cmd, id path, NSError **error)
{ [NSException raise: @"OpenTraceCheck" format: @"reader exception"]; return nil; }

int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      PDAppController *controller = [PDAppController new];
      NSString *sample = [NSString stringWithUTF8String: getenv("PD_OPEN_TRACE_SAMPLE")];
      check([controller openTraceAtPath: sample], @"actual sample reader succeeds");
      check(begins == 1 && ends == 1 && strcmp(lastOutcome, "success") == 0,
        @"successful open emits one balanced success interval");
      check(![controller openTraceAtPath: [sample stringByAppendingPathComponent: @"missing.gstrace"]],
        @"actual missing trace returns an error");
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
        @selector(initWithTracePath:error:));
      original = method_setImplementation(reader, (IMP)throwDuringOpen);
      BOOL caught = NO;
      @try { [controller openTraceAtPath: sample]; }
      @catch (NSException *exception) { caught = [exception.name isEqual: @"OpenTraceCheck"]; }
      @finally { method_setImplementation(reader, original); }
      check(caught && begins == 3 && ends == 3 && activeID == 0
        && strcmp(lastOutcome, "error") == 0, @"exception unwinding closes its interval");
      printf("All %u OpenTrace checks passed.\n", checks);
      exit(0);
    }
}
