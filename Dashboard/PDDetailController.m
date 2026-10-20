/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDDetailController.h"
#import "PDTrackRenderer.h"
#import "PDInspectorView.h"
#import "PDTheme.h"

#include <GSPerformance/gsp_format.h>
#include <GSPerformance/gsp_signpost.h>
#include <string.h>

/* Right-clicking selects the row under the pointer, so the context menu
   acts on it (GNUstep does not set the clicked row for menu events).  */
@interface PDOutlineView : NSOutlineView
@end

@implementation PDOutlineView
- (NSMenu *) menuForEvent: (NSEvent *)event
{
  NSInteger row = [self rowAtPoint: [self convertPoint: [event locationInWindow]
                                              fromView: nil]];
  if (row >= 0)
    [self selectRowIndexes: [NSIndexSet indexSetWithIndex: (NSUInteger)row]
      byExtendingSelection: NO];
  return [super menuForEvent: event];
}
@end

/* A row in list-style modes. */
@interface PDRow : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;  /* column id -> string */
@property (nonatomic, strong) NSMutableDictionary *sortKeys; /* column id -> NSNumber/NSString */
@property (nonatomic, strong) id payload;
@property (nonatomic) uint32_t stack;
@property (nonatomic) GSPTime start, end;
@property (nonatomic, copy) NSString *detail;
@end

@implementation PDRow
- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _values = [NSMutableDictionary dictionary];
      _sortKeys = [NSMutableDictionary dictionary];
    }
  return self;
}
- (void) set: (NSString *)col text: (NSString *)text sort: (id)key
{
  [_values setObject: text ?: @"" forKey: col];
  [_sortKeys setObject: key ?: (id)(text ?: @"") forKey: col];
}
@end

@interface PDDetailController () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

/* The frame Apple Instruments calls "responsible": the first one outside system
   libraries, or the leaf if all are system frames.  */
static NSString *
responsible_frame(GSPProcess *p, uint32_t stack)
{
  NSArray *syms = [p.symbolicator symbolsForStack: stack];
  for (GSPSymbol *s in syms)
    if (!s.isSystem)
      return s.name;
  return [syms count] ? [[syms objectAtIndex: 0] name] : @"";
}

@implementation PDDetailController
{
  NSView *_view;
  PDInspectorView *_inspector;
  NSPopUpButton *_mode;
  NSPopUpButton *_threads;
  NSButton *_separate, *_invert, *_hideSystem, *_flatten, *_top, *_hideKnown;
  NSSearchField *_search;
  NSTextField *_status;
  NSOutlineView *_outline;
  NSScrollView *_scroll;

  NSString *_instrument;
  GSPTime _start, _end;
  NSString *_currentMode;
  NSArray *_columns;            /* arrays: id, title, width */

  /* call tree mode */
  GSPCallTree *_tree;
  double _weightScale;          /* weight units -> seconds or bytes */
  BOOL _weightIsBytes;
  NSMapTable *_filtered;        /* node -> filtered children */
  NSString *_filterText;
  NSMutableSet *_charged, *_pruned;   /* data mining */
  NSString *_focus;

  /* list modes */
  NSMutableArray *_rows;
  uint32_t _allocCategory;      /* category drill-down for the list */
  NSString *_sortColumn;
  BOOL _sortAscending;
}

- (NSView *) view { return _view; }
- (NSString *) instrument { return _instrument; }

static NSButton *
check_box(NSString *title, NSRect frame, id target, SEL action)
{
  NSButton *b = [[NSButton alloc] initWithFrame: frame];
  [b setButtonType: NSSwitchButton];
  [b setTitle: title];
  [b setFont: [PDTheme smallFont]];
  [b setTarget: target];
  [b setAction: action];
  [b sizeToFit];
  return b;
}

- (instancetype) initWithFrame: (NSRect)frame inspector: (PDInspectorView *)inspector
{
  if ((self = [super init]) == nil)
    return nil;
  _inspector = inspector;
  _view = [[NSView alloc] initWithFrame: frame];
  [_view setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  CGFloat w = frame.size.width, h = frame.size.height;
  CGFloat barY = h - 30;      /* first row: mode, thread, search */
  CGFloat optY = h - 54;      /* second row: call tree options */

  _mode = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(6, barY + 2, 170, 24) pullsDown: NO];
  [_mode setTarget: self];
  [_mode setAction: @selector(modeChanged:)];
  [_mode setAutoresizingMask: NSViewMinYMargin];
  [_view addSubview: _mode];

  _threads = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(182, barY + 2, 200, 24) pullsDown: NO];
  [_threads setTarget: self];
  [_threads setAction: @selector(optionsChanged:)];
  [_threads setAutoresizingMask: NSViewMinYMargin];
  [_view addSubview: _threads];

  CGFloat x = 8;
  _separate = check_box(@"Separate by Thread", NSMakeRect(x, optY, 10, 20), self, @selector(optionsChanged:));
  _invert = check_box(@"Invert Call Tree", NSMakeRect(x, optY, 10, 20), self, @selector(optionsChanged:));
  _hideSystem = check_box(@"Hide System Libraries", NSMakeRect(x, optY, 10, 20), self, @selector(optionsChanged:));
  _flatten = check_box(@"Flatten Recursion", NSMakeRect(x, optY, 10, 20), self, @selector(optionsChanged:));
  _top = check_box(@"Top Functions", NSMakeRect(x, optY, 10, 20), self, @selector(optionsChanged:));
  for (NSButton *b in [NSArray arrayWithObjects: _separate, _invert, _hideSystem, _flatten, _top, nil])
    {
      NSRect f = [b frame];
      f.origin.x = x;
      f.origin.y = optY;
      [b setFrame: f];
      [b setAutoresizingMask: NSViewMinYMargin];
      [_view addSubview: b];
      x += f.size.width + 14;
    }
  /* Leaks only; placed by -layoutBar.  */
  _hideKnown = check_box(@"Hide Known GNUstep Leaks", NSMakeRect(8, optY, 10, 20), self,
                         @selector(optionsChanged:));
  [_hideKnown setAutoresizingMask: NSViewMinYMargin];
  [_view addSubview: _hideKnown];

  _search = [[NSSearchField alloc] initWithFrame: NSMakeRect(w - 226, barY + 3, 220, 22)];
  [_search setTarget: self];
  [_search setAction: @selector(searchChanged:)];
  [_search setAutoresizingMask: NSViewMinXMargin | NSViewMinYMargin];
  [[_search cell] setPlaceholderString: @"Filter symbols"];
  [_view addSubview: _search];

  _status = [[NSTextField alloc] initWithFrame: NSMakeRect(6, 2, w - 12, 18)];
  [_status setEditable: NO];
  [_status setBezeled: NO];
  [_status setDrawsBackground: NO];
  [_status setFont: [PDTheme smallFont]];
  [_status setTextColor: [PDTheme secondaryTextColor]];
  [_status setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
  [_view addSubview: _status];

  _scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(0, 22, w, h - 80)];
  [_scroll setHasVerticalScroller: YES];
  [_scroll setHasHorizontalScroller: YES];
  [_scroll setBorderType: NSBezelBorder];
  [_scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _outline = [[PDOutlineView alloc] initWithFrame: [[_scroll contentView] bounds]];
  [_outline setDataSource: self];
  [_outline setDelegate: self];
  [_outline setUsesAlternatingRowBackgroundColors: YES];
  [_outline setAllowsColumnReordering: NO];
  [_outline setAutoresizesOutlineColumn: NO];
  [_outline setTarget: self];
  [_outline setDoubleAction: @selector(rowDoubleClicked:)];
  [_scroll setDocumentView: _outline];
  [_view addSubview: _scroll];

  _rows = [NSMutableArray array];
  _filtered = [NSMapTable mapTableWithKeyOptions: NSPointerFunctionsObjectPointerPersonality
                                    valueOptions: NSPointerFunctionsStrongMemory];
  _allocCategory = UINT32_MAX;
  _charged = [NSMutableSet set];
  _pruned = [NSMutableSet set];
  [_outline setMenu: [self dataMiningMenu]];
  return self;
}

