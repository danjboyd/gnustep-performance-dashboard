/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#import "GSPRecorder.h"
#import "GSPInstruments.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#if defined(_WIN32)
/* Windows: the agent DLL is injected (docs/windows.md).  */
#  include <windows.h>
#  ifndef LIST_MODULES_64
#    define LIST_MODULES_64 0x02
#  endif
#else
#  include <dlfcn.h>
#  include <signal.h>
#  include <spawn.h>
#  include <unistd.h>
#  include <sys/utsname.h>
#  include <sys/wait.h>
#  include <sys/xattr.h>
#  include <sys/socket.h>
#  include <sys/statvfs.h>
#  include <dirent.h>
#  include "../Runtime/include/GSPerformance/gsp_capture.h"
#  include "../Runtime/include/GSPerformance/gsp_format.h"
#endif

NSString * const GSPRecorderErrorDomain = @"GSPRecorderErrorDomain";

#define GSP_VERSION @"0.1.5"
#define CTL_STOP 1
#define CTL_LEAKS 2
#define CTL_MARK 3

extern char **environ;

static NSError *
make_error(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain: GSPRecorderErrorDomain code: code
    userInfo: [NSDictionary dictionaryWithObject: message
                                          forKey: NSLocalizedDescriptionKey]];
}

@implementation GSPRecordingOptions
- (instancetype) init
{
  if ((self = [super init]) != nil)
    {
      _arguments = [NSArray array];
      _environment = [NSDictionary dictionary];
      _instrumentIdentifiers = [NSArray array];
      _perfFrequency = 1000;
      _automaticMinimumFreeSpace = YES;
    }
  return self;
}
@end

@interface GSPRecorder ()
#if defined(__linux__)
- (BOOL) captureFilesystemAtDescriptor: (int)fd capacity: (uint64_t *)capacity
                            available: (uint64_t *)available error: (int *)code;
#endif
@end

@implementation GSPRecorder
{
  GSPRecordingOptions *_options;
  NSString *_tracePath;
  pid_t _pid;
  pid_t _helperPid;
  volatile BOOL _recording;
  volatile BOOL _stopRequested;
  NSDate *_startDate;
  NSCondition *_done;
  BOOL _finished;
  int _exitStatus;
  NSString *_stopReason;
  NSString *_stopTrigger;
  NSError *_recordingError;
  uint64_t _effectiveMinimumFreeBytes;
  uint64_t _observedTraceBytes;
  uint64_t _observedAvailableBytes;
  BOOL _captureComplete;
#if defined(__linux__)
  int _waitErrno;
  int _statusFD;
  NSMutableDictionary *_completedStreams;
#endif
  void *_process;   /* Windows process handle */
}

- (instancetype) initWithOptions: (GSPRecordingOptions *)options
{
  if ((self = [super init]) != nil)
    {
      _options = options;
      _done = [NSCondition new];
      _exitStatus = -1;
#if defined(__linux__)
      _statusFD = -1;
      _completedStreams = [NSMutableDictionary dictionary];
#endif
    }
  return self;
}

- (GSPRecordingOptions *) options { return _options; }
- (int) pid { return _pid; }
- (BOOL) isRecording { return _recording; }
- (NSDate *) startDate { return _startDate; }
- (int) exitStatus { return _exitStatus; }
- (NSString *) stopReason { return _stopReason; }
- (NSString *) stopTrigger { return _stopTrigger; }
- (uint64_t) effectiveMinimumFreeBytes { return _effectiveMinimumFreeBytes; }
- (NSError *) recordingError { return _recordingError; }
- (NSString *) tracePath { return _tracePath; }

/* ------------------------------------------------------------------ */
/* locating things                                                     */

+ (NSString *) agentLibraryPath
{
#if defined(_WIN32)
  /* gsperf-agent.dll next to the GSPerformance DLL, the app's resources,
     the build tree, or GSP_AGENT_PATH.  */
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *candidates = [NSMutableArray array];
  const char *env = getenv("GSP_AGENT_PATH");
  HMODULE module = NULL;
  WCHAR wpath[MAX_PATH];

  if (env && *env)
    [candidates addObject: [NSString stringWithUTF8String: env]];
  if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                         | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCWSTR)(void *)GSPAgentEnvironmentForInstruments, &module)
      && GetModuleFileNameW(module, wpath, MAX_PATH))
    {
      NSString *dir = [[NSString stringWithCharacters: (const unichar *)wpath
                                               length: wcslen(wpath)]
                        stringByDeletingLastPathComponent];
      [candidates addObject: [dir stringByAppendingPathComponent: @"gsperf-agent.dll"]];
      [candidates addObject: [[dir stringByAppendingPathComponent:
        @"../../Runtime/obj/gsperf-agent.dll"] stringByStandardizingPath]];
    }
  [candidates addObject: [[[NSBundle mainBundle] resourcePath]
    stringByAppendingPathComponent: @"gsperf-agent.dll"]];
  for (NSString *c in candidates)
    if ([fm isReadableFileAtPath: c])
      return c;
  return nil;
#else
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *candidates = [NSMutableArray array];
  const char *env = getenv("GSP_AGENT_PATH");
  Dl_info info;

  if (env && *env)
    [candidates addObject: [NSString stringWithUTF8String: env]];
  if (dladdr((void *)GSPAgentEnvironmentForInstruments, &info) && info.dli_fname)
    {
      NSString *dir = [[NSString stringWithUTF8String: info.dli_fname]
                        stringByDeletingLastPathComponent];
      [candidates addObject: [dir stringByAppendingPathComponent: @"libgsperf-agent.so"]];
      /* in-tree build: GSPerformance/obj -> Runtime/obj */
      [candidates addObject: [[dir stringByAppendingPathComponent:
        @"../../Runtime/obj/libgsperf-agent.so"] stringByStandardizingPath]];
    }
  NSString *exe = [[NSBundle mainBundle] executablePath];
  if (exe)
    {
      NSString *dir = [exe stringByDeletingLastPathComponent];
      [candidates addObject: [[[NSBundle mainBundle] resourcePath]
        stringByAppendingPathComponent: @"libgsperf-agent.so"]];
      [candidates addObject: [[dir stringByAppendingPathComponent:
        @"../../Runtime/obj/libgsperf-agent.so"] stringByStandardizingPath]];
      [candidates addObject: [[dir stringByAppendingPathComponent:
        @"../../../Runtime/obj/libgsperf-agent.so"] stringByStandardizingPath]];
    }
  for (NSString *d in NSSearchPathForDirectoriesInDomains(GSLibrariesDirectory,
                                                          NSAllDomainsMask, YES))
    [candidates addObject: [d stringByAppendingPathComponent: @"libgsperf-agent.so"]];
  [candidates addObject: @"/usr/local/lib/libgsperf-agent.so"];
  [candidates addObject: @"/usr/lib/libgsperf-agent.so"];

  for (NSString *c in candidates)
    if ([fm isReadableFileAtPath: c])
      return c;
  return nil;
#endif
}

+ (NSString *) helperInstallLocation
{
  return @"/usr/local/libexec/gstrace-helper";
}

+ (int) perfEventParanoid
{
  NSString *s = [NSString stringWithContentsOfFile: @"/proc/sys/kernel/perf_event_paranoid"];
  return s ? [s intValue] : 3;
}

+ (BOOL) canAttachWithoutPrivileges
{
  return [self perfEventParanoid] <= 2;
}

