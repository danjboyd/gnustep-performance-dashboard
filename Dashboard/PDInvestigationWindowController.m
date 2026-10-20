/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDInvestigationWindowController.h"
#import "PDInspectorView.h"
#import "PDTheme.h"
#include <math.h>

@interface PDInvestigationWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation PDInvestigationWindowController
{
  GSPTrace *_trace, *_baseline;
  GSPProcess *_process;
  BOOL _generations;
  NSTableView *_table;
  NSTextField *_status, *_name, *_markTime, *_observation;
  NSTextField *_beforeStart, *_beforeEnd, *_afterStart, *_afterEnd;
  NSPopUpButton *_choice, *_mode, *_beforeSignpost, *_afterSignpost;
  PDInspectorView *_inspector;
  NSMutableArray *_marks, *_rows;
  NSString *_marksPath;
}

static NSTextField *
field(NSView *view, NSString *value, NSRect rect, BOOL editable)
{
  NSTextField *f = [[NSTextField alloc] initWithFrame: rect];
  [f setStringValue: value]; [f setEditable: editable]; [f setSelectable: YES];
  if (!editable) { [f setBezeled: NO]; [f setDrawsBackground: NO]; }
  [f setFont: [PDTheme smallFont]];
  [f setAutoresizingMask: NSViewMinYMargin]; [view addSubview: f];
  return f;
}

static NSButton *
button(NSView *view, NSString *title, NSRect rect, id target, SEL action)
{
  NSButton *b = [[NSButton alloc] initWithFrame: rect];
  [b setTitle: title]; [b setBezelStyle: NSRoundedBezelStyle];
  [b setTarget: target]; [b setAction: action];
  [b setAutoresizingMask: NSViewMinYMargin]; [view addSubview: b];
  return b;
}

- (NSPopUpButton *) popup: (NSView *)view frame: (NSRect)frame titles: (NSArray *)titles
                   action: (SEL)action
{
  NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame: frame pullsDown: NO];
  [p addItemsWithTitles: titles]; [p setTarget: self]; [p setAction: action];
  [p setAutoresizingMask: NSViewMinYMargin]; [view addSubview: p];
  return p;
}

