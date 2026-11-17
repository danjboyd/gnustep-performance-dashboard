/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDWelcomeProcessProvider.h"
#if defined(__linux__)
# include <sys/stat.h>
# include <unistd.h>
# include <stdlib.h>
#endif

@implementation PDWelcomeProcessProvider
- (NSString *) currentIdentityForPID: (int)pid
{
#if defined(__linux__)
  if (pid <= 0)
    return nil;
  NSString *path = [NSString stringWithFormat: @"/proc/%d/stat", pid];
  NSString *text = [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: NULL];
  NSRange end = [text rangeOfString: @") " options: NSBackwardsSearch];
  if (text == nil || end.location == NSNotFound)
    return nil;
  NSArray *fields = [[[text substringFromIndex: NSMaxRange(end)]
    componentsSeparatedByCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]]
    filteredArrayUsingPredicate: [NSPredicate predicateWithBlock:
      ^BOOL(NSString *value, NSDictionary *bindings) { return [value length] != 0; }]];
  /* After comm, field 3 (state) is index 0; field 22 (starttime) is 19. */
  return [fields count] > 19 ? [fields objectAtIndex: 19] : nil;
#else
  return nil;
#endif
}
- (NSArray *) runningProcesses
{
  NSMutableArray *processes = [NSMutableArray array];
#if defined(__linux__)
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *entry in [fm contentsOfDirectoryAtPath: @"/proc" error: NULL])
    {
      if ([entry length] == 0 || [entry rangeOfCharacterFromSet:
          [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound)
        continue;
      int pid = [entry intValue];
      if (pid <= 0 || pid == getpid())
        continue;
      NSString *identity = [self currentIdentityForPID: pid];
      if (![identity length])
        continue;
      NSString *dir = [@"/proc" stringByAppendingPathComponent: entry];
      struct stat st;
      if (stat([dir fileSystemRepresentation], &st) != 0)
        continue;
      NSString *name = [[NSString stringWithContentsOfFile: [dir stringByAppendingPathComponent: @"comm"]
        encoding: NSUTF8StringEncoding error: NULL]
        stringByTrimmingCharactersInSet: [NSCharacterSet newlineCharacterSet]];
      if (![name length])
        continue;
      PDWelcomeProcess *process = [PDWelcomeProcess new];
      process.pid = pid;
      process.name = name;
      process.identity = identity;
      process.executablePath = [fm pathContentOfSymbolicLinkAtPath:
        [dir stringByAppendingPathComponent: @"exe"]] ?: @"";
      NSString *maps = [NSString stringWithContentsOfFile: [dir stringByAppendingPathComponent: @"maps"]
        encoding: NSUTF8StringEncoding error: NULL];
      process.GNUstepIdentity = maps == nil ? PDGNUstepUnknown
        : ([maps rangeOfString: @"libgnustep-base"].location != NSNotFound
           || [maps rangeOfString: @"libgnustep-gui"].location != NSNotFound ? PDGNUstepYes : PDGNUstepNo);
      if (st.st_uid != getuid())
        process.unavailableReason = @"Owned by another user";
      if ([[self currentIdentityForPID: pid] isEqual: identity])
        [processes addObject: process];
    }
#endif
  return processes;
}
- (NSString *) attachProblemForProcess: (PDWelcomeProcess *)process
{
#if defined(__linux__)
  struct stat st;
  NSString *dir = [NSString stringWithFormat: @"/proc/%d", process.pid];
  if (stat([dir fileSystemRepresentation], &st) != 0)
    return @"The process is no longer available.";
  if (st.st_uid != getuid())
    return @"Owned by another user";
  BOOL direct = [GSPRecorder canAttachWithoutPrivileges] || getenv("GSP_HELPER_DIRECT") != NULL;
  NSString *helper = direct ? ([GSPRecorder bundledHelperPath] ?: [GSPRecorder installedHelperPath])
    : [GSPRecorder installedHelperPath];
  if (helper == nil)
    return @"Profiling helper not installed";
  /* Do not invent a ptrace/perf permission result. The existing helper performs
     the real attempt and reports its precise failure through GSPRecorder. */
  return nil;
#else
  return @"Process discovery for this platform is not available in this provider.";
#endif
}
- (NSString *) executableForPath: (NSString *)path
{
  if (![path length])
    return nil;
  NSString *resolved = [path stringByExpandingTildeInPath];
  if (![resolved isAbsolutePath])
    resolved = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent: resolved];
  resolved = [resolved stringByStandardizingPath];
  BOOL directory = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath: resolved isDirectory: &directory] && directory)
    return [[[resolved pathExtension] lowercaseString] isEqual: @"app"]
      ? [[NSBundle bundleWithPath: resolved] executablePath] : nil;
  return resolved;
}
- (NSString *) launchProblemForExecutable: (NSString *)path
{
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath: path])
    return @"The selected executable no longer exists.";
  if (![fm isExecutableFileAtPath: path])
    return @"The selected file is not executable.";
  return [GSPRecorder preloadProblemForExecutable: path];
}
- (NSString *) templateProblemForTemplate: (GSPTemplate *)t mode: (PDWelcomeTargetMode)mode
{
#if defined(__linux__)
  if (mode == PDWelcomeAttach && ![t.name isEqual: @"System Time Profiler"])
    return @"Not available when attaching on Linux";
#endif
  if (mode == PDWelcomeLaunch && [t.instrumentIdentifiers containsObject: GSPInstrumentSystemProfiler])
    return @"System Time Profiler requires attaching to a running process.";
  return nil;
}
@end
