#import "PDTrackRenderer.h"
#import "PDTheme.h"

#include <GSPerformance/gsp_format.h>
#include <GSPerformance/gsp_signpost.h>
#include <math.h>

#define TRACK_HEIGHT 64.0

@implementation PDTrackRenderer
{
  NSArray *_tracks;
  GSPHangAnalysis *_hangs;
  GSPAllocationAnalysis *_allocs;
  GSPLeakAnalysis *_leaks;
  GSPIOAnalysis *_io;
  NSMutableDictionary *_signpostLanes;   /* name -> color index */
  double _peakCPU;
}

- (instancetype) initWithTrace: (GSPTrace *)trace
{
  if ((self = [super init]) != nil)
    {
      _trace = trace;
      _process = trace.targetProcess;
      _signpostLanes = [NSMutableDictionary dictionary];
      [self rebuildTracks];
    }
  return self;
}

- (void) rebuildTracks
{
  NSArray *order = [NSArray arrayWithObjects: GSPInstrumentTimeProfiler,
    GSPInstrumentSystemProfiler, GSPInstrumentHangs, GSPInstrumentPointsOfInterest,
    GSPInstrumentLogging, GSPInstrumentAllocations, GSPInstrumentLeaks,
    GSPInstrumentZombies, GSPInstrumentFileActivity, GSPInstrumentNetwork, nil];
  NSArray *have = _trace.instrumentIdentifiers;
  NSMutableArray *tracks = [NSMutableArray array];

  /* the template's order first, then anything else in a fixed order */
  NSMutableArray *ordered = [NSMutableArray array];
  for (NSString *ident in have)
    if ([order containsObject: ident] && ![ordered containsObject: ident])
      [ordered addObject: ident];
  for (NSString *ident in order)
    if (![ordered containsObject: ident])
      [ordered addObject: ident];
  for (NSString *ident in ordered)
    {
      BOOL present = [have containsObject: ident];
      /* traces without Info.plist instrument lists: infer from data */
      if (!present && [have count] == 0)
        {
          if ([ident isEqual: GSPInstrumentTimeProfiler])
            present = _process.sampleCount > 0;
          else if ([ident isEqual: GSPInstrumentPointsOfInterest])
            present = [_process.signposts count] > 0;
          else if ([ident isEqual: GSPInstrumentAllocations])
            present = _process.allocationEventCount > 0;
          else if ([ident isEqual: GSPInstrumentLeaks])
            present = [_process.leakSnapshots count] > 0;
        }
      if (present)
        [tracks addObject: ident];
    }
  if ([tracks count] == 0)
    [tracks addObject: GSPInstrumentTimeProfiler];

  /* Threads that used at least 2% of the CPU get their own sub-track
     under the Time Profiler, as in Apple Instruments.  */
  NSUInteger tp = [tracks indexOfObject: GSPInstrumentTimeProfiler];
  if (tp == NSNotFound)
    tp = [tracks indexOfObject: GSPInstrumentSystemProfiler];
  if (tp != NSNotFound)
    {
      NSMutableDictionary *cpu = [NSMutableDictionary dictionary];
      uint64_t total = 0;
      for (NSUInteger i = 0; i < _process.sampleCount; i++)
        {
          const GSPSample *sm = &_process.samples[i];
          if (sm->kind == GSP_SAMPLE_WALL)
            continue;
          NSNumber *k = [NSNumber numberWithUnsignedInt: sm->tid];
          [cpu setObject: [NSNumber numberWithUnsignedLongLong:
            [[cpu objectForKey: k] unsignedLongLongValue] + sm->weight] forKey: k];
          total += sm->weight;
        }
      if ([cpu count] > 1)
        {
          NSUInteger at = tp + 1;
          for (GSPThreadInfo *t in [_process sortedThreads])
            {
              uint64_t w = [[cpu objectForKey: [NSNumber numberWithUnsignedInt: t.tid]]
                             unsignedLongLongValue];
              if (total && w * 50 >= total)
                [tracks insertObject: [NSString stringWithFormat: @"thread:%u", t.tid]
                             atIndex: at++];
            }
        }
    }
  _tracks = tracks;
}

