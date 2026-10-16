#import "GSPExporter.h"
#import "GSPTrace.h"
#import "GSPAnalysis.h"
#import "GSPCallTree.h"
#import "GSPStackTable.h"
#import "GSPSymbolicator.h"

#include <GSPerformance/gsp_format.h>

static NSError *
export_error(NSString *message)
{
  return [NSError errorWithDomain: @"GSPExporterErrorDomain" code: 1
    userInfo: [NSDictionary dictionaryWithObject: message
                                          forKey: NSLocalizedDescriptionKey]];
}

static NSArray *
symbol_names(GSPProcess *p, uint32_t stack, BOOL rootFirst)
{
  NSArray *syms = [p.symbolicator symbolsForStack: stack];
  NSMutableArray *names = [NSMutableArray arrayWithCapacity: [syms count]];
  if (syms == nil)
    return [NSArray arrayWithObject: @"<Recording Overhead>"];
  for (GSPSymbol *s in rootFirst ? [[syms reverseObjectEnumerator] allObjects] : syms)
    [names addObject: s.name];
  return names;
}

static NSString *
csv_escape(NSString *s)
{
  if (s == nil)
    return @"";
  if ([s rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString: @",\"\n"]].location
      == NSNotFound)
    return s;
  return [NSString stringWithFormat: @"\"%@\"",
          [s stringByReplacingOccurrencesOfString: @"\"" withString: @"\"\""]];
}

@implementation GSPExporter

+ (NSArray *) formats
{
  return [NSArray arrayWithObjects: @"json", @"chrome", @"speedscope",
          @"collapsed", @"csv", nil];
}

+ (NSArray *) csvTables
{
  return [NSArray arrayWithObjects: @"samples", @"allocations", @"signposts",
          @"hangs", @"leaks", @"logs", @"io", nil];
}