+ (NSString *) bundledHelperPath
{
#if defined(_WIN32)
  return nil;
#else
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *candidates = [NSMutableArray array];
  NSString *exe = [[NSBundle mainBundle] executablePath];
  NSString *dir = [exe stringByDeletingLastPathComponent];
  Dl_info info;

  [candidates addObject: [[[NSBundle mainBundle] resourcePath]
    stringByAppendingPathComponent: @"gstrace-helper"]];
  [candidates addObject: [dir stringByAppendingPathComponent: @"gstrace-helper"]];
  [candidates addObject: [dir stringByAppendingPathComponent:
    @"../../gstrace-helper/gstrace-helper"]];
  [candidates addObject: [dir stringByAppendingPathComponent:
    @"../../../Tools/gstrace-helper/gstrace-helper"]];
  [candidates addObject: [dir stringByAppendingPathComponent:
    @"../../../../Tools/gstrace-helper/gstrace-helper"]];
  if (dladdr((void *)GSPAgentEnvironmentForInstruments, &info) && info.dli_fname)
    {
      NSString *lib = [[NSString stringWithUTF8String: info.dli_fname]
                        stringByDeletingLastPathComponent];
      [candidates addObject: [lib stringByAppendingPathComponent:
        @"../../Tools/gstrace-helper/gstrace-helper"]];
      [candidates addObject: [lib stringByAppendingPathComponent:
        @"../libexec/performance-dashboard/gstrace-helper"]];
    }
  for (NSString *c in candidates)
    {
      NSString *p = [c stringByStandardizingPath];
      if ([fm isExecutableFileAtPath: p])
        return p;
    }
  return nil;
#endif
}

