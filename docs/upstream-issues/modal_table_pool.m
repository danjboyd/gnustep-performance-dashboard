/* A modal panel holding a table, run from a button's action, with only
   libobjc2's autorelease pool (no NSAutoreleasePool) at the bottom: under
   the default theme the application crashes once the modal session ends,
   -[NSAutoreleasePool emptyPool] recursing until the stack overflows.
   Click Open, then Stop.

   clang `gnustep-config --objc-flags` modal_table_pool.m \
     -o modal_table_pool `gnustep-config --gui-libs`  */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdio.h>

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *pool);

@interface Controller : NSObject
- (void) openPanel: (id)sender;
- (void) stop: (id)sender;
@end

@implementation Controller

- (NSInteger) numberOfRowsInTableView: (NSTableView *)tv
{
  return 5;
}

- (id) tableView: (NSTableView *)tv
objectValueForTableColumn: (NSTableColumn *)column
             row: (NSInteger)row
{
  return [NSString stringWithFormat: @"Row %ld", (long)row];
}

- (void) stop: (id)sender
{
  [NSApp stopModal];
}

- (void) openPanel: (id)sender
{
  NSPanel *panel;
  NSScrollView *scroll;
  NSTableView *table;
  NSTableColumn *column;
  NSButton *button;

  panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(100, 100, 400, 200)
                                     styleMask: NSTitledWindowMask
                                       backing: NSBackingStoreBuffered
                                         defer: NO];
  [panel setTitle: @"Modal"];

  scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(200, 60, 180, 130)];
  table = [[NSTableView alloc] initWithFrame: [[scroll contentView] bounds]];
  column = [[NSTableColumn alloc] initWithIdentifier: @"name"];
  [table addTableColumn: column];
  [table setDataSource: self];
  [scroll setDocumentView: table];
  [[panel contentView] addSubview: scroll];

  button = [[NSButton alloc] initWithFrame: NSMakeRect(20, 20, 100, 30)];
  [button setTitle: @"Stop"];
  [button setTarget: self];
  [button setAction: @selector(stop:)];
  [[panel contentView] addSubview: button];

  [NSApp runModalForWindow: panel];
  [panel orderOut: nil];
  fprintf(stderr, "modal ended\n");

  [column release];
  [table release];
  [scroll release];
  [button release];
  [panel release];
}

@end

int
main(void)
{
  void *pool = objc_autoreleasePoolPush();
  Controller *controller;
  NSWindow *window;
  NSButton *open;

  [NSApplication sharedApplication];
  controller = [Controller new];
  window = [[NSWindow alloc] initWithContentRect: NSMakeRect(50, 50, 300, 100)
                                       styleMask: NSTitledWindowMask
                                         backing: NSBackingStoreBuffered
                                           defer: NO];
  [window setTitle: @"Main"];
  open = [[NSButton alloc] initWithFrame: NSMakeRect(10, 10, 100, 30)];
  [open setTitle: @"Open"];
  [open setTarget: controller];
  [open setAction: @selector(openPanel:)];
  [[window contentView] addSubview: open];
  [window orderFront: nil];
  [NSApp run];
  objc_autoreleasePoolPop(pool);
  return 0;
}
