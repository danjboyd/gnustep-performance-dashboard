#import "GSPAnalysis.h"
#import "GSPCallTree.h"
#import "GSPStackTable.h"
#import "GSPSymbolicator.h"

#include <GSPerformance/gsp_format.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

NSString *
GSPFormatDuration(double seconds)
{
  if (seconds >= 60)
    return [NSString stringWithFormat: @"%d:%05.2f min", (int)(seconds / 60),
                     fmod(seconds, 60)];
  if (seconds >= 1)
    return [NSString stringWithFormat: @"%.2f s", seconds];
  if (seconds >= 0.001)
    return [NSString stringWithFormat: @"%.2f ms", seconds * 1e3];
  return [NSString stringWithFormat: @"%.2f µs", seconds * 1e6];
}

/* ------------------------------------------------------------------ */
/* Hangs                                                               */

@implementation GSPHang
- (double) duration
{
  return (double)(_endTime - _startTime) / 1e9;
}
- (NSString *) severityName
{
  switch (_severity)
    {
    case GSPHangMicrohang: return @"Microhang";
    case GSPHangHang: return @"Hang";
    default: return @"Severe Hang";
    }
}
@end

@implementation GSPHangAnalysis
{
  GSPProcess *_process;
  NSMutableArray *_hangs;
  NSMutableDictionary *_idleCache;
  BOOL _runLoop, _hasWall;
  uint32_t _mainTid;
}

static NSSet *
wait_symbols(void)
{
  static NSSet *set;
  if (set == nil)
    set = [NSSet setWithObjects: @"poll", @"ppoll", @"epoll_wait", @"epoll_pwait",
            @"epoll_pwait2", @"select", @"pselect", @"pselect6", @"syscall",
            @"WaitForMultipleObjects", @"WaitForMultipleObjectsEx",
            @"MsgWaitForMultipleObjects", @"MsgWaitForMultipleObjectsEx",
            @"GetMessageW", @"GetMessageA", @"NtWaitForMultipleObjects", nil];
  return set;
}

static NSString *
base_symbol(NSString *name)
{
  if ([name hasPrefix: @"__GI_"])
    name = [name substringFromIndex: 5];
  while ([name hasPrefix: @"_"])
    name = [name substringFromIndex: 1];
  NSRange at = [name rangeOfString: @"@"];
  if (at.location != NSNotFound)
    name = [name substringToIndex: at.location];
  return name;
}

- (BOOL) isIdleStack: (uint32_t)stack
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: stack];
  NSNumber *cached = [_idleCache objectForKey: key];
  if (cached != nil)
    return [cached boolValue];

  NSUInteger n;
  const uint64_t *f = [_process.stacks framesForStack: stack count: &n];
  GSPSymbolicator *sym = _process.symbolicator;
  BOOL waiting = NO, inRunLoop = NO;

  for (NSUInteger i = 0; i < n; i++)
    {
      NSString *name = [sym symbolForFrame: f[i] index: i].name;
      if (i < 5 && [wait_symbols() containsObject: base_symbol(name)])
        waiting = YES;
      if ([name rangeOfString: @"RunLoop"].location != NSNotFound
          || [name rangeOfString: @"runMode:"].location != NSNotFound
          || [name rangeOfString: @"nextEventMatchingMask"].location != NSNotFound)
        inRunLoop = YES;
    }
  BOOL idle = waiting && inRunLoop;
  [_idleCache setObject: [NSNumber numberWithBool: idle] forKey: key];
  return idle;
}