+ (NSDictionary *) summaryOfTrace: (GSPTrace *)trace process: (GSPProcess *)p
{
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  GSPTime s = trace.startTime;

  [d setObject: trace.templateName ?: @"" forKey: @"template"];
  [d setObject: trace.instrumentIdentifiers forKey: @"instruments"];
  [d setObject: [NSNumber numberWithDouble: trace.duration] forKey: @"duration"];
  [d setObject: [NSNumber numberWithInt: p.pid] forKey: @"pid"];
  [d setObject: p.executablePath ?: @"" forKey: @"executable"];
  [d setObject: [NSNumber numberWithBool: p.finishedCleanly] forKey: @"finishedCleanly"];

  NSMutableArray *threads = [NSMutableArray array];
  for (GSPThreadInfo *t in [p sortedThreads])
    [threads addObject: [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithUnsignedInt: t.tid], @"tid",
      t.name ?: @"", @"name",
      [NSNumber numberWithBool: t.isMain], @"main", nil]];
  [d setObject: threads forKey: @"threads"];

  uint64_t cpu = 0, wall = 0;
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    {
      if (p.samples[i].kind == GSP_SAMPLE_WALL)
        wall++;
      else
        cpu += p.samples[i].weight;
    }
  [d setObject: [NSNumber numberWithUnsignedLongLong: cpu] forKey: @"cpuSamples"];
  [d setObject: [NSNumber numberWithDouble:
    (double)cpu * (p.sampleIntervalMicroseconds ?: 1000) / 1e6] forKey: @"cpuSeconds"];
  [d setObject: [NSNumber numberWithUnsignedLongLong: wall] forKey: @"wallSamples"];

  if (p.sampleCount)
    {
      GSPCallTree *tree = [GSPCallTree cpuTreeForProcess: p start: 0 end: 0
        threads: nil options: GSPCallTreeTopFunctions];
      NSMutableArray *top = [NSMutableArray array];
      NSArray *kids = [tree.root.children sortedArrayUsingComparator:
        ^NSComparisonResult(GSPCallTreeNode *a, GSPCallTreeNode *b) {
          if (a.selfWeight != b.selfWeight)
            return a.selfWeight > b.selfWeight ? NSOrderedAscending : NSOrderedDescending;
          return [a.name compare: b.name];
        }];
      for (GSPCallTreeNode *n in kids)
        {
          if ([top count] >= 20)
            break;
          [top addObject: [NSDictionary dictionaryWithObjectsAndKeys:
            n.name, @"symbol", n.imageName ?: @"", @"image",
            [NSNumber numberWithUnsignedLongLong: n.selfWeight], @"self",
            [NSNumber numberWithUnsignedLongLong: n.totalWeight], @"total", nil]];
        }
      [d setObject: top forKey: @"topFunctions"];

      GSPHangAnalysis *hangs = [[GSPHangAnalysis alloc] initWithProcess: p
                                                      thresholdSeconds: 0.25];
      NSMutableArray *h = [NSMutableArray array];
      for (GSPHang *hang in hangs.hangs)
        [h addObject: [NSDictionary dictionaryWithObjectsAndKeys:
          [NSNumber numberWithDouble: [trace relativeTime: hang.startTime]], @"start",
          [NSNumber numberWithDouble: hang.duration], @"duration",
          hang.severityName, @"severity", nil]];
      [d setObject: h forKey: @"hangs"];
      [d setObject: [NSNumber numberWithBool: hangs.runLoopDetected] forKey: @"runLoopDetected"];
    }

  if (p.allocationEventCount)
    {
      GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
      NSArray *cats = [a categoriesFrom: 0 to: 0];
      NSMutableArray *c = [NSMutableArray array];
      for (GSPAllocationCategory *cat in cats)
        {
          if ([c count] >= 50)
            break;
          [c addObject: [NSDictionary dictionaryWithObjectsAndKeys:
            cat.name, @"category",
            [NSNumber numberWithUnsignedLongLong: cat.persistentCount], @"persistentCount",
            [NSNumber numberWithUnsignedLongLong: cat.persistentBytes], @"persistentBytes",
            [NSNumber numberWithUnsignedLongLong: cat.transientCount], @"transientCount",
            [NSNumber numberWithUnsignedLongLong: cat.totalCount], @"totalCount",
            [NSNumber numberWithUnsignedLongLong: cat.totalBytes], @"totalBytes", nil]];
        }
      [d setObject: c forKey: @"allocations"];
      [d setObject: [NSNumber numberWithUnsignedLongLong: a.peakLiveBytes]
            forKey: @"peakLiveBytes"];
    }

  if ([p.leakSnapshots count])
    {
      GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: p];
      NSMutableArray *l = [NSMutableArray array];
      for (GSPLeakGroup *g in [la groupsForSnapshot: nil])
        [l addObject: [NSDictionary dictionaryWithObjectsAndKeys:
          g.name, @"category",
          [NSNumber numberWithUnsignedLongLong: g.count], @"count",
          [NSNumber numberWithUnsignedLongLong: g.bytes], @"bytes", nil]];
      [d setObject: l forKey: @"leaks"];
      [d setObject: [NSNumber numberWithUnsignedInteger: [p.leakSnapshots count]]
            forKey: @"leakSnapshots"];
    }

  NSMutableArray *sp = [NSMutableArray array];
  for (GSPSignpostSummary *sum in [GSPSignpostAnalysis summariesForSignposts: p.signposts])
    [sp addObject: [NSDictionary dictionaryWithObjectsAndKeys:
      sum.name, @"name", sum.subsystem, @"subsystem", sum.category, @"category",
      [NSNumber numberWithUnsignedInteger: sum.count], @"count",
      [NSNumber numberWithBool: sum.isEvent], @"event",
      [NSNumber numberWithDouble: sum.totalDuration], @"totalDuration",
      [NSNumber numberWithDouble: sum.averageDuration], @"averageDuration", nil]];
  [d setObject: sp forKey: @"signposts"];

  NSMutableArray *z = [NSMutableArray array];
  for (GSPZombieEvent *ze in p.zombies)
    [z addObject: [NSDictionary dictionaryWithObjectsAndKeys:
      [NSString stringWithFormat: @"0x%llx", (unsigned long long)ze.address], @"address",
      ze.className ?: @"", @"class", ze.selector ?: @"", @"selector",
      [NSNumber numberWithDouble: [trace relativeTime: ze.time]], @"time", nil]];
  [d setObject: z forKey: @"zombies"];
  [d setObject: [NSNumber numberWithUnsignedInteger: [p.logMessages count]] forKey: @"logMessages"];
  if (p.ioEventCount)
    {
      GSPIOAnalysis *io = [[GSPIOAnalysis alloc] initWithProcess: p];
      for (int net = 0; net < 2; net++)
        {
          NSMutableArray *list = [NSMutableArray array];
          for (GSPIOSummary *sum in [io summariesForNetwork: net from: 0 to: 0])
            {
              if ([list count] >= 50)
                break;
              [list addObject: [NSDictionary dictionaryWithObjectsAndKeys:
                sum.name, @"name",
                [NSNumber numberWithUnsignedLongLong: sum.opens], @"opens",
                [NSNumber numberWithUnsignedLongLong: sum.bytesRead], @"bytesRead",
                [NSNumber numberWithUnsignedLongLong: sum.bytesWritten], @"bytesWritten",
                [NSNumber numberWithUnsignedLongLong: sum.errors], @"errors",
                [NSNumber numberWithDouble: sum.totalDuration / 1e9], @"seconds", nil]];
            }
          [d setObject: list forKey: net ? @"network" : @"files"];
        }
    }
  (void)s;
  return d;
}