/* ------------------------------------------------------------------ */
/* data mining (call tree context menu)                                */

- (NSMenu *) dataMiningMenu
{
  NSMenu *m = [[NSMenu alloc] initWithTitle: @"Data Mining"];
  [[m addItemWithTitle: @"Charge Symbol to Caller" action: @selector(chargeToCaller:)
         keyEquivalent: @""] setTarget: self];
  [[m addItemWithTitle: @"Prune Symbol and Subtree" action: @selector(pruneSymbol:)
         keyEquivalent: @""] setTarget: self];
  [[m addItemWithTitle: @"Focus on Symbol" action: @selector(focusSymbol:)
         keyEquivalent: @""] setTarget: self];
  [[m addItemWithTitle: @"Restore All" action: @selector(restoreDataMining:)
         keyEquivalent: @""] setTarget: self];
  return m;
}

- (GSPCallTreeNode *) clickedNode
{
  NSInteger row = [_outline selectedRow];
  id item = row >= 0 ? [_outline itemAtRow: row] : nil;
  return [item isKindOfClass: [GSPCallTreeNode class]] && ![item isThread] ? item : nil;
}

- (void) applyDataMining
{
  _tree.chargedToCaller = _charged;
  _tree.pruned = _pruned;
  _tree.focusSymbol = _focus;
  [_tree rebuild];
  [self applyFilter];
  [_outline reloadData];
  [self expandHeaviest];
  NSMutableArray *notes = [NSMutableArray array];
  if ([_charged count])
    [notes addObject: [NSString stringWithFormat: @"%lu charged to caller", (unsigned long)[_charged count]]];
  if ([_pruned count])
    [notes addObject: [NSString stringWithFormat: @"%lu pruned", (unsigned long)[_pruned count]]];
  if (_focus)
    [notes addObject: [NSString stringWithFormat: @"focused on %@", _focus]];
  if ([notes count])
    [_status setStringValue: [NSString stringWithFormat: @"Data mining: %@ (right-click, Restore All)",
                              [notes componentsJoinedByString: @", "]]];
}

- (void) chargeToCaller: (id)sender
{
  GSPCallTreeNode *n = [self clickedNode];
  if (n == nil || ![self isCallTreeMode])
    return;
  [_charged addObject: n.name];
  [self applyDataMining];
}

- (void) pruneSymbol: (id)sender
{
  GSPCallTreeNode *n = [self clickedNode];
  if (n == nil || ![self isCallTreeMode])
    return;
  [_pruned addObject: n.name];
  [self applyDataMining];
}

- (void) focusSymbol: (id)sender
{
  GSPCallTreeNode *n = [self clickedNode];
  if (n == nil || ![self isCallTreeMode])
    return;
  _focus = [n.name copy];
  [self applyDataMining];
}

- (void) restoreDataMining: (id)sender
{
  [_charged removeAllObjects];
  [_pruned removeAllObjects];
  _focus = nil;
  if ([self isCallTreeMode])
    [self reload];
}

/* ------------------------------------------------------------------ */
/* configuration                                                       */

- (NSArray *) modesFor: (NSString *)ident
{
  if ([ident isEqual: GSPInstrumentTimeProfiler] || [ident isEqual: GSPInstrumentSystemProfiler])
    return [NSArray arrayWithObjects: @"Call Tree", @"Threads", nil];
  if ([ident isEqual: GSPInstrumentHangs])
    return [NSArray arrayWithObjects: @"Hangs", @"Call Tree", nil];
  if ([ident isEqual: GSPInstrumentPointsOfInterest])
    return [NSArray arrayWithObjects: @"Summary", @"Intervals", nil];
  if ([ident isEqual: GSPInstrumentLogging])
    return [NSArray arrayWithObjects: @"Messages", nil];
  if ([ident isEqual: GSPInstrumentAllocations])
    return [NSArray arrayWithObjects: @"Statistics", @"Allocations List", @"Call Tree", nil];
  if ([ident isEqual: GSPInstrumentLeaks])
    return [NSArray arrayWithObjects: @"Leaks", @"Call Tree", @"Leak Checks", nil];
  if ([ident isEqual: GSPInstrumentZombies])
    return [NSArray arrayWithObjects: @"Zombies", nil];
  if ([ident isEqual: GSPInstrumentFileActivity])
    return [NSArray arrayWithObjects: @"Files", @"Events", @"Call Tree", nil];
  if ([ident isEqual: GSPInstrumentNetwork])
    return [NSArray arrayWithObjects: @"Connections", @"Events", @"Call Tree", nil];
  return [NSArray arrayWithObject: @"Details"];
}

- (void) showInstrument: (NSString *)identifier
{
  _instrument = [identifier copy];
  [_mode removeAllItems];
  [_mode addItemsWithTitles: [self modesFor: identifier]];
  [_mode selectItemAtIndex: 0];
  _currentMode = [_mode titleOfSelectedItem];
  _allocCategory = UINT32_MAX;
  _sortColumn = nil;
  [self rebuildThreadMenu];
  [self reload];
}

- (void) rebuildThreadMenu
{
  NSInteger tag = [[_threads selectedItem] tag];
  [_threads removeAllItems];
  [_threads addItemWithTitle: @"All Threads"];
  [[_threads lastItem] setTag: 0];
  for (GSPThreadInfo *t in [_renderer.process sortedThreads])
    {
      [_threads addItemWithTitle: t.displayName];
      [[_threads lastItem] setTag: (NSInteger)t.tid];
    }
  NSInteger idx = [_threads indexOfItemWithTag: tag];
  [_threads selectItemAtIndex: idx >= 0 ? idx : 0];
}

- (void) showThread: (uint32_t)tid
{
  NSInteger idx = [_threads indexOfItemWithTag: (NSInteger)tid];
  [_threads selectItemAtIndex: idx >= 0 ? idx : 0];
  if (![_currentMode isEqual: @"Call Tree"])
    {
      [_mode selectItemWithTitle: @"Call Tree"];
      _currentMode = @"Call Tree";
    }
  [self reload];
}

- (void) setRangeStart: (GSPTime)start end: (GSPTime)end
{
  _start = start;
  _end = end;
  [self reload];
}

- (BOOL) isCallTreeMode
{
  return [_currentMode isEqual: @"Call Tree"];
}