- (instancetype) initWithProcess: (GSPProcess *)process thresholdSeconds: (double)threshold
{
  if ((self = [super init]) == nil)
    return nil;
  _process = process;
  _hangs = [NSMutableArray array];
  _idleCache = [NSMutableDictionary dictionary];
  _mainTid = process.mainThread ? process.mainThread.tid : (uint32_t)process.pid;

  const GSPSample *s = process.samples;
  NSUInteger n = process.sampleCount;
  GSPTime interval = (GSPTime)(process.wallIntervalMicroseconds
                               ? process.wallIntervalMicroseconds : 10000) * 1000;
  GSPTime gap = interval * 4;
  __block GSPTime runStart = 0, runLast = 0;
  __block NSUInteger runSamples = 0;
  __block NSMutableDictionary *runStacks = nil;

  void (^close)(void) = ^{
    if (runSamples == 0)
      return;
    GSPTime end = runLast + interval;
    double d = (double)(end - runStart) / 1e9;
    if (d >= threshold)
      {
        GSPHang *h = [GSPHang new];
        h.startTime = runStart;
        h.endTime = end;
        h.sampleCount = runSamples;
        h.severity = d >= 2.0 ? GSPHangSevere : (d >= 0.5 ? GSPHangHang : GSPHangMicrohang);
        __block NSUInteger best = 0;
        __block uint32_t bestStack = 0;
        [runStacks enumerateKeysAndObjectsUsingBlock: ^(id k, id v, BOOL *stop) {
          if ([v unsignedIntegerValue] > best)
            {
              best = [v unsignedIntegerValue];
              bestStack = [k unsignedIntValue];
            }
        }];
        h.representativeStack = bestStack;
        [_hangs addObject: h];
      }
  };

  for (NSUInteger i = 0; i < n; i++)
    {
      if (s[i].kind != GSP_SAMPLE_WALL || s[i].tid != _mainTid)
        continue;
      _hasWall = YES;
      BOOL idle = [self isIdleStack: s[i].stack];
      if (idle)
        _runLoop = YES;
      else if (!_runLoop)
        continue;   /* launch: the run loop has not waited for events yet */
      if (idle || (runSamples && s[i].time - runLast > gap))
        {
          close();
          runSamples = 0;
          if (idle)
            continue;
        }
      if (runSamples == 0)
        {
          runStart = s[i].time;
          runStacks = [NSMutableDictionary dictionary];
        }
      runLast = s[i].time;
      runSamples++;
      NSNumber *k = [NSNumber numberWithUnsignedInt: s[i].stack];
      [runStacks setObject: [NSNumber numberWithUnsignedInteger:
        [[runStacks objectForKey: k] unsignedIntegerValue] + 1] forKey: k];
    }
  close();
  if (!_runLoop)
    [_hangs removeAllObjects];
  return self;
}

- (NSArray *) hangs { return _hangs; }
- (BOOL) runLoopDetected { return _runLoop; }
- (BOOL) hasWallSamples { return _hasWall; }

- (void) busyFraction: (double *)out buckets: (NSUInteger)nb
                start: (GSPTime)start end: (GSPTime)end
{
  double *total = calloc(nb, sizeof(double));
  const GSPSample *s = _process.samples;
  NSUInteger n = _process.sampleCount;

  memset(out, 0, nb * sizeof(double));
  if (end <= start || nb == 0)
    {
      free(total);
      return;
    }
  for (NSUInteger i = 0; i < n; i++)
    {
      if (s[i].kind != GSP_SAMPLE_WALL || s[i].tid != _mainTid
          || s[i].time < start || s[i].time >= end)
        continue;
      NSUInteger b = (NSUInteger)((double)(s[i].time - start) / (double)(end - start) * nb);
      if (b >= nb)
        b = nb - 1;
      total[b] += 1;
      if (![self isIdleStack: s[i].stack])
        out[b] += 1;
    }
  for (NSUInteger b = 0; b < nb; b++)
    out[b] = total[b] > 0 ? out[b] / total[b] : 0;
  free(total);
}

@end

/* ------------------------------------------------------------------ */
/* Allocations                                                         */

@implementation GSPAllocationCategory
@end

typedef struct addr_slot
{
  uint64_t address;
  uint32_t record;
  uint32_t used;
} addr_slot;

@implementation GSPAllocationAnalysis
{
  GSPProcess *_process;
  GSPAllocationRecord *_records;
  NSUInteger _count, _cap;
  NSMutableArray *_categoryNames;
  NSMutableDictionary *_categoryIndex;
  NSMutableSet *_objectCategories;
  uint64_t _peak;
}

+ (NSString *) formatBytes: (uint64_t)bytes
{
  if (bytes < 1024)
    return [NSString stringWithFormat: @"%llu Bytes", (unsigned long long)bytes];
  if (bytes < 1024 * 1024)
    return [NSString stringWithFormat: @"%.2f KiB", bytes / 1024.0];
  if (bytes < 1024ull * 1024 * 1024)
    return [NSString stringWithFormat: @"%.2f MiB", bytes / 1048576.0];
  return [NSString stringWithFormat: @"%.2f GiB", bytes / 1073741824.0];
}

