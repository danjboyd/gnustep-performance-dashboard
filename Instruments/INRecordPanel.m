#import "INRecordPanel.h"
#import "INTheme.h"

#include <unistd.h>
#include <sys/stat.h>

static NSTextField *
make_label(NSString *text, NSRect frame)
{
  NSTextField *t = [[NSTextField alloc] initWithFrame: frame];
  [t setStringValue: text];
  [t setEditable: NO];
  [t setSelectable: NO];
  [t setBezeled: NO];
  [t setDrawsBackground: NO];
  [t setAlignment: NSRightTextAlignment];
  return t;
}

static NSTextField *
make_field(NSRect frame)
{
  NSTextField *t = [[NSTextField alloc] initWithFrame: frame];
  [t setEditable: YES];
  [t setBezeled: YES];
  return t;
}

static NSButton *
make_button(NSString *title, NSRect frame, id target, SEL action)
{
  NSButton *b = [[NSButton alloc] initWithFrame: frame];
  [b setButtonType: NSMomentaryPushInButton];
  [b setBezelStyle: NSRoundedBezelStyle];
  [b setTitle: title];
  [b setTarget: target];
  [b setAction: action];
  return b;
}

/* ------------------------------------------------------------------ */

@interface INRecordPanel () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation INRecordPanel
{
  NSPanel *_panel;
  NSTableView *_templates;
  NSTextField *_summary;
  NSTextField *_instruments;
  NSTextField *_target, *_args, *_env, *_cwd, *_limit;
  NSTextField *_warning;
  NSArray *_list;
  BOOL _ok;
}

+ (GSPRecordingOptions *) runPanelWithTemplate: (NSString *)templateName
{
  INRecordPanel *p = [INRecordPanel new];
  return [p run: templateName];
}

- (void) build
{
  _list = [[GSPTemplate allTemplates] filteredArrayUsingPredicate:
    [NSPredicate predicateWithBlock: ^BOOL(GSPTemplate *t, NSDictionary *b) {
      return ![t.instrumentIdentifiers containsObject: GSPInstrumentSystemProfiler];
    }]];
  _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 720, 520)
    styleMask: NSTitledWindowMask | NSClosableWindowMask
      backing: NSBackingStoreBuffered defer: NO];
  [_panel setTitle: @"Choose a Profiling Template"];
  NSView *c = [_panel contentView];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame: NSMakeRect(16, 250, 240, 254)];
  [sv setHasVerticalScroller: YES];
  [sv setBorderType: NSBezelBorder];
  _templates = [[NSTableView alloc] initWithFrame: [[sv contentView] bounds]];
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier: @"name"];
  [[col headerCell] setStringValue: @"Template"];
  [col setWidth: 220];
  [col setEditable: NO];
  [_templates addTableColumn: col];
  [_templates setDataSource: self];
  [_templates setDelegate: self];
  [_templates setRowHeight: 26];
  [sv setDocumentView: _templates];
  [c addSubview: sv];

  NSTextField *title = make_label(@"", NSMakeRect(272, 470, 430, 30));
  [title setAlignment: NSLeftTextAlignment];
  [title setFont: [NSFont boldSystemFontOfSize: 16]];
  [title setTag: 1];
  [c addSubview: title];
  _summary = make_label(@"", NSMakeRect(272, 400, 430, 64));
  [_summary setAlignment: NSLeftTextAlignment];
  [[_summary cell] setWraps: YES];
  [c addSubview: _summary];
  _instruments = make_label(@"", NSMakeRect(272, 250, 430, 140));
  [_instruments setAlignment: NSLeftTextAlignment];
  [[_instruments cell] setWraps: YES];
  [_instruments setFont: [INTheme smallFont]];
  [c addSubview: _instruments];

  CGFloat y = 206;
  [c addSubview: make_label(@"Target:", NSMakeRect(16, y, 110, 22))];
  _target = make_field(NSMakeRect(132, y, 470, 24));
  [_target setTarget: self];
  [_target setAction: @selector(targetChanged:)];
  [c addSubview: _target];
  [c addSubview: make_button(@"Choose…", NSMakeRect(608, y - 2, 96, 28), self, @selector(chooseTarget:))];
  y -= 32;
  [c addSubview: make_label(@"Arguments:", NSMakeRect(16, y, 110, 22))];
  _args = make_field(NSMakeRect(132, y, 572, 24));
  [c addSubview: _args];
  y -= 32;
  [c addSubview: make_label(@"Environment:", NSMakeRect(16, y, 110, 22))];
  _env = make_field(NSMakeRect(132, y, 572, 24));
  [[_env cell] setPlaceholderString: @"NAME=value NAME2=value2"];
  [c addSubview: _env];
  y -= 32;
  [c addSubview: make_label(@"Directory:", NSMakeRect(16, y, 110, 22))];
  _cwd = make_field(NSMakeRect(132, y, 572, 24));
  [[_cwd cell] setPlaceholderString: @"Working directory (default: the target's folder)"];
  [c addSubview: _cwd];
  y -= 32;
  [c addSubview: make_label(@"Time limit (s):", NSMakeRect(16, y, 110, 22))];
  _limit = make_field(NSMakeRect(132, y, 80, 24));
  [[_limit cell] setPlaceholderString: @"none"];
  [c addSubview: _limit];

  _warning = make_label(@"", NSMakeRect(220, y, 484, 24));
  [_warning setAlignment: NSLeftTextAlignment];
  [_warning setTextColor: [INTheme leakColor]];
  [_warning setFont: [INTheme smallFont]];
  [c addSubview: _warning];

  NSButton *cancel = make_button(@"Cancel", NSMakeRect(500, 14, 96, 30), self, @selector(cancel:));
  [cancel setKeyEquivalent: @"\e"];
  [c addSubview: cancel];
  NSButton *rec = make_button(@"Record", NSMakeRect(608, 14, 96, 30), self, @selector(record:));
  [rec setKeyEquivalent: @"\r"];
  [c addSubview: rec];

  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [_target setStringValue: [d stringForKey: @"INLastTarget"] ?: @""];
  [_args setStringValue: [d stringForKey: @"INLastArguments"] ?: @""];
  [_env setStringValue: [d stringForKey: @"INLastEnvironment"] ?: @""];
  [_cwd setStringValue: [d stringForKey: @"INLastDirectory"] ?: @""];
  [_panel center];
}