- (void) layoutBar
{
  BOOL tree = [self isCallTreeMode];
  BOOL cpu = [_instrument isEqual: GSPInstrumentTimeProfiler]
    || [_instrument isEqual: GSPInstrumentSystemProfiler];
  [_threads setHidden: !(cpu && tree)];
  for (NSButton *b in [NSArray arrayWithObjects: _separate, _invert, _hideSystem, _flatten, _top, nil])
    [b setHidden: !tree];
  [_separate setHidden: !(tree && cpu)];
  [_search setHidden: !tree];
  /* after the call tree options, or alone in the Leaks list */
  BOOL leaks = [_instrument isEqual: GSPInstrumentLeaks]
    && (tree || [_currentMode isEqual: @"Leaks"]);
  NSRect hf = [_hideKnown frame];
  hf.origin.x = tree ? NSMaxX([_top frame]) + 14 : 8;
  [_hideKnown setFrame: hf];
  [_hideKnown setHidden: !leaks];
  NSRect vb = [_view bounds];
  CGFloat reserved = (tree || leaks) ? 58 : 34;   /* bar rows above the table */
  [_scroll setFrame: NSMakeRect(0, 22, vb.size.width, vb.size.height - 22 - reserved)];
}

- (void) modeChanged: (id)sender
{
  _currentMode = [_mode titleOfSelectedItem];
  _sortColumn = nil;
  [self reload];
}

- (void) optionsChanged: (id)sender
{
  if (sender == _top && PDIsOn(_top))
    [_invert setState: NSOffState];
  if (sender == _invert && PDIsOn(_invert))
    [_top setState: NSOffState];
  [self reload];
}

- (void) searchChanged: (id)sender
{
  _filterText = [[_search stringValue] length] ? [[_search stringValue] copy] : nil;
  [self applyFilter];
  [_outline reloadData];
  [self expandHeaviest];
}

/* ------------------------------------------------------------------ */
/* columns                                                             */

- (void) setColumns: (NSArray *)cols outline: (NSString *)outlineColumn
{
  for (NSTableColumn *c in [[_outline tableColumns] copy])
    [_outline removeTableColumn: c];
  for (NSArray *spec in cols)
    {
      NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier: [spec objectAtIndex: 0]];
      [[c headerCell] setStringValue: [spec objectAtIndex: 1]];
      [c setWidth: [[spec objectAtIndex: 2] floatValue]];
      [c setMinWidth: 40];
      [c setEditable: NO];
      [c setResizingMask: NSTableColumnUserResizingMask];
      [_outline addTableColumn: c];
      if ([[spec objectAtIndex: 0] isEqual: outlineColumn])
        [_outline setOutlineTableColumn: c];
    }
  if (outlineColumn == nil && [[_outline tableColumns] count])
    [_outline setOutlineTableColumn: [[_outline tableColumns] objectAtIndex: 0]];
  _columns = cols;
}

static NSArray *
col(NSString *ident, NSString *title, CGFloat width)
{
  return [NSArray arrayWithObjects: ident, title, [NSNumber numberWithFloat: width], nil];
}

/* ------------------------------------------------------------------ */
/* building content                                                    */

- (NSSet *) selectedThreads
{
  NSInteger tid = [[_threads selectedItem] tag];
  return tid ? [NSSet setWithObject: [NSNumber numberWithUnsignedInt: (uint32_t)tid]] : nil;
}

- (GSPCallTreeOptions) treeOptions
{
  GSPCallTreeOptions o = 0;
  if (PDIsOn(_separate) && ![_separate isHidden])
    o |= GSPCallTreeSeparateByThread;
  if (PDIsOn(_invert))
    o |= GSPCallTreeInvert;
  if (PDIsOn(_hideSystem))
    o |= GSPCallTreeHideSystemLibraries;
  if (PDIsOn(_flatten))
    o |= GSPCallTreeFlattenRecursion;
  if (PDIsOn(_top))
    o |= GSPCallTreeTopFunctions;
  return o;
}

- (void) buildCallTree
{
  GSPProcess *p = _renderer.process;
  /* Symbol first: GNUstep draws disclosure triangles in column 0
     whatever the outline column is.  */
  [self setColumns: [NSArray arrayWithObjects:
    col(@"symbol", @"Symbol Name", 460),
    col(@"weight", _weightIsBytes ? @"Bytes" : @"Weight", 150),
    col(@"self", _weightIsBytes ? @"Self Bytes" : @"Self Weight", 150),
    col(@"library", @"Library", 170), nil] outline: @"symbol"];

  BOOL ioTree = [_instrument isEqual: GSPInstrumentFileActivity]
    || [_instrument isEqual: GSPInstrumentNetwork];
  if (ioTree)
    {
      _weightIsBytes = NO;
      _tree = [_renderer.ioAnalysis callTreeForNetwork:
                 [_instrument isEqual: GSPInstrumentNetwork]
                                                  from: _start to: _end
                                               options: [self treeOptions]];
    }
  else if ([_instrument isEqual: GSPInstrumentHangs])
    {
      _weightIsBytes = NO;
      GSPHang *range = [GSPHang new];
      range.startTime = _start ?: p.startTime;
      range.endTime = _end ?: p.endTime;
      _tree = [_renderer.hangAnalysis wallTreeForHang: range options: [self treeOptions]];
    }
  else if ([_instrument isEqual: GSPInstrumentAllocations])
    {
      _weightIsBytes = YES;
      _tree = [_renderer.allocationAnalysis callTreeFrom: _start to: _end
                                          persistentOnly: NO options: [self treeOptions]];
    }
  else if ([_instrument isEqual: GSPInstrumentLeaks])
    {
      _weightIsBytes = YES;
      _renderer.leakAnalysis.hidesKnownLeaks = PDIsOn(_hideKnown);
      _tree = [_renderer.leakAnalysis callTreeForSnapshot: nil options: [self treeOptions]];
    }
  else
    {
      _weightIsBytes = NO;
      _tree = [GSPCallTree cpuTreeForProcess: p start: _start end: _end
                                     threads: [self selectedThreads]
                                     options: [self treeOptions]];
    }
  [[[_outline tableColumnWithIdentifier: @"weight"] headerCell]
    setStringValue: _weightIsBytes ? @"Bytes" : @"Weight"];
  [[[_outline tableColumnWithIdentifier: @"self"] headerCell]
    setStringValue: _weightIsBytes ? @"Self Bytes" : @"Self Weight"];
  _weightScale = _weightIsBytes ? 1
    : (ioTree ? 1e-9 : (p.sampleIntervalMicroseconds ?: 1000) / 1e6);
  if ([_instrument isEqual: GSPInstrumentHangs])
    _weightScale = (p.wallIntervalMicroseconds ?: 10000) / 1e6;
  if ([_charged count] || [_pruned count] || _focus)
    {
      _tree.chargedToCaller = _charged;
      _tree.pruned = _pruned;
      _tree.focusSymbol = _focus;
      [_tree rebuild];
    }
  [self applyFilter];
  [_status setStringValue: _weightIsBytes
    ? [NSString stringWithFormat: @"%@ in %llu allocations",
       [GSPAllocationAnalysis formatBytes: _tree.totalWeight],
       (unsigned long long)_tree.root.sampleCount]
    : [NSString stringWithFormat: ioTree ? @"%@ spent in %llu calls" : @"%@ of CPU time in %llu samples",
       GSPFormatDuration(_tree.totalWeight * _weightScale),
       (unsigned long long)_tree.root.sampleCount]];
  if ([_instrument isEqual: GSPInstrumentHangs])
    [_status setStringValue: @"Wall-sampled stacks in the inspection range; weights estimate observed time, not CPU time or scheduler state."];
}

- (BOOL) filterNode: (GSPCallTreeNode *)node
{
  BOOL selfMatch = [node.name rangeOfString: _filterText options: NSCaseInsensitiveSearch].location
    != NSNotFound;
  NSMutableArray *kids = [NSMutableArray array];
  for (GSPCallTreeNode *c in node.children)
    if ([self filterNode: c])
      [kids addObject: c];
  if (selfMatch)
    {
      [_filtered setObject: node.children forKey: node];
      return YES;
    }
  [_filtered setObject: kids forKey: node];
  return [kids count] > 0;
}

