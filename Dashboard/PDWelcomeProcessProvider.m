/* SPDX-License-Identifier: GPL-3.0-or-later */
#define _GNU_SOURCE 1
#import "PDWelcomeProcessProvider.h"
#include <string.h>
#include <limits.h>
#if defined(__linux__)
# include <sys/stat.h>
# include <unistd.h>
# include <stdlib.h>
#endif

@implementation PDWelcomeProcessProvider
{
  NSMutableDictionary *_mapsCache;
}
+ (NSString *) identityFromStatData: (NSData *)data
{
  const unsigned char *bytes = [data bytes];
  NSUInteger end = [data length];
  while (end > 0 && bytes[end - 1] != ')')
    end--;
  if (end == 0 || end == [data length])
    return nil;
  NSString *tail = [[NSString alloc] initWithBytes: bytes + end length: [data length] - end
    encoding: NSASCIIStringEncoding];
  if (tail == nil)
    return nil;
  NSArray *fields = [[tail componentsSeparatedByCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]] filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock: ^BOOL(NSString *value, NSDictionary *bindings) { return [value length] != 0; }]];
  if ([fields count] <= 19)
    return nil;
  NSString *identity = [fields objectAtIndex: 19];
  return [identity length] && [identity rangeOfCharacterFromSet:
    [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound ? identity : nil;
}
+ (NSString *) processNameFromData: (NSData *)data
{
  if (data == nil)
    return nil;
  NSString *name = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
  if (name == nil)
    name = [[NSString alloc] initWithData: data encoding: NSISOLatin1StringEncoding];
  return [name stringByTrimmingCharactersInSet: [NSCharacterSet newlineCharacterSet]];
}
+ (NSNumber *) realUIDFromStatusData: (NSData *)data
{
  if (data == nil)
    return nil;
  NSString *text = [[NSString alloc] initWithData: data encoding: NSISOLatin1StringEncoding];
  for (NSString *line in [text componentsSeparatedByString: @"\n"])
    if ([line hasPrefix: @"Uid:"])
      {
        long long uid = -1;
        NSScanner *scanner = [NSScanner scannerWithString: [line substringFromIndex: 4]];
        if ([scanner scanLongLong: &uid] && uid >= 0 && uid <= UINT_MAX)
          return [NSNumber numberWithUnsignedInt: (unsigned)uid];
      }
  return nil;
}
+ (NSString *) attachProblemForRealUID: (NSNumber *)uid currentUID: (unsigned)currentUID
                       helperAvailable: (BOOL)available
{
  if (uid != nil && [uid unsignedIntValue] != currentUID)
    return @"Owned by another user";
  return available ? nil : @"Profiling helper not installed";
}
- (NSData *) processMapsDataForPID: (int)pid
{
  return [NSData dataWithContentsOfFile: [NSString stringWithFormat: @"/proc/%d/maps", pid]];
}
- (PDGNUstepIdentity) GNUstepIdentityForPID: (int)pid identity: (NSString *)identity
{
  if (_mapsCache == nil)
    _mapsCache = [NSMutableDictionary dictionary];
  NSDictionary *cached = [_mapsCache objectForKey: @(pid)];
  if ([[cached objectForKey: @"identity"] isEqual: identity])
    return [[cached objectForKey: @"status"] unsignedIntegerValue];
  NSData *maps = [self processMapsDataForPID: pid];
  PDGNUstepIdentity status = maps == nil ? PDGNUstepUnknown : PDGNUstepNo;
#if defined(__linux__)
  if ([maps length] > 0 && (memmem([maps bytes], [maps length], "libgnustep-base", sizeof("libgnustep-base") - 1)
      || memmem([maps bytes], [maps length], "libgnustep-gui", sizeof("libgnustep-gui") - 1)))
    status = PDGNUstepYes;
#endif
  if (identity)
    [_mapsCache setObject: @{ @"identity": identity, @"status": @(status) } forKey: @(pid)];
  return status;
}
- (NSString *) currentIdentityForPID: (int)pid
{
#if defined(__linux__)
  if (pid <= 0)
    return nil;
  NSString *path = [NSString stringWithFormat: @"/proc/%d/stat", pid];
  return [[self class] identityFromStatData: [NSData dataWithContentsOfFile: path]];
#else
  return nil;
#endif
}
- (NSArray *) runningProcesses
{
  NSMutableArray *processes = [NSMutableArray array];
#if defined(__linux__)
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableSet *seenPIDs = [NSMutableSet set];
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
      NSString *name = [[self class] processNameFromData: [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent: @"comm"]]];
      if (![name length])
        continue;
      PDWelcomeProcess *process = [PDWelcomeProcess new];
      process.pid = pid;
      process.name = name;
      process.identity = identity;
      process.executablePath = [fm pathContentOfSymbolicLinkAtPath:
        [dir stringByAppendingPathComponent: @"exe"]] ?: @"";
      process.GNUstepIdentity = [self GNUstepIdentityForPID: pid identity: identity];
      [seenPIDs addObject: @(pid)];
      NSNumber *uid = [[self class] realUIDFromStatusData: [NSData dataWithContentsOfFile:
        [dir stringByAppendingPathComponent: @"status"]]];
      if (uid != nil && [uid unsignedIntValue] != getuid())
        process.unavailableReason = @"Owned by another user";
      if ([[self currentIdentityForPID: pid] isEqual: identity])
        [processes addObject: process];
    }
  for (NSNumber *pid in [[_mapsCache allKeys] copy])
    if (![seenPIDs containsObject: pid])
      [_mapsCache removeObjectForKey: pid];
#endif
  return processes;
}
- (NSString *) attachProblemForProcess: (PDWelcomeProcess *)process
{
#if defined(__linux__)
  NSString *dir = [NSString stringWithFormat: @"/proc/%d", process.pid];
  if (![[NSFileManager defaultManager] fileExistsAtPath: dir])
    return @"The process is no longer available.";
  NSNumber *uid = [[self class] realUIDFromStatusData: [NSData dataWithContentsOfFile:
    [dir stringByAppendingPathComponent: @"status"]]];
  BOOL direct = [GSPRecorder canAttachWithoutPrivileges] || getenv("GSP_HELPER_DIRECT") != NULL;
  NSString *helper = direct ? ([GSPRecorder bundledHelperPath] ?: [GSPRecorder installedHelperPath])
    : [GSPRecorder installedHelperPath];
  /* Do not invent a ptrace/perf permission result. The existing helper performs
     the real attempt and reports its precise failure through GSPRecorder. */
  return [[self class] attachProblemForRealUID: uid currentUID: getuid() helperAvailable: helper != nil];
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