- (GSPRecordingOptions *) run: (NSString *)templateName
{
  [self build];
  NSString *want = templateName ?: [[NSUserDefaults standardUserDefaults]
                                     stringForKey: @"INLastTemplate"] ?: @"Time Profiler";
  NSUInteger idx = 0;
  for (NSUInteger i = 0; i < [_list count]; i++)
    if ([[[_list objectAtIndex: i] name] isEqual: want])
      idx = i;
  [_templates reloadData];
  [_templates selectRowIndexes: [NSIndexSet indexSetWithIndex: idx] byExtendingSelection: NO];
  [self showTemplate];
  [self targetChanged: nil];
  [NSApp runModalForWindow: _panel];
  [_panel orderOut: nil];
  if (!_ok)
    return nil;

  GSPTemplate *t = [_list objectAtIndex: (NSUInteger)MAX(0, [_templates selectedRow])];
  GSPRecordingOptions *o = [GSPRecordingOptions new];
  o.templateName = t.name;
  o.instrumentIdentifiers = t.instrumentIdentifiers;
  o.executablePath = [[_target stringValue] stringByExpandingTildeInPath];
  NSString *args = [[_args stringValue] stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceCharacterSet]];
  o.arguments = [args length] ? [self splitArguments: args] : [NSArray array];
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  for (NSString *kv in [self splitArguments: [_env stringValue]])
    {
      NSRange eq = [kv rangeOfString: @"="];
      if (eq.location != NSNotFound && eq.location > 0)
        [env setObject: [kv substringFromIndex: eq.location + 1]
                forKey: [kv substringToIndex: eq.location]];
    }
  o.environment = env;
  NSString *cwd = [[_cwd stringValue] stringByExpandingTildeInPath];
  o.workingDirectory = [cwd length] ? cwd : [o.executablePath stringByDeletingLastPathComponent];
  o.timeLimit = [_limit doubleValue];

  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  [d setObject: t.name forKey: @"INLastTemplate"];
  [d setObject: [_target stringValue] forKey: @"INLastTarget"];
  [d setObject: [_args stringValue] forKey: @"INLastArguments"];
  [d setObject: [_env stringValue] forKey: @"INLastEnvironment"];
  [d setObject: [_cwd stringValue] forKey: @"INLastDirectory"];
  return o;
}

/* Shell-like splitting with single and double quotes. */
- (NSArray *) splitArguments: (NSString *)s
{
  NSMutableArray *out = [NSMutableArray array];
  NSMutableString *cur = nil;
  unichar quote = 0;
  for (NSUInteger i = 0; i < [s length]; i++)
    {
      unichar c = [s characterAtIndex: i];
      if (quote)
        {
          if (c == quote)
            quote = 0;
          else
            [cur appendFormat: @"%C", c];
          continue;
        }
      if (c == '"' || c == '\'')
        {
          quote = c;
          if (cur == nil)
            cur = [NSMutableString string];
          continue;
        }
      if (c == ' ' || c == '\t')
        {
          if (cur)
            [out addObject: cur];
          cur = nil;
          continue;
        }
      if (cur == nil)
        cur = [NSMutableString string];
      [cur appendFormat: @"%C", c];
    }
  if (cur)
    [out addObject: cur];
  return out;
}