+ (NSString *) mallocCategoryNameForSize: (uint64_t)size
{
  return [NSString stringWithFormat: @"Malloc %@", [self formatBytes: size]];
}

- (uint32_t) categoryNamed: (NSString *)name object: (BOOL)isObject
{
  NSNumber *idx = [_categoryIndex objectForKey: name];
  if (idx == nil)
    {
      idx = [NSNumber numberWithUnsignedInteger: [_categoryNames count]];
      [_categoryNames addObject: name];
      [_categoryIndex setObject: idx forKey: name];
      if (isObject)
        [_objectCategories addObject: idx];
    }
  return [idx unsignedIntValue];
}

/* open-addressing map: address -> open record index */
static addr_slot *
slot_for(addr_slot *slots, uint64_t mask, uint64_t address)
{
  uint64_t h = address * 0x9E3779B97F4A7C15ull;
  uint64_t i = (h >> 17) & mask;
  while (slots[i].used && slots[i].address != address)
    i = (i + 1) & mask;
  return &slots[i];
}

- (instancetype) initWithProcess: (GSPProcess *)process
{
  if ((self = [super init]) == nil)
    return nil;
  _process = process;
  _categoryNames = [NSMutableArray array];
  _categoryIndex = [NSMutableDictionary dictionary];
  _objectCategories = [NSMutableSet set];

  const GSPAllocationEvent *ev = process.allocationEvents;
  NSUInteger ne = process.allocationEventCount;
  const GSPTagEvent *tags = process.tagEvents;
  NSUInteger nt = process.tagEventCount;
  uint64_t cap = 1024;
  while (cap < ne * 2 + 16)
    cap *= 2;
  /* Deleted entries are marked used with record UINT32_MAX (tombstone). */
  addr_slot *slots = calloc(cap, sizeof(addr_slot));
  uint64_t mask = cap - 1;
  uint64_t live = 0;
  NSUInteger ti = 0;

  _cap = ne + 1;
  _records = malloc(_cap * sizeof(GSPAllocationRecord));

  for (NSUInteger i = 0; i <= ne; i++)
    {
      GSPTime now = i < ne ? ev[i].time : UINT64_MAX;
      /* apply tags that happened before this event */
      while (ti < nt && tags[ti].time <= now)
        {
          /* The tag names the object; libobjc2 allocates it with a
             refcount word in front, so the block may start 8 bytes
             earlier.  */
          addr_slot *sl = slot_for(slots, mask, tags[ti].address);
          if (!(sl->used && sl->record != UINT32_MAX))
            sl = slot_for(slots, mask, tags[ti].address - sizeof(intptr_t));
          if (sl->used && sl->record != UINT32_MAX)
            {
              NSString *cls = [process stringForID: tags[ti].className];
              if (cls != nil)
                _records[sl->record].category = [self categoryNamed: cls object: YES];
            }
          ti++;
        }
      if (i == ne)
        break;

      const GSPAllocationEvent *e = &ev[i];
      uint64_t closing = e->isFree ? e->address : e->oldAddress;
      if (closing)
        {
          addr_slot *sl = slot_for(slots, mask, closing);
          if (sl->used && sl->record != UINT32_MAX)
            {
              GSPAllocationRecord *r = &_records[sl->record];
              r->freeTime = e->time;
              live -= r->size;
              sl->record = UINT32_MAX;
            }
        }
      if (!e->isFree)
        {
          GSPAllocationRecord *r = &_records[_count];
          r->allocTime = e->time;
          r->freeTime = 0;
          r->address = e->address;
          r->size = e->size;
          r->stack = e->stack;
          r->tid = e->tid;
          r->category = [self categoryNamed:
            [GSPAllocationAnalysis mallocCategoryNameForSize: e->size] object: NO];
          r->reserved = 0;
          addr_slot *sl = slot_for(slots, mask, e->address);
          if (sl->used && sl->record != UINT32_MAX)
            {
              /* allocated again without a recorded free: close the old one */
              _records[sl->record].freeTime = e->time;
              live -= _records[sl->record].size;
            }
          sl->used = 1;
          sl->address = e->address;
          sl->record = (uint32_t)_count;
          _count++;
          live += e->size;
          if (live > _peak)
            _peak = live;
        }
    }
  free(slots);
  return self;
}

- (void) dealloc
{
  free(_records);
}

