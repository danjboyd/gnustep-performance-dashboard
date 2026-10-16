/* NSOutlineView whose outline column is not the first column: where
   -frameOfOutlineCellAtRow: puts the disclosure triangle, against the
   outline column's cell; then which of the two places a click expands.

   cc `gnustep-config --objc-flags` outline_column_frame.m -o outline_column_frame \
     `gnustep-config --gui-libs`  */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <stdio.h>

@interface Source : NSObject
@end

@implementation Source
- (NSInteger) outlineView: (NSOutlineView *)ov numberOfChildrenOfItem: (id)item
{
  return item == nil ? 1 : ([item isEqual: @"parent"] ? 1 : 0);
}
- (id) outlineView: (NSOutlineView *)ov child: (NSInteger)index ofItem: (id)item
{
  return item == nil ? @"parent" : @"child";
}
- (BOOL) outlineView: (NSOutlineView *)ov isItemExpandable: (id)item
{
  return [item isEqual: @"parent"];
}
- (id) outlineView: (NSOutlineView *)ov
  objectValueForTableColumn: (NSTableColumn *)column
             byItem: (id)item
{
  return item;
}
@end

static NSOutlineView *
makeOutline(NSWindow **window, Source *source)
{
  NSOutlineView *outline;
  NSTableColumn *first, *second;

  *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 400, 200)
                                        styleMask: NSTitledWindowMask
                                          backing: NSBackingStoreBuffered
                                            defer: NO];
  outline = [[NSOutlineView alloc] initWithFrame: NSMakeRect(0, 0, 400, 200)];
  first = [[NSTableColumn alloc] initWithIdentifier: @"first"];
  [first setWidth: 150];
  second = [[NSTableColumn alloc] initWithIdentifier: @"second"];
  [second setWidth: 200];
  [outline addTableColumn: first];
  [outline addTableColumn: second];
  [outline setOutlineTableColumn: second];
  [outline setDataSource: source];
  [[*window contentView] addSubview: outline];
  [outline reloadData];
  [outline tile];
  return outline;
}

static BOOL
clickExpands(Source *source, CGFloat x)
{
  NSWindow *window;
  NSOutlineView *outline = makeOutline(&window, source);
  NSRect row = [outline rectOfRow: 0];
  NSPoint p = [outline convertPoint: NSMakePoint(x, NSMidY(row)) toView: nil];
  NSEvent *click = [NSEvent mouseEventWithType: NSLeftMouseDown
                                      location: p
                                 modifierFlags: 0
                                     timestamp: 0
                                  windowNumber: [window windowNumber]
                                       context: nil
                                   eventNumber: 0
                                    clickCount: 1
                                      pressure: 1.0];
  NSEvent *up = [NSEvent mouseEventWithType: NSLeftMouseUp
                                   location: p
                              modifierFlags: 0
                                  timestamp: 0
                               windowNumber: [window windowNumber]
                                    context: nil
                                eventNumber: 0
                                 clickCount: 1
                                   pressure: 0.0];

  /* A click that misses the triangle goes to NSTableView's tracking,
     which waits for the mouse-up.  */
  [NSApp postEvent: up atStart: NO];
  [outline mouseDown: click];
  return [outline isItemExpanded: @"parent"];
}

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  Source *source;
  NSWindow *window;
  NSOutlineView *outline;
  NSRect cell, knob;

  [NSApplication sharedApplication];
  source = [Source new];
  outline = makeOutline(&window, source);
  cell = [outline frameOfCellAtColumn: 1 row: 0];
  knob = [outline frameOfOutlineCellAtRow: 0];

  printf("outline column (column 1) cell, row 0: x %.0f to %.0f\n",
         NSMinX(cell), NSMaxX(cell));
  printf("frameOfOutlineCellAtRow: 0:            x %.0f to %.0f\n",
         NSMinX(knob), NSMaxX(knob));
  printf("click at x %.0f (where the triangle is drawn) expands the item: %s\n",
         NSMinX(knob) + 5, clickExpands(source, NSMinX(knob) + 5) ? "yes" : "no");
  printf("click at x %.0f (start of the outline column) expands the item: %s\n",
         NSMinX(cell) + 5, clickExpands(source, NSMinX(cell) + 5) ? "yes" : "no");
  [pool release];
  return 0;
}
