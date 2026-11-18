/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeModel.h"
#import <math.h>

@implementation PDWelcomeProcess
@end

@implementation PDWelcomeHistory
{
  id _defaults;
  BOOL (^_exists)(NSString *);
}
- (instancetype) initWithDefaults: (id)defaults
                      fileExists: (BOOL (^)(NSString *))exists
{
  if ((self = [super init]))
    {
      _defaults = defaults;
      _exists = [exists copy];
    }
  return self;
}
- (BOOL) showAtLaunch
{
  id value = [_defaults objectForKey: @"PDShowWelcomeAtLaunch"];
  return ![value respondsToSelector: @selector(boolValue)] || [value boolValue];
}
- (void) setShowAtLaunch: (BOOL)value
{
  [_defaults setObject: [NSNumber numberWithBool: value] forKey: @"PDShowWelcomeAtLaunch"];
}
- (NSArray *) prunedEntriesForKey: (NSString *)key targets: (BOOL)targets
{
  id original = [_defaults objectForKey: key];
  id saved = original;
  if (targets && saved == nil)
    {
      /* Carry forward existing launch history without persisting stale PIDs. */
      NSMutableArray *migrated = [NSMutableArray array];
      id legacy = [_defaults objectForKey: @"PDRecentTargets"];
      if ([legacy isKindOfClass: [NSArray class]])
        for (id path in legacy)
          if ([path isKindOfClass: [NSString class]])
            [migrated addObject: [NSDictionary dictionaryWithObjectsAndKeys:
              path, @"path", @"launch", @"mode", @"Time Profiler", @"template", nil]];
      saved = migrated;
    }
  NSMutableArray *kept = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  if ([saved isKindOfClass: [NSArray class]])
    for (id entry in saved)
      {
        id path = targets && [entry isKindOfClass: [NSDictionary class]]
          ? [entry objectForKey: @"path"] : (targets ? nil : entry);
        if (![path isKindOfClass: [NSString class]] || ![path length] || !_exists(path))
          continue;
        NSString *mode = targets ? [entry objectForKey: @"mode"] : @"trace";
        if (targets && ![mode isEqual: @"launch"] && ![mode isEqual: @"attach"])
          continue;
        NSString *identity = [NSString stringWithFormat: @"%@:%@", mode, path];
        if ([seen containsObject: identity])
          continue;
        [seen addObject: identity];
        if (targets)
          {
            id name = [entry objectForKey: @"template"];
            GSPTemplate *t = [name isKindOfClass: [NSString class]] ? [GSPTemplate templateNamed: name] : nil;
            [kept addObject: @{ @"path": path, @"mode": mode,
              @"template": t.name ?: ([mode isEqual: @"attach"] ? @"System Time Profiler" : @"Time Profiler") }];
          }
        else
          [kept addObject: path];
        if ([kept count] == 10)
          break;
      }
  if (![original isEqual: kept])
    [_defaults setObject: kept forKey: key];
  if (targets)
    [self syncLegacyLaunchTargets: kept];
  return [kept copy];
}
- (void) syncLegacyLaunchTargets: (NSArray *)entries
{
  NSMutableArray *paths = [NSMutableArray array];
  for (NSDictionary *entry in entries)
    if ([[entry objectForKey: @"mode"] isEqual: @"launch"])
      [paths addObject: [entry objectForKey: @"path"]];
  if (![[_defaults objectForKey: @"PDRecentTargets"] isEqual: paths])
    [_defaults setObject: paths forKey: @"PDRecentTargets"];
}
- (NSArray *) recentTargets
{
  return [self prunedEntriesForKey: @"PDRecentRecordingTargets" targets: YES];
}
- (NSArray *) recentTraces
{
  return [self prunedEntriesForKey: @"PDRecentTraces" targets: NO];
}
- (void) noteTarget: (GSPRecordingOptions *)options mode: (PDWelcomeTargetMode)mode
{
  NSString *path = options.executablePath;
  if (![path length] || !_exists(path))
    return;
  NSString *kind = mode == PDWelcomeAttach ? @"attach" : @"launch";
  NSMutableArray *recent = [[self recentTargets] mutableCopy];
  NSIndexSet *duplicates = [recent indexesOfObjectsPassingTest:
    ^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
      return [[entry objectForKey: @"path"] isEqual: path]
        && [[entry objectForKey: @"mode"] isEqual: kind];
    }];
  [recent removeObjectsAtIndexes: duplicates];
  /* Persist target identity, not PIDs or a copied caller environment. A recent
     attach entry must be resolved to a fresh process snapshot when selected. */
  NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
    path, @"path", kind, @"mode", options.templateName ?: @"Time Profiler", @"template", nil];
  [recent insertObject: entry atIndex: 0];
  while ([recent count] > 10)
    [recent removeLastObject];
  if (![[_defaults objectForKey: @"PDRecentRecordingTargets"] isEqual: recent])
    [_defaults setObject: recent forKey: @"PDRecentRecordingTargets"];
  [self syncLegacyLaunchTargets: recent];
}
- (void) noteTrace: (NSString *)path
{
  if (![path length] || !_exists(path))
    return;
  NSMutableArray *recent = [[self recentTraces] mutableCopy];
  [recent removeObject: path];
  [recent insertObject: path atIndex: 0];
  while ([recent count] > 10)
    [recent removeLastObject];
  [_defaults setObject: recent forKey: @"PDRecentTraces"];
}
@end

