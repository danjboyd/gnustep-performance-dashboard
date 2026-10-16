#import "PDAppController.h"
#import "PDTraceWindowController.h"
#import "PDRecordPanel.h"
#import "PDTimelineView.h"
#import <GSPerformance/GSPerformance.h>

#if !defined(_WIN32)
#  include <fcntl.h>
#  include <signal.h>
#  include <string.h>
#  include <unistd.h>
#endif

@implementation PDAppController
{
  NSMutableArray *_windows;
  BOOL _openedAtLaunch;
  NSFileHandle *_terminationPipe;
}

- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _windows = [NSMutableArray array];
      [[NSNotificationCenter defaultCenter] addObserver: self
        selector: @selector(windowClosed:) name: @"PDTraceWindowClosed" object: nil];
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
  NSMenu *main = [[NSMenu alloc] initWithTitle: @"Performance Dashboard"];
  NSMenuItem *item;

  NSMenu *app = [[NSMenu alloc] initWithTitle: @"Performance Dashboard"];
  add_item(app, @"About Performance Dashboard", @selector(showAbout:), nil, self);
#if !defined(_WIN32)
  /* Windows attaches by injecting the agent; no helper there */
  add_item(app, @"Install Profiling Helper…", @selector(installHelper:), nil, self);
#endif
  add_item(app, @"Hide", @selector(hide:), @"h", NSApp);
  add_item(app, @"Quit Performance Dashboard", @selector(terminate:), @"q", NSApp);
  item = add_item(main, @"Performance Dashboard", NULL, nil, nil);
  [main setSubmenu: app forItem: item];

  NSMenu *file = [[NSMenu alloc] initWithTitle: @"File"];
  add_item(file, @"New Recording…", @selector(newRecording:), @"n", self);
  add_item(file, @"Open…", @selector(openTrace:), @"o", self);
  NSMenu *recent = [[NSMenu alloc] initWithTitle: @"Open Recent"];
  for (NSString *path in [[NSUserDefaults standardUserDefaults] arrayForKey: @"PDRecentTraces"])
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

#if !defined(_WIN32)
/* libs-back's SIGTERM handler calls -[NSApp terminate:] inside the signal
   handler, which is not async-signal-safe: with the Sombre theme it
   recurses in gnustep-base until the stack overflows.  Once the backend
   is up, SIGTERM only writes to a pipe, and the run loop terminates the
   app as Quit does.  */
static int termination_fds[2] = { -1, -1 };

static void
termination_signal(int sig)
{
  char c = 0;
  ssize_t n = write(termination_fds[1], &c, 1);
  (void)n;
}

- (void) installTerminationHandler
{
  struct sigaction sa;

  if (pipe(termination_fds) != 0)
    return;
  fcntl(termination_fds[0], F_SETFD, FD_CLOEXEC);
  fcntl(termination_fds[1], F_SETFD, FD_CLOEXEC);
  fcntl(termination_fds[1], F_SETFL, O_NONBLOCK);
  _terminationPipe = [[NSFileHandle alloc] initWithFileDescriptor: termination_fds[0]
                                                    closeOnDealloc: YES];
  [[NSNotificationCenter defaultCenter] addObserver: self
    selector: @selector(terminationRequested:)
        name: NSFileHandleDataAvailableNotification object: _terminationPipe];
  /* also while a modal panel or a mouse drag runs the loop */
  [_terminationPipe waitForDataInBackgroundAndNotifyForModes:
    [NSArray arrayWithObjects: NSDefaultRunLoopMode, NSModalPanelRunLoopMode,
             NSEventTrackingRunLoopMode, nil]];
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = termination_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGTERM, &sa, NULL);
}

- (void) terminationRequested: (NSNotification *)n
{
  [NSApp terminate: self];
}
#endif

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
  NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
#if !defined(_WIN32)
  [self installTerminationHandler];
