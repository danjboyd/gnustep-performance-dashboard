/* GSPTrace.m - parsing event streams into per-process tables.

   Parsing is incremental: each process remembers how far into its stream
   it has read, so a trace that is still being recorded can be reloaded
   cheaply.  Records may reference definitions (strings, stacks) that are
   written later, so references are resolved after every parse pass.  */

#import "GSPTrace.h"
#import "GSPStackTable.h"
#import "GSPSymbolicator.h"

#include <GSPerformance/gsp_format.h>
#include <stdlib.h>
#include <string.h>

NSString * const GSPTraceErrorDomain = @"GSPTraceErrorDomain";

@implementation GSPThreadInfo
- (NSString *) displayName
{
  NSString *n = [_name length] ? _name : @"Thread";
  if (_isMain)
    return [NSString stringWithFormat: @"Main Thread %u", _tid];
  return [NSString stringWithFormat: @"%@ %u", n, _tid];
}
@end

@implementation GSPImage
- (NSString *) name
{
  return [_path lastPathComponent];
}
@end

@implementation GSPSignpost
- (GSPTime) duration
{
  return _endTime > _beginTime ? _endTime - _beginTime : 0;
}
@end

@interface GSPLogMessage ()
@property (nonatomic) uint32_t subsystemID;
@property (nonatomic) uint32_t categoryID;
@end

@implementation GSPLogMessage
@end

@implementation GSPLeak
@end

@implementation GSPLeakSnapshot
@end

@implementation GSPZombieEvent
@end

/* Raw signpost record kept until intervals are matched. */
typedef struct raw_signpost
{
  GSPTime time;
  uint64_t spid;
  uint32_t tid;
  uint32_t kind;
  uint32_t subsystem, category, name;
  uint32_t messageIndex;   /* into _messages, or UINT32_MAX */
} raw_signpost;

typedef struct pending_ref
{
  uint64_t index;    /* event index */
  uint32_t agentStack;
  uint32_t table;    /* 0 alloc, 1 refcount, 2 zombie, 3 leak */
} pending_ref;

#define GROW(ptr, count, cap, type)                                   \
  do {                                                                \
    if ((count) == (cap))                                             \
      {                                                               \
        (cap) = (cap) ? (cap) * 2 : 1024;                             \
        (ptr) = (type *)realloc((ptr), (cap) * sizeof(type));         \
      }                                                               \
  } while (0)

@interface GSPProcess ()
- (instancetype) initWithPath: (NSString *)path;
- (BOOL) parseMore: (NSError **)error;
@end

@implementation GSPProcess
{
  NSString *_streamPath;
  unsigned long long _offset;
  BOOL _haveHeader;

  NSMutableDictionary *_threads;
  NSMutableArray *_images;
  NSMutableDictionary *_strings;   /* NSNumber -> NSString */
  NSMutableDictionary *_methods;
  NSMutableArray *_signposts;
  NSMutableArray *_logs;
  NSMutableArray *_snapshots;
  NSMutableArray *_zombies;
  NSMutableArray *_messages;
  GSPStackTable *_stacks;
  GSPSymbolicator *_symbolicator;

  uint32_t *_agentStacks;          /* agent stack id -> local index */
  uint32_t _agentStackCap;

  GSPSample *_samples;
  NSUInteger _sampleCount, _sampleCap;
  GSPAllocationEvent *_allocs;
  NSUInteger _allocCount, _allocCap;
  GSPTagEvent *_tags;
  NSUInteger _tagCount, _tagCap;
  GSPRefCountEvent *_refs;
  NSUInteger _refCount, _refCap;
  raw_signpost *_rawSignposts;
  NSUInteger _rawCount, _rawCap;
  pending_ref *_pending;
  NSUInteger _pendingCount, _pendingCap;
  NSMutableArray *_pendingLeaks;   /* GSPLeak with agent stack in .stack */
  NSMutableArray *_pendingZombies;

  int _pid, _ppid;
  NSString *_exe;
  GSPTime _start, _end;
  BOOL _clean, _fromPerf;
  uint32_t _interval, _wallInterval;
  uint64_t _dropped;
  BOOL _samplesSorted;
}