- (const GSPAllocationRecord *) records { return _records; }
- (NSUInteger) recordCount { return _count; }
- (NSArray *) categoryNames { return _categoryNames; }
- (uint64_t) peakLiveBytes { return _peak; }

static inline BOOL
alive_at(const GSPAllocationRecord *r, GSPTime t)
{
  return r->freeTime == 0 || r->freeTime > t;
}

- (NSArray *) categoriesFrom: (GSPTime)start to: (GSPTime)end
{
  NSUInteger nc = [_categoryNames count];
  GSPAllocationCategory *all = [GSPAllocationCategory new];
  NSMutableArray *cats = [NSMutableArray arrayWithCapacity: nc];
  GSPTime e = end ? end : UINT64_MAX;

  all.name = @"All Heap Allocations";
  all.index = UINT32_MAX;
  for (NSUInteger c = 0; c < nc; c++)
    {
      GSPAllocationCategory *cat = [GSPAllocationCategory new];
      cat.name = [_categoryNames objectAtIndex: c];
      cat.index = (uint32_t)c;
      cat.isObject = [_objectCategories containsObject:
        [NSNumber numberWithUnsignedInteger: c]];
      [cats addObject: cat];
    }
  for (NSUInteger i = 0; i < _count; i++)
    {
      const GSPAllocationRecord *r = &_records[i];
      if (r->allocTime < start || r->allocTime > e)
        continue;
      GSPAllocationCategory *cat = [cats objectAtIndex: r->category];
      cat.totalCount++;
      cat.totalBytes += r->size;
      all.totalCount++;
      all.totalBytes += r->size;
      if (alive_at(r, e))
        {
          cat.persistentCount++;
          cat.persistentBytes += r->size;
          all.persistentCount++;
          all.persistentBytes += r->size;
        }
      else
        {
          cat.transientCount++;
          cat.transientBytes += r->size;
          all.transientCount++;
          all.transientBytes += r->size;
        }
    }
  NSMutableArray *result = [NSMutableArray arrayWithObject: all];
  NSArray *sorted = [cats sortedArrayUsingComparator:
    ^NSComparisonResult(GSPAllocationCategory *a, GSPAllocationCategory *b) {
      if (a.persistentBytes != b.persistentBytes)
        return a.persistentBytes > b.persistentBytes ? NSOrderedAscending : NSOrderedDescending;
      if (a.totalBytes != b.totalBytes)
        return a.totalBytes > b.totalBytes ? NSOrderedAscending : NSOrderedDescending;
      return [a.name compare: b.name];
    }];
  for (GSPAllocationCategory *c in sorted)
    if (c.totalCount > 0)
      [result addObject: c];
  return result;
}

- (NSIndexSet *) recordsInCategory: (uint32_t)category from: (GSPTime)start
                                to: (GSPTime)end persistentOnly: (BOOL)persistent
{
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  GSPTime e = end ? end : UINT64_MAX;
  for (NSUInteger i = 0; i < _count; i++)
    {
      const GSPAllocationRecord *r = &_records[i];
      if (r->allocTime < start || r->allocTime > e)
        continue;
      if (category != UINT32_MAX && r->category != category)
        continue;
      if (persistent && !alive_at(r, e))
        continue;
      [set addIndex: i];
    }
  return set;
}

- (GSPCallTree *) callTreeFrom: (GSPTime)start to: (GSPTime)end
                persistentOnly: (BOOL)persistent options: (NSUInteger)options
{
  GSPWeightedStack *in = malloc((_count + 1) * sizeof(GSPWeightedStack));
  NSUInteger used = 0;
  GSPTime e = end ? end : UINT64_MAX;

  for (NSUInteger i = 0; i < _count; i++)
    {
      const GSPAllocationRecord *r = &_records[i];
      if (r->allocTime < start || r->allocTime > e)
        continue;
      if (persistent && !alive_at(r, e))
        continue;
      in[used].stack = r->stack;
      in[used].tid = r->tid;
      in[used].weight = r->size;
      used++;
    }
  GSPCallTree *tree = [[GSPCallTree alloc] initWithProcess: _process];
  tree.options = options;
  tree.weightUnit = @"bytes";
  [tree buildFromStacks: in count: used];
  free(in);
  return tree;
}

