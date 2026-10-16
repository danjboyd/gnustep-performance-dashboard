/* -[NSButton state] and libobjc2's selector type check.

   cc `gnustep-config --objc-flags` button_state_signature.m \
     -o button_state_signature `gnustep-config --gui-libs`  */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdio.h>

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  NSButton *button;

  [NSApplication sharedApplication];
  button = [[NSButton alloc] initWithFrame: NSMakeRect(0, 0, 100, 20)];
  [button setButtonType: NSSwitchButton];
  [button setState: NSOnState];
  fprintf(stderr, "[button state] = %ld\n", (long)[button state]);
  fprintf(stderr, "[[button cell] state] = %ld\n", (long)[[button cell] state]);
  [button release];
  [pool release];
  return 0;
}