- (instancetype) initWithPath: (NSString *)path
{
  if ((self = [super init]) != nil)
    {
      _streamPath = [path copy];
      _threads = [NSMutableDictionary dictionary];
      _images = [NSMutableArray array];
      _strings = [NSMutableDictionary dictionary];
      _methods = [NSMutableDictionary dictionary];
      _signposts = [NSMutableArray array];
      _logs = [NSMutableArray array];
      _snapshots = [NSMutableArray array];
      _zombies = [NSMutableArray array];
      _messages = [NSMutableArray array];
      _pendingLeaks = [NSMutableArray array];
      _pendingZombies = [NSMutableArray array];
      _stacks = [GSPStackTable new];
    }
  return self;
}

- (void) dealloc
{
  free(_agentStacks);
  free(_samples);
  free(_allocs);
  free(_tags);
  free(_refs);
  free(_rawSignposts);
  free(_pending);
}

- (NSString *) streamPath { return _streamPath; }
- (int) pid { return _pid; }
- (int) ppid { return _ppid; }
- (NSString *) executablePath { return _exe; }
- (GSPTime) startTime { return _start; }
- (GSPTime) endTime { return _end; }
- (BOOL) finishedCleanly { return _clean; }
- (BOOL) fromPerf { return _fromPerf; }
- (uint32_t) sampleIntervalMicroseconds { return _interval; }
- (uint32_t) wallIntervalMicroseconds { return _wallInterval; }
- (uint64_t) droppedSamples { return _dropped; }
- (NSDictionary *) threads { return _threads; }
- (NSArray *) images { return _images; }
- (NSArray *) signposts { return _signposts; }
- (NSArray *) logMessages { return _logs; }
- (NSArray *) leakSnapshots { return _snapshots; }
- (NSArray *) zombies { return _zombies; }
- (NSDictionary *) methodNames { return _methods; }
- (GSPStackTable *) stacks { return _stacks; }
- (const GSPSample *) samples { return _samples; }
- (NSUInteger) sampleCount { return _sampleCount; }
- (const GSPAllocationEvent *) allocationEvents { return _allocs; }
- (NSUInteger) allocationEventCount { return _allocCount; }
- (const GSPTagEvent *) tagEvents { return _tags; }
- (NSUInteger) tagEventCount { return _tagCount; }
- (const GSPRefCountEvent *) refCountEvents { return _refs; }
- (NSUInteger) refCountEventCount { return _refCount; }

- (GSPSymbolicator *) symbolicator
{
  if (_symbolicator == nil)
    _symbolicator = [[GSPSymbolicator alloc] initWithProcess: self];
  return _symbolicator;
}

- (NSString *) stringForID: (uint32_t)identifier
{
  if (identifier == 0)
    return nil;
  return [_strings objectForKey: [NSNumber numberWithUnsignedInt: identifier]];
}

- (NSArray *) sortedThreads
{
  return [[_threads allValues] sortedArrayUsingComparator:
    ^NSComparisonResult(GSPThreadInfo *a, GSPThreadInfo *b) {
      if (a.isMain != b.isMain)
        return a.isMain ? NSOrderedAscending : NSOrderedDescending;
      if (a.tid < b.tid)
        return NSOrderedAscending;
      return a.tid > b.tid ? NSOrderedDescending : NSOrderedSame;
    }];
}

- (GSPThreadInfo *) mainThread
{
  for (GSPThreadInfo *t in [_threads allValues])
    if (t.isMain)
      return t;
  return [_threads objectForKey: [NSNumber numberWithUnsignedInt: (uint32_t)_pid]];
}

- (GSPThreadInfo *) threadFor: (uint32_t)tid time: (GSPTime)time
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: tid];
  GSPThreadInfo *t = [_threads objectForKey: key];
  if (t == nil)
    {
      t = [GSPThreadInfo new];
      t.tid = tid;
      t.name = @"";
      t.isMain = (tid == (uint32_t)_pid);
      t.startTime = time;
      [_threads setObject: t forKey: key];
    }
  return t;
}

