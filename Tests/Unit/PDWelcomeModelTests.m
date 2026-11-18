/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <XCTest/XCTest.h>
#import "Dashboard/PDWelcomeModel.h"
#import "Dashboard/PDWelcomeProcessProvider.h"
#import "Dashboard/PDWelcomeArguments.h"
#if defined(__linux__)
#include <unistd.h>
#endif

@interface WelcomeFakeProvider : NSObject <PDWelcomeTargetProvider>
@property (nonatomic, copy) NSArray *snapshot;
@property (nonatomic, strong) NSMutableDictionary *identities;
@property (nonatomic, copy) NSString *attachProblem;
@property (nonatomic, copy) NSString *launchProblem;
@end

@interface WelcomeCountingDefaults : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
@property (nonatomic) NSUInteger writes;
@end
@implementation WelcomeCountingDefaults
- (id) objectForKey: (id)key { return [_values objectForKey: key]; }
- (void) setObject: (id)object forKey: (id)key { _writes++; [_values setObject: object forKey: key]; }
@end
@implementation WelcomeFakeProvider
- (instancetype) init
{
  if ((self = [super init]))
    {
      _snapshot = [NSArray array];
      _identities = [NSMutableDictionary dictionary];
    }
  return self;
}
- (NSArray *) runningProcesses { return _snapshot; }
- (NSString *) currentIdentityForPID: (int)pid
{
  return [_identities objectForKey: [NSNumber numberWithInt: pid]];
}
- (NSString *) attachProblemForProcess: (PDWelcomeProcess *)process { return _attachProblem; }
- (NSString *) executableForPath: (NSString *)path
{
  return [path isEqual: @"/Apps/Gorm.app"] ? @"/Apps/Gorm.app/Gorm" : path;
}
- (NSString *) launchProblemForExecutable: (NSString *)path { return _launchProblem; }
- (NSString *) templateProblemForTemplate: (GSPTemplate *)t mode: (PDWelcomeTargetMode)mode
{
  /* Linux capabilities, injected rather than baked into the model. */
  if (mode == PDWelcomeAttach && ![t.name isEqual: @"System Time Profiler"])
    return @"Not available when attaching on Linux";
  if (mode == PDWelcomeLaunch && [t.name isEqual: @"System Time Profiler"])
    return @"System Time Profiler requires attaching to a running process.";
  return nil;
}
@end

static PDWelcomeProcess *
process(int pid, NSString *name, PDGNUstepIdentity identity)
{
  PDWelcomeProcess *p = [PDWelcomeProcess new];
  p.pid = pid;
  p.name = name;
  p.identity = [NSString stringWithFormat: @"start-%d", pid];
  p.executablePath = [@"/apps" stringByAppendingPathComponent: name];
  p.GNUstepIdentity = identity;
  return p;
}