- (uint32_t) threadForTrack: (NSUInteger)track
{
  NSString *ident = [self instrumentForTrack: track];
  return [ident hasPrefix: @"thread:"] ? (uint32_t)[[ident substringFromIndex: 7] intValue] : 0;
}

- (NSArray *) trackIdentifiers { return _tracks; }

/* A new GSPTrace (the finished recording, read again) has its own process
   objects: show the same process in it, or the analyses keep the old one.  */
- (void) setTrace: (GSPTrace *)trace
{
  int pid = _process.pid;
  _trace = trace;
  _process = [trace processWithPID: pid] ?: trace.targetProcess;
}

- (void) setProcess: (GSPProcess *)process
{
  _process = process;
  [self invalidate];
}

- (void) invalidate
{
  _hangs = nil;
  _allocs = nil;
  _leaks = nil;
  _io = nil;
  _peakCPU = 0;
  [self rebuildTracks];
}

- (GSPHangAnalysis *) hangAnalysis
{
  if (_hangs == nil)
    _hangs = [[GSPHangAnalysis alloc] initWithProcess: _process thresholdSeconds: 0.25];
  return _hangs;
}

- (GSPAllocationAnalysis *) allocationAnalysis
{
  if (_allocs == nil)
    _allocs = [[GSPAllocationAnalysis alloc] initWithProcess: _process];
  return _allocs;
}

- (GSPLeakAnalysis *) leakAnalysis
{
  if (_leaks == nil)
    _leaks = [[GSPLeakAnalysis alloc] initWithProcess: _process];
  return _leaks;
}

- (GSPIOAnalysis *) ioAnalysis
{
  if (_io == nil)
    _io = [[GSPIOAnalysis alloc] initWithProcess: _process];
  return _io;
}

- (NSString *) instrumentForTrack: (NSUInteger)track
{
  return track < [_tracks count] ? [_tracks objectAtIndex: track] : nil;
}

- (NSUInteger) trackForInstrument: (NSString *)identifier
{
  return [_tracks indexOfObject: identifier];
}

/* ------------------------------------------------------------------ */
/* data source                                                         */

- (NSUInteger) numberOfTracksInTimeline: (PDTimelineView *)view
{
  return [_tracks count];
}

- (NSString *) timeline: (PDTimelineView *)view titleOfTrack: (NSUInteger)track
{
  uint32_t tid = [self threadForTrack: track];
  if (tid)
    {
      GSPThreadInfo *t = [_process.threads objectForKey: [NSNumber numberWithUnsignedInt: tid]];
      return [@"    " stringByAppendingString: t ? t.displayName
              : [NSString stringWithFormat: @"Thread %u", tid]];
    }
  return [[GSPInstrument instrumentWithIdentifier: [self instrumentForTrack: track]] name];
}

- (double) cpuSeconds
{
  uint64_t w = 0;
  for (NSUInteger i = 0; i < _process.sampleCount; i++)
    if (_process.samples[i].kind != GSP_SAMPLE_WALL)
      w += _process.samples[i].weight;
  return (double)w * (_process.sampleIntervalMicroseconds ?: 1000) / 1e6;
}

