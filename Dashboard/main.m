/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <AppKit/AppKit.h>
#import "PDAppController.h"

/* Built without ARC (GNUmakefile) so that the outermost pool is an
   NSAutoreleasePool. With @autoreleasepool it is only libobjc2's, and
   libs-base's pool list then breaks: under the default theme and Sombre,
   ending a modal panel that holds a table, opened from a button or a menu
   item (the template chooser), sent -[NSAutoreleasePool emptyPool] into
   endless recursion.  */
int
main(int argc, const char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  PDAppController *controller;

  [NSApplication sharedApplication];
  controller = [PDAppController new];
  [NSApp setDelegate: controller];
  [NSApp run];
  [controller release];
  [pool release];
  return 0;
}