- (void) applyFilter
{
  [_filtered removeAllObjects];
  if (_filterText != nil && _tree != nil)
    [self filterNode: _tree.root];
}

- (NSArray *) childrenOf: (GSPCallTreeNode *)node
{
  if (_filterText != nil)
    {
      NSArray *f = [_filtered objectForKey: node];
      return f ? f : [NSArray array];
    }
  return node.children;
}

- (void) expandHeaviest
{
  if (![self isCallTreeMode] || _tree == nil)
    return;
  GSPCallTreeNode *n = _tree.root;
  for (int depth = 0; depth < 24; depth++)
    {
      NSArray *kids = [self childrenOf: n];
      if ([kids count] == 0)
        break;
      GSPCallTreeNode *c = [kids objectAtIndex: 0];
      [_outline expandItem: c];
      /* stop where weight splits significantly */
      if (_tree.totalWeight && c.totalWeight * 10 < _tree.totalWeight)
        break;
      n = c;
    }
}

- (NSString *) formatWeight: (uint64_t)w total: (uint64_t)total
{
  double pct = total ? 100.0 * w / total : 0;
  if (_weightIsBytes)
    return [NSString stringWithFormat: @"%@  %5.1f%%",
            [GSPAllocationAnalysis formatBytes: w], pct];
  return [NSString stringWithFormat: @"%@  %5.1f%%", GSPFormatDuration(w * _weightScale), pct];
}

- (void) buildThreads
{
  GSPProcess *p = _renderer.process;
  NSMutableDictionary *cpu = [NSMutableDictionary dictionary];
  double interval = (p.sampleIntervalMicroseconds ?: 1000) / 1e6;

  [self setColumns: [NSArray arrayWithObjects: col(@"thread", @"Thread", 260),
    col(@"cpu", @"CPU Time", 120), col(@"samples", @"Samples", 90),
    col(@"start", @"Started", 110), col(@"end", @"Ended", 110), nil] outline: nil];
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    {
      const GSPSample *s = &p.samples[i];
      if (s->kind == GSP_SAMPLE_WALL || (_end && (s->time < _start || s->time > _end)))
        continue;
      NSNumber *k = [NSNumber numberWithUnsignedInt: s->tid];
      [cpu setObject: [NSNumber numberWithUnsignedLongLong:
        [[cpu objectForKey: k] unsignedLongLongValue] + s->weight] forKey: k];
    }
  for (GSPThreadInfo *t in [p sortedThreads])
    {
      PDRow *r = [PDRow new];
      uint64_t w = [[cpu objectForKey: [NSNumber numberWithUnsignedInt: t.tid]] unsignedLongLongValue];
      [r set: @"thread" text: t.displayName sort: nil];
      [r set: @"cpu" text: GSPFormatDuration(w * interval) sort: [NSNumber numberWithUnsignedLongLong: w]];
      [r set: @"samples" text: [NSString stringWithFormat: @"%llu", (unsigned long long)w]
        sort: [NSNumber numberWithUnsignedLongLong: w]];
      [r set: @"start" text: [NSString stringWithFormat: @"%.3f s", [_renderer.trace relativeTime: t.startTime]]
        sort: [NSNumber numberWithUnsignedLongLong: t.startTime]];
      [r set: @"end" text: t.endTime ? [NSString stringWithFormat: @"%.3f s",
                                        [_renderer.trace relativeTime: t.endTime]] : @"—"
        sort: [NSNumber numberWithUnsignedLongLong: t.endTime]];
      [_rows addObject: r];
    }
}

- (void) buildHangs
{
  GSPHangAnalysis *h = _renderer.hangAnalysis;
  [self setColumns: [NSArray arrayWithObjects: col(@"start", @"Start", 110),
    col(@"duration", @"Duration", 95), col(@"severity", @"Type", 100),
    col(@"cpu", @"CPU Estimate", 110), col(@"io", @"I/O Calls", 75),
    col(@"stack", @"Main Thread Was In", 300), nil] outline: nil];
  for (GSPHang *hang in h.hangs)
    {
      if (_end && (hang.endTime < _start || hang.startTime > _end))
        continue;
      PDRow *r = [PDRow new];
      GSPProcess *p = _renderer.process;
      NSString *where = responsible_frame(p, hang.representativeStack);
      [r set: @"start" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: hang.startTime]]
        sort: [NSNumber numberWithUnsignedLongLong: hang.startTime]];
      [r set: @"duration" text: GSPFormatDuration(hang.duration)
        sort: [NSNumber numberWithDouble: hang.duration]];
      [r set: @"severity" text: hang.severityName sort: [NSNumber numberWithInteger: hang.severity]];
      [r set: @"stack" text: where sort: nil];
      r.stack = hang.representativeStack;
      r.start = hang.startTime;
      r.end = hang.endTime;
      r.payload = hang;
      r.detail = [NSString stringWithFormat: @"%@ lasting %@ (%lu main-thread samples).\nThe stack below is the one the main thread was in most often.",
        hang.severityName, GSPFormatDuration(hang.duration), (unsigned long)hang.sampleCount];
      NSDictionary *evidence = [h evidenceForHang: hang];
      NSIndexSet *indices = evidence[@"ioIndices"];
      [r set: @"cpu" text: GSPFormatDuration([evidence[@"cpuSeconds"] doubleValue]) sort: evidence[@"cpuSeconds"]];
      [r set: @"io" text: @(indices.count).stringValue sort: @(indices.count)];
      NSMutableString *detail = [NSMutableString stringWithFormat:
        @"Estimated main-thread CPU: %@.\n%lu overlapping main-thread I/O calls.\nDouble-click for all wall-sampled stacks.\n\n%@\n\nMissing CPU samples do not prove blocking. I/O overlap is correlation, not causation.\n",
        GSPFormatDuration([evidence[@"cpuSeconds"] doubleValue]), (unsigned long)indices.count, r.detail];
      [indices enumerateIndexesUsingBlock: ^(NSUInteger index, BOOL *stop) {
        const GSPIOEvent *event = &p.ioEvents[index];
        [detail appendFormat: @"%@ %@ — %@\n", [GSPIOAnalysis operationName: event->op],
          [_renderer.ioAnalysis nameOfEvent: index], GSPFormatDuration(event->duration / 1e9)];
      }];
      if (!indices.count) [detail appendString: @"No overlapping I/O was recorded.\n"];
      if (p.droppedSamples) [detail appendString: @"Warning: samples were dropped.\n"];
      r.detail = detail;
      [_rows addObject: r];
    }
  NSString *msg = !h.hasWallSamples ? @"No main-thread samples were recorded."
    : (!h.runLoopDetected ? @"The main thread never waited in a run loop, so hangs cannot be measured (normal for command-line tools)."
       : [NSString stringWithFormat: @"%lu hangs of 250 ms or longer", (unsigned long)[_rows count]]);
  [_status setStringValue: msg];
}