@implementation PDWelcomeModel
- (instancetype) initWithProvider: (id<PDWelcomeTargetProvider>)provider
                         history: (PDWelcomeHistory *)history
{
  if ((self = [super init]))
    {
      _provider = provider;
      _history = history;
      _mode = PDWelcomeLaunch;
      _templateName = @"Time Profiler";
      _arguments = [NSArray array];
      _environment = [NSDictionary dictionary];
      _activeRecordingPIDs = [NSSet set];
      _processes = [NSArray array];
      _GNUstepOnly = YES;
      _searchText = @"";
      _perfFrequency = 199;
    }
  return self;
}
+ (NSArray *) commonTemplateNames
{
  return [NSArray arrayWithObjects: @"Time Profiler", @"Allocations", @"Leaks", @"Hangs", nil];
}
+ (NSArray *) moreTemplateNames
{
  NSMutableArray *names = [NSMutableArray array];
  for (GSPTemplate *t in [GSPTemplate allTemplates])
    if (![[self commonTemplateNames] containsObject: t.name])
      [names addObject: t.name];
  return names;
}
- (void) refreshProcesses
{
  _processes = [[_provider runningProcesses] sortedArrayUsingComparator:
    ^NSComparisonResult(PDWelcomeProcess *a, PDWelcomeProcess *b) {
      NSComparisonResult order = [a.name caseInsensitiveCompare: b.name];
      if (order != NSOrderedSame)
        return order;
      return a.pid < b.pid ? NSOrderedAscending : (a.pid > b.pid ? NSOrderedDescending : NSOrderedSame);
    }];
  /* Keep the selected incarnation, not merely a matching PID. Its live identity
     is rechecked at Record; refreshing must never silently select a reused PID. */
}
- (NSArray *) filteredProcesses
{
  NSString *query = [_searchText stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSMutableArray *result = [NSMutableArray array];
  for (PDWelcomeProcess *p in _processes)
    {
      if (_GNUstepOnly && p.GNUstepIdentity != PDGNUstepYes)
        continue;
      NSString *pid = [NSString stringWithFormat: @"%d", p.pid];
      if ([query length] && [p.name rangeOfString: query options: NSCaseInsensitiveSearch].location == NSNotFound
          && [pid rangeOfString: query].location == NSNotFound)
        continue;
      [result addObject: p];
    }
  return result;
}
- (NSString *) templateDisabledReason: (NSString *)name
{
  GSPTemplate *t = [GSPTemplate templateNamed: name];
  if (t == nil)
    return @"Choose a recording template.";
  return [_provider templateProblemForTemplate: t mode: _mode];
}
- (NSString *) unavailableReasonForProcess: (PDWelcomeProcess *)process
{
  if ([_activeRecordingPIDs containsObject: [NSNumber numberWithInt: process.pid]])
    return @"Already being recorded by this Performance Dashboard session";
  if ([process.unavailableReason length])
    return process.unavailableReason;
  return [_provider attachProblemForProcess: process];
}
- (NSString *) recordDisabledReason
{
  if (_mode == PDWelcomeAttach)
    {
      if (_selectedProcess == nil)
        {
          if (_GNUstepOnly && [[_searchText stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0
              && [[self filteredProcesses] count] == 0)
            return @"No GNUstep apps detected. Show all processes.";
          return @"Choose a running app.";
        }
      NSString *identity = [_provider currentIdentityForPID: _selectedProcess.pid];
      if (![_selectedProcess.identity length] || ![identity isEqual: _selectedProcess.identity])
        return @"The selected process exited or changed. Choose the target again.";
      NSString *problem = [self unavailableReasonForProcess: _selectedProcess];
      if (problem)
        return problem;
    }
  else
    {
      if (![_executablePath length])
        return @"Choose an app or executable.";
      NSString *executable = [_provider executableForPath: _executablePath];
      if (![executable length])
        return @"The selected app has no executable.";
      NSString *problem = [_provider launchProblemForExecutable: executable];
      if (problem)
        return problem;
    }
  if (!isfinite(_timeLimit) || _timeLimit < 0)
    return @"Duration must be zero (until stopped) or a positive number.";
  return [self templateDisabledReason: _templateName];
}
- (NSString *) selectionSummary
{
  NSString *target = _mode == PDWelcomeAttach && _selectedProcess
    ? [NSString stringWithFormat: @"%@ (PID %d)", _selectedProcess.name, _selectedProcess.pid]
    : [_executablePath lastPathComponent];
  return [target length] ? [NSString stringWithFormat: @"%@ · %@", target, _templateName] : @"Choose a target to record";
}
- (GSPRecordingOptions *) recordingOptionsWithError: (NSError **)error
{
  NSString *problem = [self recordDisabledReason];
  if (problem)
    {
      if (error)
        *error = [NSError errorWithDomain: @"PDWelcomeErrorDomain" code: 1
          userInfo: [NSDictionary dictionaryWithObject: problem forKey: NSLocalizedDescriptionKey]];
      return nil;
    }
  GSPTemplate *t = [GSPTemplate templateNamed: _templateName];
  GSPRecordingOptions *options = [GSPRecordingOptions new];
  options.templateName = t.name;
  options.instrumentIdentifiers = t.instrumentIdentifiers;
  options.executablePath = _mode == PDWelcomeAttach ? _selectedProcess.executablePath
    : [_provider executableForPath: _executablePath];
  options.arguments = _mode == PDWelcomeAttach ? [NSArray array] : _arguments;
  options.environment = _mode == PDWelcomeAttach ? [NSDictionary dictionary] : _environment;
  options.workingDirectory = _mode == PDWelcomeAttach ? nil : ([_workingDirectory length] ? _workingDirectory
    : [options.executablePath stringByDeletingLastPathComponent]);
  options.timeLimit = _timeLimit;
  options.sampleIntervalMicroseconds = _sampleIntervalMicroseconds;
  options.perfFrequency = _perfFrequency;
  options.attachPID = _mode == PDWelcomeAttach ? _selectedProcess.pid : 0;
  return options;
}
@end