#if !defined(_WIN32)
static BOOL
copy_private(NSString *from, NSString *to, mode_t mode)
{
  int in = open([from fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
  int out = open([to fileSystemRepresentation],
                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
  char buf[65536];
  ssize_t n;
  BOOL ok = in >= 0 && out >= 0;

  while (ok && (n = read(in, buf, sizeof(buf))) > 0)
    if (write(out, buf, (size_t)n) != n)
      ok = NO;
  if (out >= 0 && fchmod(out, mode) != 0)
    ok = NO;
  if (in >= 0)
    close(in);
  if (out >= 0)
    close(out);
  return ok;
}

+ (NSString *) stageHelperForInstall: (NSError **)error
{
  NSString *helper = [self bundledHelperPath];
  if (helper == nil)
    {
      if (error)
        *error = make_error(8, @"Cannot find gstrace-helper next to gstrace or in the app.");
      return nil;
    }
  NSString *policy = [[helper stringByDeletingLastPathComponent]
    stringByAppendingPathComponent: @"org.gnustep.performancedashboard.policy"];
  /* A fresh directory only this user can write: the root installer will
     copy whatever it finds there.  */
  char templ[PATH_MAX];
  snprintf(templ, sizeof(templ), "%s/gstrace-helper-XXXXXX",
           [NSTemporaryDirectory() fileSystemRepresentation]);
  if (mkdtemp(templ) == NULL)
    {
      if (error)
        *error = make_error(9, [NSString stringWithFormat:
          @"Cannot create a staging directory: %s", strerror(errno)]);
      return nil;
    }
  NSString *dir = [NSString stringWithUTF8String: templ];
  if (!copy_private(helper, [dir stringByAppendingPathComponent: @"gstrace-helper"], 0755)
      || !copy_private(policy, [dir stringByAppendingPathComponent:
                                     @"org.gnustep.performancedashboard.policy"], 0644))
    {
      [[NSFileManager defaultManager] removeItemAtPath: dir error: NULL];
      if (error)
        *error = make_error(10, @"Cannot copy the helper or its policy for installation.");
      return nil;
    }
  return dir;
}

+ (NSString *) installedHelperPath
{
  NSString *p = [self helperInstallLocation];
  struct stat st;
  if (stat([p fileSystemRepresentation], &st) == 0 && st.st_uid == 0
      && (st.st_mode & S_IXUSR))
    return p;
  return nil;
}

+ (NSString *) preloadProblemForExecutable: (NSString *)path
{
  struct stat st;
  if (stat([path fileSystemRepresentation], &st) != 0)
    return [NSString stringWithFormat: @"%@ does not exist.", path];
  if (st.st_mode & (S_ISUID | S_ISGID))
    return [NSString stringWithFormat:
      @"%@ is setuid/setgid; the loader ignores LD_PRELOAD for it, so it cannot be recorded by launching. Use the System Time Profiler to attach instead.",
      [path lastPathComponent]];
  if (getxattr([path fileSystemRepresentation], "security.capability", NULL, 0) > 0)
    return [NSString stringWithFormat:
      @"%@ has file capabilities; the loader ignores LD_PRELOAD for it. Use the System Time Profiler to attach instead.",
      [path lastPathComponent]];
  if (access([path fileSystemRepresentation], X_OK) != 0)
    return [NSString stringWithFormat: @"%@ is not executable.", path];
  return nil;
}

#else
+ (NSString *) stageHelperForInstall: (NSError **)error
{
  if (error)
    *error = make_error(11, @"The profiling helper is not available on Windows yet.");
  return nil;
}

+ (NSString *) installedHelperPath
{
  return nil;
}

+ (NSString *) preloadProblemForExecutable: (NSString *)path
{
  if (![[NSFileManager defaultManager] isExecutableFileAtPath: path]
      && ![[NSFileManager defaultManager] fileExistsAtPath: path])
    return [NSString stringWithFormat: @"%@ does not exist.", path];
  return nil;
}

#endif

/* When running from an AppImage, copy the agent out of the mount: the
   target may outlive Performance Dashboard and the mount disappears with it.  */
+ (NSString *) stableAgentPath: (NSString *)agent
{
  const char *appdir = getenv("APPDIR");
  if (appdir == NULL || ![agent hasPrefix: [NSString stringWithUTF8String: appdir]])
    return agent;
  const char *rt = getenv("XDG_RUNTIME_DIR");
  NSString *base = rt ? [NSString stringWithUTF8String: rt]
    : [NSHomeDirectory() stringByAppendingPathComponent: @".cache"];
  NSDictionary *attrs = [[NSFileManager defaultManager]
    attributesOfItemAtPath: agent error: NULL];
  NSString *dir = [base stringByAppendingPathComponent:
    [NSString stringWithFormat: @"performance-dashboard/%llu-%.0f",
     [attrs fileSize], [[attrs fileModificationDate] timeIntervalSince1970]]];
  NSString *dest = [dir stringByAppendingPathComponent: @"libgsperf-agent.so"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath: dest])
    {
      [fm createDirectoryAtPath: dir withIntermediateDirectories: YES
                     attributes: nil error: NULL];
      [fm copyItemAtPath: agent toPath: dest error: NULL];
    }
  return [fm fileExistsAtPath: dest] ? dest : agent;
}

static BOOL
under(NSString *value, NSString *root)
{
  return root != nil && [value hasPrefix: root];
}

+ (NSDictionary *) targetEnvironmentWithAdditions: (NSDictionary *)additions
{
  return [self targetEnvironmentFrom: [[NSProcessInfo processInfo] environment]
                           additions: additions];
}

+ (NSDictionary *) targetEnvironmentFrom: (NSDictionary *)environment
                               additions: (NSDictionary *)additions
{
  NSMutableDictionary *env = [environment mutableCopy];
  NSString *appdir = [env objectForKey: @"APPDIR"];
  NSString *hostVariables = [environment objectForKey: @"GP_HOST_VARS"];

  if (appdir != nil)
    {
      /* Undo what an AppImage runtime added for Performance Dashboard itself.  */
      for (NSString *key in [env allKeys])
        {
          NSString *value = [env objectForKey: key];
          NSArray *parts = [value componentsSeparatedByString: @":"];
          if ([parts count] > 1)
            {
              NSMutableArray *kept = [NSMutableArray array];
              for (NSString *p in parts)
                /* Empty components also occur in DISPLAY=:0 and URLs.
                   Remove only bundled paths, not unrelated separators. */
                if (!under(p, appdir))
                  [kept addObject: p];
              if ([kept count])
                [env setObject: [kept componentsJoinedByString: @":"] forKey: key];
              else
                [env removeObjectForKey: key];
            }
          else if (under(value, appdir))
            [env removeObjectForKey: key];
        }
    }

  /* AppRun preserves the first caller, including nested launches. Its marker
     is GP_HOST_VARS: direct AppRun does not export the inferred APPDIR.
     Restore the saved values before applying GP_HOST_UNSET, as the packager's
     host-tool wrappers do. APPDIR alone is the older AppImage path above. */
  if (hostVariables != nil)
    {
      NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
      NSArray *hostVars = [hostVariables componentsSeparatedByCharactersInSet: space];
      NSArray *hostUnset = [[environment objectForKey: @"GP_HOST_UNSET"]
        componentsSeparatedByCharactersInSet: space];
      for (NSString *key in hostVars)
        if ([key length] > 0)
          {
            NSString *value = [environment objectForKey:
              [@"GP_HOST_" stringByAppendingString: key]];
            if (value != nil)
              [env setObject: value forKey: key];
            else
              [env removeObjectForKey: key];
          }
      for (NSString *key in hostUnset)
        if ([key length] > 0)
          [env removeObjectForKey: key];
    }
  else
    {
      /* Native/older launchers may only provide the CLI wrapper snapshot. */
      NSString *state = [environment objectForKey: @"PD_TARGET_GNUSTEP_CONFIG_FILE_SET"];
      NSString *config = [environment objectForKey: @"PD_TARGET_GNUSTEP_CONFIG_FILE"];
      if ([state isEqual: @"1"] && config != nil)
        [env setObject: config forKey: @"GNUSTEP_CONFIG_FILE"];
      else if ([state isEqual: @"0"])
        [env removeObjectForKey: @"GNUSTEP_CONFIG_FILE"];
    }

  if (appdir != nil || hostVariables != nil)
    {
      for (NSString *key in [NSArray arrayWithObjects: @"APPDIR", @"APPIMAGE",
                             @"ARGV0", @"OWD", nil])
        [env removeObjectForKey: key];
      /* A target that is another AppImage must capture its own caller. */
      for (NSString *key in [env allKeys])
        if ([key hasPrefix: @"GP_HOST_"])
          [env removeObjectForKey: key];
    }
  [env removeObjectForKey: @"PD_TARGET_GNUSTEP_CONFIG_FILE_SET"];
  [env removeObjectForKey: @"PD_TARGET_GNUSTEP_CONFIG_FILE"];
  for (NSString *key in [env allKeys])
    if ([key hasPrefix: @"GSP_"])
      [env removeObjectForKey: key];
  [env addEntriesFromDictionary: additions];
  return env;
}

+ (NSString *) defaultTracePathForExecutable: (NSString *)path
                                    template: (NSString *)templateName
                                        date: (NSDate *)date
{
  NSDateFormatter *f = [NSDateFormatter new];
  [f setDateFormat: @"yyyy-MM-dd-HHmmss"];
  /* Independent recordings can start during the same clock second. Keep a
     readable timestamp, with a fresh identifier for every suggested path. */
  NSString *name = [NSString stringWithFormat: @"%@ %@ %@ %@.gstrace",
    [path lastPathComponent] ?: @"Recording", templateName ?: @"Trace",
    [f stringFromDate: date], [[NSUUID UUID] UUIDString]];
  return [[[NSFileManager defaultManager] currentDirectoryPath]
           stringByAppendingPathComponent: name];
}

+ (NSString *) defaultTracePathForExecutable: (NSString *)path
                                    template: (NSString *)templateName
{
  return [self defaultTracePathForExecutable: path template: templateName
                                      date: [NSDate date]];
}

/* ------------------------------------------------------------------ */
/* recording                                                           */

- (BOOL) prepareBundle: (NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];

  /* A relative target path would be looked up in the target's working
     directory; make it absolute now (and in Info.plist) instead.  */
  NSString *exe = _options.executablePath;
  if (!_options.attachPID && [exe length] && ![exe isAbsolutePath]
      && [exe rangeOfString: @"/"].location != NSNotFound)
    _options.executablePath = [[[fm currentDirectoryPath]
      stringByAppendingPathComponent: exe] stringByStandardizingPath];

  _tracePath = [_options.outputPath copy];
  if (_tracePath == nil)
    _tracePath = [GSPRecorder defaultTracePathForExecutable: _options.executablePath
                                                   template: _options.templateName];
  if (![[_tracePath pathExtension] isEqual: @"gstrace"])
    _tracePath = [_tracePath stringByAppendingPathExtension: @"gstrace"];
  if ([fm fileExistsAtPath: _tracePath])
    {
      if (error)
        *error = make_error(1, [NSString stringWithFormat:
          @"%@ already exists.", _tracePath]);
      return NO;
    }
  if (![fm createDirectoryAtPath: _tracePath withIntermediateDirectories: YES
                      attributes: nil error: error])
    return NO;
  return YES;
}

- (void) writeInfo: (BOOL)final
{
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
#if !defined(_WIN32)
  struct utsname u;
#endif

  [info setObject: [NSNumber numberWithInt: 1] forKey: @"FormatVersion"];
  [info setObject: GSP_VERSION forKey: @"RecorderVersion"];
  if (_options.templateName)
    [info setObject: _options.templateName forKey: @"Template"];
  [info setObject: _options.instrumentIdentifiers ?: [NSArray array] forKey: @"Instruments"];
  if (_options.executablePath)
    [info setObject: _options.executablePath forKey: @"TargetPath"];
  [info setObject: _options.arguments ?: [NSArray array] forKey: @"Arguments"];
  [info setObject: [NSNumber numberWithInt: _pid] forKey: @"TargetPID"];
  [info setObject: [NSNumber numberWithBool: _options.attachPID != 0] forKey: @"Attached"];
  if (_startDate)
    [info setObject: _startDate forKey: @"StartDate"];
  if (final)
    {
      [info setObject: [NSDate date] forKey: @"EndDate"];
      [info setObject: [NSNumber numberWithInt: _exitStatus] forKey: @"ExitStatus"];
      if (_stopReason)
        [info setObject: _stopReason forKey: @"StopReason"];
#if defined(__linux__)
      if (_waitErrno != 0)
        {
          [info setObject: [NSNumber numberWithInt: _waitErrno] forKey: @"WaitPIDErrno"];
          NSString *name = _waitErrno == ECHILD ? @"ECHILD"
            : _waitErrno == EINVAL ? @"EINVAL" : nil;
          if (name)
            [info setObject: name forKey: @"WaitPIDErrorName"];
          NSString *detail = [NSString stringWithUTF8String: strerror(_waitErrno)];
          if (detail)
            [info setObject: detail forKey: @"WaitPIDError"];
        }
      if (!_options.attachPID)
        {
          [info setObject: _stopTrigger ?: @"exited" forKey: @"StopTrigger"];
          [info setObject: _captureComplete ? @"complete" : @"incomplete"
                   forKey: @"CaptureStatus"];
          if (_recordingError)
            {
              [info setObject: [_recordingError localizedDescription] forKey: @"CaptureError"];
              [info setObject: @([_recordingError code]) forKey: @"CaptureErrorCode"];
            }
        }
#endif
    }
  else
    [info setObject: [NSNumber numberWithBool: YES] forKey: @"Recording"];
#if !defined(_WIN32)
  if (uname(&u) == 0)
    [info setObject: [NSString stringWithFormat: @"%s %s %s %s", u.nodename,
                      u.sysname, u.release, u.machine] forKey: @"Host"];
#endif
  [info setObject: [NSNumber numberWithUnsignedInt: _options.sampleIntervalMicroseconds
                    ? _options.sampleIntervalMicroseconds : 1000]
           forKey: @"SampleIntervalMicroseconds"];
#if defined(__linux__)
  if (!_options.attachPID)
    {
      [info setObject: @(_options.maximumTraceBytes) forKey: @"MaximumTraceBytes"];
      [info setObject: @(_options.timeLimit) forKey: @"TimeLimitSeconds"];
      [info setObject: @(_effectiveMinimumFreeBytes) forKey: @"MinimumFreeBytes"];
      [info setObject: @(_options.automaticMinimumFreeSpace) forKey: @"AutomaticMinimumFreeSpace"];
      [info setObject: @(_observedTraceBytes) forKey: @"ObservedTraceBytes"];
      if (_effectiveMinimumFreeBytes)
        [info setObject: @(_observedAvailableBytes) forKey: @"ObservedAvailableBytes"];
    }
#endif
#if defined(__linux__)
  NSError *writeError = nil;
  NSData *data = [NSPropertyListSerialization dataWithPropertyList: info
    format: NSPropertyListGNUstepFormat options: 0 error: &writeError];
  if (!data || ![data writeToFile: [_tracePath stringByAppendingPathComponent: @"Info.plist"]
                         options: NSDataWritingAtomic error: &writeError])
    {
      if (!_options.attachPID)
        {
          _captureComplete = NO;
          if (!_recordingError)
            _recordingError = writeError ?: make_error(EIO, @"Cannot write trace metadata.");
        }
    }
#else
  [info writeToFile: [_tracePath stringByAppendingPathComponent: @"Info.plist"]
         atomically: YES];
#endif
}

#if !defined(_WIN32)
static char **
c_environment(NSDictionary *env)
{
  char **envp = calloc([env count] + 1, sizeof(char *));
  NSUInteger i = 0;
  for (NSString *k in env)
    {
      NSString *kv = [NSString stringWithFormat: @"%@=%@", k, [env objectForKey: k]];
      envp[i++] = strdup([kv UTF8String]);
    }
  return envp;
}

static void
free_c_strings(char **list)
{
  for (char **p = list; p && *p; p++)
    free(*p);
  free(list);
}

#if defined(__linux__)
/* Count logical bytes, without following symlinks or accepting foreign-owned
   entries. No file content is read while a capture is running. */
static BOOL
bundle_bytes(int fd, unsigned depth, uint64_t *total)
{
  if (depth > 16) { errno = ELOOP; return NO; }
  int copy = dup(fd);
  if (copy < 0) return NO;
  DIR *directory = fdopendir(copy);
  if (!directory) { int saved = errno; close(copy); errno = saved; return NO; }
  BOOL ok = YES;
  struct dirent *entry;
  for (;;)
    {
      errno = 0;
      entry = readdir(directory);
      if (!entry) { if (errno) ok = NO; break; }
      if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
      struct stat st;
      if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0)
        {
          if (errno == ENOENT) continue; /* .next publication / atomic metadata */
          ok = NO; break;
        }
      if (st.st_uid != geteuid()) { errno = EPERM; ok = NO; break; }
      if (S_ISREG(st.st_mode))
        {
          if (st.st_size < 0 || *total > UINT64_MAX - (uint64_t)st.st_size)
            { errno = EOVERFLOW; ok = NO; break; }
          *total += (uint64_t)st.st_size;
        }
      else if (S_ISDIR(st.st_mode))
        {
          int child = openat(fd, entry->d_name, O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
          if (child < 0) { ok = NO; break; }
          ok = bundle_bytes(child, depth + 1, total);
          int saved = errno;
          close(child);
          errno = saved;
          if (!ok) break;
        }
    }
  int saved = errno;
  closedir(directory);
  errno = saved;
  return ok;
}

- (void) setStopTriggerOnce: (NSString *)trigger
{
  @synchronized(self)
    {
      if (!_stopTrigger) _stopTrigger = [trigger copy];
    }
}

- (void) captureErrorForOperation: (NSString *)operation code: (int)code
{
  if (!_recordingError)
    _recordingError = make_error(code, [NSString stringWithFormat:
      @"Recording incomplete: %@ failed (%d: %s).", operation, code, strerror(code)]);
  _captureComplete = NO;
}

- (BOOL) measureCapture: (BOOL)preflight countFiles: (BOOL)countFiles
{
  int fd = open([_tracePath fileSystemRepresentation],
                O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    { [self captureErrorForOperation: @"open trace directory" code: errno]; return NO; }
  BOOL ok = YES;
  if (_options.automaticMinimumFreeSpace || _options.minimumFreeBytes)
    {
      uint64_t capacity, available;
      int code = 0;
      if (![self captureFilesystemAtDescriptor: fd capacity: &capacity available: &available error: &code])
        { [self captureErrorForOperation: @"statvfs" code: code]; ok = NO; }
      else
        {
          _observedAvailableBytes = available;
          if (preflight)
            _effectiveMinimumFreeBytes = _options.automaticMinimumFreeSpace
              ? gsp_default_free_floor(capacity) : _options.minimumFreeBytes;
        }
    }
  if (ok && countFiles)
    {
      uint64_t total = 0;
      if (!bundle_bytes(fd, 0, &total))
        { [self captureErrorForOperation: @"measure trace files" code: errno]; ok = NO; }
      else _observedTraceBytes = total;
    }
  close(fd);
  return ok;
}

/* Kept separate so a private test subclass can supply a deterministic
   capacity/free-space crossing without filling a filesystem or adding a
   product environment-variable override. */
- (BOOL) captureFilesystemAtDescriptor: (int)fd capacity: (uint64_t *)capacity
                            available: (uint64_t *)available error: (int *)code
{
  struct statvfs fs;
  if (fstatvfs(fd, &fs) != 0) { *code = errno; return NO; }
  if (!gsp_block_bytes(fs.f_blocks, fs.f_frsize, capacity)
      || !gsp_block_bytes(fs.f_bavail, fs.f_frsize, available))
    { *code = EOVERFLOW; return NO; }
  return YES;
}

- (void) readWriterStatus
{
  /* Each datagram comes through the endpoint passed only to our spawned
     target. PID values describe streams, never select a process to kill. */
  for (unsigned i = 0; i < 256 && _statusFD >= 0; i++)
    {
      gsp_writer_status status;
      ssize_t n = recv(_statusFD, &status, sizeof(status), MSG_DONTWAIT | MSG_TRUNC);
      if (n < 0 && errno == EINTR) { i--; continue; }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
      if (n < 0)
        { [self captureErrorForOperation: @"writer status receive" code: errno]; break; }
      if (n != sizeof(status) || status.magic != GSP_WRITER_STATUS_MAGIC
          || status.version != GSP_WRITER_STATUS_VERSION || !status.pid
          || status.pid > INT32_MAX || status.reserved
          || status.operation > GSP_OUTPUT_THREAD || status.error < 0
          || (!status.error && status.operation != GSP_OUTPUT_COMPLETE)
          || (status.error && status.operation == GSP_OUTPUT_COMPLETE))
        { [self captureErrorForOperation: @"writer status framing" code: EPROTO]; continue; }
      if (status.error)
        {
          NSArray *operations = @[@"complete", @"open", @"write", @"fsync", @"close",
                                   @"rename", @"success marker", @"writer thread"];
          [self captureErrorForOperation: [NSString stringWithFormat: @"agent %@ (pid %u)",
            [operations objectAtIndex: status.operation], status.pid] code: status.error];
        }
      else
        [_completedStreams setObject: [NSData dataWithBytes: &status length: sizeof(status)]
                              forKey: @(status.pid)];
    }
}

- (void) validateCompletedStreams
{
  NSUInteger streams = 0;
  for (NSString *name in [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath: _tracePath error: NULL])
    {
      if (![name hasPrefix: @"events-"] || ![name hasSuffix: @".bin"]) continue;
      streams++;
      NSString *path = [_tracePath stringByAppendingPathComponent: name];
      int fd = open([path fileSystemRepresentation], O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
      struct stat st;
      gsp_file_header header;
      gsp_record end;
      gsp_writer_status status = {0};
      BOOL valid = fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode)
        && st.st_uid == geteuid() && st.st_size >= sizeof(header) + sizeof(end)
        && pread(fd, &header, sizeof(header), 0) == sizeof(header)
        && !memcmp(header.magic, GSP_MAGIC, sizeof(header.magic))
        && header.version == GSP_FORMAT_VERSION && header.header_size == sizeof(header)
        && pread(fd, &end, sizeof(end), st.st_size - sizeof(end)) == sizeof(end)
        && end.type == GSP_REC_END && end.size == sizeof(end);
      NSData *receipt = valid ? [_completedStreams objectForKey: @(header.pid)] : nil;
      if (receipt) [receipt getBytes: &status length: sizeof(status)];
      valid = valid && receipt && status.epoch == header.start_ns
        && status.bytes == (uint64_t)st.st_size && [self doneFileExistsFor: header.pid];
      if (fd >= 0) close(fd);
      if (!valid)
        [self captureErrorForOperation: [@"verify completed stream " stringByAppendingString: name]
                                 code: EIO];
    }
  if (!streams) [self captureErrorForOperation: @"verify recorded stream" code: EIO];
  _captureComplete = !_recordingError;
}
#endif

- (BOOL) launch: (NSError **)error
{
  NSString *problem = [GSPRecorder preloadProblemForExecutable: _options.executablePath];
  if (problem != nil)
    {
      if (error)
        *error = make_error(2, problem);
      return NO;
    }
  NSString *agent = [GSPRecorder agentLibraryPath];
  if (agent == nil)
    {
      if (error)
        *error = make_error(3, @"Cannot find libgsperf-agent.so. Set GSP_AGENT_PATH or install the runtime.");
      return NO;
    }
  agent = [GSPRecorder stableAgentPath: agent];

#if defined(__linux__)
  int statusPair[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, statusPair) != 0)
    {
      if (error) *error = make_error(errno, @"Cannot create recorder status channel.");
      return NO;
    }
  /* Reserve an unused descriptor while building the spawn actions. dup2 in
     the child deliberately clears CLOEXEC so wrapper execs keep the channel. */
  int childStatus = fcntl(statusPair[1], F_DUPFD_CLOEXEC, 64);
  if (childStatus < 0)
    {
      int saved = errno;
      close(statusPair[0]); close(statusPair[1]);
      if (error) *error = make_error(saved, @"Cannot reserve recorder status descriptor.");
      return NO;
    }
  _statusFD = statusPair[0];
#endif

  NSMutableDictionary *add = [NSMutableDictionary dictionary];
  [add addEntriesFromDictionary: GSPAgentEnvironmentForInstruments(
     _options.instrumentIdentifiers, _options.sampleIntervalMicroseconds,
     _options.leakIntervalSeconds)];
  [add setObject: _tracePath forKey: @"GSP_OUTPUT"];
  [add setObject: [NSString stringWithFormat: @"%d", getpid()] forKey: @"GSP_RECORDER_PID"];
  if (_options.followChildren)
    [add setObject: @"1" forKey: @"GSP_FOLLOW_CHILDREN"];
  NSDictionary *base = [GSPRecorder targetEnvironmentWithAdditions: add];
  NSMutableDictionary *env = [base mutableCopy];
  /* The agent goes first in LD_PRELOAD, before any the user sets (--env)
     or the environment has, rather than being replaced by them.  */
  [env addEntriesFromDictionary: _options.environment];
#if defined(__linux__)
  [env setObject: [NSString stringWithFormat: @"%d", childStatus] forKey: @"GSP_STATUS_FD"];
#endif
  NSString *preload = [env objectForKey: @"LD_PRELOAD"];
  [env setObject: [preload length] ? [NSString stringWithFormat: @"%@:%@", agent, preload]
                                   : agent
          forKey: @"LD_PRELOAD"];

  NSMutableArray *argv = [NSMutableArray arrayWithObject: _options.executablePath];
  [argv addObjectsFromArray: _options.arguments];
  char **cargv = calloc([argv count] + 1, sizeof(char *));
  for (NSUInteger i = 0; i < [argv count]; i++)
    cargv[i] = strdup([[argv objectAtIndex: i] UTF8String]);
  char **cenv = c_environment(env);

  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attr;
  posix_spawn_file_actions_init(&actions);
  posix_spawnattr_init(&attr);
  sigset_t none;
  sigemptyset(&none);
  posix_spawnattr_setsigmask(&attr, &none);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK);
#if defined(__linux__)
  int statusActionError = posix_spawn_file_actions_adddup2(&actions, statusPair[1], childStatus);
  if (!statusActionError)
    statusActionError = posix_spawn_file_actions_addclose(&actions, statusPair[0]);
  if (!statusActionError)
    statusActionError = posix_spawn_file_actions_addclose(&actions, statusPair[1]);
#endif
  if (_options.captureOutput)
    {
      NSString *out = [_tracePath stringByAppendingPathComponent: @"output.txt"];
      posix_spawn_file_actions_addopen(&actions, 1, [out fileSystemRepresentation],
                                       O_WRONLY | O_CREAT | O_TRUNC, 0644);
      posix_spawn_file_actions_adddup2(&actions, 1, 2);
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    }
  if (_options.workingDirectory)
    posix_spawn_file_actions_addchdir_np(&actions,
      [_options.workingDirectory fileSystemRepresentation]);

  _startDate = [NSDate date];
  int rc;
#if defined(__linux__)
  rc = statusActionError ? statusActionError
    : posix_spawn(&_pid, cargv[0], &actions, &attr, cargv, cenv);
  close(statusPair[1]);
  close(childStatus);
#else
  rc = posix_spawn(&_pid, cargv[0], &actions, &attr, cargv, cenv);
#endif
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  free_c_strings(cargv);
  free_c_strings(cenv);
  if (rc != 0)
    {
#if defined(__linux__)
      close(_statusFD);
      _statusFD = -1;
#endif
      if (error)
        *error = make_error(4, [NSString stringWithFormat: @"Cannot launch %@: %s",
                                _options.executablePath, strerror(rc)]);
      return NO;
    }
  return YES;
}

