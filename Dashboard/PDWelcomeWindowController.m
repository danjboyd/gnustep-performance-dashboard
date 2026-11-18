/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeWindowController.h"
#import "PDAppController.h"
#import "PDRecordPanel.h"
#import "PDTheme.h"
#import "TRLoader.h"
#include <math.h>
#include <limits.h>

@interface PDWelcomeRecentButton : NSButton
@property (nonatomic, strong) id recentEntry;
@end
@implementation PDWelcomeRecentButton
@end

@implementation PDWelcomeWindowController
{
  __weak PDAppController *_appController;
  NSTableView *_table;
  NSArray *_rows;
  NSTimer *_refreshTimer;
  BOOL _updating;
  NSString *_fieldProblem;
}
- (instancetype) initWithModel: (PDWelcomeModel *)model appController: (PDAppController *)controller
{
  if ((self = [super initWithWindow: nil]))
    {
      _model = model;
      _appController = controller;
      NSError *error = nil;
      NSString *path = [[NSBundle mainBundle] pathForResource: @"WelcomeWindow" ofType: @"trellis"];
      if (path == nil || (_root = [TRLoader loadFile: path owner: self error: &error]) == nil)
        {
          NSLog(@"Cannot load the welcome window: %@", error ?: @"WelcomeWindow.trellis is missing");
          return nil;
        }
      NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(100, 100, 960, 680)
        styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
        backing: NSBackingStoreBuffered defer: NO];
      [window setTitle: @"New Recording"];
      [window setMinSize: NSMakeSize(500, 500)];
      [window setReleasedWhenClosed: NO];
      [window setDelegate: self];
      [window setContentView: _root];
      [self setWindow: window];
      [window center];
      [_root setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
      [_root setFrame: [[window contentView] bounds]];
      _table = [[NSTableView alloc] initWithFrame: NSMakeRect(0, 0, 560, 210)];
      NSArray *keys = [NSArray arrayWithObjects: @"name", @"pid", @"status", nil];
      NSArray *titles = [NSArray arrayWithObjects: @"App", @"PID", @"Status", nil];
      CGFloat widths[] = { 140, 96, 340 };
      for (NSUInteger i = 0; i < [keys count]; i++)
        {
          NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier: [keys objectAtIndex: i]];
          [[column headerCell] setStringValue: [titles objectAtIndex: i]];
          [column setWidth: widths[i]];
          [column setEditable: NO];
          [_table addTableColumn: column];
        }
      [_table setAllowsEmptySelection: YES];
      [_table setAllowsMultipleSelection: NO];
      [_table setRowHeight: 26];
      [_table setDataSource: self];
      [_table setDelegate: self];
      [_processScroll setDocumentView: _table];
      [_processScroll setHasVerticalScroller: YES];
      [_processScroll setHasHorizontalScroller: YES];
      [_processScroll setBorderType: NSBezelBorder];
      [[_moreTemplates menu] setAutoenablesItems: NO];
      [_moreTemplates addItemsWithTitles: [PDWelcomeModel moreTemplateNames]];
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      NSString *savedTemplate = [defaults stringForKey: @"PDLastTemplate"];
      if ([GSPTemplate templateNamed: savedTemplate] != nil
          && [_model templateDisabledReason: savedTemplate] == nil)
        _model.templateName = savedTemplate;
      [_targetPath setStringValue: [defaults stringForKey: @"PDLastTarget"] ?: @""];
      [_argumentsField setStringValue: [defaults stringForKey: @"PDLastArguments"] ?: @""];
      [_environmentField setStringValue: [defaults stringForKey: @"PDLastEnvironment"] ?: @""];
      [_directoryField setStringValue: [defaults stringForKey: @"PDLastDirectory"] ?: @""];
      [_showAtLaunch setState: _model.history.showAtLaunch ? NSOnState : NSOffState];
      [_search setDelegate: (id)self];
      for (NSTextField *field in [NSArray arrayWithObjects: _targetPath, _argumentsField,
          _environmentField, _directoryField, _durationField, _intervalField, nil])
        [field setDelegate: (id)self];
      [self rebuildRecents];
      [self fieldsChanged: nil];
    }
  return self;
}
- (void) setPane: (NSView *)pane visible: (BOOL)visible
{
  [(TRBoxView *)[pane superview] setHidden: !visible forSubview: pane];
}
- (void) showForMode: (PDWelcomeTargetMode)mode
{
  _model.mode = mode;
  if (mode == PDWelcomeAttach)
    _model.templateName = @"System Time Profiler";
  else if ([_model.templateName isEqual: @"System Time Profiler"])
    _model.templateName = @"Time Profiler";
  [self fieldsChanged: nil];
  [self rebuildRecents];
  if (mode == PDWelcomeAttach)
    [self refresh: nil];
  else
    { [_refreshTimer invalidate]; _refreshTimer = nil; }
  [self showWindow: nil];
  [[self window] makeKeyAndOrderFront: nil];
  [_root layoutTrellis];
  if (mode == PDWelcomeAttach && _refreshTimer == nil)
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval: 2 target: self
      selector: @selector(refresh:) userInfo: nil repeats: YES];
}
- (NSArray *) templateButtons
{
  return [NSArray arrayWithObjects: _cpuTemplate, _allocationTemplate, _leaksTemplate, _hangsTemplate, nil];
}
- (void) updateControls
{
  [_launchMode setState: _model.mode == PDWelcomeLaunch ? NSOnState : NSOffState];
  [_attachMode setState: _model.mode == PDWelcomeAttach ? NSOnState : NSOffState];
  [self setPane: _launchPane visible: _model.mode == PDWelcomeLaunch];
  [self setPane: _attachPane visible: _model.mode == PDWelcomeAttach];
  for (NSButton *button in [self templateButtons])
    {
      NSString *problem = [_model templateDisabledReason: [button title]];
      [button setEnabled: problem == nil];
      [button setToolTip: problem];
      [button setState: [[button title] isEqual: _model.templateName] ? NSOnState : NSOffState];
    }
  for (NSMenuItem *item in [_moreTemplates itemArray])
    {
      NSString *name = [item representedObject] ?: [item title];
      GSPTemplate *t = [GSPTemplate templateNamed: name];
      if (t == nil)
        continue;
      [item setRepresentedObject: t.name];
      NSString *reason = [_model templateDisabledReason: t.name];
      [item setEnabled: reason == nil];
      [item setToolTip: reason];
      [item setTitle: reason ? [NSString stringWithFormat: @"%@ — %@", t.name, reason] : t.name];
    }
  /* A disabled selected placeholder makes Adwaita gray the entire popup. */
  [[_moreTemplates itemAtIndex: 0] setEnabled: YES];
  NSInteger selectedTemplate = 0;
  for (NSInteger i = 1; i < [_moreTemplates numberOfItems]; i++)
    if ([[[_moreTemplates itemAtIndex: i] representedObject] isEqual: _model.templateName])
      { selectedTemplate = i; break; }
  [_moreTemplates selectItemAtIndex: selectedTemplate];
  BOOL launch = _model.mode == PDWelcomeLaunch;
  [_argumentsField setEnabled: launch];
  [_environmentField setEnabled: launch];
  [_directoryField setEnabled: launch];
  NSString *problem = _fieldProblem ?: [_model recordDisabledReason];
  [_recordButton setEnabled: problem == nil];
  [_recordButton setToolTip: problem];
  [_summary setStringValue: problem ?: [_model selectionSummary]];
  [_summary setToolTip: problem ?: [_model selectionSummary]];
  [_root layoutTrellis];
}
- (void) refresh: (id)sender
{
  if (_model.mode != PDWelcomeAttach)
    return;
  _model.activeRecordingPIDs = [_appController activeRecordingPIDs] ?: [NSSet set];
  _updating = YES;
  [_model refreshProcesses];
  _rows = [_model filteredProcesses];
  [_table reloadData];
  NSInteger selected = -1;
  for (NSUInteger i = 0; i < [_rows count]; i++)
    {
      PDWelcomeProcess *p = [_rows objectAtIndex: i];
      if (p.pid == _model.selectedProcess.pid && [p.identity isEqual: _model.selectedProcess.identity])
        { selected = (NSInteger)i; _model.selectedProcess = p; break; }
    }
  if (selected >= 0)
    [_table selectRowIndexes: [NSIndexSet indexSetWithIndex: (NSUInteger)selected] byExtendingSelection: NO];
  else
    { [_table deselectAll: nil]; _model.selectedProcess = nil; }
  _updating = NO;
  [self updateControls];
}
- (NSInteger) numberOfRowsInTableView: (NSTableView *)tableView { return (NSInteger)[_rows count]; }
- (id) tableView: (NSTableView *)tableView objectValueForTableColumn: (NSTableColumn *)column row: (NSInteger)row
{
  PDWelcomeProcess *p = [_rows objectAtIndex: (NSUInteger)row];
  if ([[column identifier] isEqual: @"name"])
    return p.name;
  if ([[column identifier] isEqual: @"pid"])
    return [NSNumber numberWithInt: p.pid];
  NSString *reason = [_model unavailableReasonForProcess: p];
  if (p.GNUstepIdentity == PDGNUstepUnknown)
    return reason ? [NSString stringWithFormat: @"%@; GNUstep: unknown (memory map not readable)", reason]
                  : @"GNUstep: unknown (memory map not readable)";
  return reason ?: @"Permission unverified";
}
- (NSString *) tableView: (NSTableView *)tableView toolTipForCell: (NSCell *)cell
                   rect: (NSRect *)rect tableColumn: (NSTableColumn *)column
                    row: (NSInteger)row mouseLocation: (NSPoint)location
{
  if (row < 0 || (NSUInteger)row >= [_rows count])
    return nil;
  return [self tableView: tableView objectValueForTableColumn:
    [tableView tableColumnWithIdentifier: @"status"] row: row];
}
- (BOOL) tableView: (NSTableView *)tableView shouldSelectRow: (NSInteger)row
{
  return [_model unavailableReasonForProcess: [_rows objectAtIndex: (NSUInteger)row]] == nil;
}
- (void) tableView: (NSTableView *)tableView willDisplayCell: (id)cell forTableColumn: (NSTableColumn *)column row: (NSInteger)row
{
  BOOL unavailable = [_model unavailableReasonForProcess: [_rows objectAtIndex: (NSUInteger)row]] != nil;
  [cell setTextColor: unavailable ? [NSColor disabledControlTextColor] : [NSColor controlTextColor]];
}
- (void) tableViewSelectionDidChange: (NSNotification *)notification
{
  if (_updating)
    return;
  NSInteger row = [_table selectedRow];
  _model.selectedProcess = row >= 0 && (NSUInteger)row < [_rows count] ? [_rows objectAtIndex: (NSUInteger)row] : nil;
  [self updateControls];
}
- (void) chooseLaunch: (id)sender { [self showForMode: PDWelcomeLaunch]; }
- (void) chooseAttach: (id)sender { [self showForMode: PDWelcomeAttach]; }
- (void) chooseTemplate: (id)sender
{
  NSString *name = sender == _moreTemplates ? [[_moreTemplates selectedItem] representedObject] : [sender title];
  if ([GSPTemplate templateNamed: name] && [_model templateDisabledReason: name] == nil)
    _model.templateName = name;
  [self updateControls];
}
- (void) browseTarget: (id)sender
{
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setCanChooseFiles: YES];
  [panel setCanChooseDirectories: YES];
  [panel setAllowsMultipleSelection: NO];
  if ([panel runModalForDirectory: NSHomeDirectory() file: nil types: nil] == NSOKButton)
    { [_targetPath setStringValue: [panel filename]]; [self fieldsChanged: nil]; }
}
- (void) filtersChanged: (id)sender
{
  _model.searchText = [_search stringValue];
  _model.GNUstepOnly = [_processFilter indexOfSelectedItem] == 0;
  [self refresh: nil];
}
- (void) controlTextDidChange: (NSNotification *)notification
{
  if ([notification object] == _search)
    [self filtersChanged: nil];
  else
    [self fieldsChanged: nil];
}
- (void) fieldsChanged: (id)sender
{
  _fieldProblem = nil;
  _model.executablePath = [_targetPath stringValue];
  _model.arguments = [PDRecordPanel splitArguments: [_argumentsField stringValue]];
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  for (NSString *pair in [PDRecordPanel splitArguments: [_environmentField stringValue]])
    {
      NSRange eq = [pair rangeOfString: @"="];
      if (eq.location != NSNotFound && eq.location > 0)
        [env setObject: [pair substringFromIndex: eq.location + 1] forKey: [pair substringToIndex: eq.location]];
    }
  _model.environment = env;
  _model.workingDirectory = [[_directoryField stringValue] stringByExpandingTildeInPath];
  double duration = 0, interval = 0;
  NSString *durationText = [_durationField stringValue], *intervalText = [_intervalField stringValue];
  NSScanner *durationScanner = [NSScanner scannerWithString: durationText];
  NSScanner *intervalScanner = [NSScanner scannerWithString: intervalText];
  if ([durationText length] && (![durationScanner scanDouble: &duration] || ![durationScanner isAtEnd]
      || !isfinite(duration) || duration < 0))
    _fieldProblem = @"Duration must be zero (until stopped) or a positive number.";
  if ([intervalText length] && (![intervalScanner scanDouble: &interval] || ![intervalScanner isAtEnd]
      || !isfinite(interval) || interval < 0 || interval > UINT_MAX || floor(interval) != interval))
    _fieldProblem = @"Sample interval must be a nonnegative whole number of microseconds.";
  _model.timeLimit = duration;
  _model.sampleIntervalMicroseconds = _fieldProblem ? 0 : (unsigned)interval;
  if (_model.mode == PDWelcomeAttach && interval > 0 && !_fieldProblem)
    {
      double frequency = 1000000.0 / interval;
      if (frequency < 10 || frequency > 10000)
        _fieldProblem = @"Linux attach sample interval must select 10–10000 samples per second.";
      else
        _model.perfFrequency = (unsigned)llround(frequency);
    }
  else
    _model.perfFrequency = 199;
  [self updateControls];
}
- (void) advancedChanged: (id)sender
{
  [self setPane: _advancedPane visible: [_showAdvanced state] == NSOnState];
  [self updateControls];
}
- (void) launchPreferenceChanged: (id)sender
{
  _model.history.showAtLaunch = [_showAtLaunch state] == NSOnState;
}
- (void) populateRecentBox: (TRBoxView *)box entries: (NSArray *)entries action: (SEL)action
{
  for (NSView *view in [[box subviews] copy])
    [view removeFromSuperview];
  NSUInteger count = 0;
  for (id entry in entries)
    {
      NSString *path = [entry isKindOfClass: [NSDictionary class]] ? [entry objectForKey: @"path"] : entry;
      PDWelcomeRecentButton *button = [PDWelcomeRecentButton new];
      button.recentEntry = entry;
      [button setButtonType: NSMomentaryPushInButton];
      [button setBezelStyle: NSRoundedBezelStyle];
      [button setTitle: [path lastPathComponent]];
      [button setToolTip: path];
      [button setTarget: self];
      [button setAction: action];
      [button setTag: (NSInteger)count++];
      [box addSubview: button style: @"flex: none; min-height: 26px"];
      if (count == 3)
        break;
    }
  if (!count)
    {
      NSTextField *empty = [NSTextField new];
      [empty setStringValue: @"None yet"];
      [empty setEditable: NO];
      [empty setBezeled: NO];
      [empty setDrawsBackground: NO];
      [empty setTextColor: [PDTheme secondaryTextColor]];
      [box addSubview: empty];
    }
}
- (void) rebuildRecents
{
  [self populateRecentBox: _recentTargetsBox entries: [_model.history recentTargets] action: @selector(recentTarget:)];
  [self populateRecentBox: _recentTracesBox entries: [_model.history recentTraces] action: @selector(recentTrace:)];
}
- (void) recentTarget: (id)sender
{
  NSArray *entries = [_model.history recentTargets];
  NSDictionary *entry = [(PDWelcomeRecentButton *)sender recentEntry];
  if (![entries containsObject: entry])
    { [self rebuildRecents]; return; }
  NSString *path = [entry objectForKey: @"path"];
  BOOL attach = [[entry objectForKey: @"mode"] isEqual: @"attach"];
  NSString *name = [entry objectForKey: @"template"];
  _model.templateName = [name isKindOfClass: [NSString class]] && [GSPTemplate templateNamed: name]
    ? name : (attach ? @"System Time Profiler" : @"Time Profiler");
  [_targetPath setStringValue: path];
  _model.selectedProcess = nil;
  [self showForMode: attach ? PDWelcomeAttach : PDWelcomeLaunch];
  if (attach)
    {
      NSArray *matches = [_model.processes filteredArrayUsingPredicate: [NSPredicate predicateWithBlock:
        ^BOOL(PDWelcomeProcess *p, NSDictionary *bindings) { return [p.executablePath isEqual: path]; }]];
      if ([matches count] == 1)
        _model.selectedProcess = [matches objectAtIndex: 0];
      [self refresh: nil];
    }
}
- (void) recentTrace: (id)sender
{
  NSArray *traces = [_model.history recentTraces];
  NSString *path = [(PDWelcomeRecentButton *)sender recentEntry];
  if ([traces containsObject: path] && [_appController openTraceAtPath: path])
    [self cancel: nil];
  else
    [self rebuildRecents];
}
- (void) openTrace: (id)sender { [_appController openTrace: sender]; }
- (void) record: (id)sender
{
  [self fieldsChanged: nil];
  _model.activeRecordingPIDs = [_appController activeRecordingPIDs] ?: [NSSet set];
  if (_fieldProblem)
    return;
  NSError *error = nil;
  GSPRecordingOptions *options = [_model recordingOptionsWithError: &error];
  if (options == nil)
    { [_summary setStringValue: [error localizedDescription]]; [_recordButton setEnabled: NO]; return; }
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject: options.templateName forKey: @"PDLastTemplate"];
  [defaults setObject: [_targetPath stringValue] forKey: @"PDLastTarget"];
  [defaults setObject: [_argumentsField stringValue] forKey: @"PDLastArguments"];
  [defaults setObject: [_environmentField stringValue] forKey: @"PDLastEnvironment"];
  [defaults setObject: [_directoryField stringValue] forKey: @"PDLastDirectory"];
  [self cancel: nil];
  [_appController startRecordingWithOptions: options];
}
- (void) cancel: (id)sender
{
  [_refreshTimer invalidate];
  _refreshTimer = nil;
  [[self window] orderOut: nil];
}
- (void) windowWillClose: (NSNotification *)notification { [self cancel: nil]; }
@end