- (void) buildSignposts: (BOOL)summary
{
  GSPProcess *p = _renderer.process;
  NSArray *sps = [GSPSignpostAnalysis signposts: p.signposts from: _start to: _end];
  if (summary)
    {
      [self setColumns: [NSArray arrayWithObjects: col(@"name", @"Name", 220),
        col(@"category", @"Category", 150), col(@"count", @"Count", 70),
        col(@"total", @"Total", 100), col(@"avg", @"Average", 100),
        col(@"min", @"Min", 90), col(@"max", @"Max", 90), nil] outline: nil];
      for (GSPSignpostSummary *s in [GSPSignpostAnalysis summariesForSignposts: sps])
        {
          PDRow *r = [PDRow new];
          [r set: @"name" text: s.isEvent ? [s.name stringByAppendingString: @" (event)"] : s.name sort: s.name];
          [r set: @"category" text: s.category sort: nil];
          [r set: @"count" text: [NSString stringWithFormat: @"%lu", (unsigned long)s.count]
            sort: [NSNumber numberWithUnsignedInteger: s.count]];
          [r set: @"total" text: s.isEvent ? @"" : GSPFormatDuration(s.totalDuration)
            sort: [NSNumber numberWithDouble: s.totalDuration]];
          [r set: @"avg" text: s.isEvent ? @"" : GSPFormatDuration(s.averageDuration)
            sort: [NSNumber numberWithDouble: s.averageDuration]];
          [r set: @"min" text: s.isEvent ? @"" : GSPFormatDuration(s.minDuration)
            sort: [NSNumber numberWithDouble: s.minDuration]];
          [r set: @"max" text: s.isEvent ? @"" : GSPFormatDuration(s.maxDuration)
            sort: [NSNumber numberWithDouble: s.maxDuration]];
          r.detail = [NSString stringWithFormat: @"Subsystem: %@\nCategory: %@", s.subsystem, s.category];
          [_rows addObject: r];
        }
    }
  else
    {
      [self setColumns: [NSArray arrayWithObjects: col(@"start", @"Start", 110),
        col(@"duration", @"Duration", 100), col(@"name", @"Name", 180),
        col(@"message", @"Message", 300), col(@"thread", @"Thread", 90), nil] outline: nil];
      for (GSPSignpost *s in sps)
        {
          PDRow *r = [PDRow new];
          [r set: @"start" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: s.beginTime]]
            sort: [NSNumber numberWithUnsignedLongLong: s.beginTime]];
          [r set: @"duration" text: s.isEvent ? @"event" : (s.isOpen ? @"(open)" : GSPFormatDuration((double)s.duration / 1e9))
            sort: [NSNumber numberWithUnsignedLongLong: s.duration]];
          [r set: @"name" text: s.name sort: nil];
          NSString *msg = s.beginMessage ?: @"";
          if (s.endMessage)
            msg = [NSString stringWithFormat: @"%@ → %@", msg, s.endMessage];
          [r set: @"message" text: msg sort: nil];
          [r set: @"thread" text: [NSString stringWithFormat: @"%u", s.tid]
            sort: [NSNumber numberWithUnsignedInt: s.tid]];
          r.start = s.beginTime;
          r.end = s.isEvent ? s.beginTime : s.endTime;
          r.detail = [NSString stringWithFormat: @"%@\nSubsystem: %@\nCategory: %@\nID: 0x%llx\n%@",
            s.name, s.subsystem, s.category, (unsigned long long)s.signpostID, msg];
          [_rows addObject: r];
        }
    }
  [_status setStringValue: [NSString stringWithFormat: @"%lu signposts", (unsigned long)[sps count]]];
}

- (void) buildLogs
{
  GSPProcess *p = _renderer.process;
  [self setColumns: [NSArray arrayWithObjects: col(@"time", @"Time", 110),
    col(@"type", @"Type", 70), col(@"subsystem", @"Subsystem", 160),
    col(@"category", @"Category", 120), col(@"message", @"Message", 420), nil] outline: nil];
  for (GSPLogMessage *m in p.logMessages)
    {
      if (_end && (m.time < _start || m.time > _end))
        continue;
      PDRow *r = [PDRow new];
      NSString *type = m.level == GSP_LOG_LEVEL_ERROR ? @"Error"
        : (m.level == GSP_LOG_LEVEL_FAULT ? @"Fault"
           : (m.level == GSP_LOG_LEVEL_DEBUG ? @"Debug" : (m.level == GSP_LOG_LEVEL_INFO ? @"Info" : @"Default")));
      [r set: @"time" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: m.time]]
        sort: [NSNumber numberWithUnsignedLongLong: m.time]];
      [r set: @"type" text: type sort: [NSNumber numberWithInt: m.level]];
      [r set: @"subsystem" text: m.subsystem sort: nil];
      [r set: @"category" text: m.category sort: nil];
      [r set: @"message" text: m.message sort: nil];
      r.start = r.end = m.time;
      r.detail = m.message;
      [_rows addObject: r];
    }
  [_status setStringValue: [NSString stringWithFormat: @"%lu messages", (unsigned long)[_rows count]]];
}

- (void) buildAllocationStatistics
{
  GSPAllocationAnalysis *a = _renderer.allocationAnalysis;
  [self setColumns: [NSArray arrayWithObjects: col(@"category", @"Category", 260),
    col(@"pbytes", @"Persistent Bytes", 120), col(@"pcount", @"# Persistent", 95),
    col(@"tcount", @"# Transient", 90), col(@"bytes", @"Total Bytes", 110),
    col(@"count", @"# Total", 80), nil] outline: nil];
  for (GSPAllocationCategory *c in [a categoriesFrom: _start to: _end])
    {
      PDRow *r = [PDRow new];
      [r set: @"category" text: c.name sort: nil];
      [r set: @"pbytes" text: [GSPAllocationAnalysis formatBytes: c.persistentBytes]
        sort: [NSNumber numberWithUnsignedLongLong: c.persistentBytes]];
      [r set: @"pcount" text: [NSString stringWithFormat: @"%llu", (unsigned long long)c.persistentCount]
        sort: [NSNumber numberWithUnsignedLongLong: c.persistentCount]];
      [r set: @"tcount" text: [NSString stringWithFormat: @"%llu", (unsigned long long)c.transientCount]
        sort: [NSNumber numberWithUnsignedLongLong: c.transientCount]];
      [r set: @"bytes" text: [GSPAllocationAnalysis formatBytes: c.totalBytes]
        sort: [NSNumber numberWithUnsignedLongLong: c.totalBytes]];
      [r set: @"count" text: [NSString stringWithFormat: @"%llu", (unsigned long long)c.totalCount]
        sort: [NSNumber numberWithUnsignedLongLong: c.totalCount]];
      r.payload = c;
      r.detail = [NSString stringWithFormat: @"%@\nDouble-click to list these allocations.", c.name];
      [_rows addObject: r];
    }
  /* keep "All Heap Allocations" first when sorting */
  [_status setStringValue: [NSString stringWithFormat: @"Peak live heap %@",
    [GSPAllocationAnalysis formatBytes: a.peakLiveBytes]]];
}