- (BOOL) attach: (NSError **)error
{
  /* With perf_event_paranoid <= 2 the helper can sample our own processes
     without privileges; otherwise the root-owned copy runs via pkexec.  */
  BOOL direct = [GSPRecorder canAttachWithoutPrivileges]
    || getenv("GSP_HELPER_DIRECT") != NULL;
  NSString *helper = direct
    ? ([GSPRecorder bundledHelperPath] ?: [GSPRecorder installedHelperPath])
    : [GSPRecorder installedHelperPath];
  if (helper == nil)
    {
      if (error)
        *error = make_error(5, @"The profiling helper is not installed. Use \"Install Profiling Helper…\" (or `gstrace install-helper`) first, or set kernel.perf_event_paranoid to 2 or lower to attach without it.");
      return NO;
    }
  NSMutableArray *args = [NSMutableArray arrayWithObjects: helper, @"record",
    @"--pid", [NSString stringWithFormat: @"%d", _options.attachPID],
    @"--output", _tracePath,
    @"--frequency", [NSString stringWithFormat: @"%u", _options.perfFrequency], nil];
  if (_options.timeLimit > 0)
    {
      [args addObject: @"--duration"];
      [args addObject: [NSString stringWithFormat: @"%.3f", _options.timeLimit]];
    }
  if (!direct)
    [args insertObject: @"pkexec" atIndex: 0];
  char **cargv = calloc([args count] + 1, sizeof(char *));
  for (NSUInteger i = 0; i < [args count]; i++)
    cargv[i] = strdup([[args objectAtIndex: i] UTF8String]);
  _startDate = [NSDate date];
  int rc = posix_spawnp(&_helperPid, cargv[0], NULL, NULL, cargv, environ);
  free_c_strings(cargv);
  if (rc != 0)
    {
      if (error)
        *error = make_error(6, [NSString stringWithFormat: @"Cannot run the profiling helper: %s",
                                strerror(rc)]);
      return NO;
    }
  _pid = _options.attachPID;
  return YES;
}