- (NSString *) timeline: (PDTimelineView *)view subtitleOfTrack: (NSUInteger)track
{
  NSString *ident = [self instrumentForTrack: track];
  if ([self threadForTrack: track])
    return nil;
  if ([ident isEqual: GSPInstrumentTimeProfiler] || [ident isEqual: GSPInstrumentSystemProfiler])
    return [NSString stringWithFormat: @"%@ CPU", GSPFormatDuration([self cpuSeconds])];
  if ([ident isEqual: GSPInstrumentHangs])
    {
      GSPHangAnalysis *h = [self hangAnalysis];
      if (!h.hasWallSamples)
        return @"No main-thread samples";
      if (!h.runLoopDetected)
        return @"No run loop detected";
      return [NSString stringWithFormat: @"%lu hang%@", (unsigned long)[h.hangs count],
              [h.hangs count] == 1 ? @"" : @"s"];
    }
  if ([ident isEqual: GSPInstrumentPointsOfInterest])
    return [NSString stringWithFormat: @"%lu signposts", (unsigned long)[_process.signposts count]];
  if ([ident isEqual: GSPInstrumentLogging])
    return [NSString stringWithFormat: @"%lu messages", (unsigned long)[_process.logMessages count]];
  if ([ident isEqual: GSPInstrumentAllocations])
    return [NSString stringWithFormat: @"Peak %@",
            [GSPAllocationAnalysis formatBytes: [self allocationAnalysis].peakLiveBytes]];
  if ([ident isEqual: GSPInstrumentLeaks])
    {
      GSPLeakSnapshot *s = [self leakAnalysis].latestSnapshot;
      if (s == nil)
        return @"No checks yet";
      return [NSString stringWithFormat: @"%lu leaks, %@", (unsigned long)[s.leaks count],
              [GSPAllocationAnalysis formatBytes: s.leakedBytes]];
    }
  if ([ident isEqual: GSPInstrumentZombies])
    return [NSString stringWithFormat: @"%lu zombie messages", (unsigned long)[_process.zombies count]];
  if ([ident isEqual: GSPInstrumentFileActivity] || [ident isEqual: GSPInstrumentNetwork])
    {
      BOOL net = [ident isEqual: GSPInstrumentNetwork];
      uint64_t rd = 0, wr = 0;
      for (GSPIOSummary *sum in [[self ioAnalysis] summariesForNetwork: net from: 0 to: 0])
        {
          rd += sum.bytesRead;
          wr += sum.bytesWritten;
        }
      return [NSString stringWithFormat: net ? @"%@ in, %@ out" : @"%@ read, %@ written",
              [GSPAllocationAnalysis formatBytes: rd], [GSPAllocationAnalysis formatBytes: wr]];
    }
  return nil;
}

- (CGFloat) timeline: (PDTimelineView *)view heightOfTrack: (NSUInteger)track
{
  return [self threadForTrack: track] ? 36.0 : TRACK_HEIGHT;
}

static void
draw_area(double *values, NSUInteger n, double maxValue, NSRect rect, NSColor *color)
{
  if (n == 0 || maxValue <= 0)
    return;
  NSBezierPath *path = [NSBezierPath bezierPath];
  CGFloat bottom = NSMaxY(rect);
  CGFloat step = rect.size.width / n;
  [path moveToPoint: NSMakePoint(rect.origin.x, bottom)];
  for (NSUInteger i = 0; i < n; i++)
    {
      double v = values[i] / maxValue;
      if (v > 1)
        v = 1;
      CGFloat y = bottom - (CGFloat)v * rect.size.height;
      [path lineToPoint: NSMakePoint(rect.origin.x + i * step, y)];
      [path lineToPoint: NSMakePoint(rect.origin.x + (i + 1) * step, y)];
    }
  [path lineToPoint: NSMakePoint(NSMaxX(rect), bottom)];
  [path closePath];
  [[PDTheme color: color alpha: 0.45] set];
  [path fill];
  [color set];
  [path setLineWidth: 1];
  [path stroke];
}

static void
draw_label(NSString *s, NSPoint p, NSColor *color)
{
  NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
    [PDTheme smallFont], NSFontAttributeName, color, NSForegroundColorAttributeName, nil];
  [s drawAtPoint: p withAttributes: a];
}

- (GSPTime) abs: (double)seconds
{
  return [_trace absoluteTime: seconds];
}

- (void) drawCPU: (NSRect)r from: (double)start to: (double)end
{
  [self drawCPU: r from: start to: end thread: 0];
}