- (instancetype) initWithTrace: (GSPTrace *)trace process: (GSPProcess *)process
                   generations: (BOOL)generations start: (GSPTime)start end: (GSPTime)end
{
  NSWindow *w = [[NSWindow alloc] initWithContentRect: NSMakeRect(70, 70, 1100, 650)
    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
    backing: NSBackingStoreBuffered defer: NO];
  if ((self = [super initWithWindow: w]))
    {
      _trace = trace; _process = process; _generations = generations;
      _rows = [NSMutableArray array]; _marks = [NSMutableArray array];
      [w setReleasedWhenClosed: NO]; [w setMinSize: NSMakeSize(1000, 500)];
      [w setTitle: generations ? @"Allocation Generations" : @"Compare Recordings"];
      NSView *v = w.contentView;
      if (generations)
        {
          _marksPath = [trace.path stringByAppendingPathComponent:
            [NSString stringWithFormat: @"generations-%d.plist", process.pid]];
          NSArray *saved = [NSArray arrayWithContentsOfFile: _marksPath];
          uint64_t last = 0;
          for (id mark in saved)
            if ([mark isKindOfClass: [NSDictionary class]] && [mark[@"name"] isKindOfClass: [NSString class]]
                && [mark[@"time"] isKindOfClass: [NSNumber class]])
              {
                uint64_t time = [mark[@"time"] unsignedLongLongValue];
                if (time > last && time >= process.startTime && time <= process.endTime)
                  { [_marks addObject: mark]; last = time; }
              }
          field(v, @"Generation name", NSMakeRect(10, 620, 140, 20), NO);
          _name = field(v, @"Generation", NSMakeRect(150, 618, 180, 24), YES);
          field(v, @"End (seconds)", NSMakeRect(340, 620, 110, 20), NO);
          _markTime = field(v, [NSString stringWithFormat: @"%.9f", [trace relativeTime: end ?: process.endTime]],
            NSMakeRect(450, 618, 130, 24), YES);
          button(v, @"Mark Generation", NSMakeRect(590, 615, 160, 28), self, @selector(mark:));
          button(v, @"Mark Now", NSMakeRect(760, 615, 130, 28), self, @selector(markNow:));
          _choice = [self popup: v frame: NSMakeRect(10, 580, 470, 26) titles: @[] action: @selector(refresh:)];
          _mode = [self popup: v frame: NSMakeRect(490, 580, 250, 26)
            titles: @[@"Categories", @"Surviving Stacks", @"Surviving Allocations"] action: @selector(refresh:)];
          field(v, @"Observe survival at (seconds)", NSMakeRect(10, 544, 210, 20), NO);
          _observation = field(v, [NSString stringWithFormat: @"%.9f", [trace relativeTime: process.endTime]],
            NSMakeRect(225, 542, 130, 24), YES);
          button(v, @"Refresh", NSMakeRect(370, 540, 110, 28), self, @selector(refresh:));
          button(v, @"Remove Last Mark", NSMakeRect(490, 540, 170, 28), self, @selector(removeMark:));
          [self rebuildGenerations];
        }
      else
        {
          button(v, @"Choose Baseline…", NSMakeRect(10, 612, 180, 30), self, @selector(chooseBaseline:));
          _choice = [self popup: v frame: NSMakeRect(200, 615, 240, 26)
            titles: @[@"CPU Self Time", @"Allocated Bytes", @"Leaked Bytes", @"Signpost Duration", @"File Bytes", @"Network Bytes", @"CPU Call Paths"] action: @selector(refresh:)];
          button(v, @"Compare", NSMakeRect(450, 612, 110, 30), self, @selector(refresh:));
          field(v, @"Baseline range (seconds)", NSMakeRect(10, 582, 180, 20), NO);
          _beforeStart = field(v, @"0", NSMakeRect(200, 580, 100, 24), YES);
          _beforeEnd = field(v, @"0", NSMakeRect(310, 580, 100, 24), YES);
          _beforeSignpost = [self popup: v frame: NSMakeRect(420, 580, 320, 26)
            titles: @[@"Choose a baseline first"] action: @selector(selectSignpost:)];
          field(v, @"Current range (seconds)", NSMakeRect(10, 546, 180, 20), NO);
          _afterStart = field(v, [NSString stringWithFormat: @"%.9f", start ? [trace relativeTime: start] : 0],
            NSMakeRect(200, 544, 100, 24), YES);
          _afterEnd = field(v, [NSString stringWithFormat: @"%.9f", end ? [trace relativeTime: end] : trace.duration],
            NSMakeRect(310, 544, 100, 24), YES);
          _afterSignpost = [self popup: v frame: NSMakeRect(420, 544, 320, 26)
            titles: @[] action: @selector(selectSignpost:)];
          [self fillSignposts: _afterSignpost trace: trace];
          field(v, @"Target processes only. Values are absolute; unequal workload lengths are not normalized.", NSMakeRect(10, 512, 1000, 20), NO);
        }
      NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(10, 40, 720, 466)];
      [scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
      [scroll setHasVerticalScroller: YES]; [scroll setHasHorizontalScroller: YES];
      [scroll setBorderType: NSBezelBorder];
      _table = [[NSTableView alloc] initWithFrame: scroll.contentView.bounds];
      [_table setDataSource: self]; [_table setDelegate: self];
      [_table setUsesAlternatingRowBackgroundColors: YES];
      [scroll setDocumentView: _table]; [v addSubview: scroll];
      _inspector = [[PDInspectorView alloc] initWithFrame: NSMakeRect(740, 40, 350, 466)];
      [_inspector setAutoresizingMask: NSViewMinXMargin | NSViewHeightSizable]; [v addSubview: _inspector];
      _status = field(v, @"", NSMakeRect(10, 7, 1080, 26), NO);
      [_status setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
      [w setInitialFirstResponder: _generations ? (NSView *)_name : (NSView *)_beforeStart];
      [self refresh: nil];
    }
  return self;
}

- (BOOL) readTime: (NSTextField *)field trace: (GSPTrace *)trace result: (GSPTime *)time
{
  NSScanner *scanner = [NSScanner scannerWithString: field.stringValue];
  double value = 0;
  if (![scanner scanDouble: &value] || !scanner.isAtEnd || !isfinite(value)
      || value < 0 || value > trace.duration + 1e-9)
    { [_status setStringValue: @"Enter a finite time within the recording, in seconds."]; return NO; }
  /* Round the relative offset before adding the integer clock origin;
     adding the origin as a double can lose nanoseconds at range boundaries. */
  *time = value >= trace.duration ? trace.endTime
    : trace.startTime + (GSPTime)roundl((long double)value * 1e9L);
  return YES;
}

- (void) rebuildGenerations
{
  [_choice removeAllItems];
  for (NSDictionary *mark in _marks)
    [_choice addItemWithTitle: [NSString stringWithFormat: @"%@ — through %.6f s", mark[@"name"],
      [_trace relativeTime: [mark[@"time"] unsignedLongLongValue]]]];
  [_choice addItemWithTitle: @"After last mark (through end of recording)"];
  [_choice selectItemAtIndex: _marks.count];
}

- (void) mark: (id)sender
{
  GSPTime time;
  if (![self readTime: _markTime trace: _trace result: &time]) return;
  GSPTime previous = _marks.count ? [[_marks lastObject][@"time"] unsignedLongLongValue] : _process.startTime - 1;
  if (time <= previous || time > _process.endTime || !_name.stringValue.length)
    { [_status setStringValue: @"Marks must increase, fall within this process recording, and have a name."]; return; }
  [_marks addObject: @{ @"name": _name.stringValue, @"time": @(time) }];
  if (![_marks writeToFile: _marksPath atomically: YES])
    { [_marks removeLastObject]; [_status setStringValue: @"Cannot save generation marks to this trace. Save a writable copy first."]; return; }
  [self rebuildGenerations]; [_choice selectItemAtIndex: _marks.count - 1];
  [self refresh: nil];
}

- (void) markNow: (id)sender
{
  /* The owning trace window reloads the live process. Do not consume its
     changedOnLastReload flag here. Use the latest received event time. */
  NSString *time = [NSString stringWithFormat: @"%.9f", [_trace relativeTime: _process.endTime]];
  [_markTime setStringValue: time]; [_observation setStringValue: time];
  [self mark: sender];
}

- (void) removeMark: (id)sender
{
  if (!_marks.count) return;
  id last = _marks.lastObject;
  [_marks removeLastObject];
  if (![_marks writeToFile: _marksPath atomically: YES])
    { [_marks addObject: last]; [_status setStringValue: @"Cannot save generation marks."]; return; }
  [self rebuildGenerations]; [self refresh: nil];
}

- (void) columns: (NSArray *)names
{
  for (NSTableColumn *column in [_table.tableColumns copy]) [_table removeTableColumn: column];
  for (NSUInteger i = 0; i < names.count; i++)
    {
      NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier: @(i)];
      [c.headerCell setStringValue: names[i]]; [c setEditable: NO];
      [c setWidth: i == 0 ? (_generations ? 340 : 260) : (_generations ? 120 : 100)]; [_table addTableColumn: c];
    }
}