- (BOOL) start: (NSError **)error
{
#if defined(__linux__)
  if ((_options.followChildren && _options.maximumTraceBytes)
      || (_options.attachPID && (_options.maximumTraceBytes
          || !_options.automaticMinimumFreeSpace || _options.minimumFreeBytes)))
    {
      if (error) *error = make_error(EINVAL,
        @"Size thresholds with followed children, and explicit storage thresholds when attaching, are not qualified yet.");
      return NO;
    }
#endif
  if (![self prepareBundle: error])
    return NO;
#if defined(__linux__)
  if (!_options.attachPID)
    {
      BOOL measured = [self measureCapture: YES countFiles: NO];
      if (!measured || (_effectiveMinimumFreeBytes
                       && _observedAvailableBytes < _effectiveMinimumFreeBytes))
        {
          if (error) *error = _recordingError ?: make_error(ENOSPC, [NSString stringWithFormat:
            @"Free space %llu bytes is below recording floor %llu bytes; use --min-free 0 to disable or --min-free <size> to override.",
            (unsigned long long)_observedAvailableBytes,
            (unsigned long long)_effectiveMinimumFreeBytes]);
          [[NSFileManager defaultManager] removeItemAtPath: _tracePath error: NULL];
          return NO;
        }
    }
#endif
  BOOL ok = _options.attachPID ? [self attach: error] : [self launch: error];
  if (!ok)
    {
      [[NSFileManager defaultManager] removeItemAtPath: _tracePath error: NULL];
      return NO;
    }
  _recording = YES;
  [self writeInfo: NO];
  [NSThread detachNewThreadSelector: @selector(monitor) toTarget: self withObject: nil];
  if ([_delegate respondsToSelector: @selector(recorderDidStart:)])
    [_delegate recorderDidStart: self];
  return YES;
}