- (void) mapAgentStack: (uint32_t)agentID toLocal: (uint32_t)local
{
  if (agentID >= _agentStackCap)
    {
      uint32_t ncap = _agentStackCap ? _agentStackCap : 1024;
      while (ncap <= agentID)
        ncap *= 2;
      _agentStacks = realloc(_agentStacks, ncap * sizeof(uint32_t));
      memset(_agentStacks + _agentStackCap, 0,
             (ncap - _agentStackCap) * sizeof(uint32_t));
      _agentStackCap = ncap;
    }
  _agentStacks[agentID] = local;
}

- (uint32_t) localStack: (uint32_t)agentID
{
  if (agentID == 0 || agentID >= _agentStackCap)
    return 0;
  return _agentStacks[agentID];
}

- (void) addPending: (uint64_t)index stack: (uint32_t)agentID table: (uint32_t)table
{
  GROW(_pending, _pendingCount, _pendingCap, pending_ref);
  _pending[_pendingCount].index = index;
  _pending[_pendingCount].agentStack = agentID;
  _pending[_pendingCount].table = table;
  _pendingCount++;
}

static NSString *
payload_string(const uint8_t *p, size_t max)
{
  size_t len = strnlen((const char *)p, max);
  NSString *s = [[NSString alloc] initWithBytes: p length: len
                                       encoding: NSUTF8StringEncoding];
  if (s == nil)
    s = [[NSString alloc] initWithBytes: p length: len
                               encoding: NSISOLatin1StringEncoding];
  return s ? s : @"";
}

