/* gstrace - command-line recording and analysis (an xctrace equivalent).  */

#import <Foundation/Foundation.h>
#import <GSPerformance/GSPerformance.h>

#include <GSPerformance/gsp_format.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#define GSTRACE_VERSION "0.1.0"

static volatile sig_atomic_t interrupted;

static void
on_interrupt(int sig)
{
  (void)sig;
  interrupted = 1;
}

static void
out(NSString *s)
{
  fputs([s UTF8String], stdout);
}

static void
err(NSString *s)
{
  fprintf(stderr, "gstrace: %s\n", [s UTF8String]);
}

static void
usage(void)
{
  out(@"usage: gstrace <command> [options]\n"
      @"\n"
      @"Recording\n"
      @"  record [options] --launch <executable> [arguments...]\n"
      @"  record [options] --attach <pid>\n"
      @"    --template <name>        template (default \"Time Profiler\"; see `list templates`)\n"
      @"    --instrument <id>        add an instrument (repeatable; replaces the template's)\n"
      @"    --output <path>          trace bundle to create (.gstrace)\n"
      @"    --time-limit <duration>  stop after e.g. 10s, 500ms, 2m\n"
      @"    --sample-interval <dur>  Time Profiler interval (default 1ms)\n"
      @"    --leak-interval <secs>   seconds between leak checks (default 10)\n"
      @"    --follow-children        also record processes the target launches\n"
      @"    --env <NAME=VALUE>       set an environment variable in the target\n"
      @"    --cwd <directory>        working directory for the target\n"
      @"    --frequency <hz>         sampling frequency when attaching (default 1000)\n"
      @"\n"
      @"Analysis\n"
      @"  info <trace>\n"
      @"  report <trace> <calltree|top|hangs|allocations|leaks|signposts|logs|zombies|threads|files|network>\n"
      @"    --pid <pid>  --thread <tid>  --range <start-end seconds>\n"
      @"    --invert  --separate-threads  --hide-system  --flatten-recursion\n"
      @"    --charge-to-caller <symbol>  --prune <symbol>  --focus <symbol>\n"
      @"    --depth <n>  --min-percent <p>  --limit <n>  --by-stack  --persistent  --lines  --events\n"
      @"  export <trace> --format <json|chrome|speedscope|collapsed|csv> [--table <name>]\n"
      @"         [--output <file>] [--pid <pid>]\n"
      @"  symbolicate <trace> [--embed] [address...]\n"
      @"  diff <before> <after> [--kind cpu|allocations|leaks|signposts|files|network]\n"
      @"       [--limit n] [--fail-above percent]   compare two traces (exit 1 above the limit)\n"
      @"\n"
      @"Other\n"
      @"  list <templates|instruments>\n"
      @"  install-helper               install the privileged sampling helper (asks for a password)\n"
      @"  uninstall-helper             remove it again\n"
      @"  version\n");
}

static BOOL
parse_duration(NSString *s, double *seconds)
{
  double scale = 1;
  NSString *num = s;
  if ([s hasSuffix: @"ms"])
    {
      scale = 1e-3;
      num = [s substringToIndex: [s length] - 2];
    }
  else if ([s hasSuffix: @"us"])
    {
      scale = 1e-6;
      num = [s substringToIndex: [s length] - 2];
    }
  else if ([s hasSuffix: @"s"])
    num = [s substringToIndex: [s length] - 1];
  else if ([s hasSuffix: @"m"])
    {
      scale = 60;
      num = [s substringToIndex: [s length] - 1];
    }
  else if ([s hasSuffix: @"h"])
    {
      scale = 3600;
      num = [s substringToIndex: [s length] - 1];
    }
  NSScanner *sc = [NSScanner scannerWithString: num];
  double v;
  if (![sc scanDouble: &v] || ![sc isAtEnd] || v < 0)
    return NO;
  *seconds = v * scale;
  return YES;
}

/* ------------------------------------------------------------------ */
/* record                                                              */

@interface RecordWaiter : NSObject <GSPRecorderDelegate>
@property (nonatomic) BOOL finished;
@property (nonatomic, strong) NSError *error;
@end

@implementation RecordWaiter
- (void) recorder: (GSPRecorder *)recorder didFinishWithError: (NSError *)error
{
  self.error = error;
  self.finished = YES;
}
@end