- (void) liveBytes: (double *)out buckets: (NSUInteger)nb
             start: (GSPTime)start end: (GSPTime)end
{
  double *delta = calloc(nb + 1, sizeof(double));
  double base = 0;

  memset(out, 0, nb * sizeof(double));
  if (end <= start || nb == 0)
    {
      free(delta);
      return;
    }
  double span = (double)(end - start);
  for (NSUInteger i = 0; i < _count; i++)
    {
      const GSPAllocationRecord *r = &_records[i];
      double sz = (double)r->size;
      if (r->allocTime < start)
        {
          if (alive_at(r, start))
            base += sz;
        }
      else if (r->allocTime < end)
        delta[(NSUInteger)((double)(r->allocTime - start) / span * nb)] += sz;
      if (r->freeTime && r->freeTime >= start && r->freeTime < end
          && r->allocTime < r->freeTime)
        {
          if (r->allocTime >= start || alive_at(r, start))
            delta[(NSUInteger)((double)(r->freeTime - start) / span * nb)] -= sz;
        }
    }
  double running = base;
  for (NSUInteger b = 0; b < nb; b++)
    {
      running += delta[b];
      out[b] = running < 0 ? 0 : running;
    }
  free(delta);
}

@end

/* ------------------------------------------------------------------ */
/* Leaks                                                               */

@implementation GSPLeakGroup
@end

@implementation GSPLeakAnalysis
{
  GSPProcess *_process;
}

- (instancetype) initWithProcess: (GSPProcess *)process
{
  if ((self = [super init]) != nil)
    _process = process;
  return self;
}

- (GSPLeakSnapshot *) latestSnapshot
{
  return [_process.leakSnapshots lastObject];
}

static NSString *
leak_name(GSPLeak *leak)
{
  return leak.className ? leak.className
    : [GSPAllocationAnalysis mallocCategoryNameForSize: leak.size];
}

- (NSArray *) groupsForSnapshot: (GSPLeakSnapshot *)snapshot
{
  NSMutableDictionary *groups = [NSMutableDictionary dictionary];
  if (snapshot == nil)
    snapshot = [self latestSnapshot];
  for (GSPLeak *leak in snapshot.leaks)
    {
      NSString *name = leak_name(leak);
      GSPLeakGroup *g = [groups objectForKey: name];
      if (g == nil)
        {
          g = [GSPLeakGroup new];
          g.name = name;
          g.leaks = [NSMutableArray array];
          [groups setObject: g forKey: name];
        }
      g.count++;
      g.bytes += leak.size;
      [g.leaks addObject: leak];
    }
  return [[groups allValues] sortedArrayUsingComparator:
    ^NSComparisonResult(GSPLeakGroup *a, GSPLeakGroup *b) {
      if (a.bytes != b.bytes)
        return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
      return [a.name compare: b.name];
    }];
}

- (NSArray *) newLeaksInSnapshot: (GSPLeakSnapshot *)snapshot
{
  NSArray *all = _process.leakSnapshots;
  NSUInteger idx = [all indexOfObjectIdenticalTo: snapshot];
  if (idx == NSNotFound || idx == 0)
    return snapshot.leaks;
  NSMutableSet *prev = [NSMutableSet set];
  for (GSPLeak *l in [[all objectAtIndex: idx - 1] leaks])
    [prev addObject: [NSNumber numberWithUnsignedLongLong: l.address]];
  NSMutableArray *fresh = [NSMutableArray array];
  for (GSPLeak *l in snapshot.leaks)
    if (![prev containsObject: [NSNumber numberWithUnsignedLongLong: l.address]])
      [fresh addObject: l];
  return fresh;
}

- (GSPCallTree *) callTreeForSnapshot: (GSPLeakSnapshot *)snapshot options: (NSUInteger)options
{
  if (snapshot == nil)
    snapshot = [self latestSnapshot];
  NSUInteger n = [snapshot.leaks count];
  GSPWeightedStack *in = malloc((n + 1) * sizeof(GSPWeightedStack));
  NSUInteger i = 0;
  for (GSPLeak *l in snapshot.leaks)
    {
      in[i].stack = l.stack;
      in[i].tid = 0;
      in[i].weight = l.size;
      i++;
    }
  GSPCallTree *tree = [[GSPCallTree alloc] initWithProcess: _process];
  tree.options = options;
  tree.weightUnit = @"bytes";
  [tree buildFromStacks: in count: n];
  free(in);
  return tree;
}

@end

