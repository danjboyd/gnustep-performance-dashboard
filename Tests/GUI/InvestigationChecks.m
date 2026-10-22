/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Runs the actual investigation controllers against a deterministic trace. */
#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>
#import "Dashboard/PDInvestigationWindowController.h"
#import "Dashboard/PDSourceWindowController.h"
#import "Tests/Unit/TraceBuilder.h"
#import "Dashboard/PDDetailController.h"
#import "Dashboard/PDTrackRenderer.h"
#import "Dashboard/PDInspectorView.h"
#include <stdlib.h>
#include <math.h>

@interface PDDetailController (Checks)
- (void) modeChanged: (id)sender;
@end

@interface PDInvestigationWindowController (Checks)
- (void) mark: (id)sender;
- (void) refresh: (id)sender;
- (void) removeMark: (id)sender;
@end

static unsigned checks;
static void check(BOOL result, NSString *name)
{
  if (!result) { NSLog(@"FAIL: %@", name); exit(1); }
  checks++; NSLog(@"ok: %@", name);
}
static void setText(id controller, NSString *key, NSString *value)
{ [[controller valueForKey: key] setStringValue: value]; }
static void capture(NSWindowController *controller, NSString *output, NSString *name)
{
  NSRect visible = (controller.window.screen ?: [NSScreen mainScreen]).visibleFrame;
  [controller.window setFrameOrigin: NSMakePoint(MAX(NSMinX(visible), MIN(60, NSMaxX(visible) - NSWidth(controller.window.frame))),
    MAX(NSMinY(visible), MIN(130, NSMaxY(visible) - NSHeight(controller.window.frame))))];
  [controller showWindow: nil];
  [controller.window makeKeyAndOrderFront: nil];
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow: .4];
  while ([until timeIntervalSinceNow] > 0)
    {
      NSEvent *event = [NSApp nextEventMatchingMask: NSAnyEventMask untilDate: until
        inMode: NSDefaultRunLoopMode dequeue: YES];
      if (event) [NSApp sendEvent: event];
    }
  [NSApp updateWindows];
#if !defined(_WIN32)
  NSTask *task = [NSTask new];
  task.launchPath = @"/usr/bin/import";
  task.arguments = @[@"-window", @"root", [output stringByAppendingPathComponent: name]];
  [task launch]; [task waitUntilExit];
  check(task.terminationStatus == 0, @"screenshot captured");
#endif
}

static void checkLayout(NSWindowController *controller, NSString *output, NSString *name)
{
  NSWindow *window = controller.window;
  NSRect original = window.frame;
  check(NSContainsRect((window.screen ?: [NSScreen mainScreen]).visibleFrame, original),
    [name stringByAppendingString: @" initial window fits the available display"]);
  for (NSUInteger i = 0; i < 2; i++)
    {
      NSSize size = i ? window.minSize : NSMakeSize(1008, 650);
      [window setFrame: NSMakeRect(60, 130, size.width, size.height) display: YES];
      NSString *label = [NSString stringWithFormat: @"%@-%@", name, i ? @"minimum" : @"1008"];
      capture(controller, output, [label stringByAppendingPathExtension: @"png"]);
      NSView *content = window.contentView;
      BOOL contained = YES;
      for (NSView *view in content.subviews)
        if (!view.isHidden && !NSContainsRect(NSInsetRect(content.bounds, -1, -1), view.frame))
          { NSLog(@"Outside content: %@ %@ in %@", view, NSStringFromRect(view.frame), NSStringFromRect(content.bounds)); contained = NO; }
      check(contained, [label stringByAppendingString: @" controls remain within the content view"]);
      NSTableView *table = [controller valueForKey: @"table"];
      NSRect last = [table rectOfColumn: table.tableColumns.count - 1];
      check(NSMaxX(last) <= NSWidth(table.enclosingScrollView.contentView.bounds) + 1,
        [label stringByAppendingString: @" all column headings are visible without scrolling"]);
      BOOL readable = YES;
      for (NSTableColumn *column in table.tableColumns)
        {
          NSCell *header = column.headerCell;
          NSFont *font = header.font ?: [NSFont systemFontOfSize: [NSFont systemFontSize]];
          CGFloat title = [header.stringValue sizeWithAttributes: @{NSFontAttributeName: font}].width;
          if (column.width < ceil(title) + 8) readable = NO;
        }
      check(readable, [label stringByAppendingString: @" column headings retain room for their text"]);
      NSArray *rows = [controller valueForKey: @"rows"];
      BOOL valuesFit = YES;
      if (rows.count)
        for (NSUInteger columnIndex = 1; columnIndex < table.tableColumns.count; columnIndex++)
          {
            NSTableColumn *column = table.tableColumns[columnIndex];
            NSFont *font = column.dataCell.font ?: [NSFont systemFontOfSize: [NSFont systemFontSize]];
            NSString *value = rows[0][@"cells"][columnIndex];
            if (column.width < ceil([value sizeWithAttributes: @{NSFontAttributeName: font}].width) + 8)
              valuesFit = NO;
          }
      check(valuesFit, [label stringByAppendingString: @" numeric values remain readable"]);
      NSTableView *frames = [[controller valueForKey: @"inspector"] valueForKey: @"frames"];
      BOOL inspectorHeadings = NSMaxX([frames rectOfColumn: frames.tableColumns.count - 1])
        <= NSWidth(frames.enclosingScrollView.contentView.bounds) + 1;
      for (NSTableColumn *column in frames.tableColumns)
        {
          NSFont *font = column.headerCell.font ?: [NSFont systemFontOfSize: [NSFont systemFontSize]];
          CGFloat title = [column.headerCell.stringValue sizeWithAttributes: @{NSFontAttributeName: font}].width;
          if (column.width < ceil(title) + 8) inspectorHeadings = NO;
        }
      check(inspectorHeadings, [label stringByAppendingString: @" inspector column headings remain readable"]);
    }
  [window setFrame: original display: YES];
}