- (void) drawCPU: (NSRect)r from: (double)start to: (double)end thread: (uint32_t)onlyTid
{
  NSUInteger n = MAX(1, (NSUInteger)(r.size.width / 2));
  double *v = calloc(n, sizeof(double));
  GSPTime s = [self abs: start], e = [self abs: end];
  const GSPSample *samples = _process.samples;
  NSUInteger count = _process.sampleCount;
  double interval = (_process.sampleIntervalMicroseconds ?: 1000) / 1e6;
  double bucket = (end - start) / n;

  /* binary search for the first sample >= s */
  NSUInteger lo = 0, hi = count;
  while (lo < hi)
    {
      NSUInteger mid = (lo + hi) / 2;
      if (samples[mid].time < s)
        lo = mid + 1;
      else
        hi = mid;
    }
  /* A sample of weight w stands for w intervals of CPU time ending at its
     timestamp (CPU-time timers fire on the scheduler tick), so spread it
     over that span instead of piling it into one bucket.  */
  for (NSUInteger i = lo; i < count && samples[i].time <= e + (GSPTime)(interval * 1e9 * 64); i++)
    {
      if (samples[i].kind == GSP_SAMPLE_WALL || (onlyTid && samples[i].tid != onlyTid))
        continue;
      double t1 = (double)((int64_t)(samples[i].time - s)) / 1e9;
      double t0 = t1 - samples[i].weight * interval;
      if (t1 < 0)
        continue;
      double cpu = samples[i].weight * interval;
      double span = t1 - t0;
      NSInteger b0 = (NSInteger)floor(t0 / bucket), b1 = (NSInteger)floor(t1 / bucket);
      for (NSInteger b = MAX(0, b0); b <= b1 && b < (NSInteger)n; b++)
        {
          double lo2 = MAX(t0, b * bucket), hi2 = MIN(t1, (b + 1) * bucket);
          if (hi2 > lo2)
            v[b] += cpu * (hi2 - lo2) / span;
        }
    }
  /* the first samples also cover time before the visible start */
  /* Smooth over a few sampling intervals: timer jitter otherwise shows
     up as spikes when zoomed in.  */
  NSUInteger win = (NSUInteger)ceil(4 * interval / bucket);
  if (win > 1)
    {
      double *sm = calloc(n, sizeof(double));
      double acc = 0;
      for (NSUInteger i = 0; i < n; i++)
        {
          acc += v[i];
          if (i >= win)
            acc -= v[i - win];
          sm[i] = acc / (double)MIN(win, i + 1);
        }
      memcpy(v, sm, n * sizeof(double));
      free(sm);
    }
  double peak = 0;
  for (NSUInteger i = 0; i < n; i++)
    {
      v[i] = v[i] / bucket * 100.0;   /* CPU % */
      if (v[i] > peak)
        peak = v[i];
    }
  double scale = MAX(100.0, ceil(peak / 100.0 - 0.15) * 100.0);
  draw_area(v, n, scale, NSInsetRect(r, 0, 2), [PDTheme cpuColor]);
  draw_label([NSString stringWithFormat: @"%.0f%%", scale],
             NSMakePoint(r.origin.x + 4, r.origin.y), [PDTheme secondaryTextColor]);
  free(v);
}