@interface PDWelcomeModelTests : XCTestCase
@end
@implementation PDWelcomeModelTests
{
  WelcomeFakeProvider *_provider;
  PDWelcomeModel *_model;
  PDWelcomeHistory *_history;
  NSMutableDictionary *_defaults;
}
- (void) setUp
{
  _provider = [WelcomeFakeProvider new];
  _defaults = [NSMutableDictionary dictionary];
  _history = [[PDWelcomeHistory alloc] initWithDefaults: _defaults
    fileExists: ^BOOL(NSString *path) { return ![path hasPrefix: @"/missing"]; }];
  _model = [[PDWelcomeModel alloc] initWithProvider: _provider history: _history];
}
- (void) testDefaultSelectionIsDisabledAndUsesTimeProfiler
{
  XCTAssertEqualObjects(_model.templateName, @"Time Profiler");
  XCTAssertTrue(_model.GNUstepOnly);
  XCTAssertEqualObjects([_model recordDisabledReason], @"Choose an app or executable.");
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
  _model.mode = PDWelcomeAttach;
  XCTAssertEqualObjects([_model recordDisabledReason], @"No GNUstep apps detected. Show all processes.");
}
- (void) testGNUstepFilterRequiresConfirmedIdentityAndAllIncludesUnknown
{
  PDWelcomeProcess *gorm = process(48213, @"Gorm", PDGNUstepYes);
  PDWelcomeProcess *unknown = process(25, @"Unverified", PDGNUstepUnknown);
  PDWelcomeProcess *other = process(35, @"Other", PDGNUstepNo);
  _provider.snapshot = [NSArray arrayWithObjects: unknown, other, gorm, nil];
  [_model refreshProcesses];
  XCTAssertEqualObjects([_model filteredProcesses], [NSArray arrayWithObject: gorm]);
  _model.searchText = @" GOR ";
  XCTAssertEqualObjects([_model filteredProcesses], [NSArray arrayWithObject: gorm]);
  _model.searchText = @"821";
  XCTAssertEqualObjects([_model filteredProcesses], [NSArray arrayWithObject: gorm]);
  _model.searchText = @"Other";
  XCTAssertEqual([[_model filteredProcesses] count], (NSUInteger)0);
  _model.GNUstepOnly = NO;
  XCTAssertEqualObjects([_model filteredProcesses], [NSArray arrayWithObject: other]);
  _model.searchText = @"Unverified";
  XCTAssertEqualObjects([_model filteredProcesses], [NSArray arrayWithObject: unknown]);
}
- (void) testUnreadableMapsOnlyOffersAllProcessesHint
{
  PDWelcomeProcess *unknown = process(25, @"Unverified", PDGNUstepUnknown);
  _provider.snapshot = @[unknown];
  _model.mode = PDWelcomeAttach;
  [_model refreshProcesses];
  XCTAssertEqual([[_model filteredProcesses] count], (NSUInteger)0);
  XCTAssertEqualObjects([_model recordDisabledReason], @"No GNUstep apps detected. Show all processes.");
  _model.GNUstepOnly = NO;
  XCTAssertEqualObjects([_model filteredProcesses], @[unknown]);
  XCTAssertEqualObjects([_model recordDisabledReason], @"Choose a running app.");
}
- (void) testKnownAttachReasonsDoNotInventPermissions
{
  PDWelcomeProcess *p = process(25, @"Gorm", PDGNUstepYes);
  XCTAssertNil([_model unavailableReasonForProcess: p]);
  p.unavailableReason = @"Owned by another user";
  XCTAssertEqualObjects([_model unavailableReasonForProcess: p], p.unavailableReason);
  p.unavailableReason = nil;
  _provider.attachProblem = @"Profiling helper not installed";
  XCTAssertEqualObjects([_model unavailableReasonForProcess: p], _provider.attachProblem);
  _model.activeRecordingPIDs = [NSSet setWithObject: @25];
  XCTAssertTrue([[_model unavailableReasonForProcess: p] hasPrefix: @"Already being recorded"]);
  _model.activeRecordingPIDs = [NSSet set];
  _provider.attachProblem = nil;
  XCTAssertNil([_model unavailableReasonForProcess: p]);
}
- (void) testEveryTemplateIsAnExistingTemplateAndMoreCompletesTheList
{
  NSMutableSet *names = [NSMutableSet setWithArray: [PDWelcomeModel commonTemplateNames]];
  [names addObjectsFromArray: [PDWelcomeModel moreTemplateNames]];
  NSMutableSet *existing = [NSMutableSet set];
  for (GSPTemplate *t in [GSPTemplate allTemplates])
    [existing addObject: t.name];
  XCTAssertEqualObjects(names, existing);
  XCTAssertFalse([names containsObject: @"Everything"]);
  XCTAssertFalse([names containsObject: @"Signposts and intervals"]);
}
- (void) testLaunchMappingsPreserveTheExactExistingTemplateOptions
{
  _model.executablePath = @"/Apps/Gorm.app";
  for (GSPTemplate *t in [GSPTemplate allTemplates])
    {
      _model.templateName = t.name;
      GSPRecordingOptions *options = [_model recordingOptionsWithError: NULL];
      if ([t.name isEqual: @"System Time Profiler"])
        XCTAssertNil(options);
      else
        {
          XCTAssertNotNil(options);
          XCTAssertEqualObjects(options.templateName, t.name);
          XCTAssertEqualObjects(options.instrumentIdentifiers, t.instrumentIdentifiers);
        }
    }
}
- (void) testLinuxAttachDoesNotSilentlySubstituteATemplate
{
  PDWelcomeProcess *p = process(25, @"Gorm", PDGNUstepYes);
  _model.mode = PDWelcomeAttach;
  _model.selectedProcess = p;
  [_provider.identities setObject: p.identity forKey: @25];
  XCTAssertEqualObjects([_model recordDisabledReason], @"Not available when attaching on Linux");
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
  _model.templateName = @"System Time Profiler";
  _model.arguments = [NSArray arrayWithObject: @"launch-only"];
  _model.environment = [NSDictionary dictionaryWithObject: @"value" forKey: @"LAUNCH_ONLY"];
  _model.workingDirectory = @"/launch-only";
  GSPRecordingOptions *options = [_model recordingOptionsWithError: NULL];
  XCTAssertNotNil(options);
  XCTAssertEqual(options.attachPID, 25);
  XCTAssertEqual([options.arguments count], (NSUInteger)0);
  XCTAssertEqual([options.environment count], (NSUInteger)0);
  XCTAssertNil(options.workingDirectory);
  XCTAssertEqualObjects(options.instrumentIdentifiers, [NSArray arrayWithObject: GSPInstrumentSystemProfiler]);
}
- (void) testPIDReuseAndExitAreRefusedImmediatelyBeforeRecord
{
  PDWelcomeProcess *p = process(25, @"Gorm", PDGNUstepYes);
  _model.mode = PDWelcomeAttach;
  _model.templateName = @"System Time Profiler";
  _model.selectedProcess = p;
  [_provider.identities setObject: p.identity forKey: @25];
  XCTAssertNotNil([_model recordingOptionsWithError: NULL]);
  [_provider.identities setObject: @"different-start-time" forKey: @25];
  NSError *error = nil;
  XCTAssertNil([_model recordingOptionsWithError: &error]);
  XCTAssertTrue([[error localizedDescription] containsString: @"exited or changed"]);
  [_provider.identities removeObjectForKey: @25];
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
  PDWelcomeProcess *replacement = process(25, @"New app", PDGNUstepYes);
  replacement.identity = @"different-start-time";
  _provider.snapshot = [NSArray arrayWithObject: replacement];
  [_provider.identities setObject: replacement.identity forKey: @25];
  [_model refreshProcesses];
  XCTAssertEqualObjects(_model.selectedProcess.identity, @"start-25");
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
}
- (void) testLaunchOptionsPreserveArgsEnvironmentDirectoryAndTiming
{
  _model.executablePath = @"/Apps/Gorm.app";
  _model.arguments = [NSArray arrayWithObjects: @"one two", @"--target-option", nil];
  _model.environment = [NSDictionary dictionaryWithObject: @"" forKey: @"GNUSTEP_CONFIG_FILE"];
  _model.workingDirectory = @"/workspace";
  _model.timeLimit = 4.5;
  _model.sampleIntervalMicroseconds = 2000;
  GSPRecordingOptions *o = [_model recordingOptionsWithError: NULL];
  XCTAssertEqualObjects(o.executablePath, @"/Apps/Gorm.app/Gorm");
  XCTAssertEqualObjects(o.arguments, _model.arguments);
  XCTAssertEqualObjects(o.environment, _model.environment);
  XCTAssertEqualObjects(o.workingDirectory, @"/workspace");
  XCTAssertEqual(o.timeLimit, 4.5);
  XCTAssertEqual(o.sampleIntervalMicroseconds, 2000u);
  XCTAssertEqual(o.attachPID, 0);
}
- (void) testInvalidDurationUnknownTemplateAndLaunchPreconditionsDisableRecord
{
  _model.executablePath = @"/bin/program";
  _model.timeLimit = -1;
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
  _model.timeLimit = 0;
  _model.templateName = @"Invented";
  XCTAssertNil([_model recordingOptionsWithError: NULL]);
  _model.templateName = @"Time Profiler";
  _provider.launchProblem = @"The executable is setuid and ignores LD_PRELOAD.";
  XCTAssertEqualObjects([_model recordDisabledReason], _provider.launchProblem);
}
- (void) testRecentsPruneMissingMalformedAndDuplicateEntries
{
  [_defaults setObject: [NSArray arrayWithObjects: @"/trace.gstrace", @"/missing/old.gstrace", @"/trace.gstrace", @42, nil] forKey: @"PDRecentTraces"];
  XCTAssertEqualObjects([_history recentTraces], [NSArray arrayWithObject: @"/trace.gstrace"]);
  NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys: @"/app", @"path", @"launch", @"mode", nil];
  [_defaults setObject: [NSArray arrayWithObjects: @42, entry, entry,
    [NSDictionary dictionaryWithObjectsAndKeys: @"/missing/app", @"path", @"launch", @"mode", nil], nil]
    forKey: @"PDRecentRecordingTargets"];
  NSDictionary *canonical = @{ @"path": @"/app", @"mode": @"launch", @"template": @"Time Profiler" };
  XCTAssertEqualObjects([_history recentTargets], [NSArray arrayWithObject: canonical]);
}
- (void) testHistoryPrunesUnknownKeysOnceAndKeepsLegacyLaunchListInSync
{
  WelcomeCountingDefaults *defaults = [WelcomeCountingDefaults new];
  defaults.values = [NSMutableDictionary dictionaryWithObject: @[
    @{ @"path": @"/app", @"mode": @"launch", @"template": @"Time Profiler", @"pid": @42, @"extra": @"discard" }]
    forKey: @"PDRecentRecordingTargets"];
  PDWelcomeHistory *history = [[PDWelcomeHistory alloc] initWithDefaults: defaults fileExists: ^BOOL(NSString *path) { return YES; }];
  NSArray *first = [history recentTargets];
  XCTAssertEqual([[first objectAtIndex: 0] count], (NSUInteger)3);
  XCTAssertEqualObjects([defaults objectForKey: @"PDRecentTargets"], [NSArray arrayWithObject: @"/app"]);
  NSUInteger writes = defaults.writes;
  XCTAssertTrue(writes > 0);
  XCTAssertEqualObjects([history recentTargets], first);
  XCTAssertEqual(defaults.writes, writes);
  GSPRecordingOptions *options = [GSPRecordingOptions new];
  options.executablePath = @"/app"; options.templateName = @"Time Profiler";
  [history noteTarget: options mode: PDWelcomeLaunch];
  XCTAssertEqual(defaults.writes, writes);
}
- (void) testRecentsAreBoundedAndDoNotSaveAttachPIDs
{
  GSPRecordingOptions *o = [GSPRecordingOptions new];
  o.templateName = @"System Time Profiler";
  o.attachPID = 25;
  for (int i = 0; i < 12; i++)
    {
      o.executablePath = [NSString stringWithFormat: @"/apps/App%d", i];
      [_history noteTarget: o mode: PDWelcomeAttach];
      [_history noteTrace: [NSString stringWithFormat: @"/trace%d.gstrace", i]];
    }
  XCTAssertEqual([[_history recentTargets] count], (NSUInteger)10);
  XCTAssertEqual([[_history recentTraces] count], (NSUInteger)10);
  XCTAssertNil([[[_history recentTargets] objectAtIndex: 0] objectForKey: @"pid"]);
  XCTAssertEqualObjects([[[_history recentTargets] objectAtIndex: 0] objectForKey: @"path"], @"/apps/App11");
}
- (void) testShowAtLaunchPreferenceDefaultsOnAndPersistsOff
{
  XCTAssertTrue(_history.showAtLaunch);
  _history.showAtLaunch = NO;
  XCTAssertFalse(_history.showAtLaunch);
  _history.showAtLaunch = YES;
  XCTAssertTrue(_history.showAtLaunch);
}
- (void) testGUIAliasesPreserveTargetArgumentsAndTemplate
{
  BOOL handled = NO;
  NSArray *argv = [NSArray arrayWithObjects: @"PerformanceDashboard", @"--template", @"Allocations",
    @"--launch", @"/Apps/Gorm.app", @"one two", @"--template", @"target-value", nil];
  GSPRecordingOptions *o = [PDWelcomeArguments optionsFromArguments: argv provider: _provider handled: &handled error: NULL];
  XCTAssertTrue(handled);
  XCTAssertEqualObjects(o.templateName, @"Allocations");
  NSArray *expected = [NSArray arrayWithObjects: @"one two", @"--template", @"target-value", nil];
  XCTAssertEqualObjects(o.arguments, expected);
  XCTAssertEqualObjects(o.executablePath, @"/Apps/Gorm.app/Gorm");
}
- (void) testGUIAttachAliasUsesLiveIdentityAndSystemProfilerDefault
{
  PDWelcomeProcess *p = process(25, @"Gorm", PDGNUstepYes);
  _provider.snapshot = [NSArray arrayWithObject: p];
  [_provider.identities setObject: p.identity forKey: @25];
  BOOL handled = NO;
  GSPRecordingOptions *o = [PDWelcomeArguments optionsFromArguments:
    [NSArray arrayWithObjects: @"app", @"--attach", @"25", nil]
    provider: _provider handled: &handled error: NULL];
  XCTAssertTrue(handled);
  XCTAssertEqual(o.attachPID, 25);
  XCTAssertEqualObjects(o.templateName, @"System Time Profiler");
}
- (void) testInvalidGUIAliasesRefuseAndLegacyArgumentsStayUnhandled
{
  for (NSArray *argv in [NSArray arrayWithObjects:
    [NSArray arrayWithObjects: @"app", @"--attach", @"0", nil],
    [NSArray arrayWithObjects: @"app", @"--attach", @"25oops", nil],
    [NSArray arrayWithObjects: @"app", @"--launch", nil],
    [NSArray arrayWithObjects: @"app", @"--template", @"Leaks", nil], nil])
    {
      BOOL handled = NO;
      NSError *error = nil;
      XCTAssertNil([PDWelcomeArguments optionsFromArguments: argv provider: _provider handled: &handled error: &error]);
      XCTAssertTrue(handled);
      XCTAssertNotNil(error);
    }
  BOOL handled = YES;
  NSArray *legacy = [NSArray arrayWithObjects: @"app", @"-PDRecordTarget", @"/bin/sleep", nil];
  XCTAssertNil([PDWelcomeArguments optionsFromArguments: legacy
    provider: _provider handled: &handled error: NULL]);
  XCTAssertFalse(handled);
}
#if defined(__linux__)
- (void) testRealLinuxProviderReadsIncarnationAndLaunchPreconditions
{
  PDWelcomeProcessProvider *provider = [PDWelcomeProcessProvider new];
  XCTAssertTrue([[provider currentIdentityForPID: getpid()] length] > 0);
  XCTAssertNil([provider currentIdentityForPID: 0]);
  XCTAssertNil([provider currentIdentityForPID: -1]);
  XCTAssertNil([provider launchProblemForExecutable: @"/bin/sh"]);
  XCTAssertNotNil([provider launchProblemForExecutable: @"/no-such-PD-welcome-test-executable"]);
  XCTAssertTrue([[provider executableForPath: @"relative-program"] isAbsolutePath]);
}
#endif
- (void) testLegacyLaunchHistoryMigratesAndPrunesMissingPaths
{
  [_defaults setObject: [NSArray arrayWithObjects: @"/apps/Gorm.app", @"/missing/old", nil] forKey: @"PDRecentTargets"];
  NSArray *recent = [_history recentTargets];
  XCTAssertEqual([recent count], (NSUInteger)1);
  XCTAssertEqualObjects([[recent objectAtIndex: 0] objectForKey: @"mode"], @"launch");
  XCTAssertEqualObjects([[recent objectAtIndex: 0] objectForKey: @"path"], @"/apps/Gorm.app");
}
@end