- (void) buildAllocationList
{
  GSPAllocationAnalysis *a = _renderer.allocationAnalysis;
  GSPProcess *p = _renderer.process;
  [self setColumns: [NSArray arrayWithObjects: col(@"address", @"Address", 130),
    col(@"category", @"Category", 200), col(@"time", @"Timestamp", 110),
    col(@"live", @"Live", 50), col(@"size", @"Size", 90),
    col(@"caller", @"Responsible Caller", 300), nil] outline: nil];
  NSIndexSet *set = [a recordsInCategory: _allocCategory from: _start to: _end persistentOnly: NO];
  __block NSUInteger shown = 0;
  const NSUInteger limit = 50000;
  [set enumerateIndexesUsingBlock: ^(NSUInteger i, BOOL *stop) {
    if (shown++ >= limit)
      {
        *stop = YES;
        return;
      }
    const GSPAllocationRecord *rec = &a.records[i];
    PDRow *r = [PDRow new];
    BOOL live = rec->freeTime == 0 || (_end && rec->freeTime > _end);
    NSString *caller = responsible_frame(p, rec->stack);
    [r set: @"address" text: [NSString stringWithFormat: @"0x%llx", (unsigned long long)rec->address]
      sort: [NSNumber numberWithUnsignedLongLong: rec->address]];
    [r set: @"category" text: [a.categoryNames objectAtIndex: rec->category] sort: nil];
    [r set: @"time" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: rec->allocTime]]
      sort: [NSNumber numberWithUnsignedLongLong: rec->allocTime]];
    [r set: @"live" text: live ? @"•" : @"" sort: [NSNumber numberWithBool: live]];
    [r set: @"size" text: [GSPAllocationAnalysis formatBytes: rec->size]
      sort: [NSNumber numberWithUnsignedLongLong: rec->size]];
    [r set: @"caller" text: caller sort: nil];
    r.stack = rec->stack;
    r.detail = [NSString stringWithFormat: @"%@ at 0x%llx, %@\nAllocated at %.6f s%@",
      [a.categoryNames objectAtIndex: rec->category], (unsigned long long)rec->address,
      [GSPAllocationAnalysis formatBytes: rec->size], [_renderer.trace relativeTime: rec->allocTime],
      rec->freeTime ? [NSString stringWithFormat: @", freed at %.6f s",
                       [_renderer.trace relativeTime: rec->freeTime]] : @", still alive"];
    [_rows addObject: r];
  }];
  NSString *what = _allocCategory == UINT32_MAX ? @"all categories"
    : [a.categoryNames objectAtIndex: _allocCategory];
  [_status setStringValue: [NSString stringWithFormat: @"%lu allocations (%@)%@",
    (unsigned long)[set count], what, [set count] > limit ? @", first 50000 shown" : @""]];
}

- (void) buildLeaks
{
  if (_renderer.process.leakScanUnavailable)
    {
      [self setColumns: [NSArray arrayWithObject: col(@"object", @"Leak Scan", 400)] outline: nil];
      [_status setStringValue: @"Leak scan unavailable. See the recording warning; no reliable result for the latest attempt."];
      return;
    }
  GSPLeakAnalysis *la = _renderer.leakAnalysis;
  GSPProcess *p = _renderer.process;
  GSPLeakSnapshot *snap = la.latestSnapshot;
  NSUInteger known = [la knownLeakCountInSnapshot: snap];
  la.hidesKnownLeaks = PDIsOn(_hideKnown);
  [self setColumns: [NSArray arrayWithObjects: col(@"object", @"Leaked Object", 240),
    col(@"count", @"#", 60), col(@"address", @"Address", 130), col(@"size", @"Size", 100),
    col(@"known", @"Known Issue", 130), col(@"caller", @"Responsible Frame", 300), nil]
           outline: nil];
  for (GSPLeakGroup *g in [la groupsForSnapshot: snap])
    {
      GSPLeak *first = [g.leaks objectAtIndex: 0];
      PDRow *r = [PDRow new];
      NSString *caller = responsible_frame(p, first.stack);
      [r set: @"object" text: g.name sort: nil];
      [r set: @"count" text: [NSString stringWithFormat: @"%llu", (unsigned long long)g.count]
        sort: [NSNumber numberWithUnsignedLongLong: g.count]];
      [r set: @"address" text: g.count == 1 ? [NSString stringWithFormat: @"0x%llx",
                                              (unsigned long long)first.address] : @"< multiple >"
        sort: [NSNumber numberWithUnsignedLongLong: first.address]];
      [r set: @"size" text: [GSPAllocationAnalysis formatBytes: g.bytes]
        sort: [NSNumber numberWithUnsignedLongLong: g.bytes]];
      [r set: @"caller" text: caller sort: nil];
      [r set: @"known" text: g.knownLeak.identifier ?: @"" sort: nil];
      r.stack = first.stack;
      NSMutableString *d = [NSMutableString stringWithFormat: @"%llu leaked %@ (%@)\n",
        (unsigned long long)g.count, g.name, [GSPAllocationAnalysis formatBytes: g.bytes]];
      if (g.knownLeak != nil)
        [d appendFormat: @"Known GNUstep leak, not the program's: %@\n%@\n",
         g.knownLeak.summary, g.knownLeak.URL];
      NSUInteger shown = 0;
      for (GSPLeak *l in g.leaks)
        if (shown++ < 20)
          [d appendFormat: @"0x%llx  %@\n", (unsigned long long)l.address,
           [GSPAllocationAnalysis formatBytes: l.size]];
      r.detail = d;
      [_rows addObject: r];
    }
  [_status setStringValue: snap == nil ? @"No leak checks yet."
    : [NSString stringWithFormat: @"%lu leaked blocks (%@) at the check at %.3f s; %llu live blocks scanned in %@%@",
       (unsigned long)[snap.leaks count], [GSPAllocationAnalysis formatBytes: snap.leakedBytes],
       [_renderer.trace relativeTime: snap.time], (unsigned long long)snap.liveCount,
       GSPFormatDuration(snap.scanMicroseconds / 1e6),
       known == 0 ? @"" : [NSString stringWithFormat: @"; %lu known GNUstep leaks%@",
                           (unsigned long)known, PDIsOn(_hideKnown) ? @" hidden" : @""]]];
}

- (void) buildLeakChecks
{
  GSPLeakAnalysis *la = _renderer.leakAnalysis;
  [self setColumns: [NSArray arrayWithObjects: col(@"time", @"Time", 110),
    col(@"leaks", @"Leaked Blocks", 110), col(@"new", @"New", 70),
    col(@"bytes", @"Leaked Bytes", 110), col(@"live", @"Live Blocks", 100),
    col(@"scan", @"Scan Time", 100), nil] outline: nil];
  for (GSPLeakSnapshot *s in _renderer.process.leakSnapshots)
    {
      PDRow *r = [PDRow new];
      [r set: @"time" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: s.time]]
        sort: [NSNumber numberWithUnsignedLongLong: s.time]];
      [r set: @"leaks" text: [NSString stringWithFormat: @"%lu", (unsigned long)[s.leaks count]]
        sort: [NSNumber numberWithUnsignedInteger: [s.leaks count]]];
      NSUInteger fresh = [[la newLeaksInSnapshot: s] count];
      [r set: @"new" text: [NSString stringWithFormat: @"%lu", (unsigned long)fresh]
        sort: [NSNumber numberWithUnsignedInteger: fresh]];
      [r set: @"bytes" text: [GSPAllocationAnalysis formatBytes: s.leakedBytes]
        sort: [NSNumber numberWithUnsignedLongLong: s.leakedBytes]];
      [r set: @"live" text: [NSString stringWithFormat: @"%llu", (unsigned long long)s.liveCount]
        sort: [NSNumber numberWithUnsignedLongLong: s.liveCount]];
      [r set: @"scan" text: GSPFormatDuration(s.scanMicroseconds / 1e6)
        sort: [NSNumber numberWithUnsignedLongLong: s.scanMicroseconds]];
      r.start = r.end = s.time;
      [_rows addObject: r];
    }
  [_status setStringValue: [NSString stringWithFormat: @"%lu leak checks",
    (unsigned long)[_renderer.process.leakSnapshots count]]];
}