- (void) handleRecord: (const gsp_record *)r payload: (const uint8_t *)p
               length: (size_t)plen
{
  if (r->time > _end)
    _end = r->time;

  switch (r->type)
    {
    case GSP_REC_STRING:
      [_strings setObject: payload_string(p, plen)
                   forKey: [NSNumber numberWithUnsignedInt: r->aux]];
      break;

    case GSP_REC_THREAD:
      {
        GSPThreadInfo *t = [self threadFor: r->tid time: r->time];
        t.name = payload_string(p, plen);
        t.isMain = (r->aux & GSP_THREAD_MAIN) != 0;
        t.startTime = r->time;
      }
      break;

    case GSP_REC_THREAD_END:
      [self threadFor: r->tid time: r->time].endTime = r->time;
      break;

    case GSP_REC_IMAGE:
      if (plen >= sizeof(gsp_image_payload))
        {
          const gsp_image_payload *ip = (const gsp_image_payload *)p;
          GSPImage *im = [GSPImage new];
          im.base = ip->base;
          im.start = ip->start;
          im.end = ip->end;
          im.path = payload_string(p + sizeof(*ip), plen - sizeof(*ip));
          [_images addObject: im];
        }
      break;

    case GSP_REC_STACK:
    case GSP_REC_SAMPLE:
      if (plen >= sizeof(gsp_frames_payload))
        {
          const gsp_frames_payload *fp = (const gsp_frames_payload *)p;
          NSUInteger n = fp->count;
          if (sizeof(*fp) + n * 8 > plen)
            n = (plen - sizeof(*fp)) / 8;
          uint64_t frames[256];
          if (n > 256)
            n = 256;
          memcpy(frames, p + sizeof(*fp), n * 8);
          uint32_t local = [_stacks internFrames: frames count: n];
          if (r->type == GSP_REC_STACK)
            [self mapAgentStack: r->aux toLocal: local];
          else
            {
              GROW(_samples, _sampleCount, _sampleCap, GSPSample);
              GSPSample *s = &_samples[_sampleCount++];
              s->time = r->time;
              s->tid = r->tid;
              s->stack = local;
              s->kind = (uint16_t)r->aux;
              s->weight = fp->weight ? fp->weight : 1;
              s->reserved = 0;
              [self threadFor: r->tid time: r->time];
              _samplesSorted = NO;
            }
        }
      break;

    case GSP_REC_ALLOC:
    case GSP_REC_FREE:
      {
        GROW(_allocs, _allocCount, _allocCap, GSPAllocationEvent);
        GSPAllocationEvent *e = &_allocs[_allocCount];
        memset(e, 0, sizeof(*e));
        e->time = r->time;
        e->tid = r->tid;
        if (r->type == GSP_REC_ALLOC && plen >= sizeof(gsp_alloc_payload))
          {
            const gsp_alloc_payload *ap = (const gsp_alloc_payload *)p;
            e->address = ap->address;
            e->size = ap->size;
            e->oldAddress = ap->old_address;
            if (ap->stack)
              [self addPending: _allocCount stack: ap->stack table: 0];
          }
        else if (r->type == GSP_REC_FREE && plen >= sizeof(gsp_free_payload))
          {
            e->address = ((const gsp_free_payload *)p)->address;
            e->isFree = 1;
          }
        else
          break;
        _allocCount++;
      }
      break;

    case GSP_REC_OBJC_TAG:
      if (plen >= sizeof(gsp_tag_payload))
        {
          const gsp_tag_payload *tp = (const gsp_tag_payload *)p;
          GROW(_tags, _tagCount, _tagCap, GSPTagEvent);
          _tags[_tagCount].time = r->time;
          _tags[_tagCount].address = tp->address;
          _tags[_tagCount].className = tp->class_name;
          _tags[_tagCount].reserved = 0;
          _tagCount++;
        }
      break;

    case GSP_REC_REFCOUNT:
      if (plen >= sizeof(gsp_refcount_payload))
        {
          const gsp_refcount_payload *rp = (const gsp_refcount_payload *)p;
          GROW(_refs, _refCount, _refCap, GSPRefCountEvent);
          GSPRefCountEvent *e = &_refs[_refCount];
          e->time = r->time;
          e->address = rp->address;
          e->stack = 0;
          e->tid = r->tid;
          e->kind = (int32_t)r->aux;
          e->refcount = rp->refcount;
          if (rp->stack)
            [self addPending: _refCount stack: rp->stack table: 1];
          _refCount++;
        }
      break;

    case GSP_REC_SIGNPOST:
    case GSP_REC_LOG:
      if (plen >= sizeof(gsp_signpost_payload))
        {
          const gsp_signpost_payload *sp = (const gsp_signpost_payload *)p;
          size_t mlen = sp->message_length;
          if (sizeof(*sp) + mlen > plen)
            mlen = plen - sizeof(*sp);
          NSString *msg = mlen ? payload_string(p + sizeof(*sp), mlen) : @"";
          if (r->type == GSP_REC_LOG)
            {
              GSPLogMessage *m = [GSPLogMessage new];
              m.time = r->time;
              m.tid = r->tid;
              m.level = (int)r->aux;
              m.subsystemID = sp->subsystem;
              m.categoryID = sp->category;
              m.message = msg;
              [_logs addObject: m];
            }
          else
            {
              GROW(_rawSignposts, _rawCount, _rawCap, raw_signpost);
              raw_signpost *rs = &_rawSignposts[_rawCount++];
              rs->time = r->time;
              rs->spid = sp->signpost_id;
              rs->tid = r->tid;
              rs->kind = r->aux;
              rs->subsystem = sp->subsystem;
              rs->category = sp->category;
              rs->name = sp->name;
              if (mlen)
                {
                  rs->messageIndex = (uint32_t)[_messages count];
                  [_messages addObject: msg];
                }
              else
                rs->messageIndex = UINT32_MAX;
            }
        }
      break;

    case GSP_REC_LEAK_BEGIN:
      if (plen >= sizeof(gsp_leak_summary_payload))
        {
          const gsp_leak_summary_payload *lp = (const gsp_leak_summary_payload *)p;
          GSPLeakSnapshot *s = [self snapshot: r->aux];
          s.time = r->time;
          s.liveCount = lp->count;
          s.liveBytes = lp->bytes;
        }
      break;

    case GSP_REC_LEAK:
      if (plen >= sizeof(gsp_leak_payload))
        {
          const gsp_leak_payload *lp = (const gsp_leak_payload *)p;
          GSPLeak *leak = [GSPLeak new];
          leak.address = lp->address;
          leak.size = lp->size;
          leak.stack = lp->stack;   /* agent id until resolved */
          leak.className = lp->class_name
            ? [NSString stringWithFormat: @"#%u", lp->class_name] : nil;
          [[self snapshot: lp->snapshot].leaks addObject: leak];
          [_pendingLeaks addObject: leak];
        }
      break;

    case GSP_REC_LEAK_END:
      if (plen >= sizeof(gsp_leak_summary_payload))
        {
          const gsp_leak_summary_payload *lp = (const gsp_leak_summary_payload *)p;
          GSPLeakSnapshot *s = [self snapshot: r->aux];
          s.leakedBytes = lp->bytes;
          s.scanMicroseconds = lp->duration_us;
        }
      break;

    case GSP_REC_METHOD:
      if (plen > sizeof(gsp_method_payload))
        {
          const gsp_method_payload *mp = (const gsp_method_payload *)p;
          NSNumber *key = [NSNumber numberWithUnsignedLongLong: mp->imp];
          if ([_methods objectForKey: key] == nil)
            [_methods setObject: payload_string(p + sizeof(*mp), plen - sizeof(*mp))
                         forKey: key];
        }
      break;

    case GSP_REC_ZOMBIE:
      if (plen >= sizeof(gsp_zombie_payload))
        {
          const gsp_zombie_payload *zp = (const gsp_zombie_payload *)p;
          GSPZombieEvent *z = [GSPZombieEvent new];
          z.time = r->time;
          z.tid = r->tid;
          z.address = zp->address;
          z.selector = [NSString stringWithFormat: @"#%u", zp->selector];
          z.stack = zp->stack;
          [_zombies addObject: z];
          [_pendingZombies addObject: z];
        }
      break;

    case GSP_REC_DROPPED:
      if (plen >= 8)
        {
          uint64_t d;
          memcpy(&d, p, 8);
          _dropped += d;
        }
      break;

    case GSP_REC_END:
      _clean = YES;
      break;

    default:
      break;
    }
}