- (void) refresh: (id)sender
{
  [_rows removeAllObjects]; [_inspector clear]; [_table reloadData];
  if (_generations) [self showGeneration]; else [self compare];
  [_table reloadData];
}

- (void) showGeneration
{
  [self columns: @[@"Category / Stack / Address", @"Surviving Bytes", @"Surviving Count", @"Allocated Bytes"]];
  NSUInteger index = _choice.indexOfSelectedItem;
  GSPTime start = index ? [_marks[index - 1][@"time"] unsignedLongLongValue] + 1 : _process.startTime;
  GSPTime end = index < _marks.count ? [_marks[index][@"time"] unsignedLongLongValue] : _process.endTime;
  GSPTime observed;
  if (![self readTime: _observation trace: _trace result: &observed]) return;
  if (observed < end) { [_status setStringValue: @"Survival checkpoint must be at or after the generation end."]; return; }
  if (start > end) { [_status setStringValue: @"There are no allocations after the last mark."]; return; }
  GSPAllocationAnalysis *analysis = [[GSPAllocationAnalysis alloc] initWithProcess: _process];
  if (_mode.indexOfSelectedItem == 0)
    for (GSPAllocationCategory *c in [analysis categoriesFrom: start to: end survivingAt: observed])
      [_rows addObject: @{ @"cells": @[c.name, [GSPAllocationAnalysis formatBytes: c.persistentBytes],
        @(c.persistentCount).stringValue, [GSPAllocationAnalysis formatBytes: c.totalBytes]],
        @"detail": @"Surviving means still allocated at the observation checkpoint. It does not mean leaked. Select Surviving Stacks or Surviving Allocations to inspect allocation sites." }];
  else if (_mode.indexOfSelectedItem == 1)
    {
      GSPCallTree *tree = [analysis callTreeFrom: start to: end survivingAt: observed
        persistentOnly: YES options: GSPCallTreeInvert];
      for (GSPCallTreeNode *node in tree.root.children)
        [_rows addObject: @{ @"cells": @[node.name, [GSPAllocationAnalysis formatBytes: node.totalWeight],
          @(node.sampleCount).stringValue, @""], @"stack": @(node.heaviestStack),
          @"detail": @"Surviving allocations grouped by leaf function. The inspector shows a representative allocation stack." }];
    }
  else
    {
      NSIndexSet *records = [analysis recordsInCategory: UINT32_MAX from: start to: end
        survivingAt: observed persistentOnly: YES];
      [records enumerateIndexesUsingBlock: ^(NSUInteger i, BOOL *stop) {
        if (_rows.count >= 50000) { *stop = YES; return; }
        const GSPAllocationRecord *r = &analysis.records[i];
        [_rows addObject: @{ @"cells": @[[NSString stringWithFormat: @"0x%llx %@", (unsigned long long)r->address, analysis.categoryNames[r->category]],
          [GSPAllocationAnalysis formatBytes: r->size], @"1", @""], @"stack": @(r->stack),
          @"detail": [NSString stringWithFormat: @"Allocated at %.6f s. Alive at %.6f s. %@",
            [_trace relativeTime: r->allocTime], [_trace relativeTime: observed],
            r->freeTime ? [NSString stringWithFormat: @"Freed at %.6f s.", [_trace relativeTime: r->freeTime]] : @"Not freed in this recording."] }];
      }];
    }
  [_status setStringValue: [NSString stringWithFormat: @"Created %.6f–%.6f s; observed %.6f s. %@",
    [_trace relativeTime: start], [_trace relativeTime: end], [_trace relativeTime: observed],
    _rows.count >= 50000 ? @"First 50,000 allocations shown." : @"Marks are saved in the trace bundle."]];
}