- (void) showTemplate
{
  NSInteger row = [_templates selectedRow];
  if (row < 0)
    return;
  GSPTemplate *t = [_list objectAtIndex: (NSUInteger)row];
  [[[_panel contentView] viewWithTag: 1] setStringValue: t.name];
  [_summary setStringValue: t.summary];
  NSMutableString *s = [NSMutableString stringWithString: @"Instruments:\n"];
  for (NSString *ident in t.instrumentIdentifiers)
    {
      GSPInstrument *i = [GSPInstrument instrumentWithIdentifier: ident];
      [s appendFormat: @"• %@ — %@\n", i.name, i.summary];
    }
  if ([t.instrumentIdentifiers count] == 0)
    [s appendString: @"(none: the trace records only thread and image information)"];
  [_instruments setStringValue: s];
}

- (void) tableViewSelectionDidChange: (NSNotification *)n
{
  [self showTemplate];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)tv
{
  return (NSInteger)[_list count];
}

- (id) tableView: (NSTableView *)tv objectValueForTableColumn: (NSTableColumn *)c row: (NSInteger)row
{
  return [[_list objectAtIndex: (NSUInteger)row] name];
}

- (void) targetChanged: (id)sender
{
  NSString *path = [[_target stringValue] stringByExpandingTildeInPath];
  NSString *problem = [path length] ? [GSPRecorder preloadProblemForExecutable: path] : nil;
  [_warning setStringValue: problem ?: @""];
}

- (void) chooseTarget: (id)sender
{
  NSOpenPanel *op = [NSOpenPanel openPanel];
  [op setTitle: @"Choose Target"];
  [op setCanChooseFiles: YES];
  [op setCanChooseDirectories: NO];
  [op setAllowsMultipleSelection: NO];
  NSString *start = [[_target stringValue] length]
    ? [[[_target stringValue] stringByExpandingTildeInPath] stringByDeletingLastPathComponent]
    : NSHomeDirectory();
  if ([op runModalForDirectory: start file: nil types: nil] != NSOKButton)
    return;
  NSString *path = [op filename];
  /* An .app bundle: record its executable. */
  if ([[path pathExtension] isEqual: @"app"])
    {
      NSBundle *b = [NSBundle bundleWithPath: path];
      if ([b executablePath])
        path = [b executablePath];
    }
  [_target setStringValue: path];
  [self targetChanged: nil];
}

- (void) cancel: (id)sender
{
  _ok = NO;
  [NSApp stopModal];
}

- (void) record: (id)sender
{
  NSString *path = [[_target stringValue] stringByExpandingTildeInPath];
  NSString *problem = [path length] ? [GSPRecorder preloadProblemForExecutable: path]
                                    : @"Choose the program to record.";
  if (problem != nil)
    {
      NSRunAlertPanel(@"Cannot Record This Target", @"%@", @"OK", nil, nil, problem);
      return;
    }
  _ok = YES;
  [NSApp stopModal];
}

@end

/* ------------------------------------------------------------------ */

@interface INAttachPanel () <NSTableViewDataSource>
@end

@implementation INAttachPanel
{
  NSPanel *_panel;
  NSTableView *_table;
  NSTextField *_status;
  NSMutableArray *_procs;   /* NSDictionary pid, name, exe */
  NSTextField *_duration;
  BOOL _ok;
}

+ (GSPRecordingOptions *) runPanel
{
  return [[INAttachPanel new] run];
}

- (void) refresh: (id)sender
{
  NSFileManager *fm = [NSFileManager defaultManager];
  uid_t me = getuid();
  [_procs removeAllObjects];
  for (NSString *name in [fm contentsOfDirectoryAtPath: @"/proc" error: NULL])
    {
      int pid = [name intValue];
      if (pid <= 0 || pid == getpid())
        continue;
      struct stat st;
      NSString *dir = [@"/proc" stringByAppendingPathComponent: name];
      if (stat([dir fileSystemRepresentation], &st) != 0 || st.st_uid != me)
        continue;
      NSString *comm = [[NSString stringWithContentsOfFile:
        [dir stringByAppendingPathComponent: @"comm"]]
        stringByTrimmingCharactersInSet: [NSCharacterSet newlineCharacterSet]];
      NSString *exe = [fm pathContentOfSymbolicLinkAtPath: [dir stringByAppendingPathComponent: @"exe"]];
      if (comm == nil)
        continue;
      [_procs addObject: [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithInt: pid], @"pid", comm, @"name", exe ?: @"", @"exe", nil]];
    }
  [_procs sortUsingComparator: ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [[a objectForKey: @"name"] caseInsensitiveCompare: [b objectForKey: @"name"]];
  }];
  [_table reloadData];
}