- (GSPLeakSnapshot *) snapshot: (uint32_t)ordinal
{
  for (GSPLeakSnapshot *s in _snapshots)
    if (s.ordinal == ordinal)
      return s;
  GSPLeakSnapshot *s = [GSPLeakSnapshot new];
  s.ordinal = ordinal;
  s.leaks = [NSMutableArray array];
  [_snapshots addObject: s];
  return s;
}

static int
compare_samples(const void *a, const void *b)
{
  const GSPSample *x = a, *y = b;
  if (x->time != y->time)
    return x->time < y->time ? -1 : 1;
  return (x->tid > y->tid) - (x->tid < y->tid);
}

static int
compare_tags(const void *a, const void *b)
{
  const GSPTagEvent *x = a, *y = b;
  return (x->time > y->time) - (x->time < y->time);
}

static int
compare_refs(const void *a, const void *b)
{
  const GSPRefCountEvent *x = a, *y = b;
  return (x->time > y->time) - (x->time < y->time);
}

- (NSString *) classNameForAddress: (uint64_t)address before: (GSPTime)time
{
  NSString *name = nil;
  for (NSUInteger i = 0; i < _tagCount; i++)
    if (_tags[i].address == address && _tags[i].time <= time)
      name = [self stringForID: _tags[i].className];
  return name;
}