- (BOOL) doneFileExistsFor: (int)pid
{
  NSString *p = [_tracePath stringByAppendingPathComponent:
    [NSString stringWithFormat: @"events-%d.done", pid]];
  return [[NSFileManager defaultManager] fileExistsAtPath: p];
}

/* pids with a stream that has not finished */
- (NSArray *) unfinishedPIDs
{
  NSMutableArray *pids = [NSMutableArray array];
  for (NSString *name in [[NSFileManager defaultManager]
                           contentsOfDirectoryAtPath: _tracePath error: NULL])
    if ([name hasPrefix: @"events-"] && [name hasSuffix: @".bin"])
      {
        int pid = [[[name substringFromIndex: 7] stringByDeletingPathExtension] intValue];
        if (pid > 0 && ![self doneFileExistsFor: pid] && kill(pid, 0) == 0)
          [pids addObject: [NSNumber numberWithInt: pid]];
      }
  return pids;
}

static void
send_control(int pid, int request)
{
  union sigval v;
  v.sival_int = request;
  sigqueue(pid, SIGRTMIN + 5, v);
}

- (void) finishAttached
{
  /* The helper watches for a stop file: it runs as root and cannot be
     signalled by us.  */
  NSString *stop = [_tracePath stringByAppendingPathComponent: @"stop"];
  [[NSData data] writeToFile: stop atomically: NO];
}

#if defined(__linux__)
- (void) recordWaitFailure: (int)code
{
  _waitErrno = code;
  if (!_options.attachPID)
    _stopReason = @"unknown";
}
#endif

- (void) monitor
{
  @autoreleasepool
    {
      NSDate *deadline = _options.timeLimit > 0
        ? [_startDate dateByAddingTimeInterval: _options.timeLimit] : nil;
      BOOL stopSent = NO;
      NSDate *stopSentAt = nil;
      BOOL termSent = NO, killSent = NO;
      pid_t waitFor = _options.attachPID ? _helperPid : _pid;

      for (;;)
        {
#if defined(__linux__)
          if (!_options.attachPID)
            {
              [self readWriterStatus];
              if (_recordingError) [self setStopTriggerOnce: @"error"];
            }
#endif
          int status = 0;
          pid_t r = waitpid(waitFor, &status, WNOHANG);
          int waitErrno = r < 0 ? errno : 0;
          if (r == waitFor)
            {
              _exitStatus = status;
#if defined(__linux__)
              if (!_options.attachPID)
                {
                  if (killSent && WIFSIGNALED(status)
                      && WTERMSIG(status) == SIGKILL)
                    _stopReason = @"escalated-kill";
                  else if (termSent && (WIFEXITED(status)
                           || (WIFSIGNALED(status)
                               && WTERMSIG(status) == SIGTERM)))
                    _stopReason = @"requested-terminate";
                  else if (WIFSIGNALED(status))
                    _stopReason = @"signal";
                  else if (WIFEXITED(status))
                    _stopReason = @"exited";
                  else
                    _stopReason = @"unknown";
                }
#endif
              break;
            }
          if (r < 0 && waitErrno != EINTR)
            {
#if defined(__linux__)
              [self recordWaitFailure: waitErrno];
              if (!_options.attachPID)
                [self setStopTriggerOnce: @"error"];
#endif
              break;
            }

          BOOL wantStop = _stopRequested
            || (deadline && [deadline timeIntervalSinceNow] <= 0);
#if defined(__linux__)
          if (!_options.attachPID)
            {
              if (_stopRequested) [self setStopTriggerOnce: @"user"];
              if (deadline && [deadline timeIntervalSinceNow] <= 0)
                [self setStopTriggerOnce: @"time-limit"];
              if (!stopSent)
                {
                  if ((_effectiveMinimumFreeBytes || _options.maximumTraceBytes)
                      && ![self measureCapture: NO countFiles: _options.maximumTraceBytes != 0])
                    [self setStopTriggerOnce: @"error"];
                  else if (_effectiveMinimumFreeBytes
                           && _observedAvailableBytes < _effectiveMinimumFreeBytes)
                    [self setStopTriggerOnce: @"min-free"];
                  else if (_options.maximumTraceBytes
                           && _observedTraceBytes >= _options.maximumTraceBytes)
                    [self setStopTriggerOnce: @"max-size"];
                }
              wantStop = wantStop || _stopTrigger != nil || _recordingError != nil;
            }
#endif
          if (wantStop && !stopSent)
            {
              stopSent = YES;
              stopSentAt = [NSDate date];
              if (_options.attachPID)
                [self finishAttached];
              else
                {
                  send_control(_pid, CTL_STOP);
                  for (NSNumber *p in [self unfinishedPIDs])
                    if ([p intValue] != _pid)
                      send_control([p intValue], CTL_STOP);
                }
            }
          if (stopSent && !_options.attachPID)
            {
              /* Once the agent has written everything (or after a grace
                 period for long leak scans) end the target.  */
              double waited = -[stopSentAt timeIntervalSinceNow];
              BOOL flushed = [self doneFileExistsFor: _pid];
              if (!termSent && (flushed || waited > 60
#if defined(__linux__)
                                || (_recordingError && waited > 1)
#endif
                                ))
                {
                  termSent = YES;
                  kill(_pid, SIGTERM);
                  stopSentAt = [NSDate date];
                }
              else if (termSent && !killSent && -[stopSentAt timeIntervalSinceNow] > 3)
                {
                  killSent = YES;
                  kill(_pid, SIGKILL);
                }
            }
          usleep(20000);
        }

      /* Children may still be finishing their streams.  */
      for (int i = 0; i < 100 && [[self unfinishedPIDs] count]; i++)
        {
          if (i == 0)
            for (NSNumber *p in [self unfinishedPIDs])
              send_control([p intValue], CTL_STOP);
          usleep(50000);
        }

#if defined(__linux__)
      if (!_options.attachPID)
        {
          [self readWriterStatus];
          [self setStopTriggerOnce: _recordingError ? @"error" : @"exited"];
          [self measureCapture: NO countFiles: YES];
          [self validateCompletedStreams];
          close(_statusFD);
          _statusFD = -1;
        }
#endif
      _recording = NO;
      [self writeInfo: YES];
      [_done lock];
      _finished = YES;
      [_done broadcast];
      [_done unlock];
      [self performSelectorOnMainThread: @selector(notifyFinished)
                             withObject: nil waitUntilDone: NO];
    }
}

#else
/* Windows: start the target suspended, load gsperf-agent.dll into it with
   a remote LoadLibraryW thread, then let it run.  */

static NSString *
quote_argument(NSString *a)
{
  if ([a length] && [a rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString: @" \t\""]].location == NSNotFound)
    return a;
  NSMutableString *q = [NSMutableString stringWithString: @"\""];
  NSUInteger backslashes = 0;
  for (NSUInteger i = 0; i < [a length]; i++)
    {
      unichar c = [a characterAtIndex: i];
      if (c == '\\')
        {
          backslashes++;
          continue;
        }
      for (NSUInteger k = 0; k < (c == '"' ? backslashes * 2 + 1 : backslashes); k++)
        [q appendString: @"\\"];
      backslashes = 0;
      [q appendFormat: @"%C", c];
    }
  for (NSUInteger k = 0; k < backslashes * 2; k++)
    [q appendString: @"\\"];
  [q appendString: @"\""];
  return q;
}