- (GSPRecordingOptions *) run
{
  _procs = [NSMutableArray array];
  _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 640, 480)
    styleMask: NSTitledWindowMask | NSClosableWindowMask backing: NSBackingStoreBuffered defer: NO];
  [_panel setTitle: @"Attach to Process"];
  NSView *c = [_panel contentView];

  NSScrollView *sv = [[NSScrollView alloc] initWithFrame: NSMakeRect(16, 120, 608, 344)];
  [sv setHasVerticalScroller: YES];
  [sv setBorderType: NSBezelBorder];
  _table = [[NSTableView alloc] initWithFrame: [[sv contentView] bounds]];
  NSArray *cols = [NSArray arrayWithObjects: @"pid", @"name", @"exe", nil];
  NSArray *titles = [NSArray arrayWithObjects: @"PID", @"Process", @"Executable", nil];
  CGFloat widths[] = { 70, 160, 360 };
  for (NSUInteger i = 0; i < 3; i++)
    {
      NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier: [cols objectAtIndex: i]];
      [[col headerCell] setStringValue: [titles objectAtIndex: i]];
      [col setWidth: widths[i]];
      [col setEditable: NO];
      [_table addTableColumn: col];
    }
  [_table setDataSource: self];
  [sv setDocumentView: _table];
  [c addSubview: sv];

  _status = make_label(@"", NSMakeRect(16, 60, 608, 52));
  [_status setAlignment: NSLeftTextAlignment];
  [[_status cell] setWraps: YES];
  [_status setFont: [INTheme smallFont]];
  int paranoid = [GSPRecorder perfEventParanoid];
  NSString *helper = [GSPRecorder installedHelperPath];
  if ([GSPRecorder canAttachWithoutPrivileges])
    [_status setStringValue: [NSString stringWithFormat:
      @"kernel.perf_event_paranoid is %d: your own processes can be sampled without a password (user-space stacks only).",
      paranoid]];
  else if (helper)
    [_status setStringValue: @"The profiling helper is installed; you will be asked for a password when recording starts. Kernel stacks are included."];
  else
    [_status setStringValue: [NSString stringWithFormat:
      @"kernel.perf_event_paranoid is %d and the profiling helper is not installed. Use "Install Profiling Helper…" in the Instruments menu first.",
      paranoid]];
  [c addSubview: _status];

  [c addSubview: make_label(@"Duration (s):", NSMakeRect(16, 22, 100, 22))];
  _duration = make_field(NSMakeRect(120, 22, 70, 24));
  [[_duration cell] setPlaceholderString: @"until stop"];
  [c addSubview: _duration];

  [c addSubview: make_button(@"Refresh", NSMakeRect(300, 16, 96, 30), self, @selector(refresh:))];
  NSButton *cancel = make_button(@"Cancel", NSMakeRect(410, 16, 96, 30), self, @selector(cancel:));
  [cancel setKeyEquivalent: @"\e"];
  [c addSubview: cancel];
  NSButton *attach = make_button(@"Attach", NSMakeRect(518, 16, 106, 30), self, @selector(attach:));
  [attach setKeyEquivalent: @"\r"];
  [c addSubview: attach];

  [self refresh: nil];
  [_panel center];
  [NSApp runModalForWindow: _panel];
  [_panel orderOut: nil];
  NSInteger row = [_table selectedRow];
  if (!_ok || row < 0)
    return nil;
  NSDictionary *p = [_procs objectAtIndex: (NSUInteger)row];
  GSPRecordingOptions *o = [GSPRecordingOptions new];
  o.attachPID = [[p objectForKey: @"pid"] intValue];
  o.executablePath = [p objectForKey: @"exe"];
  o.templateName = @"System Time Profiler";
  o.instrumentIdentifiers = [NSArray arrayWithObject: GSPInstrumentSystemProfiler];
  o.timeLimit = [_duration doubleValue];
  return o;
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)tv
{
  return (NSInteger)[_procs count];
}

- (id) tableView: (NSTableView *)tv objectValueForTableColumn: (NSTableColumn *)c row: (NSInteger)row
{
  return [[_procs objectAtIndex: (NSUInteger)row] objectForKey: [c identifier]];
}

- (void) cancel: (id)sender
{
  _ok = NO;
  [NSApp stopModal];
}

- (void) attach: (id)sender
{
  if ([_table selectedRow] < 0)
    return;
  _ok = YES;
  [NSApp stopModal];
}

@end
