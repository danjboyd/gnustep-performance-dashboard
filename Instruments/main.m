#import <AppKit/AppKit.h>
#import "INAppController.h"

int
main(int argc, const char **argv)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      INAppController *controller = [INAppController new];
      [NSApp setDelegate: controller];
      [NSApp run];
    }
  return 0;
}