static NSData *
json_data(id obj, NSError **error)
{
  return [NSJSONSerialization dataWithJSONObject: obj
                                         options: NSJSONWritingPrettyPrinted
                                           error: error];
}

+ (NSData *) chromeTrace: (GSPTrace *)trace process: (GSPProcess *)p error: (NSError **)error
{
  NSMutableArray *events = [NSMutableArray array];
  NSMutableDictionary *frames = [NSMutableDictionary dictionary];
  NSMutableArray *samples = [NSMutableArray array];
  GSPTime base = trace.startTime;
  NSNumber *pid = [NSNumber numberWithInt: p.pid];

#define US(t) [NSNumber numberWithDouble: (double)((t) - base) / 1000.0]

  [events addObject: [NSDictionary dictionaryWithObjectsAndKeys:
    @"process_name", @"name", @"M", @"ph", pid, @"pid",
    [NSDictionary dictionaryWithObject: [p.executablePath lastPathComponent] ?: @"process"
                                forKey: @"name"], @"args", nil]];
  for (GSPThreadInfo *t in [p sortedThreads])
    [events addObject: [NSDictionary dictionaryWithObjectsAndKeys:
      @"thread_name", @"name", @"M", @"ph", pid, @"pid",
      [NSNumber numberWithUnsignedInt: t.tid], @"tid",
      [NSDictionary dictionaryWithObject: t.displayName forKey: @"name"], @"args", nil]];

  for (GSPSignpost *s in p.signposts)
    {
      NSMutableDictionary *e = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        s.name, @"name", s.category ?: @"", @"cat", pid, @"pid",
        [NSNumber numberWithUnsignedInt: s.tid], @"tid", US(s.beginTime), @"ts", nil];
      if (s.isEvent)
        {
          [e setObject: @"i" forKey: @"ph"];
          [e setObject: @"t" forKey: @"s"];
        }
      else
        {
          [e setObject: @"X" forKey: @"ph"];
          [e setObject: [NSNumber numberWithDouble: (double)s.duration / 1000.0] forKey: @"dur"];
        }
      NSMutableDictionary *args = [NSMutableDictionary dictionary];
      if (s.beginMessage)
        [args setObject: s.beginMessage forKey: @"begin"];
      if (s.endMessage)
        [args setObject: s.endMessage forKey: @"end"];
      [args setObject: s.subsystem ?: @"" forKey: @"subsystem"];
      [e setObject: args forKey: @"args"];
      [events addObject: e];
    }

  GSPHangAnalysis *hangs = [[GSPHangAnalysis alloc] initWithProcess: p thresholdSeconds: 0.25];
  GSPThreadInfo *main = p.mainThread;
  for (GSPHang *h in hangs.hangs)
    [events addObject: [NSDictionary dictionaryWithObjectsAndKeys:
      h.severityName, @"name", @"hangs", @"cat", @"X", @"ph", pid, @"pid",
      [NSNumber numberWithUnsignedInt: main ? main.tid : (uint32_t)p.pid], @"tid",
      US(h.startTime), @"ts",
      [NSNumber numberWithDouble: (double)(h.endTime - h.startTime) / 1000.0], @"dur", nil]];

  /* CPU samples: one stack frame node per (parent, symbol) */
  NSMutableDictionary *frameIDs = [NSMutableDictionary dictionary];
  NSMutableDictionary *stackLeaf = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    {
      const GSPSample *s = &p.samples[i];
      if (s->kind == GSP_SAMPLE_WALL)
        continue;
      NSNumber *key = [NSNumber numberWithUnsignedInt: s->stack];
      NSString *leaf = [stackLeaf objectForKey: key];
      if (leaf == nil)
        {
          NSString *parent = nil;
          for (NSString *name in symbol_names(p, s->stack, YES))
            {
              NSString *fk = [NSString stringWithFormat: @"%@|%@", parent ?: @"", name];
              NSString *fid = [frameIDs objectForKey: fk];
              if (fid == nil)
                {
                  fid = [NSString stringWithFormat: @"%lu", (unsigned long)[frameIDs count] + 1];
                  [frameIDs setObject: fid forKey: fk];
                  NSMutableDictionary *fr = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                    name, @"name", @"cpu", @"category", nil];
                  if (parent)
                    [fr setObject: parent forKey: @"parent"];
                  [frames setObject: fr forKey: fid];
                }
              parent = fid;
            }
          leaf = parent ?: @"";
          [stackLeaf setObject: leaf forKey: key];
        }
      if ([leaf length] == 0)
        continue;
      [samples addObject: [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInt: s->tid], @"tid", US(s->time), @"ts",
        @"cpu", @"name", leaf, @"sf",
        [NSNumber numberWithUnsignedInt: s->weight], @"weight", nil]];
    }

  if (p.allocationEventCount)
    {
      GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
      NSUInteger nb = 200;
      double *live = calloc(nb, sizeof(double));
      GSPTime s0 = trace.startTime, e0 = trace.endTime;
      [a liveBytes: live buckets: nb start: s0 end: e0];
      for (NSUInteger b = 0; b < nb; b++)
        [events addObject: [NSDictionary dictionaryWithObjectsAndKeys:
          @"Heap", @"name", @"C", @"ph", pid, @"pid",
          US(s0 + (e0 - s0) * b / nb), @"ts",
          [NSDictionary dictionaryWithObject: [NSNumber numberWithDouble: live[b]]
                                      forKey: @"bytes"], @"args", nil]];
      free(live);
    }