- (void) resolve
{
  NSUInteger keep = 0;

  /* stack references */
  for (NSUInteger i = 0; i < _pendingCount; i++)
    {
      pending_ref *pr = &_pending[i];
      uint32_t local = [self localStack: pr->agentStack];
      if (local == 0)
        {
          _pending[keep++] = *pr;
          continue;
        }
      if (pr->table == 0 && pr->index < _allocCount)
        _allocs[pr->index].stack = local;
      else if (pr->table == 1 && pr->index < _refCount)
        _refs[pr->index].stack = local;
    }
  _pendingCount = keep;

  /* Allocation events are in ring order per thread; sort by time while
     keeping each thread's order (insertion sort on nearly sorted data is
     too slow for millions, so use a stable merge via indices).  */
  if (_allocCount > 1)
    {
      /* Pending indices point into the unsorted array; resolve first,
         unresolved references (rare) are dropped.  */
      _pendingCount = 0;
      GSPAllocationEvent *tmp = malloc(_allocCount * sizeof(GSPAllocationEvent));
      /* bottom-up merge sort, stable */
      GSPAllocationEvent *src = _allocs, *dst = tmp;
      for (NSUInteger width = 1; width < _allocCount; width *= 2)
        {
          for (NSUInteger lo = 0; lo < _allocCount; lo += 2 * width)
            {
              NSUInteger mid = MIN(lo + width, _allocCount);
              NSUInteger hi = MIN(lo + 2 * width, _allocCount);
              NSUInteger a = lo, b = mid, k = lo;
              while (a < mid && b < hi)
                dst[k++] = (src[b].time < src[a].time) ? src[b++] : src[a++];
              while (a < mid)
                dst[k++] = src[a++];
              while (b < hi)
                dst[k++] = src[b++];
            }
          GSPAllocationEvent *swap = src;
          src = dst;
          dst = swap;
        }
      if (src != _allocs)
        memcpy(_allocs, src, _allocCount * sizeof(GSPAllocationEvent));
      free(tmp);
    }
  if (_tagCount > 1)
    qsort(_tags, _tagCount, sizeof(GSPTagEvent), compare_tags);
  if (_refCount > 1)
    qsort(_refs, _refCount, sizeof(GSPRefCountEvent), compare_refs);

  if (!_samplesSorted && _sampleCount > 1)
    qsort(_samples, _sampleCount, sizeof(GSPSample), compare_samples);
  _samplesSorted = YES;

  /* leaks */
  NSMutableArray *stillPending = [NSMutableArray array];
  for (GSPLeak *leak in _pendingLeaks)
    {
      uint32_t local = [self localStack: leak.stack];
      if (leak.stack != 0 && local == 0)
        {
          [stillPending addObject: leak];
          continue;
        }
      leak.stack = local;
      if ([leak.className hasPrefix: @"#"])
        leak.className = [self stringForID:
          (uint32_t)[[leak.className substringFromIndex: 1] intValue]];
    }
  _pendingLeaks = stillPending;
  [_snapshots sortUsingComparator: ^NSComparisonResult(GSPLeakSnapshot *a,
                                                       GSPLeakSnapshot *b) {
    return a.ordinal < b.ordinal ? NSOrderedAscending
      : (a.ordinal > b.ordinal ? NSOrderedDescending : NSOrderedSame);
  }];

  /* zombies */
  stillPending = [NSMutableArray array];
  for (GSPZombieEvent *z in _pendingZombies)
    {
      uint32_t local = [self localStack: z.stack];
      if (z.stack != 0 && local == 0)
        {
          [stillPending addObject: z];
          continue;
        }
      z.stack = local;
      if ([z.selector hasPrefix: @"#"])
        z.selector = [self stringForID:
          (uint32_t)[[z.selector substringFromIndex: 1] intValue]];
      z.className = [self classNameForAddress: z.address before: z.time];
    }
  _pendingZombies = stillPending;

  /* logs */
  for (GSPLogMessage *m in _logs)
    {
      if (m.subsystem == nil)
        m.subsystem = [self stringForID: m.subsystemID] ?: @"";
      if (m.category == nil)
        m.category = [self stringForID: m.categoryID] ?: @"";
    }
  [_logs sortUsingComparator: ^NSComparisonResult(GSPLogMessage *a, GSPLogMessage *b) {
    return a.time < b.time ? NSOrderedAscending
      : (a.time > b.time ? NSOrderedDescending : NSOrderedSame);
  }];

  [self matchSignposts];
  [_images sortUsingComparator: ^NSComparisonResult(GSPImage *a, GSPImage *b) {
    return a.start < b.start ? NSOrderedAscending
      : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
  }];
  [_symbolicator invalidate];
}

static int
compare_raw_signposts(const void *a, const void *b)
{
  const raw_signpost *x = a, *y = b;
  if (x->time != y->time)
    return x->time < y->time ? -1 : 1;
  /* at equal times, ends before begins so zero-length nesting works */
  return (int)y->kind - (int)x->kind;
}