int main(int argc, char **argv)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      [NSApp finishLaunching];
      NSString *output = [[NSProcessInfo processInfo] environment][@"PD_GUI_OUTPUT"] ?: NSTemporaryDirectory();
      TraceBuilder *b = [[TraceBuilder alloc] initWithPID: 4242];
      uint64_t frames[] = { 0x3010, 0x1010 };
      [b name: 0x3000 as: @"make_document"]; [b name: 0x1000 as: @"main"];
      [b thread: 4242 name: "main" main: YES at: b.start];
      [b stack: 1 frames: frames count: 2];
      [b allocAt: b.start + 10000000 address: 0x10000 size: 32 stack: 1];
      [b allocAt: b.start + 20000000 address: 0x20000 size: 64 stack: 1];
      [b freeAt: b.start + 30000000 address: 0x10000];
      [b sampleAt: b.start + 10000000 tid: 4242 kind: GSP_SAMPLE_CPU weight: 3 frames: frames count: 2];
      [b name: 0x5000 as: @"poll"]; [b name: 0x6000 as: @"-[NSRunLoop runMode:beforeDate:]"];
      uint64_t idle[] = { 0x5010, 0x6010, 0x1010 };
      [b sampleAt: b.start tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: idle count: 3];
      for (unsigned i = 1; i <= 40; i++)
        [b sampleAt: b.start + i * 10000000ull tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: frames count: 2];
      [b sampleAt: b.start + 410000000 tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: idle count: 3];
      [b ioAt: b.start duration: 15000000 tid: 4242];
      [b end: b.start + 500000000];
      NSString *path = [b writeBundleNamed: @"investigation-gui" instruments: @[GSPInstrumentTimeProfiler, GSPInstrumentAllocations]];
      GSPTrace *trace = [GSPTrace traceWithPath: path error: NULL];
      PDInvestigationWindowController *generation = [[PDInvestigationWindowController alloc]
        initWithTrace: trace process: trace.targetProcess generations: YES start: 0 end: 0];
      setText(generation, @"name", @"Open document"); setText(generation, @"markTime", @"0.02");
      [generation mark: nil];
      check([[generation valueForKey: @"marks"] count] == 1, @"generation mark saved");
      NSTableView *table = [generation valueForKey: @"table"];
      check(table.numberOfRows == 3, @"generation category summary");
      check([[[generation valueForKey: @"rows"][0] objectForKey: @"cells"][1] isEqual: @"64 Bytes"], @"survival measured after free");
      capture(generation, output, @"generations.png");
      checkLayout(generation, output, @"generations-layout");
      [[generation valueForKey: @"mode"] selectItemAtIndex: 1]; [generation refresh: nil];
      check(table.numberOfRows == 1, @"surviving stack counts leaf allocations once");
      [table selectRowIndexes: [NSIndexSet indexSetWithIndex: 0] byExtendingSelection: NO];
      capture(generation, output, @"generation-stacks.png");
      setText(generation, @"markTime", @"0.01"); [generation mark: nil];
      check([[generation valueForKey: @"marks"] count] == 1, @"out-of-order mark refused");
      [generation close];
      generation = [[PDInvestigationWindowController alloc] initWithTrace: trace process: trace.targetProcess
        generations: YES start: 0 end: 0];
      check([[generation valueForKey: @"marks"] count] == 1, @"marks survive reopening");
      [generation removeMark: nil];
      check([[generation valueForKey: @"marks"] count] == 0, @"remove last mark persists");
      [generation close];
      PDInvestigationWindowController *comparison = [[PDInvestigationWindowController alloc]
        initWithTrace: trace process: trace.targetProcess generations: NO start: 0 end: 0];
      [comparison setValue: trace forKey: @"baseline"];
      setText(comparison, @"beforeStart", @"0"); setText(comparison, @"beforeEnd", @"0.02");
      setText(comparison, @"afterStart", @"0.03"); setText(comparison, @"afterEnd", @"0.05");
      [comparison refresh: nil];
      table = [comparison valueForKey: @"table"];
      check(table.numberOfRows == 1, @"independent comparison ranges");
      [table selectRowIndexes: [NSIndexSet indexSetWithIndex: 0] byExtendingSelection: NO];
      capture(comparison, output, @"comparison.png");
      checkLayout(comparison, output, @"comparison-layout");
      setText(comparison, @"beforeStart", @"not a number"); [comparison refresh: nil];
      check(table.numberOfRows == 0, @"invalid input clears stale results");
      [comparison close];
      NSWindow *hangWindow = [[NSWindow alloc] initWithContentRect: NSMakeRect(60, 130, 1100, 650)
        styleMask: NSTitledWindowMask | NSClosableWindowMask backing: NSBackingStoreBuffered defer: NO];
      [hangWindow setReleasedWhenClosed: NO]; [hangWindow setTitle: @"Hang Evidence"];
      NSWindowController *hangController = [[NSWindowController alloc] initWithWindow: hangWindow];
      PDInspectorView *inspector = [[PDInspectorView alloc] initWithFrame: NSMakeRect(750, 0, 350, 650)];
      PDDetailController *detail = [[PDDetailController alloc] initWithFrame: NSMakeRect(0, 0, 740, 650) inspector: inspector];
      detail.renderer = [[PDTrackRenderer alloc] initWithTrace: trace];
      [hangWindow.contentView addSubview: detail.view]; [hangWindow.contentView addSubview: inspector];
      [detail showInstrument: GSPInstrumentHangs];
      NSOutlineView *outline = [detail valueForKey: @"outline"];
      check(outline.numberOfRows == 1, @"hang evidence list");
      [outline selectRowIndexes: [NSIndexSet indexSetWithIndex: 0] byExtendingSelection: NO];
      capture(hangController, output, @"hang-evidence.png");
      /* Dispatch the actual outline gesture. Merely changing the popup mode
         does not exercise rowDoubleClicked: or its inspection-range update. */
      NSRect rowRect = [outline rectOfRow: 0];
      NSPoint click = [outline convertPoint: NSMakePoint(NSMidX(rowRect), NSMidY(rowRect)) toView: nil];
      NSEvent *up = [NSEvent mouseEventWithType: NSLeftMouseUp location: click modifierFlags: 0
        timestamp: 2 windowNumber: hangWindow.windowNumber context: nil eventNumber: 2 clickCount: 2 pressure: 0];
      NSEvent *down = [NSEvent mouseEventWithType: NSLeftMouseDown location: click modifierFlags: 0
        timestamp: 1 windowNumber: hangWindow.windowNumber context: nil eventNumber: 1 clickCount: 2 pressure: 1];
      [NSApp postEvent: up atStart: YES];
      [NSApp sendEvent: down];
      check([[[detail valueForKey: @"mode"] titleOfSelectedItem] isEqual: @"Call Tree"],
        @"hang-row double-click enters wall call tree");
      GSPHang *hang = detail.renderer.hangAnalysis.hangs.firstObject;
      check([[detail valueForKey: @"start"] unsignedLongLongValue] == hang.startTime
        && [[detail valueForKey: @"end"] unsignedLongLongValue] == hang.endTime,
        @"hang drill-down narrows the inspection range to the selected hang");
      check(outline.numberOfRows > 0, @"whole-hang wall stack tree");
      capture(hangController, output, @"hang-stacks.png"); [hangController close];
      NSString *source = [NSString stringWithFormat: @"%s:1", __FILE__];
      PDSourceWindowController *viewer = [[PDSourceWindowController alloc] initWithLocation: source];
      check([[[viewer valueForKey: @"source"] string] containsString: @"SPDX-License-Identifier"], @"source viewer loads actual file");
      capture(viewer, output, @"source.png"); [viewer close];
      [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
      printf("All %u investigation GUI checks passed.\n", checks);
    }
  return 0;
}