static WCHAR *
wide(NSString *s)
{
  NSUInteger n = [s length];
  WCHAR *w = calloc(n + 1, sizeof(WCHAR));
  [s getCharacters: (unichar *)w range: NSMakeRange(0, n)];
  return w;
}

/* Loads the agent DLL into a process with a remote LoadLibraryW thread.  */
static BOOL
load_agent(HANDLE process, NSString *agent)
{
  WCHAR *agentw = wide([agent stringByReplacingOccurrencesOfString: @"/" withString: @"\\"]);
  SIZE_T bytes = (wcslen(agentw) + 1) * sizeof(WCHAR);
  LPVOID remote = VirtualAllocEx(process, NULL, bytes, MEM_COMMIT | MEM_RESERVE,
                                 PAGE_READWRITE);
  BOOL injected = NO;
  if (remote && WriteProcessMemory(process, remote, agentw, bytes, NULL))
    {
      LPTHREAD_START_ROUTINE load = (LPTHREAD_START_ROUTINE)(void *)
        GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryW");
      HANDLE t = CreateRemoteThread(process, NULL, 0, load, remote, 0, NULL);
      if (t)
        {
          DWORD code = 0;
          WaitForSingleObject(t, 30000);
          GetExitCodeThread(t, &code);
          injected = code != 0;
          CloseHandle(t);
        }
    }
  free(agentw);
  if (remote)
    VirtualFreeEx(process, remote, 0, MEM_RELEASE);
  return injected;
}

/* Address of an agent export inside another process: the agent's base
   there plus the export's offset in a local, uninitialised copy.  */
static LPTHREAD_START_ROUTINE
remote_agent_export(HANDLE process, NSString *agent, const char *name)
{
  HMODULE mods[1024];
  DWORD needed = 0;
  uintptr_t remoteBase = 0;
  WCHAR path[MAX_PATH];

  /* looked up at run time: the headers hide them below Windows 7 */
  HMODULE k32 = GetModuleHandleA("kernel32.dll");
  BOOL (WINAPI *enumMods)(HANDLE, HMODULE *, DWORD, LPDWORD, DWORD) =
    (void *)GetProcAddress(k32, "K32EnumProcessModulesEx");
  DWORD (WINAPI *baseName)(HANDLE, HMODULE, LPWSTR, DWORD) =
    (void *)GetProcAddress(k32, "K32GetModuleBaseNameW");
  if (!enumMods || !baseName
      || !enumMods(process, mods, sizeof(mods), &needed, LIST_MODULES_64))
    return NULL;
  for (DWORD i = 0; i < needed / sizeof(HMODULE) && i < 1024; i++)
    if (baseName(process, mods[i], path, MAX_PATH)
        && _wcsicmp(path, L"gsperf-agent.dll") == 0)
      remoteBase = (uintptr_t)mods[i];
  if (remoteBase == 0)
    return NULL;
  WCHAR *agentw = wide([agent stringByReplacingOccurrencesOfString: @"/" withString: @"\\"]);
  HMODULE local = LoadLibraryExW(agentw, NULL, DONT_RESOLVE_DLL_REFERENCES);
  free(agentw);
  if (local == NULL)
    return NULL;
  FARPROC f = GetProcAddress(local, name);
  uintptr_t offset = f ? (uintptr_t)f - (uintptr_t)local : 0;
  FreeLibrary(local);
  return offset ? (LPTHREAD_START_ROUTINE)(remoteBase + offset) : NULL;
}

- (BOOL) launch: (NSError **)error
{
  NSString *agent = [GSPRecorder agentLibraryPath];
  if (agent == nil)
    {
      if (error)
        *error = make_error(3, @"Cannot find gsperf-agent.dll. Set GSP_AGENT_PATH or install the runtime.");
      return NO;
    }
  NSMutableDictionary *add = [NSMutableDictionary dictionary];
  [add addEntriesFromDictionary: GSPAgentEnvironmentForInstruments(
     _options.instrumentIdentifiers, _options.sampleIntervalMicroseconds,
     _options.leakIntervalSeconds)];
  [add setObject: [_tracePath stringByStandardizingPath] forKey: @"GSP_OUTPUT"];
  NSMutableDictionary *env = [[GSPRecorder targetEnvironmentWithAdditions: add] mutableCopy];
  [env addEntriesFromDictionary: _options.environment];

  /* environment block: sorted NAME=value\0 ... \0 */
  NSMutableString *block = [NSMutableString string];
  unichar zero = 0;
  NSString *nul = [NSString stringWithCharacters: &zero length: 1];
  for (NSString *k in [[env allKeys] sortedArrayUsingSelector: @selector(caseInsensitiveCompare:)])
    {
      [block appendFormat: @"%@=%@", k, [env objectForKey: k]];
      [block appendString: nul];
    }
  [block appendString: nul];

  NSMutableArray *parts = [NSMutableArray arrayWithObject: quote_argument(_options.executablePath)];
  for (NSString *a in _options.arguments)
    [parts addObject: quote_argument(a)];
  WCHAR *cmd = wide([parts componentsJoinedByString: @" "]);
  WCHAR *app = wide(_options.executablePath);
  WCHAR *envw = calloc([block length] + 1, sizeof(WCHAR));
  [block getCharacters: (unichar *)envw range: NSMakeRange(0, [block length])];
  WCHAR *cwd = _options.workingDirectory ? wide(_options.workingDirectory) : NULL;

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  HANDLE outh = INVALID_HANDLE_VALUE;
  memset(&si, 0, sizeof(si));
  si.cb = sizeof(si);
  if (_options.captureOutput)
    {
      SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
      WCHAR *outp = wide([_tracePath stringByAppendingPathComponent: @"output.txt"]);
      outh = CreateFileW(outp, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, NULL);
      free(outp);
      si.dwFlags = STARTF_USESTDHANDLES;
      si.hStdOutput = si.hStdError = outh;
      si.hStdInput = NULL;
    }
  _startDate = [NSDate date];
  BOOL ok = CreateProcessW(app, cmd, NULL, NULL, _options.captureOutput,
                           CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, envw, cwd,
                           &si, &pi);
  DWORD lastError = GetLastError();
  free(cmd);
  free(app);
  free(envw);
  free(cwd);
  if (outh != INVALID_HANDLE_VALUE)
    CloseHandle(outh);
  if (!ok)
    {
      if (error)
        *error = make_error(4, [NSString stringWithFormat: @"Cannot launch %@ (error %lu)",
                                _options.executablePath, (unsigned long)lastError]);
      return NO;
    }

  /* inject the agent; it signals this event once its sampler runs */
  WCHAR readyName[64];
  swprintf(readyName, 64, L"Local\\gsperf-ready-%lu", (unsigned long)pi.dwProcessId);
  HANDLE ready = CreateEventW(NULL, TRUE, FALSE, readyName);
  BOOL injected = load_agent(pi.hProcess, agent);
  if (!injected)
    {
      if (ready)
        CloseHandle(ready);
      TerminateProcess(pi.hProcess, 1);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      if (error)
        *error = make_error(13, @"Cannot load the recording agent into the target.");
      return NO;
    }
  /* Let the target run only when sampling has started, or a short program
     would be over before its first sample.  */
  if (ready)
    {
      WaitForSingleObject(ready, 5000);
      CloseHandle(ready);
    }
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  _process = pi.hProcess;
  _pid = (int)pi.dwProcessId;
  return YES;
}

/* Attaching to a running program of the same user: the configuration
   goes into shared memory the agent reads, the agent is loaded with
   LoadLibraryW and started with its gsp_agent_attach export.  The agent
   stays loaded (its hooks are in the program's import tables) and goes
   quiet when the recording stops.  */