static int
cmd_record(NSArray *args)
{
  GSPRecordingOptions *opts = [GSPRecordingOptions new];
  NSMutableArray *instruments = [NSMutableArray array];
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  NSString *templateName = @"Time Profiler";
  BOOL explicitTemplate = NO;
  NSUInteger i = 0, n = [args count];

  while (i < n)
    {
      NSString *a = [args objectAtIndex: i++];
      NSString *v = i < n ? [args objectAtIndex: i] : nil;
#define NEED_VALUE() if (v == nil) { err([NSString stringWithFormat: @"%@ needs a value", a]); return 2; } i++
      if ([a isEqual: @"--template"]) { NEED_VALUE(); templateName = v; explicitTemplate = YES; }
      else if ([a isEqual: @"--instrument"]) { NEED_VALUE(); [instruments addObject: v]; }
      else if ([a isEqual: @"--output"] || [a isEqual: @"-o"]) { NEED_VALUE(); opts.outputPath = v; }
      else if ([a isEqual: @"--time-limit"])
        {
          double d;
          NEED_VALUE();
          if (!parse_duration(v, &d)) { err(@"bad --time-limit"); return 2; }
          opts.timeLimit = d;
        }
      else if ([a isEqual: @"--sample-interval"])
        {
          double d;
          NEED_VALUE();
          if (!parse_duration(v, &d) || d <= 0) { err(@"bad --sample-interval"); return 2; }
          opts.sampleIntervalMicroseconds = (unsigned)(d * 1e6);
        }
      else if ([a isEqual: @"--leak-interval"]) { NEED_VALUE(); opts.leakIntervalSeconds = (unsigned)[v intValue]; }
      else if ([a isEqual: @"--follow-children"]) opts.followChildren = YES;
      else if ([a isEqual: @"--env"])
        {
          NEED_VALUE();
          NSRange eq = [v rangeOfString: @"="];
          if (eq.location == NSNotFound) { err(@"--env needs NAME=VALUE"); return 2; }
          [env setObject: [v substringFromIndex: eq.location + 1]
                  forKey: [v substringToIndex: eq.location]];
        }
      else if ([a isEqual: @"--cwd"]) { NEED_VALUE(); opts.workingDirectory = v; }
      else if ([a isEqual: @"--frequency"]) { NEED_VALUE(); opts.perfFrequency = (unsigned)[v intValue]; }
      else if ([a isEqual: @"--attach"]) { NEED_VALUE(); opts.attachPID = [v intValue]; }
      else if ([a isEqual: @"--launch"] || [a isEqual: @"--"])
        {
          if (i >= n) { err(@"--launch needs an executable"); return 2; }
          opts.executablePath = [args objectAtIndex: i++];
          opts.arguments = [args subarrayWithRange: NSMakeRange(i, n - i)];
          i = n;
        }
      else
        {
          err([NSString stringWithFormat: @"unknown option %@", a]);
          return 2;
        }
#undef NEED_VALUE
    }

  if (opts.attachPID)
    {
#if defined(_WIN32)
      /* Windows attaches by injecting the agent: every template works, and
         the recorder finds the executable.  */
#else
      templateName = @"System Time Profiler";
      if ([instruments count] == 0)
        [instruments addObject: GSPInstrumentSystemProfiler];
      opts.executablePath = [[NSFileManager defaultManager]
        pathContentOfSymbolicLinkAtPath: [NSString stringWithFormat: @"/proc/%d/exe",
                                          opts.attachPID]];
#endif
    }
  else if (opts.executablePath == nil)
    {
      err(@"nothing to record: give --launch <executable> or --attach <pid>");
      return 2;
    }
  else if ([opts.executablePath rangeOfString: @"/"].location == NSNotFound)
    {
      /* resolve through PATH like a shell */
      for (NSString *dir in [[[[NSProcessInfo processInfo] environment]
                               objectForKey: @"PATH"] componentsSeparatedByString: @":"])
        {
          NSString *c = [dir stringByAppendingPathComponent: opts.executablePath];
          if ([[NSFileManager defaultManager] isExecutableFileAtPath: c])
            {
              opts.executablePath = c;
              break;
            }
        }
    }

  if ([instruments count] > 0 && !explicitTemplate && !opts.attachPID)
    templateName = @"Custom";
  if ([instruments count] == 0)
    {
      GSPTemplate *t = [GSPTemplate templateNamed: templateName];
      if (t == nil)
        {
          err([NSString stringWithFormat: @"unknown template \"%@\" (see `gstrace list templates`)",
                        templateName]);
          return 2;
        }
      templateName = t.name;
      [instruments addObjectsFromArray: t.instrumentIdentifiers];
    }
  for (NSString *ident in instruments)
    if ([GSPInstrument instrumentWithIdentifier: ident] == nil)
      {
        err([NSString stringWithFormat: @"unknown instrument \"%@\" (see `gstrace list instruments`)",
                      ident]);
        return 2;
      }
  opts.templateName = templateName;
  opts.instrumentIdentifiers = instruments;
  opts.environment = env;

  GSPRecorder *rec = [[GSPRecorder alloc] initWithOptions: opts];
  RecordWaiter *waiter = [RecordWaiter new];
  rec.delegate = waiter;

  signal(SIGINT, on_interrupt);
  signal(SIGTERM, on_interrupt);
  NSError *error = nil;
  if (![rec start: &error])
    {
      err([error localizedDescription]);
      return 1;
    }
  fprintf(stderr, "Recording %s with %s (pid %d) into %s\n",
          [[opts.executablePath lastPathComponent] UTF8String],
          [templateName UTF8String], rec.pid, [rec.tracePath UTF8String]);
  if (opts.timeLimit > 0)
    fprintf(stderr, "Time limit %.1fs. Press Ctrl-C to stop early.\n", opts.timeLimit);

  BOOL stopSent = NO;
  while (!waiter.finished)
    {
      [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                               beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
      if (interrupted && !stopSent)
        {
          stopSent = YES;
          fprintf(stderr, "Stopping...\n");
          [rec stop];
        }
    }
  if (waiter.error)
    {
      err([waiter.error localizedDescription]);
      return 1;
    }
  fprintf(stderr, "Trace saved to %s\n", [rec.tracePath UTF8String]);
  return 0;
}

/* ------------------------------------------------------------------ */
/* analysis helpers                                                    */

typedef struct report_opts
{
  int pid;
  NSMutableSet *threads;
  double rangeStart, rangeEnd;
  BOOL haveRange;
  GSPCallTreeOptions treeOptions;
  NSMutableSet *charge, *prune;
  NSString *focus;
  NSUInteger depth;
  double minPercent;
  NSUInteger limit;
  BOOL byStack, persistent, lines, events;
} report_opts;

static GSPTrace *
open_trace(NSString *path)
{
  NSError *error = nil;
  GSPTrace *t = [GSPTrace traceWithPath: path error: &error];
  if (t == nil)
    err([error localizedDescription]);
  return t;
}

static GSPProcess *
pick_process(GSPTrace *t, int pid)
{
  if (pid == 0)
    return t.targetProcess;
  GSPProcess *p = [t processWithPID: pid];
  if (p == nil)
    err([NSString stringWithFormat: @"no process %d in this trace", pid]);
  return p;
}

static void
range_for(GSPTrace *t, report_opts *o, GSPTime *start, GSPTime *end)
{
  if (o->haveRange)
    {
      *start = [t absoluteTime: o->rangeStart];
      *end = [t absoluteTime: o->rangeEnd];
    }
  else
    {
      *start = 0;
      *end = 0;
    }
}

static NSString *
stack_text(GSPProcess *p, uint32_t stack, NSString *indent, BOOL lines)
{
  NSMutableString *s = [NSMutableString string];
  NSArray *syms = [p.symbolicator symbolsForStack: stack];
  NSArray *addrs = [p.symbolicator addressesForStack: stack];
  for (NSUInteger i = 0; i < [syms count]; i++)
    {
      GSPSymbol *sym = [syms objectAtIndex: i];
      NSString *loc = lines ? [p.symbolicator sourceLocationForFrame:
        [[addrs objectAtIndex: i] unsignedLongLongValue] index: 0] : nil;
      [s appendFormat: @"%@%@  (%@)%@\n", indent, sym.name, sym.imageName ?: @"?",
        loc ? [NSString stringWithFormat: @"  %@", loc] : @""];
    }
  if ([syms count] == 0)
    [s appendFormat: @"%@%@\n", indent, syms ? @"<no stack>" : @"<recording overhead>"];
  return s;
}

static NSString *(^ms_formatter(GSPProcess *p))(uint64_t)
{
  double interval = (p.sampleIntervalMicroseconds ? p.sampleIntervalMicroseconds : 1000) / 1e6;
  return ^NSString *(uint64_t w) {
    return GSPFormatDuration(w * interval);
  };
}

static NSString *(^byte_formatter(void))(uint64_t)
{
  return ^NSString *(uint64_t w) {
    return [GSPAllocationAnalysis formatBytes: w];
  };
}

static GSPCallTree *
configured(GSPCallTree *tree, report_opts *o)
{
  tree.chargedToCaller = o->charge;
  tree.pruned = o->prune;
  tree.focusSymbol = o->focus;
  return tree;
}

/* ------------------------------------------------------------------ */

static int
cmd_info(NSArray *args)
{
  if ([args count] < 1)
    {
      err(@"info needs a trace");
      return 2;
    }
  GSPTrace *t = open_trace([args objectAtIndex: 0]);
  if (t == nil)
    return 1;
  out([NSString stringWithFormat: @"Trace:       %@\n", t.path]);
  out([NSString stringWithFormat: @"Template:    %@\n", t.templateName ?: @"-"]);
  out([NSString stringWithFormat: @"Instruments: %@\n",
       [t.instrumentIdentifiers componentsJoinedByString: @", "]]);
  out([NSString stringWithFormat: @"Started:     %@\n", t.startDate ?: @"-"]);
  out([NSString stringWithFormat: @"Duration:    %@\n", GSPFormatDuration(t.duration)]);
  id host = [t.info objectForKey: @"Host"];
  if (host)
    out([NSString stringWithFormat: @"Host:        %@\n", host]);
  for (GSPProcess *p in t.processes)
    {
      uint64_t cpu = 0, wall = 0;
      for (NSUInteger i = 0; i < p.sampleCount; i++)
        if (p.samples[i].kind == GSP_SAMPLE_WALL)
          wall++;
        else
          cpu += p.samples[i].weight;
      out([NSString stringWithFormat: @"\nProcess %d%@: %@\n", p.pid,
           p == t.targetProcess ? @" (target)" : @"", p.executablePath]);
      out([NSString stringWithFormat: @"  finished cleanly: %@\n", p.finishedCleanly ? @"yes" : @"no"]);
      out([NSString stringWithFormat: @"  threads: %lu  images: %lu  stacks: %lu\n",
           (unsigned long)[p.threads count], (unsigned long)[p.images count],
           (unsigned long)[p.stacks count]]);
      out([NSString stringWithFormat: @"  CPU samples: %llu (%@ CPU)  wall samples: %llu  dropped: %llu\n",
           (unsigned long long)cpu,
           GSPFormatDuration(cpu * (p.sampleIntervalMicroseconds ?: 1000) / 1e6),
           (unsigned long long)wall, (unsigned long long)p.droppedSamples]);
      out([NSString stringWithFormat: @"  allocation events: %lu  class tags: %lu  refcount events: %lu\n",
           (unsigned long)p.allocationEventCount, (unsigned long)p.tagEventCount,
           (unsigned long)p.refCountEventCount]);
      out([NSString stringWithFormat: @"  signposts: %lu  log messages: %lu  leak checks: %lu  zombies: %lu  ObjC methods: %lu\n",
           (unsigned long)[p.signposts count], (unsigned long)[p.logMessages count],
           (unsigned long)[p.leakSnapshots count], (unsigned long)[p.zombies count],
           (unsigned long)[p.methodNames count]]);
    }
  return 0;
}

static int
report_calltree(GSPTrace *t, GSPProcess *p, report_opts *o, BOOL top)
{
  GSPTime s, e;
  range_for(t, o, &s, &e);
  GSPCallTreeOptions opts = o->treeOptions | (top ? GSPCallTreeTopFunctions : 0);
  GSPCallTree *tree = configured([[GSPCallTree alloc] initWithProcess: p], o);
  NSMutableData *in = [NSMutableData data];

  tree.options = opts;
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    {
      const GSPSample *sm = &p.samples[i];
      if (sm->kind == GSP_SAMPLE_WALL || (e && (sm->time < s || sm->time > e)))
        continue;
      if (o->threads && ![o->threads containsObject: [NSNumber numberWithUnsignedInt: sm->tid]])
        continue;
      GSPWeightedStack w = { sm->stack, sm->tid, sm->weight };
      [in appendBytes: &w length: sizeof(w)];
    }
  [tree buildFromStacks: [in bytes] count: [in length] / sizeof(GSPWeightedStack)];
  if (tree.totalWeight == 0)
    {
      out(@"No CPU samples (record with the Time Profiler template).\n");
      return 0;
    }
  out([NSString stringWithFormat: @"Time Profiler: %@ of CPU time, process %d\n\n",
       ms_formatter(p)(tree.totalWeight), p.pid]);
  if (top)
    {
      NSArray *kids = [tree.root.children sortedArrayUsingComparator:
        ^NSComparisonResult(GSPCallTreeNode *a, GSPCallTreeNode *b) {
          if (a.selfWeight != b.selfWeight)
            return a.selfWeight > b.selfWeight ? NSOrderedAscending : NSOrderedDescending;
          return [a.name compare: b.name];
        }];
      NSUInteger limit = o->limit ? o->limit : 25;
      out([NSString stringWithFormat: @"%10@ %7@ %10@  %@\n", @"Self", @"", @"Total", @"Symbol"]);
      for (GSPCallTreeNode *nd in kids)
        {
          if (limit-- == 0)
            break;
          out([NSString stringWithFormat: @"%10@ %6.1f%% %10@  %@  (%@)\n",
               ms_formatter(p)(nd.selfWeight),
               100.0 * nd.selfWeight / tree.totalWeight,
               ms_formatter(p)(nd.totalWeight), nd.name, nd.imageName ?: @"?"]);
        }
      return 0;
    }
  out([tree textWithMaxDepth: o->depth minPercent: o->minPercent
             weightFormatter: ms_formatter(p)]);
  return 0;
}

static int
report_hangs(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  GSPHangAnalysis *h = [[GSPHangAnalysis alloc] initWithProcess: p thresholdSeconds: 0.25];
  if (!h.hasWallSamples)
    {
      out(@"No main-thread samples (record with the Time Profiler or Hangs template).\n");
      return 0;
    }
  if (!h.runLoopDetected)
    {
      out(@"The main thread never waited in a run loop, so hangs cannot be measured\n"
          @"(normal for command-line tools).\n");
      return 0;
    }
  out([NSString stringWithFormat: @"%lu hang(s) of 250 ms or longer\n\n",
       (unsigned long)[h.hangs count]]);
  for (GSPHang *hang in h.hangs)
    {
      out([NSString stringWithFormat: @"%@ at %.3fs, %@\n", hang.severityName,
           [t relativeTime: hang.startTime], GSPFormatDuration(hang.duration)]);
      out(stack_text(p, hang.representativeStack, @"    ", o->lines));
    }
  return 0;
}

static int
report_allocations(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  if (p.allocationEventCount == 0)
    {
      out(@"No allocations recorded (use the Allocations or Leaks template).\n");
      return 0;
    }
  GSPTime s, e;
  range_for(t, o, &s, &e);
  GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
  if (o->byStack)
    {
      GSPCallTree *tree = [a callTreeFrom: s to: e persistentOnly: o->persistent
                                  options: o->treeOptions];
      configured(tree, o);
      out([NSString stringWithFormat: @"%@ allocated by call stack%@\n\n",
           [GSPAllocationAnalysis formatBytes: tree.totalWeight],
           o->persistent ? @" (persistent only)" : @""]);
      out([tree textWithMaxDepth: o->depth minPercent: o->minPercent
                 weightFormatter: byte_formatter()]);
      return 0;
    }
  NSArray *cats = [a categoriesFrom: s to: e];
  NSUInteger limit = o->limit ? o->limit : 40;
  out([NSString stringWithFormat: @"Peak live heap: %@\n\n",
       [GSPAllocationAnalysis formatBytes: a.peakLiveBytes]]);
  out([NSString stringWithFormat: @"%-40@ %14@ %10@ %10@ %14@ %10@\n", @"Category",
       @"Persistent", @"# Persist", @"# Transnt", @"Total Bytes", @"# Total"]);
  for (GSPAllocationCategory *c in cats)
    {
      if (limit-- == 0)
        break;
      NSString *name = [c.name length] > 40 ? [[c.name substringToIndex: 37]
                                               stringByAppendingString: @"..."] : c.name;
      out([NSString stringWithFormat: @"%-40@ %14@ %10llu %10llu %14@ %10llu\n", name,
           [GSPAllocationAnalysis formatBytes: c.persistentBytes],
           (unsigned long long)c.persistentCount, (unsigned long long)c.transientCount,
           [GSPAllocationAnalysis formatBytes: c.totalBytes],
           (unsigned long long)c.totalCount]);
    }
  return 0;
}

static int
report_leaks(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: p];
  GSPLeakSnapshot *snap = la.latestSnapshot;
  if (snap == nil)
    {
      out(@"No leak checks recorded (use the Leaks template).\n");
      return 0;
    }
  out([NSString stringWithFormat: @"%lu leak check(s); latest at %.3fs scanned %llu blocks (%@) in %@\n",
       (unsigned long)[p.leakSnapshots count], [t relativeTime: snap.time],
       (unsigned long long)snap.liveCount, [GSPAllocationAnalysis formatBytes: snap.liveBytes],
       GSPFormatDuration(snap.scanMicroseconds / 1e6)]);
  out([NSString stringWithFormat: @"%lu leaked block(s), %@\n\n",
       (unsigned long)[snap.leaks count], [GSPAllocationAnalysis formatBytes: snap.leakedBytes]]);
  if (o->byStack)
    {
      GSPCallTree *tree = [la callTreeForSnapshot: snap options: o->treeOptions];
      out([tree textWithMaxDepth: o->depth minPercent: o->minPercent
                 weightFormatter: byte_formatter()]);
      return 0;
    }
  NSUInteger limit = o->limit ? o->limit : 20;
  for (GSPLeakGroup *g in [la groupsForSnapshot: snap])
    {
      if (limit-- == 0)
        break;
      out([NSString stringWithFormat: @"%-40@ %6llu  %@\n", g.name,
           (unsigned long long)g.count, [GSPAllocationAnalysis formatBytes: g.bytes]]);
      GSPLeak *first = [g.leaks objectAtIndex: 0];
      out(stack_text(p, first.stack, @"      ", o->lines));
    }
  return 0;
}