- (void) drawHangs: (NSRect)r from: (double)start to: (double)end view: (PDTimelineView *)view
{
  GSPHangAnalysis *h = [self hangAnalysis];
  if (h.runLoopDetected)
    {
      /* main-thread busy fraction (not waiting in the run loop) */
      NSUInteger n = MAX(1, (NSUInteger)(r.size.width / 4));
      double *busy = calloc(n, sizeof(double));
      [h busyFraction: busy buckets: n start: [self abs: start] end: [self abs: end]];
      NSRect graph = NSMakeRect(r.origin.x, r.origin.y + r.size.height * 0.5,
                                r.size.width, r.size.height * 0.5);
      draw_area(busy, n, 1.0, graph, [PDTheme logColor]);
      free(busy);
    }

  double span = end - start;
  for (GSPHang *hang in h.hangs)
    {
      double hs = [_trace relativeTime: hang.startTime];
      double he = [_trace relativeTime: hang.endTime];
      if (he < start || hs > end)
        continue;
      CGFloat x0 = r.origin.x + (CGFloat)((hs - start) / span) * r.size.width;
      CGFloat x1 = r.origin.x + (CGFloat)((he - start) / span) * r.size.width;
      NSRect bar = NSMakeRect(x0, r.origin.y + 4, MAX(2, x1 - x0), r.size.height * 0.45);
      [[PDTheme hangColor: hang.severity] set];
      NSRectFill(bar);
      if (bar.size.width > 60)
        draw_label([NSString stringWithFormat: @"%@ %@", hang.severityName,
                    GSPFormatDuration(hang.duration)],
                   NSMakePoint(x0 + 4, bar.origin.y + 2), [NSColor whiteColor]);
    }
  if (!h.runLoopDetected)
    draw_label(h.hasWallSamples ? @"Main thread never waited in a run loop"
                                : @"No main-thread samples",
               NSMakePoint(r.origin.x + 8, r.origin.y + 4), [PDTheme secondaryTextColor]);
}

- (NSUInteger) colorIndexForSignpost: (NSString *)name
{
  NSNumber *idx = [_signpostLanes objectForKey: name];
  if (idx == nil)
    {
      idx = [NSNumber numberWithUnsignedInteger: [_signpostLanes count]];
      [_signpostLanes setObject: idx forKey: name];
    }
  return [idx unsignedIntegerValue];
}

- (void) drawSignposts: (NSRect)r from: (double)start to: (double)end
{
  double span = end - start;
  NSUInteger lanes = 3;
  CGFloat laneH = (r.size.height - 4) / lanes;
  double laneEnd[3] = { -1, -1, -1 };

  for (GSPSignpost *s in _process.signposts)
    {
      double bs = [_trace relativeTime: s.beginTime];
      double be = [_trace relativeTime: s.endTime];
      if (be < start || bs > end)
        continue;
      CGFloat x0 = r.origin.x + (CGFloat)((bs - start) / span) * r.size.width;
      CGFloat x1 = r.origin.x + (CGFloat)((be - start) / span) * r.size.width;
      NSColor *c = [PDTheme signpostColor: [self colorIndexForSignpost: s.name]];
      NSUInteger lane = 0;
      for (lane = 0; lane < lanes; lane++)
        if (laneEnd[lane] < x0)
          break;
      if (lane == lanes)
        lane = lanes - 1;
      CGFloat y = r.origin.y + 2 + lane * laneH;
      if (s.isEvent)
        {
          NSBezierPath *d = [NSBezierPath bezierPath];
          CGFloat cy = y + laneH / 2;
          [d moveToPoint: NSMakePoint(x0, cy - 5)];
          [d lineToPoint: NSMakePoint(x0 + 5, cy)];
          [d lineToPoint: NSMakePoint(x0, cy + 5)];
          [d lineToPoint: NSMakePoint(x0 - 5, cy)];
          [d closePath];
          [c set];
          [d fill];
          laneEnd[lane] = x0 + 6;
          continue;
        }
      NSRect bar = NSMakeRect(x0, y + 1, MAX(2, x1 - x0), laneH - 2);
      [[PDTheme color: c alpha: s.isOpen ? 0.45 : 0.85] set];
      NSRectFill(bar);
      if (bar.size.width > 40)
        draw_label(s.name, NSMakePoint(x0 + 3, y + 1), [NSColor whiteColor]);
      laneEnd[lane] = NSMaxX(bar) + 2;
    }
}

- (void) drawLogs: (NSRect)r from: (double)start to: (double)end
{
  double span = end - start;
  for (GSPLogMessage *m in _process.logMessages)
    {
      double t = [_trace relativeTime: m.time];
      if (t < start || t > end)
        continue;
      CGFloat x = r.origin.x + (CGFloat)((t - start) / span) * r.size.width;
      NSColor *c = m.level >= GSP_LOG_LEVEL_ERROR ? [PDTheme leakColor] : [PDTheme logColor];
      [c set];
      NSRectFill(NSMakeRect(x, r.origin.y + 8, 2, r.size.height - 16));
    }
}