- (BOOL) attach: (NSError **)error
{
  NSString *agent = [GSPRecorder agentLibraryPath];
  if (agent == nil)
    {
      if (error)
        *error = make_error(3, @"Cannot find gsperf-agent.dll. Set GSP_AGENT_PATH or install the runtime.");
      return NO;
    }
  DWORD pid = (DWORD)_options.attachPID;
  HANDLE proc = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION
                            | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ
                            | SYNCHRONIZE, FALSE, pid);
  if (proc == NULL)
    {
      if (error)
        *error = make_error(5, [NSString stringWithFormat:
          @"Cannot open process %lu (error %lu). Only your own, non-elevated programs can be attached to.",
          (unsigned long)pid, (unsigned long)GetLastError()]);
      return NO;
    }
  if (_options.executablePath == nil)
    {
      WCHAR exe[MAX_PATH * 2];
      DWORD n = MAX_PATH * 2;
      BOOL (WINAPI *imageName)(HANDLE, DWORD, LPWSTR, PDWORD) = (void *)
        GetProcAddress(GetModuleHandleA("kernel32.dll"), "QueryFullProcessImageNameW");
      if (imageName && imageName(proc, 0, exe, &n))
        _options.executablePath = [[NSString stringWithCharacters: (unichar *)exe length: n]
                                    stringByReplacingOccurrencesOfString: @"\\" withString: @"/"];
    }

  NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
  [cfg addEntriesFromDictionary: GSPAgentEnvironmentForInstruments(
     _options.instrumentIdentifiers, _options.sampleIntervalMicroseconds,
     _options.leakIntervalSeconds)];
  [cfg setObject: [_tracePath stringByStandardizingPath] forKey: @"GSP_OUTPUT"];
  NSMutableString *text = [NSMutableString string];
  for (NSString *k in cfg)
    [text appendFormat: @"%@=%@\n", k, [cfg objectForKey: k]];
  NSData *bytes = [text dataUsingEncoding: NSUTF8StringEncoding];

  WCHAR name[64];
  swprintf(name, 64, L"Local\\gsperf-config-%lu", (unsigned long)pid);
  HANDLE map = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                  (DWORD)[bytes length] + 1, name);
  void *view = map ? MapViewOfFile(map, FILE_MAP_WRITE, 0, 0, 0) : NULL;
  if (view)
    {
      memcpy(view, [bytes bytes], [bytes length]);
      ((char *)view)[[bytes length]] = 0;
      UnmapViewOfFile(view);
    }
  swprintf(name, 64, L"Local\\gsperf-ready-%lu", (unsigned long)pid);
  HANDLE ready = CreateEventW(NULL, TRUE, FALSE, name);

  _startDate = [NSDate date];
  DWORD code = 1;
  BOOL loaded = view != NULL && load_agent(proc, agent);
  LPTHREAD_START_ROUTINE entry = loaded ? remote_agent_export(proc, agent, "gsp_agent_attach") : NULL;
  if (entry)
    {
      HANDLE t = CreateRemoteThread(proc, NULL, 0, entry, NULL, 0, NULL);
      if (t)
        {
          WaitForSingleObject(t, 30000);
          GetExitCodeThread(t, &code);
          CloseHandle(t);
        }
    }
  if (code == 0 && ready)
    WaitForSingleObject(ready, 5000);
  if (ready)
    CloseHandle(ready);
  if (map)
    CloseHandle(map);
  if (code != 0)
    {
      CloseHandle(proc);
      if (error)
        *error = make_error(13, code == 2
          ? @"This process was already recorded once; the agent records a process only once. Restart the program to record it again."
          : @"Cannot load the recording agent into the process.");
      return NO;
    }
  _process = proc;
  _pid = (int)pid;
  return YES;
}

- (BOOL) start: (NSError **)error
{
  if (![self prepareBundle: error])
    return NO;
  if (!(_options.attachPID ? [self attach: error] : [self launch: error]))
    {
      [[NSFileManager defaultManager] removeItemAtPath: _tracePath error: NULL];
      return NO;
    }
  _recording = YES;
  [self writeInfo: NO];
  [NSThread detachNewThreadSelector: @selector(monitor) toTarget: self withObject: nil];
  if ([_delegate respondsToSelector: @selector(recorderDidStart:)])
    [_delegate recorderDidStart: self];
  return YES;
}

- (BOOL) doneFileExistsFor: (int)pid
{
  NSString *p = [_tracePath stringByAppendingPathComponent:
    [NSString stringWithFormat: @"events-%d.done", pid]];
  return [[NSFileManager defaultManager] fileExistsAtPath: p];
}

- (void) monitor
{
  @autoreleasepool
    {
      NSDate *deadline = _options.timeLimit > 0
        ? [_startDate dateByAddingTimeInterval: _options.timeLimit] : nil;
      BOOL stopSent = NO;
      NSDate *stopSentAt = nil;
      HANDLE proc = (HANDLE)_process;

      for (;;)
        {
          if (WaitForSingleObject(proc, 20) == WAIT_OBJECT_0)
            break;
          BOOL wantStop = _stopRequested
            || (deadline && [deadline timeIntervalSinceNow] <= 0);
          if (wantStop && !stopSent)
            {
              WCHAR name[64];
              swprintf(name, 64, L"Local\\gsperf-stop-%d", _pid);
              HANDLE ev = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
              if (ev)
                {
                  SetEvent(ev);
                  CloseHandle(ev);
                }
              stopSent = YES;
              stopSentAt = [NSDate date];
            }
          if (stopSent && ([self doneFileExistsFor: _pid] || -[stopSentAt timeIntervalSinceNow] > 30))
            {
              /* an attached program keeps running */
              if (_options.attachPID)
                break;
              TerminateProcess(proc, 0);
              WaitForSingleObject(proc, 5000);
              break;
            }
        }
      DWORD code = 0;
      GetExitCodeProcess(proc, &code);
      _exitStatus = code == STILL_ACTIVE ? 0 : (int)code;
      CloseHandle(proc);
      _recording = NO;
      [self writeInfo: YES];
      [_done lock];
      _finished = YES;
      [_done broadcast];
      [_done unlock];
      [self performSelectorOnMainThread: @selector(notifyFinished)
                             withObject: nil waitUntilDone: NO];
    }
}

#endif

- (void) notifyFinished
{
  NSError *error = _recordingError;
  NSString *anyStream = nil;
  for (NSString *n in [[NSFileManager defaultManager]
                        contentsOfDirectoryAtPath: _tracePath error: NULL])
    if ([n hasPrefix: @"events-"] && [n hasSuffix: @".bin"])
      anyStream = n;
  if (anyStream == nil && !error)
    error = make_error(7, _options.attachPID
#if defined(_WIN32)
      ? @"The agent did not record anything in the attached process."
#else
      ? @"The profiling helper did not record anything (authentication cancelled or perf_event unavailable)."
#endif
      : @"The target did not record anything. It may have exited immediately, been statically linked, or ignored LD_PRELOAD.");
  if ([_delegate respondsToSelector: @selector(recorder:didFinishWithError:)])
    [_delegate recorder: self didFinishWithError: error];
#if defined(__linux__)
  /* Let the GUI attach the recorded trace before presenting a status notice.
     Missing process status does not make the stream itself unreadable. */
  if (error == nil && !_options.attachPID && _exitStatus < 0
      && [_delegate respondsToSelector: @selector(recorder:didFinishWithNotice:)])
    [_delegate recorder: self didFinishWithNotice:
      @"The target's exit status couldn't be read."];
#endif
}

- (void) stop
{
#if defined(__linux__)
  if (!_options.attachPID) [self setStopTriggerOnce: @"user"];
#endif
  _stopRequested = YES;
}

- (void) waitUntilFinished
{
  [_done lock];
  while (!_finished)
    [_done wait];
  [_done unlock];
}

- (void) requestLeakCheck
{
#if !defined(_WIN32)
  if (_recording && _pid > 0 && !_options.attachPID)
    send_control(_pid, CTL_LEAKS);
#endif
}

- (void) addMark
{
#if !defined(_WIN32)
  if (_recording && _pid > 0 && !_options.attachPID)
    send_control(_pid, CTL_MARK);
#endif
}

@end