#undef US

  NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:
    events, @"traceEvents", frames, @"stackFrames", samples, @"samples",
    @"ns", @"displayTimeUnit", nil];
  return json_data(root, error);
}

+ (NSData *) speedscope: (GSPTrace *)trace process: (GSPProcess *)p error: (NSError **)error
{
  NSMutableArray *frames = [NSMutableArray array];
  NSMutableDictionary *frameIndex = [NSMutableDictionary dictionary];
  NSMutableArray *profiles = [NSMutableArray array];
  double unit = (p.sampleIntervalMicroseconds ?: 1000) / 1000.0;  /* ms */

  for (GSPThreadInfo *t in [p sortedThreads])
    {
      NSMutableArray *ss = [NSMutableArray array];
      NSMutableArray *weights = [NSMutableArray array];
      for (NSUInteger i = 0; i < p.sampleCount; i++)
        {
          const GSPSample *s = &p.samples[i];
          if (s->tid != t.tid || s->kind == GSP_SAMPLE_WALL)
            continue;
          NSMutableArray *idx = [NSMutableArray array];
          for (NSString *name in symbol_names(p, s->stack, YES))
            {
              NSNumber *fi = [frameIndex objectForKey: name];
              if (fi == nil)
                {
                  fi = [NSNumber numberWithUnsignedInteger: [frames count]];
                  [frameIndex setObject: fi forKey: name];
                  [frames addObject: [NSDictionary dictionaryWithObject: name forKey: @"name"]];
                }
              [idx addObject: fi];
            }
          [ss addObject: idx];
          [weights addObject: [NSNumber numberWithDouble: s->weight * unit]];
        }
      if ([ss count] == 0)
        continue;
      double total = 0;
      for (NSNumber *w in weights)
        total += [w doubleValue];
      [profiles addObject: [NSDictionary dictionaryWithObjectsAndKeys:
        @"sampled", @"type", t.displayName, @"name", @"milliseconds", @"unit",
        [NSNumber numberWithInt: 0], @"startValue",
        [NSNumber numberWithDouble: total], @"endValue",
        ss, @"samples", weights, @"weights", nil]];
    }
  NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:
    @"https://www.speedscope.app/file-format-schema.json", @"$schema",
    [NSDictionary dictionaryWithObject: frames forKey: @"frames"], @"shared",
    profiles, @"profiles",
    [p.executablePath lastPathComponent] ?: @"trace", @"name",
    @"Performance Dashboard", @"exporter", nil];
  return json_data(root, error);
}