- (void) fillSignposts: (NSPopUpButton *)popup trace: (GSPTrace *)trace
{
  [popup removeAllItems]; [popup addItemWithTitle: @"Manual range / choose signpost"];
  for (GSPSignpost *s in trace.targetProcess.signposts)
    if (!s.isEvent && !s.isOpen)
      {
        [popup addItemWithTitle: [NSString stringWithFormat: @"%@ / %@ / %@ at %.6f s", s.subsystem, s.category, s.name, [trace relativeTime: s.beginTime]]];
        [popup.lastItem setRepresentedObject: s];
      }
}

- (void) selectSignpost: (NSPopUpButton *)sender
{
  GSPSignpost *s = sender.selectedItem.representedObject;
  if (!s) return;
  BOOL before = sender == _beforeSignpost;
  GSPTrace *trace = before ? _baseline : _trace;
  [(before ? _beforeStart : _afterStart) setStringValue: [NSString stringWithFormat: @"%.9f", [trace relativeTime: s.beginTime]]];
  [(before ? _beforeEnd : _afterEnd) setStringValue: [NSString stringWithFormat: @"%.9f", [trace relativeTime: s.endTime]]];
  [self refresh: nil];
}

- (void) chooseBaseline: (id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setTitle: @"Choose baseline trace"]; [panel setCanChooseDirectories: YES]; [panel setCanChooseFiles: YES];
  if ([panel runModal] != NSOKButton) return;
  NSError *error = nil;
  GSPTrace *baseline = [GSPTrace traceWithPath: panel.URL.path error: &error];
  if (!baseline) { [_status setStringValue: error.localizedDescription]; return; }
  _baseline = baseline;
  [_beforeStart setStringValue: @"0"];
  [_beforeEnd setStringValue: [NSString stringWithFormat: @"%.9f", baseline.duration]];
  [self fillSignposts: _beforeSignpost trace: baseline];
  [self.window setTitle: [NSString stringWithFormat: @"Compare %@ → %@", baseline.path.lastPathComponent, _trace.path.lastPathComponent]];
  [self refresh: nil];
}

