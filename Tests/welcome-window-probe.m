/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Real AppKit/controller checks; run only through the private headless harness.
   The delegate is a spy: no attach or target launch is performed here. */
#import <AppKit/AppKit.h>
#import "Dashboard/PDWelcomeWindowController.h"
#import "Dashboard/PDAppController.h"
#import "TRBoxView.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define CHECK(condition, label) do { checks++; if (!(condition)) { \
  fprintf(stderr, "FAIL %s\n", label); fflush(NULL); _Exit(1); } } while (0)

@interface PDWelcomeWindowController (ToolTipProbe)
- (NSString *) tableView: (NSTableView *)tableView toolTipForCell: (NSCell *)cell
                   rect: (NSRect *)rect tableColumn: (NSTableColumn *)column
                    row: (NSInteger)row mouseLocation: (NSPoint)location;
@end

@interface WelcomeProbeProvider : NSObject <PDWelcomeTargetProvider>
@property (nonatomic, copy) NSArray *snapshot;
@property (nonatomic, strong) NSMutableDictionary *identities;
@end
@implementation WelcomeProbeProvider
- (NSArray *) runningProcesses { return _snapshot; }
- (NSString *) currentIdentityForPID: (int)pid { return [_identities objectForKey: @(pid)]; }
- (NSString *) attachProblemForProcess: (PDWelcomeProcess *)p { return nil; }
- (NSString *) executableForPath: (NSString *)path { return path; }
- (NSString *) launchProblemForExecutable: (NSString *)path { return nil; }
- (NSString *) templateProblemForTemplate: (GSPTemplate *)t mode: (PDWelcomeTargetMode)mode
{
  if (mode == PDWelcomeAttach && ![t.name isEqual: @"System Time Profiler"])
    return @"Not available when attaching on Linux";
  if (mode == PDWelcomeLaunch && [t.name isEqual: @"System Time Profiler"])
    return @"System Time Profiler requires attaching to a running process.";
  return nil;
}
@end

@interface WelcomeProbeDelegate : NSObject
@property (nonatomic, strong) GSPRecordingOptions *recorded;
@end
@implementation WelcomeProbeDelegate
- (NSSet *) activeRecordingPIDs { return [NSSet setWithObject: @43]; }
- (void) startRecordingWithOptions: (GSPRecordingOptions *)options { self.recorded = options; }
- (BOOL) openTraceAtPath: (NSString *)path { return YES; }
- (void) openTrace: (id)sender {}
@end