static int
report_signposts(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  GSPTime s, e;
  range_for(t, o, &s, &e);
  NSArray *sps = [GSPSignpostAnalysis signposts: p.signposts from: s to: e];
  if ([sps count] == 0)
    {
      out(@"No signposts recorded.\n");
      return 0;
    }
  out([NSString stringWithFormat: @"%-30@ %-24@ %6@ %12@ %12@ %12@\n", @"Name", @"Category",
       @"Count", @"Total", @"Average", @"Max"]);
  for (GSPSignpostSummary *sum in [GSPSignpostAnalysis summariesForSignposts: sps])
    out([NSString stringWithFormat: @"%-30@ %-24@ %6lu %12@ %12@ %12@\n", sum.name,
         sum.category, (unsigned long)sum.count,
         sum.isEvent ? @"event" : GSPFormatDuration(sum.totalDuration),
         sum.isEvent ? @"" : GSPFormatDuration(sum.averageDuration),
         sum.isEvent ? @"" : GSPFormatDuration(sum.maxDuration)]);
  if (o->limit)
    {
      out(@"\n");
      NSUInteger limit = o->limit;
      for (GSPSignpost *sp in sps)
        {
          if (limit-- == 0)
            break;
          out([NSString stringWithFormat: @"%10.4fs %@ %@%@%@\n", [t relativeTime: sp.beginTime],
               sp.isEvent ? @"event   " : GSPFormatDuration((double)sp.duration / 1e9),
               sp.name, sp.beginMessage ? [@" " stringByAppendingString: sp.beginMessage] : @"",
               sp.endMessage ? [@" -> " stringByAppendingString: sp.endMessage] : @""]);
        }
    }
  return 0;
}

