#import <AppKit/AppKit.h>
#import "PDAppController.h"

int
main(int argc, const char **argv)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      PDAppController *controller = [PDAppController new];
      [NSApp setDelegate: controller];
      [NSApp run];
    }
  return 0;
}
