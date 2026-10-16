#import "INAppController.h"
#import "INTraceWindowController.h"
#import "INRecordPanel.h"
#import "INTimelineView.h"
#import <GSPerformance/GSPerformance.h>

@implementation INAppController
{
  NSMutableArray *_windows;
  BOOL _openedAtLaunch;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _windows = [NSMutableArray array];
      [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(windowClosed:) name: @"INTraceWindowClosed" object: nil];
    }
  return self;
}

static NSMenuItem *
add_item(NSMenu *menu, NSString *title, SEL action, NSString *key, id target)
{
  NSMenuItem *i = (NSMenuItem *)[menu addItemWithTitle: title action: action keyEquivalent: key ?: @""];
  if (target)
    [i setTarget: target];
  return i;
}

- (void) buildMenus
{
  NSMenu *main = [[NSMenu alloc] initWithTitle: @"Instruments"];
  NSMenuItem *item;

  NSMenu *app = [[NSMenu alloc] initWithTitle: @"Instruments"];
  add_item(app, @"About Instruments", @selector(showAbout:), nil, self);
  add_item(app, @"Install Profiling Helper…", @selector(installHelper:), nil, self);
  add_item(app, @"Hide", @selector(hide:), @"h", NSApp);
  add_item(app, @"Quit Instruments", @selector(terminate:), @"q", NSApp);
  item = add_item(main, @"Instruments", NULL, nil, nil);
  [main setSubmenu: app forItem: item];

  NSMenu *file = [[NSMenu alloc] initWithTitle: @"File"];
  add_item(file, @"New Recording…", @selector(newRecording:), @"n", self);
  add_item(file, @"Open…", @selector(openTrace:), @"o", self);
  NSMenu *recent = [[NSMenu alloc] initWithTitle: @"Open Recent"];
  for (NSString *path in [[NSUserDefaults standardUserDefaults] arrayForKey: @"INRecentTraces"])
    {
      NSMenuItem *r = add_item(recent, [path lastPathComponent], @selector(openRecent:), nil, self);
      [r setRepresentedObject: path];
    }
  item = add_item(file, @"Open Recent", NULL, nil, nil);
  [file setSubmenu: recent forItem: item];
  add_item(file, @"Attach to Process…", @selector(attachToProcess:), nil, self);
  add_item(file, @"Save As…", @selector(saveTraceAs:), @"S", nil);
  add_item(file, @"Export…", @selector(exportTrace:), @"e", nil);
  add_item(file, @"Close", @selector(performClose:), @"w", nil);
  item = add_item(main, @"File", NULL, nil, nil);
  [main setSubmenu: file forItem: item];

  NSMenu *rec = [[NSMenu alloc] initWithTitle: @"Recording"];
  add_item(rec, @"Record", @selector(startRecording:), @"r", nil);
  add_item(rec, @"Stop", @selector(stopRecording:), @".", nil);
  add_item(rec, @"Check for Leaks Now", @selector(checkForLeaksNow:), nil, nil);
  item = add_item(main, @"Recording", NULL, nil, nil);
  [main setSubmenu: rec forItem: item];

  NSMenu *view = [[NSMenu alloc] initWithTitle: @"View"];
  add_item(view, @"Zoom In", @selector(zoomIn:), @"+", nil);
  add_item(view, @"Zoom Out", @selector(zoomOut:), @"-", nil);
  add_item(view, @"Zoom to Fit", @selector(zoomToFit:), @"0", nil);
  add_item(view, @"Zoom to Selection", @selector(zoomToSelection:), nil, nil);
  add_item(view, @"Clear Inspection Range", @selector(clearSelection), nil, nil);
  item = add_item(main, @"View", NULL, nil, nil);
  [main setSubmenu: view forItem: item];

  NSMenu *windows = [[NSMenu alloc] initWithTitle: @"Windows"];
  add_item(windows, @"Minimize", @selector(performMiniaturize:), @"m", nil);
  item = add_item(main, @"Windows", NULL, nil, nil);
  [main setSubmenu: windows forItem: item];
  [NSApp setWindowsMenu: windows];

  [NSApp setMainMenu: main];
}

- (void) applicationWillFinishLaunching: (NSNotification *)n
{
  [self buildMenus];
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  /* Automation (tests, screenshots): -INRecordTarget path
     [-INRecordTemplate name] [-INRecordArguments "a b"] [-INRecordTimeLimit s] */
  NSString *target = [d stringForKey: @"INRecordTarget"];
  if (target != nil)
    {
      GSPRecordingOptions *o = [GSPRecordingOptions new];
      GSPTemplate *t = [GSPTemplate templateNamed:
        [d stringForKey: @"INRecordTemplate"] ?: @"Time Profiler"];
      o.templateName = t.name;
      o.instrumentIdentifiers = t.instrumentIdentifiers;
      o.executablePath = target;
      NSString *args = [d stringForKey: @"INRecordArguments"];
      o.arguments = [args length] ? [args componentsSeparatedByString: @" "] : [NSArray array];
      o.timeLimit = [d doubleForKey: @"INRecordTimeLimit"];
      [self startRecordingWithOptions: o];
      return;
    }
  NSString *open = [d stringForKey: @"INOpenTrace"];
  if (open != nil)
    {
      [self openTraceAtPath: open];
      return;
    }
  if (!_openedAtLaunch)
    [self performSelector: @selector(newRecording:) withObject: nil afterDelay: 0];
}