- (void) matchSignposts
{
  NSMutableDictionary *open = [NSMutableDictionary dictionary];
  NSMutableArray *result = [NSMutableArray array];

  if (_rawCount > 1)
    qsort(_rawSignposts, _rawCount, sizeof(raw_signpost), compare_raw_signposts);
  for (NSUInteger i = 0; i < _rawCount; i++)
    {
      raw_signpost *r = &_rawSignposts[i];
      NSString *msg = r->messageIndex == UINT32_MAX ? nil
        : [_messages objectAtIndex: r->messageIndex];
      NSString *key = [NSString stringWithFormat: @"%u/%u/%u/%llu",
        r->subsystem, r->category, r->name, (unsigned long long)r->spid];

      if (r->kind == GSP_SIGNPOST_EVENT)
        {
          GSPSignpost *s = [self signpostFrom: r];
          s.isEvent = YES;
          s.endTime = r->time;
          s.beginMessage = msg;
          [result addObject: s];
        }
      else if (r->kind == GSP_SIGNPOST_BEGIN)
        {
          GSPSignpost *s = [self signpostFrom: r];
          s.beginMessage = msg;
          s.isOpen = YES;
          s.endTime = _end;
          NSMutableArray *stack = [open objectForKey: key];
          if (stack == nil)
            {
              stack = [NSMutableArray array];
              [open setObject: stack forKey: key];
            }
          [stack addObject: s];
          [result addObject: s];
        }
      else
        {
          NSMutableArray *stack = [open objectForKey: key];
          GSPSignpost *s = [stack lastObject];
          if (s == nil)
            continue;   /* end without begin (recording started late) */
          [stack removeLastObject];
          s.endTime = r->time;
          s.endMessage = msg;
          s.isOpen = NO;
        }
    }
  [_signposts setArray: result];
}

- (GSPSignpost *) signpostFrom: (raw_signpost *)r
{
  GSPSignpost *s = [GSPSignpost new];
  s.subsystem = [self stringForID: r->subsystem] ?: @"";
  s.category = [self stringForID: r->category] ?: @"";
  s.name = [self stringForID: r->name] ?: @"";
  s.signpostID = r->spid;
  s.tid = r->tid;
  s.beginTime = r->time;
  return s;
}

- (BOOL) parseMore: (NSError **)error
{
  NSData *data = [NSData dataWithContentsOfMappedFile: _streamPath];
  const uint8_t *bytes = [data bytes];
  NSUInteger length = [data length];

  if (data == nil)
    {
      if (error)
        *error = [NSError errorWithDomain: GSPTraceErrorDomain code: 1
          userInfo: [NSDictionary dictionaryWithObject:
            [NSString stringWithFormat: @"Cannot read %@", _streamPath]
                                                forKey: NSLocalizedDescriptionKey]];
      return NO;
    }
  if (!_haveHeader)
    {
      const gsp_file_header *h = (const gsp_file_header *)bytes;
      if (length < sizeof(gsp_file_header) || memcmp(h->magic, GSP_MAGIC, 8) != 0
          || h->version != GSP_FORMAT_VERSION)
        {
          if (error)
            *error = [NSError errorWithDomain: GSPTraceErrorDomain code: 2
              userInfo: [NSDictionary dictionaryWithObject:
                [NSString stringWithFormat: @"%@ is not a supported event stream",
                          _streamPath]
                                                    forKey: NSLocalizedDescriptionKey]];
          return NO;
        }
      _pid = (int)h->pid;
      _ppid = (int)h->ppid;
      _start = h->start_ns;
      _end = h->start_ns;
      _interval = h->sample_interval_us;
      _wallInterval = h->wall_interval_us;
      _fromPerf = (h->flags & GSP_STREAM_FROM_PERF) != 0;
      _exe = payload_string((const uint8_t *)h->exe, sizeof(h->exe));
      _offset = h->header_size;
      _haveHeader = YES;
    }

  while (_offset + sizeof(gsp_record) <= length)
    {
      const gsp_record *r = (const gsp_record *)(bytes + _offset);
      if (r->size < sizeof(gsp_record) || (r->size & 7) != 0)
        break;   /* corrupt: stop here */
      if (_offset + r->size > length)
        break;   /* record still being written */
      [self handleRecord: r payload: (const uint8_t *)(r + 1)
                  length: r->size - sizeof(gsp_record)];
      _offset += r->size;
    }
  [self resolve];
  return YES;
}

@end