#endif
  /* Automation (tests, screenshots): -PDRecordTarget path
     [-PDRecordTemplate name] [-PDRecordArguments "a b"] [-PDRecordTimeLimit s] */
  NSString *target = [d stringForKey: @"PDRecordTarget"];
  if (target != nil)
    {
      GSPRecordingOptions *o = [GSPRecordingOptions new];
      GSPTemplate *t = [GSPTemplate templateNamed:
        [d stringForKey: @"PDRecordTemplate"] ?: @"Time Profiler"];
      o.templateName = t.name;
      o.instrumentIdentifiers = t.instrumentIdentifiers;
      o.executablePath = target;
      NSString *args = [d stringForKey: @"PDRecordArguments"];
      o.arguments = [args length] ? [args componentsSeparatedByString: @" "] : [NSArray array];
      o.timeLimit = [d doubleForKey: @"PDRecordTimeLimit"];
      [self startRecordingWithOptions: o];
      return;
    }
  NSString *open = [d stringForKey: @"PDOpenTrace"];
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

/* After this notification libs-gui closes every window and frees NSApp.
   With the Sombre theme (libs-gui 0.32.0) that close cascades through the
   image cache windows (GSCacheW) and autorelease pools until the stack
   overflows.  Nothing needs closing when the process is about to end, so
   finish here: stop recordings so their traces are complete, save the
   defaults and exit.  */
- (void) applicationWillTerminate: (NSNotification *)n
{
  for (PDTraceWindowController *wc in [_windows copy])
    [wc finishRecording];
  [[NSUserDefaults standardUserDefaults] synchronize];
  exit(0);
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
  NSMutableArray *recent = [[d arrayForKey: @"PDRecentTraces"] mutableCopy] ?: [NSMutableArray array];
  [recent removeObject: path];
  [recent insertObject: path atIndex: 0];
  while ([recent count] > 10)
    [recent removeLastObject];
  [d setObject: recent forKey: @"PDRecentTraces"];
}

- (BOOL) openTraceAtPath: (NSString *)path
{
  NSError *error = nil;
  /* accept a file inside the bundle too */
  if (![[path pathExtension] isEqual: @"gstrace"]
      && [[[path stringByDeletingLastPathComponent] pathExtension] isEqual: @"gstrace"])
    path = [path stringByDeletingLastPathComponent];
  PDTraceWindowController *wc = [[PDTraceWindowController alloc] initWithTracePath: path
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
  PDTraceWindowController *wc = [[PDTraceWindowController alloc] initWithRecordingOptions: o];
  [_windows addObject: wc];
  [wc showWindow: self];
  [wc startRecording: nil];
}

- (void) newRecording: (id)sender
{
  GSPRecordingOptions *o = [PDRecordPanel runPanelWithTemplate: nil];
  if (o != nil)
    [self startRecordingWithOptions: o];
}

- (void) attachToProcess: (id)sender
{
  GSPRecordingOptions *o = [PDAttachPanel runPanel];
  if (o != nil)
    [self startRecordingWithOptions: o];
}

- (void) showAbout: (id)sender
{
  NSRunAlertPanel(@"Performance Dashboard",
    @"Version 0.1.0\n\nA performance analysis tool for GNUstep applications: Time Profiler, Hangs, Points of Interest, os_log, Allocations, Leaks and Zombies.\n\nAgent: %@",
    @"OK", nil, nil, [GSPRecorder agentLibraryPath] ?: @"not found");
}

- (void) installHelper: (id)sender
{
  NSString *helper = [GSPRecorder bundledHelperPath];
  if (helper == nil)
    {
      NSRunAlertPanel(@"Profiling Helper Not Found",
        @"This build of Performance Dashboard does not include gstrace-helper.", @"OK", nil, nil);
      return;
    }
  NSString *installed = [GSPRecorder installedHelperPath];
  NSInteger r = NSRunAlertPanel(installed ? @"Reinstall Profiling Helper?" : @"Install Profiling Helper?",
    @"The profiling helper lets Performance Dashboard attach to running processes and record kernel stacks. "
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