- (void) drawAllocations: (NSRect)r from: (double)start to: (double)end
{
  GSPAllocationAnalysis *a = [self allocationAnalysis];
  NSUInteger n = MAX(1, (NSUInteger)(r.size.width / 2));
  double *v = calloc(n, sizeof(double));
  [a liveBytes: v buckets: n start: [self abs: start] end: [self abs: end]];
  double peak = MAX(1, (double)a.peakLiveBytes);
  draw_area(v, n, peak, NSInsetRect(r, 0, 2), [PDTheme allocationColor]);
  draw_label([GSPAllocationAnalysis formatBytes: (uint64_t)peak],
             NSMakePoint(r.origin.x + 4, r.origin.y), [PDTheme secondaryTextColor]);
  free(v);
}

- (void) drawLeaks: (NSRect)r from: (double)start to: (double)end
{
  GSPLeakAnalysis *la = [self leakAnalysis];
  double span = end - start;
  for (GSPLeakSnapshot *s in _process.leakSnapshots)
    {
      double t = [_trace relativeTime: s.time];
      if (t < start || t > end)
        continue;
      CGFloat x = r.origin.x + (CGFloat)((t - start) / span) * r.size.width;
      NSUInteger fresh = [[la newLeaksInSnapshot: s] count];
      CGFloat cy = r.origin.y + r.size.height / 2;
      NSRect dot = NSMakeRect(x - 7, cy - 7, 14, 14);
      NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect: dot];
      [(fresh ? [PDTheme leakColor] : [PDTheme okColor]) set];
      [circle fill];
      NSBezierPath *mark = [NSBezierPath bezierPath];
      [mark setLineWidth: 2];
      if (fresh)
        {
          [mark moveToPoint: NSMakePoint(x - 3, cy - 3)];
          [mark lineToPoint: NSMakePoint(x + 3, cy + 3)];
          [mark moveToPoint: NSMakePoint(x + 3, cy - 3)];
          [mark lineToPoint: NSMakePoint(x - 3, cy + 3)];
        }
      else
        {
          [mark moveToPoint: NSMakePoint(x - 4, cy)];
          [mark lineToPoint: NSMakePoint(x - 1, cy + 3)];
          [mark lineToPoint: NSMakePoint(x + 4, cy - 3)];
        }
      [[NSColor whiteColor] set];
      [mark stroke];
      if (fresh)
        draw_label([NSString stringWithFormat: @"%lu new", (unsigned long)fresh],
                   NSMakePoint(x + 10, cy - 7), [PDTheme textColor]);
    }
}

- (void) drawZombies: (NSRect)r from: (double)start to: (double)end
{
  double span = end - start;
  for (GSPZombieEvent *z in _process.zombies)
    {
      double t = [_trace relativeTime: z.time];
      if (t < start || t > end)
        continue;
      CGFloat x = r.origin.x + (CGFloat)((t - start) / span) * r.size.width;
      [[PDTheme zombieColor] set];
      NSRectFill(NSMakeRect(x, r.origin.y + 6, 2, r.size.height - 12));
      NSBezierPath *flag = [NSBezierPath bezierPath];
      [flag moveToPoint: NSMakePoint(x + 2, r.origin.y + 6)];
      [flag lineToPoint: NSMakePoint(x + 14, r.origin.y + 11)];
      [flag lineToPoint: NSMakePoint(x + 2, r.origin.y + 16)];
      [flag closePath];
      [flag fill];
      draw_label([NSString stringWithFormat: @"-%@", z.selector ?: @"?"],
                 NSMakePoint(x + 16, r.origin.y + 6), [PDTheme textColor]);
    }
}