static int
report_logs(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  NSUInteger limit = o->limit ? o->limit : NSUIntegerMax;
  if ([p.logMessages count] == 0)
    out(@"No os_log messages recorded.\n");
  for (GSPLogMessage *m in p.logMessages)
    {
      if (limit-- == 0)
        break;
      out([NSString stringWithFormat: @"%10.4fs [%@:%@] %@\n", [t relativeTime: m.time],
           m.subsystem, m.category, m.message]);
    }
  return 0;
}

static int
report_zombies(GSPTrace *t, GSPProcess *p, report_opts *o)
{
  if ([p.zombies count] == 0)
    {
      out(@"No messages to deallocated objects were recorded.\n");
      return 0;
    }
  for (GSPZombieEvent *z in p.zombies)
    {
      out([NSString stringWithFormat:
           @"%.4fs: -%@ sent to deallocated %@ at 0x%llx\n",
           [t relativeTime: z.time], z.selector ?: @"?", z.className ?: @"object",
           (unsigned long long)z.address]);
      out(stack_text(p, z.stack, @"    ", o->lines));
      out(@"  History:\n");
      for (GSPHistoryEvent *h in GSPZombieHistory(p, z))
        {
          NSString *who = @"";
          for (GSPSymbol *sym in [p.symbolicator symbolsForStack: h.stack])
            if (!sym.isSystem)
              {
                who = sym.name;
                break;
              }
          out([NSString stringWithFormat: @"    %.4fs %-11@ %@\n", [t relativeTime: h.time],
               h.kind, who]);
        }
    }
  return 0;
}