+ (NSData *) collapsed: (GSPProcess *)p
{
  NSMutableDictionary *counts = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < p.sampleCount; i++)
    {
      const GSPSample *s = &p.samples[i];
      if (s->kind == GSP_SAMPLE_WALL)
        continue;
      NSString *line = [[symbol_names(p, s->stack, YES) componentsJoinedByString: @";"]
        stringByReplacingOccurrencesOfString: @" " withString: @"_"];
      if ([line length] == 0)
        line = @"[unknown]";
      NSNumber *c = [counts objectForKey: line];
      [counts setObject: [NSNumber numberWithUnsignedLongLong:
        [c unsignedLongLongValue] + s->weight] forKey: line];
    }
  NSMutableString *out = [NSMutableString string];
  for (NSString *k in [[counts allKeys] sortedArrayUsingSelector: @selector(compare:)])
    [out appendFormat: @"%@ %@\n", k, [counts objectForKey: k]];
  return [out dataUsingEncoding: NSUTF8StringEncoding];
}

+ (NSData *) csv: (GSPTrace *)trace process: (GSPProcess *)p table: (NSString *)table
           error: (NSError **)error
{
  NSMutableString *out = [NSMutableString string];

  if ([table isEqual: @"samples"])
    {
      [out appendString: @"time,tid,kind,weight,stack\n"];
      for (NSUInteger i = 0; i < p.sampleCount; i++)
        {
          const GSPSample *s = &p.samples[i];
          [out appendFormat: @"%.6f,%u,%@,%u,%@\n", [trace relativeTime: s->time],
            s->tid, s->kind == GSP_SAMPLE_WALL ? @"wall" : @"cpu", s->weight,
            csv_escape([symbol_names(p, s->stack, NO) componentsJoinedByString: @" <- "])];
        }
    }
  else if ([table isEqual: @"allocations"])
    {
      GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
      [out appendString: @"time,free_time,address,size,category,tid,responsible\n"];
      for (NSUInteger i = 0; i < a.recordCount; i++)
        {
          const GSPAllocationRecord *r = &a.records[i];
          NSArray *names = symbol_names(p, r->stack, NO);
          [out appendFormat: @"%.6f,%@,0x%llx,%llu,%@,%u,%@\n",
            [trace relativeTime: r->allocTime],
            r->freeTime ? [NSString stringWithFormat: @"%.6f", [trace relativeTime: r->freeTime]] : @"",
            (unsigned long long)r->address, (unsigned long long)r->size,
            csv_escape([a.categoryNames objectAtIndex: r->category]), r->tid,
            csv_escape([names count] ? [names objectAtIndex: 0] : @"")];
        }
    }
  else if ([table isEqual: @"signposts"])
    {
      [out appendString: @"start,duration,name,subsystem,category,id,event,begin_message,end_message\n"];
      for (GSPSignpost *s in p.signposts)
        [out appendFormat: @"%.6f,%.6f,%@,%@,%@,%llu,%d,%@,%@\n",
          [trace relativeTime: s.beginTime], (double)s.duration / 1e9,
          csv_escape(s.name), csv_escape(s.subsystem), csv_escape(s.category),
          (unsigned long long)s.signpostID, s.isEvent,
          csv_escape(s.beginMessage), csv_escape(s.endMessage)];
    }
  else if ([table isEqual: @"hangs"])
    {
      GSPHangAnalysis *h = [[GSPHangAnalysis alloc] initWithProcess: p thresholdSeconds: 0.25];
      [out appendString: @"start,duration,severity,stack\n"];
      for (GSPHang *hang in h.hangs)
        [out appendFormat: @"%.6f,%.6f,%@,%@\n", [trace relativeTime: hang.startTime],
          hang.duration, hang.severityName,
          csv_escape([symbol_names(p, hang.representativeStack, NO)
                       componentsJoinedByString: @" <- "])];
    }
  else if ([table isEqual: @"leaks"])
    {
      [out appendString: @"snapshot,address,size,category,responsible\n"];
      for (GSPLeakSnapshot *snap in p.leakSnapshots)
        for (GSPLeak *l in snap.leaks)
          {
            NSArray *names = symbol_names(p, l.stack, NO);
            [out appendFormat: @"%u,0x%llx,%llu,%@,%@\n", snap.ordinal,
              (unsigned long long)l.address, (unsigned long long)l.size,
              csv_escape(l.className ?: [GSPAllocationAnalysis mallocCategoryNameForSize: l.size]),
              csv_escape([names count] ? [names objectAtIndex: 0] : @"")];
          }
    }
  else if ([table isEqual: @"io"])
    {
      GSPIOAnalysis *io = [[GSPIOAnalysis alloc] initWithProcess: p];
      [out appendString: @"time,duration,operation,result,name,network,tid,responsible\n"];
      for (NSUInteger i = 0; i < p.ioEventCount; i++)
        {
          const GSPIOEvent *e = &p.ioEvents[i];
          NSArray *names = symbol_names(p, e->stack, NO);
          [out appendFormat: @"%.6f,%.9f,%@,%lld,%@,%d,%u,%@\n", [trace relativeTime: e->time],
            e->duration / 1e9, [GSPIOAnalysis operationName: e->op], (long long)e->result,
            csv_escape([io nameOfEvent: i]), [io isNetworkEvent: i], e->tid,
            csv_escape([names count] ? [names objectAtIndex: 0] : @"")];
        }
    }
  else if ([table isEqual: @"logs"])
    {
      [out appendString: @"time,tid,level,subsystem,category,message\n"];
      for (GSPLogMessage *m in p.logMessages)
        [out appendFormat: @"%.6f,%u,%d,%@,%@,%@\n", [trace relativeTime: m.time],
          m.tid, m.level, csv_escape(m.subsystem), csv_escape(m.category),
          csv_escape(m.message)];
    }
  else
    {
      if (error)
        *error = export_error([NSString stringWithFormat:
          @"Unknown table \"%@\"; choose one of: %@", table,
          [[self csvTables] componentsJoinedByString: @", "]]);
      return nil;
    }
  return [out dataUsingEncoding: NSUTF8StringEncoding];
}

+ (NSData *) exportTrace: (GSPTrace *)trace process: (GSPProcess *)process
                  format: (NSString *)format table: (NSString *)table
                   error: (NSError **)error
{
  if (process == nil)
    process = trace.targetProcess;
  if ([format isEqual: @"json"])
    return json_data([self summaryOfTrace: trace process: process], error);
  if ([format isEqual: @"chrome"] || [format isEqual: @"perfetto"])
    return [self chromeTrace: trace process: process error: error];
  if ([format isEqual: @"speedscope"])
    return [self speedscope: trace process: process error: error];
  if ([format isEqual: @"collapsed"])
    return [self collapsed: process];
  if ([format isEqual: @"csv"])
    return [self csv: trace process: process table: table ?: @"samples" error: error];
  if (error)
    *error = export_error([NSString stringWithFormat:
      @"Unknown format \"%@\"; choose one of: %@", format,
      [[self formats] componentsJoinedByString: @", "]]);
  return nil;
}

@end