/* Reads (or bytes received) above the middle line, writes (sent) below. */
- (void) drawIO: (NSRect)r from: (double)start to: (double)end network: (BOOL)net
{
  NSUInteger n = MAX(1, (NSUInteger)(r.size.width / 3));
  double *rd = calloc(n, sizeof(double)), *wr = calloc(n, sizeof(double));
  [[self ioAnalysis] bytesForNetwork: net read: rd written: wr buckets: n
                               start: [self abs: start] end: [self abs: end]];
  double peak = 1;
  for (NSUInteger i = 0; i < n; i++)
    peak = MAX(peak, MAX(rd[i], wr[i]));
  CGFloat half = r.size.height / 2;
  NSRect top = NSMakeRect(r.origin.x, r.origin.y, r.size.width, half);
  draw_area(rd, n, peak, top, [PDTheme cpuColor]);
  CGFloat step = r.size.width / n;
  [[PDTheme color: [PDTheme hangColor: 1] alpha: 0.75] set];
  for (NSUInteger i = 0; i < n; i++)
    if (wr[i] > 0)
      NSRectFill(NSMakeRect(r.origin.x + i * step, r.origin.y + half,
                            MAX(1, step), half * MIN(1.0, wr[i] / peak)));
  [[PDTheme gridColor] set];
  NSRectFill(NSMakeRect(r.origin.x, r.origin.y + half, r.size.width, 1));
  draw_label(net ? @"in" : @"read", NSMakePoint(r.origin.x + 4, r.origin.y),
             [PDTheme secondaryTextColor]);
  draw_label(net ? @"out" : @"written", NSMakePoint(r.origin.x + 4, r.origin.y + half + 2),
             [PDTheme secondaryTextColor]);
  free(rd);
  free(wr);
}

- (void) timeline: (PDTimelineView *)view drawTrack: (NSUInteger)track
           inRect: (NSRect)rect from: (double)start to: (double)end
{
  NSString *ident = [self instrumentForTrack: track];
  if (end <= start)
    return;
  if ([self threadForTrack: track])
    [self drawCPU: rect from: start to: end thread: [self threadForTrack: track]];
  else if ([ident isEqual: GSPInstrumentTimeProfiler] || [ident isEqual: GSPInstrumentSystemProfiler])
    [self drawCPU: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentHangs])
    [self drawHangs: rect from: start to: end view: view];
  else if ([ident isEqual: GSPInstrumentPointsOfInterest])
    [self drawSignposts: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentLogging])
    [self drawLogs: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentAllocations])
    [self drawAllocations: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentLeaks])
    [self drawLeaks: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentZombies])
    [self drawZombies: rect from: start to: end];
  else if ([ident isEqual: GSPInstrumentFileActivity])
    [self drawIO: rect from: start to: end network: NO];
  else if ([ident isEqual: GSPInstrumentNetwork])
    [self drawIO: rect from: start to: end network: YES];
}

- (NSString *) timeline: (PDTimelineView *)view describeTrack: (NSUInteger)track
                 atTime: (double)seconds
{
  NSString *ident = [self instrumentForTrack: track];
  GSPTime t = [self abs: seconds];
  if ([ident isEqual: GSPInstrumentPointsOfInterest])
    {
      for (GSPSignpost *s in _process.signposts)
        if (t >= s.beginTime && t <= MAX(s.endTime, s.beginTime + 2000000))
          return [NSString stringWithFormat: @"%@ %@%@", s.name,
                  s.isEvent ? @"" : GSPFormatDuration((double)s.duration / 1e9),
                  s.beginMessage ? [@"  " stringByAppendingString: s.beginMessage] : @""];
    }
  else if ([ident isEqual: GSPInstrumentHangs])
    {
      for (GSPHang *h in [self hangAnalysis].hangs)
        if (t >= h.startTime && t <= h.endTime)
          return [NSString stringWithFormat: @"%@ %@", h.severityName,
                  GSPFormatDuration(h.duration)];
    }
  return nil;
}

@end