static int
report_io(GSPTrace *t, GSPProcess *p, report_opts *o, BOOL network, BOOL events)
{
  GSPTime s, e;
  range_for(t, o, &s, &e);
  GSPIOAnalysis *io = [[GSPIOAnalysis alloc] initWithProcess: p];
  if (!(network ? io.hasNetworkEvents : io.hasFileEvents))
    {
      out(network ? @"No network activity recorded (use the Network template).\n"
                  : @"No file activity recorded (use the File Activity template).\n");
      return 0;
    }
  if (o->byStack)
    {
      GSPCallTree *tree = configured([io callTreeForNetwork: network from: s to: e
                                                    options: o->treeOptions], o);
      [tree rebuild];
      out([tree textWithMaxDepth: o->depth minPercent: o->minPercent
                 weightFormatter: ^NSString *(uint64_t w) { return GSPFormatDuration(w / 1e9); }]);
      return 0;
    }
  if (events)
    {
      NSUInteger limit = o->limit ? o->limit : 50;
      const GSPIOEvent *ev = p.ioEvents;
      out([NSString stringWithFormat: @"%10@ %-8@ %10@ %12@  %@\n", @"Time", @"Op",
           @"Duration", @"Result", network ? @"Peer" : @"File"]);
      [[io eventsForNetwork: network from: s to: e] enumerateIndexesUsingBlock:
        ^(NSUInteger i, BOOL *stop) {
          static NSUInteger shown;
          if (shown++ >= limit)
            {
              *stop = YES;
              return;
            }
          out([NSString stringWithFormat: @"%9.4fs %-8@ %10@ %12lld  %@\n",
               [t relativeTime: ev[i].time], [GSPIOAnalysis operationName: ev[i].op],
               GSPFormatDuration(ev[i].duration / 1e9), (long long)ev[i].result,
               [io nameOfEvent: i]]);
        }];
      return 0;
    }
  NSUInteger limit = o->limit ? o->limit : 30;
  out([NSString stringWithFormat: @"%-44@ %6@ %8@ %12@ %8@ %12@ %6@ %10@\n",
       network ? @"Peer" : @"File", network ? @"Conn" : @"Opens",
       network ? @"Recvs" : @"Reads", network ? @"Received" : @"Bytes Read",
       network ? @"Sends" : @"Writes", network ? @"Sent" : @"Written",
       @"Errors", @"Time"]);
  for (GSPIOSummary *sum in [io summariesForNetwork: network from: s to: e])
    {
      if (limit-- == 0)
        break;
      NSString *name = [sum.name length] > 44
        ? [@"…" stringByAppendingString: [sum.name substringFromIndex: [sum.name length] - 43]]
        : sum.name;
      out([NSString stringWithFormat: @"%-44@ %6llu %8llu %12@ %8llu %12@ %6llu %10@\n", name,
           (unsigned long long)sum.opens, (unsigned long long)sum.reads,
           [GSPAllocationAnalysis formatBytes: sum.bytesRead],
           (unsigned long long)sum.writes, [GSPAllocationAnalysis formatBytes: sum.bytesWritten],
           (unsigned long long)sum.errors, GSPFormatDuration(sum.totalDuration / 1e9)]);
    }
  return 0;
}