- (void) buildIOSummaries: (BOOL)net
{
  GSPIOAnalysis *io = _renderer.ioAnalysis;
  [self setColumns: [NSArray arrayWithObjects:
    col(@"name", net ? @"Peer" : @"File", 320),
    col(@"opens", net ? @"Connections" : @"Opens", 90),
    col(@"reads", net ? @"Receives" : @"Reads", 80),
    col(@"rbytes", net ? @"Received" : @"Bytes Read", 100),
    col(@"writes", net ? @"Sends" : @"Writes", 70),
    col(@"wbytes", net ? @"Sent" : @"Written", 100),
    col(@"errors", @"Errors", 60), col(@"time", @"Time", 100), nil] outline: nil];
  for (GSPIOSummary *sum in [io summariesForNetwork: net from: _start to: _end])
    {
      PDRow *r = [PDRow new];
      [r set: @"name" text: sum.name sort: nil];
      [r set: @"opens" text: [NSString stringWithFormat: @"%llu", (unsigned long long)sum.opens]
        sort: [NSNumber numberWithUnsignedLongLong: sum.opens]];
      [r set: @"reads" text: [NSString stringWithFormat: @"%llu", (unsigned long long)sum.reads]
        sort: [NSNumber numberWithUnsignedLongLong: sum.reads]];
      [r set: @"rbytes" text: [GSPAllocationAnalysis formatBytes: sum.bytesRead]
        sort: [NSNumber numberWithUnsignedLongLong: sum.bytesRead]];
      [r set: @"writes" text: [NSString stringWithFormat: @"%llu", (unsigned long long)sum.writes]
        sort: [NSNumber numberWithUnsignedLongLong: sum.writes]];
      [r set: @"wbytes" text: [GSPAllocationAnalysis formatBytes: sum.bytesWritten]
        sort: [NSNumber numberWithUnsignedLongLong: sum.bytesWritten]];
      [r set: @"errors" text: [NSString stringWithFormat: @"%llu", (unsigned long long)sum.errors]
        sort: [NSNumber numberWithUnsignedLongLong: sum.errors]];
      [r set: @"time" text: GSPFormatDuration(sum.totalDuration / 1e9)
        sort: [NSNumber numberWithUnsignedLongLong: sum.totalDuration]];
      r.detail = [NSString stringWithFormat: @"%@\n%llu syncs", sum.name,
                  (unsigned long long)sum.syncs];
      [_rows addObject: r];
    }
  [_status setStringValue: [NSString stringWithFormat: net ? @"%lu peers" : @"%lu files",
                            (unsigned long)[_rows count]]];
}

- (void) buildIOEvents: (BOOL)net
{
  GSPIOAnalysis *io = _renderer.ioAnalysis;
  const GSPIOEvent *ev = _renderer.process.ioEvents;
  [self setColumns: [NSArray arrayWithObjects: col(@"time", @"Time", 110),
    col(@"op", @"Operation", 90), col(@"duration", @"Duration", 100),
    col(@"result", @"Result", 90), col(@"name", net ? @"Peer" : @"File", 320),
    col(@"thread", @"Thread", 80), nil] outline: nil];
  NSIndexSet *set = [io eventsForNetwork: net from: _start to: _end];
  __block NSUInteger shown = 0;
  [set enumerateIndexesUsingBlock: ^(NSUInteger i, BOOL *stop) {
    if (shown++ >= 50000)
      {
        *stop = YES;
        return;
      }
    const GSPIOEvent *e = &ev[i];
    PDRow *r = [PDRow new];
    NSString *res = e->result < 0
      ? [NSString stringWithFormat: @"%s", strerror((int)-e->result)]
      : ((e->op == GSP_IO_READ || e->op == GSP_IO_WRITE || e->op == GSP_IO_SEND || e->op == GSP_IO_RECV)
         ? [GSPAllocationAnalysis formatBytes: (uint64_t)e->result]
         : [NSString stringWithFormat: @"%lld", (long long)e->result]);
    [r set: @"time" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: e->time]]
      sort: [NSNumber numberWithUnsignedLongLong: e->time]];
    [r set: @"op" text: [GSPIOAnalysis operationName: e->op] sort: nil];
    [r set: @"duration" text: GSPFormatDuration(e->duration / 1e9)
      sort: [NSNumber numberWithUnsignedLongLong: e->duration]];
    [r set: @"result" text: res sort: [NSNumber numberWithLongLong: e->result]];
    [r set: @"name" text: [io nameOfEvent: i] sort: nil];
    [r set: @"thread" text: [NSString stringWithFormat: @"%u", e->tid]
      sort: [NSNumber numberWithUnsignedInt: e->tid]];
    r.stack = e->stack;
    r.start = e->time;
    r.end = e->time + e->duration;
    r.detail = [NSString stringWithFormat: @"%@ %@\n%@, result %@",
                [GSPIOAnalysis operationName: e->op], [io nameOfEvent: i],
                GSPFormatDuration(e->duration / 1e9), res];
    [_rows addObject: r];
  }];
  [_status setStringValue: [NSString stringWithFormat: @"%lu operations%@",
    (unsigned long)[set count], [set count] > 50000 ? @", first 50000 shown" : @""]];
}

- (void) buildZombies
{
  GSPProcess *p = _renderer.process;
  [self setColumns: [NSArray arrayWithObjects: col(@"time", @"Time", 110),
    col(@"class", @"Object", 200), col(@"selector", @"Message", 200),
    col(@"address", @"Address", 130), nil] outline: nil];
  for (GSPZombieEvent *z in p.zombies)
    {
      PDRow *r = [PDRow new];
      [r set: @"time" text: [PDTimelineView formatTime: [_renderer.trace relativeTime: z.time]]
        sort: [NSNumber numberWithUnsignedLongLong: z.time]];
      [r set: @"class" text: z.className ?: @"(unknown class)" sort: nil];
      [r set: @"selector" text: [@"-" stringByAppendingString: z.selector ?: @"?"] sort: nil];
      [r set: @"address" text: [NSString stringWithFormat: @"0x%llx", (unsigned long long)z.address]
        sort: [NSNumber numberWithUnsignedLongLong: z.address]];
      r.stack = z.stack;
      r.start = r.end = z.time;
      NSMutableString *d = [NSMutableString stringWithFormat:
        @"An Objective-C message (-%@) was sent to a deallocated %@ at 0x%llx.\n\nHistory:\n",
        z.selector ?: @"?", z.className ?: @"object", (unsigned long long)z.address];
      for (GSPHistoryEvent *h in GSPZombieHistory(p, z))
        [d appendFormat: @"%.4f s  %-11@ %@\n", [_renderer.trace relativeTime: h.time],
         h.kind, responsible_frame(p, h.stack)];
      r.detail = d;
      [_rows addObject: r];
    }
  [_status setStringValue: [NSString stringWithFormat: @"%lu messages to deallocated objects",
    (unsigned long)[_rows count]]];
}