/* ------------------------------------------------------------------ */
/* Signposts                                                           */

@implementation GSPSignpostSummary
- (double) averageDuration
{
  return _count ? _totalDuration / (double)_count : 0;
}
@end

@implementation GSPSignpostAnalysis

+ (BOOL) isPointOfInterest: (GSPSignpost *)signpost
{
  return [signpost.category isEqual: @"PointsOfInterest"];
}

+ (NSArray *) summariesForSignposts: (NSArray *)signposts
{
  NSMutableDictionary *by = [NSMutableDictionary dictionary];
  for (GSPSignpost *s in signposts)
    {
      NSString *key = [NSString stringWithFormat: @"%@\t%@\t%@\t%d",
        s.subsystem, s.category, s.name, s.isEvent];
      GSPSignpostSummary *sum = [by objectForKey: key];
      if (sum == nil)
        {
          sum = [GSPSignpostSummary new];
          sum.name = s.name;
          sum.subsystem = s.subsystem;
          sum.category = s.category;
          sum.isEvent = s.isEvent;
          sum.minDuration = INFINITY;
          [by setObject: sum forKey: key];
        }
      double d = (double)s.duration / 1e9;
      sum.count++;
      sum.totalDuration += d;
      if (d < sum.minDuration)
        sum.minDuration = d;
      if (d > sum.maxDuration)
        sum.maxDuration = d;
    }
  for (GSPSignpostSummary *s in [by allValues])
    if (isinf(s.minDuration))
      s.minDuration = 0;
  return [[by allValues] sortedArrayUsingComparator:
    ^NSComparisonResult(GSPSignpostSummary *a, GSPSignpostSummary *b) {
      if (a.totalDuration != b.totalDuration)
        return a.totalDuration > b.totalDuration ? NSOrderedAscending : NSOrderedDescending;
      return [a.name compare: b.name];
    }];
}

+ (NSArray *) signposts: (NSArray *)signposts from: (GSPTime)start to: (GSPTime)end
{
  if (end == 0)
    return signposts;
  NSMutableArray *r = [NSMutableArray array];
  for (GSPSignpost *s in signposts)
    if (s.endTime >= start && s.beginTime <= end)
      [r addObject: s];
  return r;
}

@end

/* ------------------------------------------------------------------ */
/* Zombies                                                             */

@implementation GSPHistoryEvent
@end

NSArray *
GSPZombieHistory(GSPProcess *p, GSPZombieEvent *z)
{
  NSMutableArray *events = [NSMutableArray array];
  /* libobjc2 objects start 8 bytes into their malloc block */
  uint64_t block = z.address - sizeof(intptr_t);
  GSPTime lastMalloc = 0;

  for (NSUInteger i = 0; i < p.allocationEventCount; i++)
    {
      const GSPAllocationEvent *e = &p.allocationEvents[i];
      if (e->time > z.time || (e->address != block && e->address != z.address))
        continue;
      if (!e->isFree)
        {
          /* a newer allocation at the same address starts a new history */
          [events removeAllObjects];
          lastMalloc = e->time;
        }
      GSPHistoryEvent *h = [GSPHistoryEvent new];
      h.time = e->time;
      h.kind = e->isFree ? @"Free" : @"Malloc";
      h.stack = e->stack;
      [events addObject: h];
    }
  for (NSUInteger i = 0; i < p.refCountEventCount; i++)
    {
      const GSPRefCountEvent *r = &p.refCountEvents[i];
      if (r->address != z.address || r->time > z.time || r->time < lastMalloc)
        continue;
      GSPHistoryEvent *h = [GSPHistoryEvent new];
      h.time = r->time;
      h.kind = r->kind == GSP_RC_RETAIN ? @"Retain"
        : (r->kind == GSP_RC_RELEASE ? @"Release" : @"Autorelease");
      h.stack = r->stack;
      [events addObject: h];
    }
  GSPHistoryEvent *last = [GSPHistoryEvent new];
  last.time = z.time;
  last.kind = @"Zombie";
  last.stack = z.stack;
  [events addObject: last];
  [events sortUsingComparator: ^NSComparisonResult(GSPHistoryEvent *a, GSPHistoryEvent *b) {
    return a.time < b.time ? NSOrderedAscending
      : (a.time > b.time ? NSOrderedDescending : NSOrderedSame);
  }];
  return events;
}