static int
report_threads(GSPTrace *t, GSPProcess *p)
{
  NSMutableDictionary *cpu = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    if (p.samples[i].kind != GSP_SAMPLE_WALL)
      {
        NSNumber *k = [NSNumber numberWithUnsignedInt: p.samples[i].tid];
        [cpu setObject: [NSNumber numberWithUnsignedLongLong:
          [[cpu objectForKey: k] unsignedLongLongValue] + p.samples[i].weight] forKey: k];
      }
  for (GSPThreadInfo *th in [p sortedThreads])
    out([NSString stringWithFormat: @"%-28@ CPU %10@  started %.3fs%@\n", th.displayName,
         ms_formatter(p)([[cpu objectForKey: [NSNumber numberWithUnsignedInt: th.tid]]
                          unsignedLongLongValue]),
         [t relativeTime: th.startTime],
         th.endTime ? [NSString stringWithFormat: @"  ended %.3fs", [t relativeTime: th.endTime]] : @""]);
  return 0;
}

static int
cmd_report(NSArray *args)
{
  if ([args count] < 2)
    {
      err(@"report needs a trace and a report name");
      return 2;
    }
  NSString *path = [args objectAtIndex: 0];
  NSString *kind = [args objectAtIndex: 1];
  report_opts o = { 0 };
  o.charge = [NSMutableSet set];
  o.prune = [NSMutableSet set];

  for (NSUInteger i = 2; i < [args count]; i++)
    {
      NSString *a = [args objectAtIndex: i];
      NSString *v = i + 1 < [args count] ? [args objectAtIndex: i + 1] : nil;
      BOOL takes = YES;
      if ([a isEqual: @"--invert"]) { o.treeOptions |= GSPCallTreeInvert; takes = NO; }
      else if ([a isEqual: @"--separate-threads"]) { o.treeOptions |= GSPCallTreeSeparateByThread; takes = NO; }
      else if ([a isEqual: @"--hide-system"]) { o.treeOptions |= GSPCallTreeHideSystemLibraries; takes = NO; }
      else if ([a isEqual: @"--flatten-recursion"]) { o.treeOptions |= GSPCallTreeFlattenRecursion; takes = NO; }
      else if ([a isEqual: @"--by-stack"]) { o.byStack = YES; takes = NO; }
      else if ([a isEqual: @"--persistent"]) { o.persistent = YES; takes = NO; }
      else if ([a isEqual: @"--lines"]) { o.lines = YES; takes = NO; }
      else if ([a isEqual: @"--events"]) { o.events = YES; takes = NO; }
      else if (v == nil)
        {
          err([NSString stringWithFormat: @"%@ needs a value (or is unknown)", a]);
          return 2;
        }
      else if ([a isEqual: @"--pid"]) o.pid = [v intValue];
      else if ([a isEqual: @"--thread"])
        {
          if (o.threads == nil)
            o.threads = [NSMutableSet set];
          [o.threads addObject: [NSNumber numberWithUnsignedInt: (uint32_t)[v intValue]]];
        }
      else if ([a isEqual: @"--range"])
        {
          NSArray *parts = [v componentsSeparatedByString: @"-"];
          if ([parts count] != 2) { err(@"--range is start-end in seconds"); return 2; }
          o.rangeStart = [[parts objectAtIndex: 0] doubleValue];
          o.rangeEnd = [[parts objectAtIndex: 1] doubleValue];
          o.haveRange = YES;
        }
      else if ([a isEqual: @"--depth"]) o.depth = (NSUInteger)[v intValue];
      else if ([a isEqual: @"--min-percent"]) o.minPercent = [v doubleValue];
      else if ([a isEqual: @"--limit"]) o.limit = (NSUInteger)[v intValue];
      else if ([a isEqual: @"--charge-to-caller"]) [o.charge addObject: v];
      else if ([a isEqual: @"--prune"]) [o.prune addObject: v];
      else if ([a isEqual: @"--focus"]) o.focus = v;
      else
        {
          err([NSString stringWithFormat: @"unknown option %@", a]);
          return 2;
        }
      if (takes)
        i++;
    }

  GSPTrace *t = open_trace(path);
  if (t == nil)
    return 1;
  GSPProcess *p = pick_process(t, o.pid);
  if (p == nil)
    return 1;
  if ([kind isEqual: @"calltree"])
    return report_calltree(t, p, &o, NO);
  if ([kind isEqual: @"top"])
    return report_calltree(t, p, &o, YES);
  if ([kind isEqual: @"hangs"])
    return report_hangs(t, p, &o);
  if ([kind isEqual: @"allocations"])
    return report_allocations(t, p, &o);
  if ([kind isEqual: @"leaks"])
    return report_leaks(t, p, &o);
  if ([kind isEqual: @"signposts"])
    return report_signposts(t, p, &o);
  if ([kind isEqual: @"logs"])
    return report_logs(t, p, &o);
  if ([kind isEqual: @"zombies"])
    return report_zombies(t, p, &o);
  if ([kind isEqual: @"threads"])
    return report_threads(t, p);
  if ([kind isEqual: @"files"])
    return report_io(t, p, &o, NO, o.events);
  if ([kind isEqual: @"network"])
    return report_io(t, p, &o, YES, o.events);
  err([NSString stringWithFormat: @"unknown report \"%@\"", kind]);
  return 2;
}

