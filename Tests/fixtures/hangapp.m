/* hangapp - AppKit fixture for the Hangs instrument: blocks the main
   thread for 0.3 s, 0.7 s and 2.2 s at known times, emitting a signpost
   around each block, then quits.  */

#import <AppKit/AppKit.h>
#include <os/signpost.h>

static os_log_t poi;

@interface HangController : NSObject
{
  NSWindow *window;
  int step;
}
@end

@implementation HangController

static void
busy(double seconds)
{
  NSDate *end = [NSDate dateWithTimeIntervalSinceNow: seconds];
  volatile double x = 0;
  while ([end timeIntervalSinceNow] > 0)
    for (int i = 0; i < 10000; i++)
      x += i * 0.5;
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  window = [[NSWindow alloc] initWithContentRect: NSMakeRect(100, 100, 320, 120)
                                       styleMask: NSTitledWindowMask
                                         backing: NSBackingStoreBuffered defer: NO];
  [window setTitle: @"Hang Fixture"];
  [window orderFront: nil];
  [NSTimer scheduledTimerWithTimeInterval: 0.6 target: self
                                 selector: @selector(tick:) userInfo: nil repeats: YES];
}

- (void) tick: (NSTimer *)t
{
  static const double durations[] = { 0.3, 0.0, 0.7, 0.0, 2.2, 0.0, 0.0 };
  if (step < 7)
    {
      double d = durations[step];
      if (d > 0)
        {
          os_signpost_id_t spid = os_signpost_id_generate(poi);
          os_signpost_interval_begin(poi, spid, "Block", "%.1f s", d);
          busy(d);
          os_signpost_interval_end(poi, spid, "Block");
        }
      step++;
      return;
    }
  [t invalidate];
  [NSApp terminate: nil];
}

@end

int
main(int argc, const char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  poi = os_log_create("org.gnustep.tests", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  [NSApplication sharedApplication];
  [NSApp setDelegate: [HangController new]];
  [NSApp run];
  [pool release];
  return 0;
}