@implementation GSPTrace
{
  NSString *_path;
  NSDictionary *_info;
  NSMutableArray *_processes;
}

+ (instancetype) traceWithPath: (NSString *)path error: (NSError **)error
{
  GSPTrace *t = [self new];
  t->_path = [path copy];
  t->_processes = [NSMutableArray array];
  if (![t reload: error])
    return nil;
  return t;
}

- (BOOL) reload: (NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDir = NO;

  if (![fm fileExistsAtPath: _path isDirectory: &isDir] || !isDir)
    {
      if (error)
        *error = [NSError errorWithDomain: GSPTraceErrorDomain code: 3
          userInfo: [NSDictionary dictionaryWithObject:
            [NSString stringWithFormat: @"%@ is not a trace bundle", _path]
                                                forKey: NSLocalizedDescriptionKey]];
      return NO;
    }
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
    [_path stringByAppendingPathComponent: @"Info.plist"]];
  _info = info ? info : [NSDictionary dictionary];

  NSArray *names = [[fm contentsOfDirectoryAtPath: _path error: NULL]
    sortedArrayUsingSelector: @selector(compare:)];
  for (NSString *name in names)
    {
      if (![name hasPrefix: @"events-"] || ![name hasSuffix: @".bin"])
        continue;
      NSString *full = [_path stringByAppendingPathComponent: name];
      GSPProcess *proc = nil;
      for (GSPProcess *p in _processes)
        if ([[p streamPath] isEqual: full])
          proc = p;
      if (proc == nil)
        {
          proc = [[GSPProcess alloc] initWithPath: full];
          if (![proc parseMore: error])
            return NO;
          [_processes addObject: proc];
        }
      else if (![proc parseMore: error])
        return NO;
    }
  if ([_processes count] == 0)
    {
      if (error)
        *error = [NSError errorWithDomain: GSPTraceErrorDomain code: 4
          userInfo: [NSDictionary dictionaryWithObject:
            [NSString stringWithFormat: @"%@ contains no recorded processes", _path]
                                                forKey: NSLocalizedDescriptionKey]];
      return NO;
    }
  return YES;
}

- (NSString *) path { return _path; }
- (NSDictionary *) info { return _info; }
- (NSArray *) processes { return _processes; }

- (GSPProcess *) processWithPID: (int)pid
{
  for (GSPProcess *p in _processes)
    if (p.pid == pid)
      return p;
  return nil;
}

- (GSPProcess *) targetProcess
{
  id pid = [_info objectForKey: @"TargetPID"];
  GSPProcess *p = pid ? [self processWithPID: [pid intValue]] : nil;
  if (p != nil)
    return p;
  GSPProcess *best = nil;
  for (GSPProcess *q in _processes)
    if (best == nil || q.startTime < best.startTime)
      best = q;
  return best;
}

- (GSPTime) startTime
{
  GSPTime t = UINT64_MAX;
  for (GSPProcess *p in _processes)
    if (p.startTime < t)
      t = p.startTime;
  return t == UINT64_MAX ? 0 : t;
}

- (GSPTime) endTime
{
  GSPTime t = 0;
  for (GSPProcess *p in _processes)
    if (p.endTime > t)
      t = p.endTime;
  return t;
}

- (NSTimeInterval) duration
{
  GSPTime s = [self startTime], e = [self endTime];
  return e > s ? (double)(e - s) / 1e9 : 0;
}

- (NSDate *) startDate
{
  id d = [_info objectForKey: @"StartDate"];
  if ([d isKindOfClass: [NSDate class]])
    return d;
  return nil;
}

- (NSString *) templateName
{
  return [_info objectForKey: @"Template"];
}

- (NSArray *) instrumentIdentifiers
{
  NSArray *a = [_info objectForKey: @"Instruments"];
  return a ? a : [NSArray array];
}

- (double) relativeTime: (GSPTime)time
{
  GSPTime s = [self startTime];
  if (time < s)
    return -(double)(s - time) / 1e9;
  return (double)(time - s) / 1e9;
}

- (GSPTime) absoluteTime: (double)seconds
{
  double t = (double)[self startTime] + seconds * 1e9;
  return t < 0 ? 0 : (GSPTime)t;
}

@end