static int
cmd_export(NSArray *args)
{
  NSString *format = nil, *table = nil, *output = nil;
  int pid = 0;

  if ([args count] < 1)
    {
      err(@"export needs a trace");
      return 2;
    }
  for (NSUInteger i = 1; i < [args count]; i += 2)
    {
      NSString *a = [args objectAtIndex: i];
      NSString *v = i + 1 < [args count] ? [args objectAtIndex: i + 1] : nil;
      if (v == nil)
        {
          err([NSString stringWithFormat: @"%@ needs a value", a]);
          return 2;
        }
      if ([a isEqual: @"--format"]) format = v;
      else if ([a isEqual: @"--table"]) table = v;
      else if ([a isEqual: @"--output"] || [a isEqual: @"-o"]) output = v;
      else if ([a isEqual: @"--pid"]) pid = [v intValue];
      else
        {
          err([NSString stringWithFormat: @"unknown option %@", a]);
          return 2;
        }
    }
  if (format == nil)
    {
      err(@"export needs --format");
      return 2;
    }
  GSPTrace *t = open_trace([args objectAtIndex: 0]);
  if (t == nil)
    return 1;
  GSPProcess *p = pick_process(t, pid);
  if (p == nil)
    return 1;
  NSError *error = nil;
  NSData *d = [GSPExporter exportTrace: t process: p format: format table: table error: &error];
  if (d == nil)
    {
      err([error localizedDescription]);
      return 1;
    }
  if (output == nil || [output isEqual: @"-"])
    fwrite([d bytes], 1, [d length], stdout);
  else if (![d writeToFile: output atomically: YES])
    {
      err([NSString stringWithFormat: @"cannot write %@", output]);
      return 1;
    }
  return 0;
}

static int
cmd_symbolicate(NSArray *args)
{
  if ([args count] < 1)
    {
      err(@"symbolicate needs a trace");
      return 2;
    }
  GSPTrace *t = open_trace([args objectAtIndex: 0]);
  if (t == nil)
    return 1;
  BOOL embed = NO;
  NSMutableArray *addrs = [NSMutableArray array];
  for (NSUInteger i = 1; i < [args count]; i++)
    {
      NSString *a = [args objectAtIndex: i];
      if ([a isEqual: @"--embed"])
        embed = YES;
      else
        [addrs addObject: a];
    }
  if (embed)
    {
      for (GSPProcess *p in t.processes)
        {
          NSDictionary *table = [p.symbolicator symbolTableForAllStacks];
          NSString *file = [t.path stringByAppendingPathComponent:
            [NSString stringWithFormat: @"symbols-%d.plist", p.pid]];
          [table writeToFile: file atomically: YES];
          out([NSString stringWithFormat: @"%@: %lu symbols\n", [file lastPathComponent],
               (unsigned long)[table count]]);
        }
    }
  GSPProcess *p = t.targetProcess;
  for (NSString *a in addrs)
    {
      unsigned long long v = strtoull([a UTF8String], NULL, 0);
      GSPSymbol *s = [p.symbolicator symbolForAddress: v];
      NSString *loc = [p.symbolicator sourceLocationForFrame: v index: 0];
      out([NSString stringWithFormat: @"%@  %@  (%@)%@\n", a, s.name, s.imageName ?: @"?",
           loc ? [@"  " stringByAppendingString: loc] : @""]);
    }
  return 0;
}

static int
cmd_diff(NSArray *args)
{
  NSString *kindName = @"cpu";
  NSUInteger limit = 25;
  double threshold = NAN;
  NSMutableArray *paths = [NSMutableArray array];

  for (NSUInteger i = 0; i < [args count]; i++)
    {
      NSString *a = [args objectAtIndex: i];
      NSString *v = i + 1 < [args count] ? [args objectAtIndex: i + 1] : nil;
      if ([a isEqual: @"--kind"] && v) { kindName = v; i++; }
      else if ([a isEqual: @"--limit"] && v) { limit = (NSUInteger)[v intValue]; i++; }
      else if ([a isEqual: @"--fail-above"] && v) { threshold = [v doubleValue]; i++; }
      else if ([a hasPrefix: @"--"])
        {
          err([NSString stringWithFormat: @"unknown option %@", a]);
          return 2;
        }
      else
        [paths addObject: a];
    }
  GSPComparisonKind kind;
  if ([paths count] != 2 || ![GSPComparison kindFromString: kindName kind: &kind])
    {
      err(@"diff <before.gstrace> <after.gstrace> [--kind cpu|allocations|leaks|signposts|files|network] [--limit n] [--fail-above percent]");
      return 2;
    }
  GSPTrace *before = open_trace([paths objectAtIndex: 0]);
  GSPTrace *after = open_trace([paths objectAtIndex: 1]);
  if (before == nil || after == nil)
    return 1;
  BOOL time = [GSPComparison kindIsTime: kind];
  NSString *(^fmt)(double) = ^NSString *(double v) {
    if (time)
      return GSPFormatDuration(fabs(v));
    return [GSPAllocationAnalysis formatBytes: (uint64_t)fabs(v)];
  };
  GSPComparisonRow *total = [GSPComparison totalFor: before with: after kind: kind];
  out([NSString stringWithFormat: @"%12@ %12@ %13@ %8@  %@\n", @"Before", @"After", @"Change", @"%", @"Name"]);
  out([NSString stringWithFormat: @"%12@ %12@ %@%12@ %7.1f%%  %@\n", fmt(total.before), fmt(total.after),
       total.delta < 0 ? @"-" : @"+", fmt(total.delta),
       isnan(total.percentChange) ? 0.0 : total.percentChange, @"(total)"]);
  for (GSPComparisonRow *r in [GSPComparison compare: before with: after kind: kind])
    {
      if (limit-- == 0)
        break;
      NSString *pct = isnan(r.percentChange) ? @"    new"
        : [NSString stringWithFormat: @"%7.1f%%", r.percentChange];
      out([NSString stringWithFormat: @"%12@ %12@ %@%12@ %@  %@\n", fmt(r.before), fmt(r.after),
           r.delta < 0 ? @"-" : @"+", fmt(r.delta), pct, r.name]);
    }
  if (!isnan(threshold) && !isnan(total.percentChange) && total.percentChange > threshold)
    {
      err([NSString stringWithFormat: @"total grew by %.1f%%, more than %.1f%%",
           total.percentChange, threshold]);
      return 1;
    }
  return 0;
}