static PDWelcomeProcess *target(int pid, NSString *name, PDGNUstepIdentity identity)
{
  PDWelcomeProcess *p = [PDWelcomeProcess new];
  p.pid = pid; p.name = name; p.identity = [NSString stringWithFormat: @"start-%d", pid];
  p.executablePath = [@"/apps" stringByAppendingPathComponent: name];
  p.GNUstepIdentity = identity;
  return p;
}
static NSInteger rowForPID(NSTableView *table, int pid)
{
  NSTableColumn *column = [table tableColumnWithIdentifier: @"pid"];
  for (NSInteger i = 0; i < [table numberOfRows]; i++)
    if ([[[table dataSource] tableView: table objectValueForTableColumn: column row: i] intValue] == pid)
      return i;
  return -1;
}
int main(int argc, const char **argv)
{
  @autoreleasepool
    {
      CHECK(argc == 3, "theme and screenshot arguments");
      NSDictionary *env = [[NSProcessInfo processInfo] environment];
      CHECK([[env objectForKey: @"DISPLAY"] isEqual: @":151"], "private display151 only");
      CHECK([[env objectForKey: @"GNUSTEP_HOME"] length] > 0, "private GNUstep home");
      NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
      NSString *homePrefix = [home stringByAppendingString: @"/"];
      NSString *defaultsRoot = [GSDefaultsRootForUser(NSUserName()) stringByResolvingSymlinksInPath];
      CHECK([defaultsRoot hasPrefix: homePrefix], "resolved defaults database stays inside private home");
      /* CI reuses its ephemeral home for both themes. Reset this probe's own
         domain so the first theme's persisted recents cannot seed the next. */
      NSUserDefaults *persistent = [NSUserDefaults standardUserDefaults];
      NSString *domainName = [[NSProcessInfo processInfo] processName];
      [persistent removePersistentDomainForName: domainName];
      [[NSUserDefaults standardUserDefaults] setObject: [NSString stringWithUTF8String: argv[1]] forKey: @"GSTheme"];
      [NSApplication sharedApplication];
      WelcomeProbeProvider *provider = [WelcomeProbeProvider new];
      PDWelcomeProcess *ready = target(41, @"Gorm", PDGNUstepYes);
      PDWelcomeProcess *owned = target(42, @"Other user", PDGNUstepYes);
      owned.unavailableReason = @"Owned by another user";
      PDWelcomeProcess *unknown = target(45, @"Unreadable", PDGNUstepUnknown);
      unknown.unavailableReason = @"Profiling helper not installed";
      provider.snapshot = @[ready, owned, target(43, @"Busy", PDGNUstepYes), target(44, @"Plain C", PDGNUstepNo), unknown];
      provider.identities = [NSMutableDictionary dictionary];
      for (PDWelcomeProcess *p in provider.snapshot)
        [provider.identities setObject: p.identity forKey: @(p.pid)];
      NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
      PDWelcomeHistory *history = [[PDWelcomeHistory alloc] initWithDefaults: defaults fileExists: ^BOOL(NSString *path) { return YES; }];
      PDWelcomeModel *model = [[PDWelcomeModel alloc] initWithProvider: provider history: history];
      WelcomeProbeDelegate *spy = [WelcomeProbeDelegate new];
      [[NSUserDefaults standardUserDefaults] setObject: @"Leaks" forKey: @"PDLastTemplate"];
      PDWelcomeWindowController *window = [[PDWelcomeWindowController alloc] initWithModel: model appController: (PDAppController *)spy];
      CHECK(window != nil, "TRLoader binds real owner/outlets");
      [window showForMode: PDWelcomeLaunch];
      CHECK([window valueForKey: @"refreshTimer"] == nil, "launch mode has no process timer");
      CHECK([[window.moreTemplates itemAtIndex: 0] isEnabled], "More placeholder keeps the popup looking enabled");
      NSMenuItem *systemItem = nil, *zombiesItem = nil;
      for (NSMenuItem *item in [window.moreTemplates itemArray])
        {
          if ([[item representedObject] isEqual: @"System Time Profiler"]) systemItem = item;
          if ([[item representedObject] isEqual: @"Zombies"]) zombiesItem = item;
        }
      CHECK([[systemItem title] rangeOfString: @"requires attaching"].location != NSNotFound,
        "disabled More template explains its reason in the title");
      CHECK([window.leaksTemplate state] == NSOnState, "last valid launch template restored");
      CHECK(![window.recordButton isEnabled], "Record disabled without a target");
      CHECK([window.cpuTemplate target] == window && [window.cpuTemplate action] == @selector(chooseTemplate:), "Trellis target/action binding");
      [window.targetPath setStringValue: @"/bin/sleep"];
      [window.argumentsField setStringValue: @"\"one two\" --value"];
      [window.environmentField setStringValue: @"WELCOME_TEST=\"one two\" EMPTY=\"\""];
      [window.directoryField setStringValue: @"/tmp"];
      [window.durationField setStringValue: @"1.5"];
      [window.intervalField setStringValue: @"2000"];
      [window chooseTemplate: window.allocationTemplate];
      [window fieldsChanged: nil];
      CHECK([window.recordButton isEnabled], "valid launch target enables Record");
      [window record: nil];
      CHECK(spy.recorded != nil && [spy.recorded.templateName isEqual: @"Allocations"], "Record emits chosen template");
      CHECK(([spy.recorded.arguments isEqual: @[@"one two", @"--value"]]), "existing argument splitting preserved");
      CHECK([[spy.recorded.environment objectForKey: @"EMPTY"] isEqual: @""], "empty environment preserved");
      CHECK([[spy.recorded.environment objectForKey: @"WELCOME_TEST"] isEqual: @"one two"], "quoted environment preserved");
      CHECK(spy.recorded.timeLimit == 1.5 && spy.recorded.sampleIntervalMicroseconds == 2000, "advanced timing options");
      CHECK(![[window window] isVisible], "Record dismisses welcome window");
      [window chooseAttach: window.attachMode];
      CHECK(![zombiesItem isEnabled] && [[zombiesItem title] rangeOfString: @"Not available when attaching on Linux"].location != NSNotFound,
        "attach More list shows disabled reasons");
      CHECK([window valueForKey: @"refreshTimer"] != nil, "attach mode refreshes processes");
      NSTableView *table = (NSTableView *)[window.processScroll documentView];
      CHECK([table isKindOfClass: [NSTableView class]], "native process table");
      CHECK([table numberOfRows] == 3, "GNUstep filter shows confirmed identities only");
      CHECK(![window.allocationTemplate isEnabled], "unsupported attach template disabled");
      CHECK([[[window.moreTemplates selectedItem] title] isEqual: @"System Time Profiler"], "attach shows actual System template");
      CHECK(![window tableView: table shouldSelectRow: rowForPID(table, 42)], "other-user target disabled");
      CHECK(![window tableView: table shouldSelectRow: rowForPID(table, 43)], "own recorded target disabled");
      [table selectRowIndexes: [NSIndexSet indexSetWithIndex: (NSUInteger)rowForPID(table, 41)] byExtendingSelection: NO];
      [window tableViewSelectionDidChange: nil];
      CHECK([window.recordButton isEnabled], "ready attach target enables Record");
      spy.recorded = nil;
      [provider.identities setObject: @"reused-pid" forKey: @41];
      [window record: nil];
      CHECK(spy.recorded == nil && ![window.recordButton isEnabled], "PID reuse blocked at Record");
      CHECK([[window.summary stringValue] rangeOfString: @"exited or changed"].location != NSNotFound, "PID reuse reason visible");
      [window.search setStringValue: @"41"];
      [window filtersChanged: nil];
      CHECK([table numberOfRows] == 1, "PID search");
      [window.search setStringValue: @"gorm"];
      [window filtersChanged: nil];
      CHECK([table numberOfRows] == 1, "case-insensitive name search");
      [window.search setStringValue: @""];
      [window.processFilter selectItemAtIndex: 1];
      [window filtersChanged: nil];
      CHECK([table numberOfRows] == 5, "All processes includes non-GNUstep and unknown identities");
      NSTableColumn *pidColumn = [table tableColumnWithIdentifier: @"pid"];
      NSFont *pidFont = [[pidColumn dataCell] font] ?: [NSFont systemFontOfSize: [NSFont systemFontSize]];
      CGFloat pidWidth = [@"4194304" sizeWithAttributes: @{NSFontAttributeName: pidFont}].width;
      CHECK([pidColumn width] >= pidWidth + 16, "PID column fits seven digits in the active theme");
      NSString *unknownStatus = [window tableView: table objectValueForTableColumn:
        [table tableColumnWithIdentifier: @"status"] row: rowForPID(table, 45)];
      CHECK([unknownStatus hasPrefix: @"Profiling helper not installed; "]
        && [unknownStatus rangeOfString: @"GNUstep: unknown (memory map not readable)"].location != NSNotFound,
        "All processes labels unreadable memory maps explicitly");
      CHECK([[window tableView: table toolTipForCell: [pidColumn dataCell] rect: NULL
        tableColumn: pidColumn row: rowForPID(table, 45) mouseLocation: NSZeroPoint] isEqual: unknownStatus],
        "every row cell exposes the complete status tooltip");
      NSArray *savedSnapshot = provider.snapshot;
      provider.snapshot = @[target(45, @"Unreadable", PDGNUstepUnknown)];
      [window.processFilter selectItemAtIndex: 0];
      [window filtersChanged: nil];
      CHECK([table numberOfRows] == 0 && [[window.summary stringValue] rangeOfString:
        @"No GNUstep apps. Show all processes."].location != NSNotFound,
        "unreadable-only snapshot offers the All processes hint");
      NSFont *summaryFont = [window.summary font] ?: [NSFont systemFontOfSize: [NSFont systemFontSize]];
      CHECK([[window.summary stringValue] sizeWithAttributes: @{NSFontAttributeName: summaryFont}].width
        <= NSWidth([window.summary bounds]), "empty-filter hint fits one footer line");
      provider.snapshot = savedSnapshot;
      [window filtersChanged: nil];
      [window chooseLaunch: window.launchMode];
      CHECK([window valueForKey: @"refreshTimer"] == nil, "leaving attach stops process timer");
      CHECK([window.cpuTemplate state] == NSOnState, "launch radio restores a supported template");
      [window.showAdvanced setState: NSOnState];
      [window advancedChanged: nil];
      [[window window] setContentSize: NSMakeSize(500, 500)];
      [window.root layoutTrellis];
      NSRect recordFrame = [window.root convertRect: [window.recordButton bounds] fromView: window.recordButton];
      CHECK(NSContainsRect([window.root bounds], recordFrame), "footer remains inside narrow advanced window");
      NSScrollView *scroller = [window.advancedPane enclosingScrollView];
      CHECK(scroller != nil && [scroller hasVerticalScroller], "advanced options scroll");
      [window.intervalField scrollRectToVisible: [window.intervalField bounds]];
      CHECK(NSHeight([window.intervalField visibleRect]) > 0, "last advanced control reachable by scrolling");
      [window.showAtLaunch setState: NSOffState];
      [window launchPreferenceChanged: nil];
      CHECK(!history.showAtLaunch, "launch preference off");
      [window.showAtLaunch setState: NSOnState];
      [window launchPreferenceChanged: nil];
      CHECK(history.showAtLaunch, "launch preference on");
      GSPRecordingOptions *recent = [GSPRecordingOptions new];
      recent.executablePath = @"/apps/Gorm"; recent.templateName = @"System Time Profiler"; recent.attachPID = 41;
      [history noteTarget: recent mode: PDWelcomeAttach];
      [window showForMode: PDWelcomeLaunch];
      [window recentTarget: [[window.recentTargetsBox subviews] objectAtIndex: 0]];
      CHECK(model.mode == PDWelcomeAttach && [window valueForKey: @"refreshTimer"] != nil,
        "recent attach target starts process refresh");
      recent.executablePath = @"/bin/sleep"; recent.templateName = @"Time Profiler"; recent.attachPID = 0;
      [history noteTarget: recent mode: PDWelcomeLaunch];
      [window showForMode: PDWelcomeAttach];
      [window recentTarget: [[window.recentTargetsBox subviews] objectAtIndex: 0]];
      CHECK(model.mode == PDWelcomeLaunch && [window valueForKey: @"refreshTimer"] == nil,
        "recent launch target stops process refresh");
      [[window window] setContentSize: NSMakeSize(900, 680)];
      [window.root layoutTrellis];
      [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.15]];
      NSTask *capture = [NSTask new];
      [capture setLaunchPath: @"/usr/bin/import"];
      [capture setArguments: @[@"-display", @":151", @"-window", @"root", [NSString stringWithUTF8String: argv[2]]]];
      [capture launch]; [capture waitUntilExit];
      CHECK([capture terminationStatus] == 0, "private display screenshot retained");
      [window cancel: nil];
      /* Exercise the product history with real persistent defaults too. The
         controller cases above use a dictionary to keep their state explicit. */
      PDWelcomeHistory *diskHistory = [[PDWelcomeHistory alloc] initWithDefaults: persistent
        fileExists: ^BOOL(NSString *path) { return YES; }];
      [diskHistory noteTarget: recent mode: PDWelcomeLaunch];
      [diskHistory noteTrace: @"/tmp/welcome-home-probe.gstrace"];
      NSString *token = [[NSUUID UUID] UUIDString];
      [persistent setObject: token forKey: @"PDWelcomeHomeProbe"];
      CHECK([persistent synchronize], "private defaults synchronize");
      NSString *domain = [domainName stringByAppendingPathExtension: @"plist"];
      NSString *database = [[defaultsRoot stringByAppendingPathComponent: domain] stringByResolvingSymlinksInPath];
      CHECK([database hasPrefix: homePrefix], "persisted defaults file stays inside private home");
      NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile: database];
      CHECK([[saved objectForKey: @"PDWelcomeHomeProbe"] isEqual: token], "defaults marker persisted in private home");
      CHECK([[[[saved objectForKey: @"PDRecentRecordingTargets"] firstObject] objectForKey: @"path"]
        isEqual: recent.executablePath], "recent target persisted in private home");
      CHECK([[[saved objectForKey: @"PDRecentTraces"] firstObject] isEqual: @"/tmp/welcome-home-probe.gstrace"],
        "recent trace persisted in private home");
      printf("Welcome controller: %u checks PASSED\n", checks);
      fflush(NULL);
      _Exit(0); /* AppKit caches are process-global; no modal teardown at exit. */
    }
}