- (void) compare
{
  [self columns: @[@"Function / Category / Call Path", @"Before", @"After", @"Delta", @"Change"]];
  if (!_baseline) { [_status setStringValue: @"Choose a baseline recording. Current values come from this trace’s target process."]; return; }
  GSPTime bs, be, as, ae;
  if (![self readTime: _beforeStart trace: _baseline result: &bs]
      || ![self readTime: _beforeEnd trace: _baseline result: &be]
      || ![self readTime: _afterStart trace: _trace result: &as]
      || ![self readTime: _afterEnd trace: _trace result: &ae]) return;
  if (bs > be || as > ae) { [_status setStringValue: @"Range start must not exceed range end."]; return; }
  GSPComparisonKind kind = (GSPComparisonKind)_choice.indexOfSelectedItem;
  if (kind == GSPCompareLeaks && (_baseline.targetProcess.leakScanUnavailable || _trace.targetProcess.leakScanUnavailable))
    { [_status setStringValue: @"Leak comparison unavailable: a recording reports failed memory reads."]; return; }
  NSArray *required = @[GSPInstrumentTimeProfiler, GSPInstrumentAllocations, GSPInstrumentLeaks,
    GSPInstrumentPointsOfInterest, GSPInstrumentFileActivity, GSPInstrumentNetwork, GSPInstrumentTimeProfiler];
  NSString *instrument = required[kind];
  for (GSPTrace *trace in @[_baseline, _trace])
    if (![trace.instrumentIdentifiers containsObject: instrument]
        && !([instrument isEqual: GSPInstrumentTimeProfiler] && [trace.instrumentIdentifiers containsObject: GSPInstrumentSystemProfiler]))
      { [_status setStringValue: @"Both recordings must include the selected instrument; missing data is not zero."]; return; }
  if (kind == GSPCompareLeaks)
    {
      for (NSUInteger i = 0; i < 2; i++)
        {
          GSPProcess *process = i ? _trace.targetProcess : _baseline.targetProcess;
          GSPTime limit = i ? ae : be;
          BOOL available = NO;
          for (GSPLeakSnapshot *snapshot in process.leakSnapshots)
            if (snapshot.time <= limit) available = YES;
          if (!available)
            { [_status setStringValue: @"No leak snapshot exists at or before one of the selected range ends."]; return; }
        }
    }
  BOOL seconds = [GSPComparison kindIsTime: kind];
  for (GSPComparisonRow *r in [GSPComparison compare: _baseline start: bs end: be with: _trace start: as end: ae kind: kind])
    {
      NSString *(^value)(double) = ^NSString *(double x) {
        return [NSString stringWithFormat: seconds ? @"%.6f s" : @"%.0f B", x];
      };
      [_rows addObject: @{ @"cells": @[r.name, value(r.before), value(r.after), value(r.delta),
        isnan(r.percentChange) ? @"New" : [NSString stringWithFormat: @"%+.1f%%", r.percentChange]],
        @"detail": [NSString stringWithFormat: @"%@\nBefore: %@\nAfter: %@\nDelta: %@\n%@", r.name, value(r.before), value(r.after), value(r.delta),
          kind == GSPCompareCPUCallPaths ? @"Call path values are inclusive; do not sum parent and child rows." : @"Absolute values; match equivalent workloads before interpreting changes."] }];
    }
  NSArray *warnings = [[_baseline qualityWarningsIncludingIncomplete: YES]
    arrayByAddingObjectsFromArray: [_trace qualityWarningsIncludingIncomplete: YES]];
  [_status setStringValue: warnings.count ? [NSString stringWithFormat: @"Recording quality: %@", [warnings componentsJoinedByString: @"; "]]
    : [NSString stringWithFormat: @"%lu changed rows. %@", (unsigned long)_rows.count,
      kind == GSPCompareLeaks ? @"Leaks use the latest snapshot at or before each range end." : @"Positive deltas mean growth; sampling differences may be noise."]];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)table { return _rows.count; }
- (id) tableView: (NSTableView *)table objectValueForTableColumn: (NSTableColumn *)column row: (NSInteger)row
{ return _rows[row][@"cells"][[column.identifier unsignedIntegerValue]]; }
- (void) tableViewSelectionDidChange: (NSNotification *)note
{
  NSInteger row = _table.selectedRow;
  if (row < 0 || row >= (NSInteger)_rows.count) { [_inspector clear]; return; }
  NSDictionary *r = _rows[row];
  [_inspector showTitle: @"Extended Detail" text: r[@"detail"] stack: [r[@"stack"] unsignedIntValue] process: _process];
}
@end