static int
cmd_list(NSArray *args)
{
  NSString *what = [args count] ? [args objectAtIndex: 0] : @"templates";
  if ([what hasPrefix: @"template"])
    {
      for (GSPTemplate *t in [GSPTemplate allTemplates])
        out([NSString stringWithFormat: @"%-22@ %@\n%-22@ instruments: %@\n", t.name, t.summary,
             @"", [t.instrumentIdentifiers count]
               ? [t.instrumentIdentifiers componentsJoinedByString: @", "] : @"(none)"]);
      return 0;
    }
  if ([what hasPrefix: @"instrument"])
    {
      for (GSPInstrument *i in [GSPInstrument allInstruments])
        out([NSString stringWithFormat: @"%-22@ %-22@ %@%@\n", i.identifier, i.name, i.summary,
             i.requiresPrivilegedHelper ? @" [helper]" : @""]);
      return 0;
    }
  err(@"list templates|instruments");
  return 2;
}

static int
cmd_uninstall_helper(void)
{
  NSError *error = nil;
  NSString *staging = [GSPRecorder stageHelperForInstall: &error];
  if (staging == nil)
    {
      err([error localizedDescription]);
      return 1;
    }
  out(@"Removing the profiling helper (you will be asked for an administrator password)\n");
  NSTask *task = [NSTask launchedTaskWithLaunchPath: @"/usr/bin/pkexec"
    arguments: [NSArray arrayWithObjects:
      [staging stringByAppendingPathComponent: @"gstrace-helper"], @"uninstall", nil]];
  [task waitUntilExit];
  [[NSFileManager defaultManager] removeItemAtPath: staging error: NULL];
  return [task terminationStatus];
}

static int
cmd_install_helper(NSArray *args)
{
  /* Find the helper and policy next to this tool (build tree or install),
     copy them somewhere root can read, then run the helper's installer
     through pkexec.  */
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  NSString *staging = [GSPRecorder stageHelperForInstall: &error];
  if (staging == nil)
    {
      err([error localizedDescription]);
      return 1;
    }
  out([NSString stringWithFormat: @"Installing %@ (you will be asked for an administrator password)\n",
       [GSPRecorder helperInstallLocation]]);
  NSTask *task = [NSTask launchedTaskWithLaunchPath: @"/usr/bin/pkexec"
    arguments: [NSArray arrayWithObjects:
      [staging stringByAppendingPathComponent: @"gstrace-helper"], @"install",
      @"--source", staging, nil]];
  [task waitUntilExit];
  [fm removeItemAtPath: staging error: NULL];
  (void)args;
  return [task terminationStatus];
}

int
main(int argc, const char **argv)
{
  @autoreleasepool
    {
      NSArray *all = [[NSProcessInfo processInfo] arguments];
      NSArray *args = [all count] > 2
        ? [all subarrayWithRange: NSMakeRange(2, [all count] - 2)] : [NSArray array];
      NSString *cmd = [all count] > 1 ? [all objectAtIndex: 1] : nil;

      (void)argc;
      (void)argv;
      if (cmd == nil || [cmd isEqual: @"help"] || [cmd isEqual: @"--help"] || [cmd isEqual: @"-h"])
        {
          usage();
          return cmd == nil ? 2 : 0;
        }
      if ([cmd isEqual: @"version"] || [cmd isEqual: @"--version"])
        {
          out(@"gstrace " GSTRACE_VERSION "\n");
          return 0;
        }
      if ([cmd isEqual: @"record"])
        return cmd_record(args);
      if ([cmd isEqual: @"info"])
        return cmd_info(args);
      if ([cmd isEqual: @"report"])
        return cmd_report(args);
      if ([cmd isEqual: @"export"])
        return cmd_export(args);
      if ([cmd isEqual: @"symbolicate"])
        return cmd_symbolicate(args);
      if ([cmd isEqual: @"list"])
        return cmd_list(args);
      if ([cmd isEqual: @"diff"])
        return cmd_diff(args);
      if ([cmd isEqual: @"install-helper"])
        return cmd_install_helper(args);
      if ([cmd isEqual: @"uninstall-helper"])
        return cmd_uninstall_helper();
      err([NSString stringWithFormat: @"unknown command \"%@\"", cmd]);
      usage();
      return 2;
    }
}