- (BOOL) application: (NSApplication *)app openFile: (NSString *)file
{
  _openedAtLaunch = YES;
  return [self openTraceAtPath: file];
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)app
{
  return NO;
}

- (void) windowClosed: (NSNotification *)n
{
  [_windows removeObject: [n object]];
}

- (void) remember: (NSString *)path
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
  NSMutableArray *recent = [[d arrayForKey: @"INRecentTraces"] mutableCopy] ?: [NSMutableArray array];
  [recent removeObject: path];
  [recent insertObject: path atIndex: 0];
  while ([recent count] > 10)
    [recent removeLastObject];
  [d setObject: recent forKey: @"INRecentTraces"];
}

- (BOOL) openTraceAtPath: (NSString *)path
{
  NSError *error = nil;
  /* accept a file inside the bundle too */
  if (![[path pathExtension] isEqual: @"gstrace"]
      && [[[path stringByDeletingLastPathComponent] pathExtension] isEqual: @"gstrace"])
    path = [path stringByDeletingLastPathComponent];
  INTraceWindowController *wc = [[INTraceWindowController alloc] initWithTracePath: path
                                                                             error: &error];
  if (wc == nil)
    {
      NSRunAlertPanel(@"Cannot Open Trace", @"%@", @"OK", nil, nil,
                      [error localizedDescription] ?: path);
      return NO;
    }
  [_windows addObject: wc];
  [wc showWindow: self];
  [self remember: path];
  return YES;
}

- (void) openTrace: (id)sender
{
  NSOpenPanel *op = [NSOpenPanel openPanel];
  [op setTitle: @"Open Trace"];
  [op setCanChooseDirectories: YES];
  [op setCanChooseFiles: YES];
  [op setAllowsMultipleSelection: NO];
  if ([op runModalForDirectory: NSHomeDirectory() file: nil
                         types: [NSArray arrayWithObject: @"gstrace"]] == NSOKButton)
    [self openTraceAtPath: [op filename]];
}

- (void) openRecent: (id)sender
{
  [self openTraceAtPath: [sender representedObject]];
}

- (void) startRecordingWithOptions: (GSPRecordingOptions *)o
{
  INTraceWindowController *wc = [[INTraceWindowController alloc] initWithRecordingOptions: o];
  [_windows addObject: wc];
  [wc showWindow: self];
  [wc startRecording: nil];
}

- (void) newRecording: (id)sender
{
  GSPRecordingOptions *o = [INRecordPanel runPanelWithTemplate: nil];
  if (o != nil)
    [self startRecordingWithOptions: o];
}

- (void) attachToProcess: (id)sender
{
  GSPRecordingOptions *o = [INAttachPanel runPanel];
  if (o != nil)
    [self startRecordingWithOptions: o];
}

- (void) showAbout: (id)sender
{
  NSRunAlertPanel(@"GNUstep Instruments",
    @"Version 0.1.0\n\nA performance analysis tool for GNUstep applications: Time Profiler, Hangs, Points of Interest, os_log, Allocations, Leaks and Zombies.\n\nAgent: %@",
    @"OK", nil, nil, [GSPRecorder agentLibraryPath] ?: @"not found");
}

- (void) installHelper: (id)sender
{
  NSString *helper = [GSPRecorder bundledHelperPath];
  if (helper == nil)
    {
      NSRunAlertPanel(@"Profiling Helper Not Found",
        @"This build of Instruments does not include gstrace-helper.", @"OK", nil, nil);
      return;
    }
  NSString *installed = [GSPRecorder installedHelperPath];
  NSInteger r = NSRunAlertPanel(installed ? @"Reinstall Profiling Helper?" : @"Install Profiling Helper?",
    @"The profiling helper lets Instruments attach to running processes and record kernel stacks. "
    @"It is installed as %@ with a polkit policy, and you will be asked for an administrator password.\n\n"
    @"Alternatively, set kernel.perf_event_paranoid to 2 or lower to sample your own processes without it.",
    @"Install", @"Cancel", nil, [GSPRecorder helperInstallLocation]);
  if (r != NSAlertDefaultReturn)
    return;

  /* Stage the files where root can read them (an AppImage mount is not
     readable by root) and nobody else can change them, then run the
     installer through pkexec.  */
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  NSString *staging = [GSPRecorder stageHelperForInstall: &error];
  if (staging == nil)
    {
      NSRunAlertPanel(@"Installation Failed", @"%@", @"OK", nil, nil, [error localizedDescription]);
      return;
    }
  NSTask *task = [NSTask new];
  [task setLaunchPath: @"/usr/bin/pkexec"];
  [task setArguments: [NSArray arrayWithObjects:
    [staging stringByAppendingPathComponent: @"gstrace-helper"], @"install",
    @"--source", staging, nil]];
  @try
    {
      [task launch];
      [task waitUntilExit];
    }
  @catch (NSException *e)
    {
      NSRunAlertPanel(@"Installation Failed", @"%@", @"OK", nil, nil, [e reason]);
      return;
    }
  [fm removeItemAtPath: staging error: NULL];
  if ([task terminationStatus] == 0 && [GSPRecorder installedHelperPath])
    NSRunAlertPanel(@"Profiling Helper Installed", @"You can now attach to running processes.",
                    @"OK", nil, nil);
  else
    NSRunAlertPanel(@"Installation Failed",
      @"The helper was not installed (authentication cancelled or pkexec unavailable).",
      @"OK", nil, nil);
}

@end