- (void) reload
{
  NSString *mode = _currentMode;
  _tree = nil;
  [_rows removeAllObjects];
  [self layoutBar];
  if (_renderer == nil || _instrument == nil)
    {
      [_outline reloadData];
      return;
    }
  if ([mode isEqual: @"Call Tree"])
    [self buildCallTree];
  else if ([mode isEqual: @"Threads"])
    [self buildThreads];
  else if ([mode isEqual: @"Hangs"])
    [self buildHangs];
  else if ([mode isEqual: @"Summary"])
    [self buildSignposts: YES];
  else if ([mode isEqual: @"Intervals"])
    [self buildSignposts: NO];
  else if ([mode isEqual: @"Messages"])
    [self buildLogs];
  else if ([mode isEqual: @"Statistics"])
    [self buildAllocationStatistics];
  else if ([mode isEqual: @"Allocations List"])
    [self buildAllocationList];
  else if ([mode isEqual: @"Leaks"])
    [self buildLeaks];
  else if ([mode isEqual: @"Leak Checks"])
    [self buildLeakChecks];
  else if ([mode isEqual: @"Zombies"])
    [self buildZombies];
  else if ([mode isEqual: @"Files"])
    [self buildIOSummaries: NO];
  else if ([mode isEqual: @"Connections"])
    [self buildIOSummaries: YES];
  else if ([mode isEqual: @"Events"])
    [self buildIOEvents: [_instrument isEqual: GSPInstrumentNetwork]];
  [self sortRows];
  [_outline reloadData];
  [self expandHeaviest];
  [_inspector clear];
}

/* ------------------------------------------------------------------ */
/* sorting                                                             */

- (void) sortRows
{
  if (_sortColumn == nil || [_rows count] < 2)
    return;
  NSString *colId = _sortColumn;
  BOOL asc = _sortAscending;
  PDRow *pinned = nil;
  if ([[_rows objectAtIndex: 0] payload] != nil
      && [[[_rows objectAtIndex: 0] payload] isKindOfClass: [GSPAllocationCategory class]]
      && [(GSPAllocationCategory *)[[_rows objectAtIndex: 0] payload] index] == UINT32_MAX)
    {
      pinned = [_rows objectAtIndex: 0];
      [_rows removeObjectAtIndex: 0];
    }
  [_rows sortUsingComparator: ^NSComparisonResult(PDRow *a, PDRow *b) {
    id x = [a.sortKeys objectForKey: colId], y = [b.sortKeys objectForKey: colId];
    NSComparisonResult r = [x isKindOfClass: [NSString class]]
      ? [x caseInsensitiveCompare: y] : [x compare: y];
    return asc ? r : -r;
  }];
  if (pinned)
    [_rows insertObject: pinned atIndex: 0];
}

- (void) outlineView: (NSOutlineView *)ov didClickTableColumn: (NSTableColumn *)column
{
  if ([self isCallTreeMode])
    return;
  NSString *ident = [column identifier];
  if ([ident isEqual: _sortColumn])
    _sortAscending = !_sortAscending;
  else
    {
      _sortColumn = ident;
      PDRow *any = [_rows lastObject];
      _sortAscending = [[any.sortKeys objectForKey: ident] isKindOfClass: [NSString class]];
    }
  [self sortRows];
  [_outline reloadData];
}

/* ------------------------------------------------------------------ */
/* outline data source                                                 */

- (NSInteger) outlineView: (NSOutlineView *)ov numberOfChildrenOfItem: (id)item
{
  if ([self isCallTreeMode])
    {
      if (_tree == nil)
        return 0;
      return (NSInteger)[[self childrenOf: item ? item : _tree.root] count];
    }
  return item == nil ? (NSInteger)[_rows count] : 0;
}

- (id) outlineView: (NSOutlineView *)ov child: (NSInteger)index ofItem: (id)item
{
  if ([self isCallTreeMode])
    return [[self childrenOf: item ? item : _tree.root] objectAtIndex: (NSUInteger)index];
  return [_rows objectAtIndex: (NSUInteger)index];
}

- (BOOL) outlineView: (NSOutlineView *)ov isItemExpandable: (id)item
{
  if ([self isCallTreeMode])
    return [[self childrenOf: item] count] > 0;
  return NO;
}

- (id) outlineView: (NSOutlineView *)ov objectValueForTableColumn: (NSTableColumn *)column
            byItem: (id)item
{
  NSString *ident = [column identifier];
  if ([item isKindOfClass: [GSPCallTreeNode class]])
    {
      GSPCallTreeNode *n = item;
      if ([ident isEqual: @"weight"])
        return [self formatWeight: n.totalWeight total: _tree.totalWeight];
      if ([ident isEqual: @"self"])
        return [self formatWeight: n.selfWeight total: _tree.totalWeight];
      if ([ident isEqual: @"symbol"])
        return n.name;
      if ([ident isEqual: @"library"])
        return n.imageName ?: @"";
      return @"";
    }
  return [[(PDRow *)item values] objectForKey: ident];
}

- (void) outlineView: (NSOutlineView *)ov willDisplayCell: (id)cell
      forTableColumn: (NSTableColumn *)column item: (id)item
{
  if (![cell respondsToSelector: @selector(setTextColor:)])
    return;
  NSColor *c = [PDTheme textColor];
  if ([item isKindOfClass: [GSPCallTreeNode class]])
    {
      GSPCallTreeNode *n = item;
      if (n.symbol.isSystem)
        c = [PDTheme secondaryTextColor];
    }
  [cell setTextColor: c];
}

- (void) outlineViewSelectionDidChange: (NSNotification *)note
{
  NSInteger row = [_outline selectedRow];
  GSPProcess *p = _renderer.process;
  if (row < 0)
    {
      [_inspector clear];
      return;
    }
  id item = [_outline itemAtRow: row];
  if ([item isKindOfClass: [GSPCallTreeNode class]])
    {
      GSPCallTreeNode *n = item;
      NSString *text = [NSString stringWithFormat: @"%@\n%@\nWeight %@, self %@, %llu %@",
        n.name, n.imageName ?: @"",
        [self formatWeight: n.totalWeight total: _tree.totalWeight],
        [self formatWeight: n.selfWeight total: _tree.totalWeight],
        (unsigned long long)n.sampleCount, _weightIsBytes ? @"allocations" : @"samples"];
      [_inspector showTitle: @"Heaviest Stack Trace" text: text stack: n.heaviestStack process: p];
      return;
    }
  PDRow *r = item;
  [_inspector showTitle: @"Extended Detail" text: r.detail stack: r.stack process: p];
  if (r.start && [_delegate respondsToSelector: @selector(detailController:showTimeRangeStart:end:)])
    [_delegate detailController: self showTimeRangeStart: r.start end: r.end];
}

- (void) rowDoubleClicked: (id)sender
{
  NSInteger row = [_outline clickedRow];
  if (row < 0)
    return;
  id item = [_outline itemAtRow: row];
  if ([item isKindOfClass: [PDRow class]]
      && [[(PDRow *)item payload] isKindOfClass: [GSPAllocationCategory class]])
    {
      _allocCategory = [(GSPAllocationCategory *)[(PDRow *)item payload] index];
      [_mode selectItemWithTitle: @"Allocations List"];
      _currentMode = @"Allocations List";
      [self reload];
    }
  else if ([item isKindOfClass: [PDRow class]]
           && [[(PDRow *)item payload] isKindOfClass: [GSPHang class]])
    {
      GSPHang *hang = [(PDRow *)item payload];
      _start = hang.startTime;
      _end = hang.endTime;
      [_mode selectItemWithTitle: @"Call Tree"];
      _currentMode = @"Call Tree";
      [self reload];
    }
  else if ([item isKindOfClass: [GSPCallTreeNode class]])
    {
      if ([_outline isItemExpanded: item])
        [_outline collapseItem: item];
      else
        [_outline expandItem: item expandChildren: NO];
    }
}

@end
