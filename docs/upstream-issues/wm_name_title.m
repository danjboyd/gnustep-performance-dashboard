/* A window titled with a non-ASCII character (an em dash): run it with
   no locale in the environment and read WM_NAME with xprop.

   clang `gnustep-config --objc-flags` wm_name_title.m \
     -o wm_name_title `gnustep-config --gui-libs`  */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSWindow *window;

  [NSApplication sharedApplication];
  window = [[NSWindow alloc] initWithContentRect: NSMakeRect(50, 50, 300, 100)
                                       styleMask: NSTitledWindowMask
                                         backing: NSBackingStoreBuffered
                                           defer: NO];
  [window setTitle: [NSString stringWithUTF8String: "Caf\xc3\xa9 \xe2\x80\x94 Test"]];
  [window orderFront: nil];
  [NSApp run];
  [window release];
  [pool release];
  return 0;
}
