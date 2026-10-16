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
/* Recording is not implemented on Windows yet (see docs/windows.md); the
   framework still reads, analyses and exports traces there.  */
#  include <windows.h>
#else
#  include <dlfcn.h>
#  include <signal.h>
#  include <spawn.h>
#  include <unistd.h>
#  include <sys/utsname.h>
#  include <sys/wait.h>
#  include <sys/xattr.h>
#endif

NSString * const GSPRecorderErrorDomain = @"GSPRecorderErrorDomain";

#define GSP_VERSION @"0.1.0"
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
    }
  return self;
}
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
  void *_process;   /* Windows process handle */
}

- (instancetype) initWithOptions: (GSPRecordingOptions *)options
{
  if ((self = [super init]) != nil)
    {
      _options = options;
      _done = [NSCondition new];
      _exitStatus = -1;
    }
  return self;
}

- (GSPRecordingOptions *) options { return _options; }
- (int) pid { return _pid; }
- (BOOL) isRecording { return _recording; }
- (NSDate *) startDate { return _startDate; }
- (int) exitStatus { return _exitStatus; }
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
        @"../libexec/gnustep-instruments/gstrace-helper"]];
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
    stringByAppendingPathComponent: @"org.gnustep.instruments.policy"];
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
                                     @"org.gnustep.instruments.policy"], 0644))
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
   target may outlive Instruments and the mount disappears with it.  */
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
    [NSString stringWithFormat: @"gnustep-instruments/%llu-%.0f",
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

  if (appdir != nil)
    {
      /* Undo what an AppImage runtime added for Instruments itself.  */
      for (NSString *key in [env allKeys])
        {
          NSString *value = [env objectForKey: key];
          NSArray *parts = [value componentsSeparatedByString: @":"];
          if ([parts count] > 1)
            {
              NSMutableArray *kept = [NSMutableArray array];
              for (NSString *p in parts)
                if ([p length] && !under(p, appdir))
                  [kept addObject: p];
              if ([kept count])
                [env setObject: [kept componentsJoinedByString: @":"] forKey: key];
              else
                [env removeObjectForKey: key];
            }
          else if (under(value, appdir))
            [env removeObjectForKey: key];
        }
      for (NSString *key in [NSArray arrayWithObjects: @"APPDIR", @"APPIMAGE",
                             @"ARGV0", @"OWD", nil])
        [env removeObjectForKey: key];
    }
  for (NSString *key in [env allKeys])
    if ([key hasPrefix: @"GSP_"])
      [env removeObjectForKey: key];
  [env addEntriesFromDictionary: additions];
  return env;
}

+ (NSString *) defaultTracePathForExecutable: (NSString *)path
                                    template: (NSString *)templateName
{
  NSDateFormatter *f = [NSDateFormatter new];
  [f setDateFormat: @"yyyy-MM-dd-HHmmss"];
  NSString *name = [NSString stringWithFormat: @"%@ %@ %@.gstrace",
    [path lastPathComponent] ?: @"Recording", templateName ?: @"Trace",
    [f stringFromDate: [NSDate date]]];
  return [[[NSFileManager defaultManager] currentDirectoryPath]
           stringByAppendingPathComponent: name];
}

/* ------------------------------------------------------------------ */
/* recording                                                           */

- (BOOL) prepareBundle: (NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];

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
  [info writeToFile: [_tracePath stringByAppendingPathComponent: @"Info.plist"]
         atomically: YES];
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
  NSString *preload = [env objectForKey: @"LD_PRELOAD"];
  [env setObject: [preload length] ? [NSString stringWithFormat: @"%@:%@", agent, preload]
                                   : agent
          forKey: @"LD_PRELOAD"];
  [env addEntriesFromDictionary: _options.environment];

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
  int rc = posix_spawn(&_pid, cargv[0], &actions, &attr, cargv, cenv);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attr);
  free_c_strings(cargv);
  free_c_strings(cenv);
  if (rc != 0)
    {
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
  if (![self prepareBundle: error])
    return NO;
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
          int status = 0;
          pid_t r = waitpid(waitFor, &status, WNOHANG);
          if (r == waitFor)
            {
              _exitStatus = status;
              break;
            }
          if (r < 0 && errno != EINTR)
            break;

          BOOL wantStop = _stopRequested
            || (deadline && [deadline timeIntervalSinceNow] <= 0);
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
              if (!termSent && (flushed || waited > 60))
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

  /* inject the agent */
  WCHAR *agentw = wide([agent stringByReplacingOccurrencesOfString: @"/" withString: @"\\"]);
  SIZE_T bytes = (wcslen(agentw) + 1) * sizeof(WCHAR);
  LPVOID remote = VirtualAllocEx(pi.hProcess, NULL, bytes, MEM_COMMIT | MEM_RESERVE,
                                 PAGE_READWRITE);
  BOOL injected = NO;
  if (remote && WriteProcessMemory(pi.hProcess, remote, agentw, bytes, NULL))
    {
      LPTHREAD_START_ROUTINE load = (LPTHREAD_START_ROUTINE)(void *)
        GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryW");
      HANDLE t = CreateRemoteThread(pi.hProcess, NULL, 0, load, remote, 0, NULL);
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
    VirtualFreeEx(pi.hProcess, remote, 0, MEM_RELEASE);
  if (!injected)
    {
      TerminateProcess(pi.hProcess, 1);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      if (error)
        *error = make_error(13, @"Cannot load the recording agent into the target.");
      return NO;
    }
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  _process = pi.hProcess;
  _pid = (int)pi.dwProcessId;
  return YES;
}

- (BOOL) start: (NSError **)error
{
  if (_options.attachPID)
    {
      if (error)
        *error = make_error(12, @"Attaching to running processes is not supported on Windows yet.");
      return NO;
    }
  if (![self prepareBundle: error])
    return NO;
  if (![self launch: error])
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
              TerminateProcess(proc, 0);
              WaitForSingleObject(proc, 5000);
              break;
            }
        }
      DWORD code = 0;
      GetExitCodeProcess(proc, &code);
      _exitStatus = (int)code;
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
  NSError *error = nil;
  NSString *anyStream = nil;
  for (NSString *n in [[NSFileManager defaultManager]
                        contentsOfDirectoryAtPath: _tracePath error: NULL])
    if ([n hasPrefix: @"events-"] && [n hasSuffix: @".bin"])
      anyStream = n;
  if (anyStream == nil)
    error = make_error(7, _options.attachPID
      ? @"The profiling helper did not record anything (authentication cancelled or perf_event unavailable)."
      : @"The target did not record anything. It may have exited immediately, been statically linked, or ignored LD_PRELOAD.");
  if ([_delegate respondsToSelector: @selector(recorder:didFinishWithError:)])
    [_delegate recorder: self didFinishWithError: error];
}

- (void) stop
{
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
