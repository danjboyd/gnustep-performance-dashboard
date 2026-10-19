/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import "GSPCallTree.h"
#import "GSPStackTable.h"
#import "GSPSymbolicator.h"

#include <GSPerformance/gsp_format.h>
#include <stdlib.h>
#include <string.h>

@interface GSPCallTreeNode ()
/* The input index of the sample heaviestStack came from: of equally
   heavy samples, the first one wins.  */
@property (nonatomic) NSUInteger heaviestIndex;
@end

@implementation GSPCallTreeNode
{
  NSMutableDictionary *_childMap;
  NSArray *_sorted;
}

- (GSPCallTreeNode *) childFor: (NSString *)key
{
  if (_childMap == nil)
    _childMap = [NSMutableDictionary dictionary];
  GSPCallTreeNode *c = [_childMap objectForKey: key];
  if (c == nil)
    {
      c = [GSPCallTreeNode new];
      c.parent = self;
      [_childMap setObject: c forKey: key];
      _sorted = nil;
    }
  return c;
}

- (NSArray *) children
{
  if (_sorted == nil)
    {
      _sorted = [[_childMap allValues] sortedArrayUsingComparator:
        ^NSComparisonResult(GSPCallTreeNode *a, GSPCallTreeNode *b) {
          if (a.totalWeight != b.totalWeight)
            return a.totalWeight > b.totalWeight ? NSOrderedAscending : NSOrderedDescending;
          return [a.name compare: b.name];
        }];
      if (_sorted == nil)
        _sorted = [NSArray array];
    }
  return _sorted;
}

- (GSPCallTreeNode *) heaviestPathLeaf
{
  GSPCallTreeNode *n = self;
  while ([n.children count] > 0)
    n = [n.children objectAtIndex: 0];
  return n;
}

- (NSArray *) pathFromRoot
{
  NSMutableArray *path = [NSMutableArray array];
  for (GSPCallTreeNode *n = self; n.parent != nil; n = n.parent)
    [path insertObject: n atIndex: 0];
  return path;
}

@end

@implementation GSPCallTree
{
  GSPProcess *_process;
  GSPCallTreeNode *_root;
  uint64_t _total;
  NSData *_input;
}

- (instancetype) initWithProcess: (GSPProcess *)process
{
  if ((self = [super init]) != nil)
    {
      _process = process;
      _weightUnit = @"samples";
    }
  return self;
}

- (GSPCallTreeNode *) root { return _root; }
- (uint64_t) totalWeight { return _total; }
- (GSPProcess *) process { return _process; }

+ (GSPCallTree *) cpuTreeForProcess: (GSPProcess *)process
                              start: (GSPTime)start
                                end: (GSPTime)end
                            threads: (NSSet *)tids
                            options: (GSPCallTreeOptions)options
{
  const GSPSample *samples = process.samples;
  NSUInteger n = process.sampleCount;
  GSPWeightedStack *in = malloc((n + 1) * sizeof(GSPWeightedStack));
  NSUInteger used = 0;

  for (NSUInteger i = 0; i < n; i++)
    {
      const GSPSample *s = &samples[i];
      if (s->kind == GSP_SAMPLE_WALL)
        continue;
      if (end != 0 && (s->time < start || s->time > end))
        continue;
      if (tids != nil && ![tids containsObject: [NSNumber numberWithUnsignedInt: s->tid]])
        continue;
      in[used].stack = s->stack;
      in[used].tid = s->tid;
      in[used].weight = s->weight;
      used++;
    }
  GSPCallTree *tree = [[GSPCallTree alloc] initWithProcess: process];
  tree.options = options;
  tree.weightUnit = @"samples";
  [tree buildFromStacks: in count: used];
  free(in);
  return tree;
}

/* Symbolized, filtered frames for one stack, root first. */
- (NSArray *) framesFor: (uint32_t)stack cache: (NSMutableDictionary *)cache
{
  NSNumber *key = [NSNumber numberWithUnsignedInt: stack];
  NSArray *frames = [cache objectForKey: key];
  if (frames != nil)
    return frames;

  GSPSymbolicator *sym = _process.symbolicator;
  NSArray *leafFirst = [sym symbolsForStack: stack];
  NSMutableArray *list;
  BOOL hideSystem = (_options & GSPCallTreeHideSystemLibraries) != 0;
  BOOL anyUser = NO;

  if (leafFirst == nil)
    {
      /* Only agent frames (its stack could not be walked further): show
         the time as recording overhead rather than as agent internals.  */
      static GSPSymbol *overhead;
      if (overhead == nil)
        {
          overhead = [GSPSymbol new];
          overhead.name = @"<Recording Overhead>";
          overhead.imagePath = @"libgsperf-agent.so";
          overhead.isSystem = YES;
        }
      frames = [NSArray arrayWithObject: overhead];
      [cache setObject: frames forKey: key];
      return frames;
    }
  list = [NSMutableArray arrayWithCapacity: [leafFirst count]];
  for (GSPSymbol *s in [leafFirst reverseObjectEnumerator])
    {
      if (!s.isSystem)
        anyUser = YES;
      [list addObject: s];
    }
  if (hideSystem && anyUser)
    {
      NSMutableArray *kept = [NSMutableArray arrayWithCapacity: [list count]];
      for (GSPSymbol *s in list)
        if (!s.isSystem)
          [kept addObject: s];
      list = kept;
    }
  if ([_chargedToCaller count])
    {
      NSMutableArray *kept = [NSMutableArray arrayWithCapacity: [list count]];
      for (GSPSymbol *s in list)
        if (![_chargedToCaller containsObject: s.name])
          [kept addObject: s];
      list = kept;
    }
  if (_options & GSPCallTreeFlattenRecursion)
    {
      NSMutableArray *kept = [NSMutableArray arrayWithCapacity: [list count]];
      GSPSymbol *prev = nil;
      for (GSPSymbol *s in list)
        {
          if (prev != nil && [prev.key isEqual: s.key])
            continue;
          [kept addObject: s];
          prev = s;
        }
      list = kept;
    }
  if (_focusSymbol != nil)
    {
      NSUInteger idx = NSNotFound;
      for (NSUInteger i = 0; i < [list count]; i++)
        if ([[[list objectAtIndex: i] name] isEqual: _focusSymbol])
          {
            idx = i;
            break;
          }
      list = idx == NSNotFound ? nil
        : (NSMutableArray *)[list subarrayWithRange: NSMakeRange(idx, [list count] - idx)];
    }
  if (list != nil && [_pruned count])
    for (GSPSymbol *s in list)
      if ([_pruned containsObject: s.name])
        {
          list = nil;
          break;
        }
  frames = list ? list : (id)[NSNull null];
  [cache setObject: frames forKey: key];
  return frames;
}

- (void) rebuild
{
  NSData *input = _input;
  [self buildFromStacks: [input bytes] count: [input length] / sizeof(GSPWeightedStack)];
}

/* The samples of one stack on one thread, added up.  */
typedef struct stack_group
{
  uint32_t stack;
  uint32_t tid;
  uint64_t weight;      /* sum */
  uint64_t count;       /* samples */
  uint64_t maxWeight;   /* heaviest single sample */
  NSUInteger maxIndex;  /* its input index (the first, of equal ones) */
} stack_group;

/* Groups the samples by stack and thread, in order of first appearance,
   so that the tree is walked once per distinct stack rather than once per
   sample (millions, for an Allocations trace).  Returns the number of
   groups; *out is malloc'd.  */
static NSUInteger
group_stacks(const GSPWeightedStack *stacks, NSUInteger count, stack_group **out)
{
  NSUInteger cap = 64, used = 0;
  while (cap < count * 2 && cap < ((NSUInteger)1 << 30))
    cap <<= 1;
  /* open addressing: slot holds a group index + 1, 0 = empty */
  NSUInteger *slots = calloc(cap, sizeof(NSUInteger));
  NSUInteger gcap = 256;
  stack_group *groups = malloc(gcap * sizeof(stack_group));

  for (NSUInteger i = 0; i < count; i++)
    {
      uint64_t key = ((uint64_t)stacks[i].stack << 32) | stacks[i].tid;
      NSUInteger h = (NSUInteger)((key * 0x9E3779B97F4A7C15ull) >> 17) & (cap - 1);
      stack_group *g = NULL;

      while (slots[h] != 0)
        {
          stack_group *c = &groups[slots[h] - 1];
          if (c->stack == stacks[i].stack && c->tid == stacks[i].tid)
            {
              g = c;
              break;
            }
          h = (h + 1) & (cap - 1);
        }
      if (g == NULL)
        {
          if (used == gcap)
            {
              gcap *= 2;
              groups = realloc(groups, gcap * sizeof(stack_group));
            }
          g = &groups[used];
          memset(g, 0, sizeof(*g));
          g->stack = stacks[i].stack;
          g->tid = stacks[i].tid;
          g->maxIndex = i;
          g->maxWeight = stacks[i].weight;
          slots[h] = ++used;
          if (used * 2 > cap)
            {
              /* full enough: rehash into a table twice the size */
              free(slots);
              cap <<= 1;
              slots = calloc(cap, sizeof(NSUInteger));
              for (NSUInteger j = 0; j < used; j++)
                {
                  uint64_t k = ((uint64_t)groups[j].stack << 32) | groups[j].tid;
                  NSUInteger hh = (NSUInteger)((k * 0x9E3779B97F4A7C15ull) >> 17) & (cap - 1);
                  while (slots[hh] != 0)
                    hh = (hh + 1) & (cap - 1);
                  slots[hh] = j + 1;
                }
            }
        }
      g->weight += stacks[i].weight;
      g->count++;
      if (stacks[i].weight > g->maxWeight)
        {
          g->maxWeight = stacks[i].weight;
          g->maxIndex = i;
        }
    }
  free(slots);
  *out = groups;
  return used;
}

/* Whether a group's heaviest sample beats the node's: heavier, or as
   heavy and earlier, as if the samples were visited one by one.  */
static BOOL
heavier(const stack_group *g, GSPCallTreeNode *node)
{
  return node.heaviestStack == 0 || g->maxWeight > node.heaviestStackWeight
    || (g->maxWeight == node.heaviestStackWeight && g->maxIndex < node.heaviestIndex);
}

- (void) buildFromStacks: (const GSPWeightedStack *)stacks count: (NSUInteger)count
{
  NSMutableDictionary *cache = [NSMutableDictionary dictionary];
  stack_group *groups = NULL;
  NSUInteger ngroups;

  if (stacks != [_input bytes])
    _input = [NSData dataWithBytes: stacks length: count * sizeof(GSPWeightedStack)];
  BOOL invert = (_options & GSPCallTreeInvert) != 0;
  BOOL byThread = (_options & GSPCallTreeSeparateByThread) != 0;
  BOOL top = (_options & GSPCallTreeTopFunctions) != 0;

  _root = [GSPCallTreeNode new];
  _root.name = @"All";
  _total = 0;

  ngroups = group_stacks(stacks, count, &groups);
  for (NSUInteger i = 0; i < ngroups; i++)
    {
      const stack_group *g = &groups[i];
      id framesObj = [self framesFor: g->stack cache: cache];
      if (framesObj == (id)[NSNull null])
        continue;
      NSArray *frames = framesObj;
      uint64_t w = g->weight;
      GSPCallTreeNode *node = _root;

      _total += w;
      _root.totalWeight += w;
      _root.sampleCount += g->count;

      if (byThread)
        {
          GSPThreadInfo *t = [_process.threads objectForKey:
            [NSNumber numberWithUnsignedInt: g->tid]];
          NSString *tname = t ? t.displayName
            : [NSString stringWithFormat: @"Thread %u", g->tid];
          node = [node childFor: [NSString stringWithFormat: @"thread:%u", g->tid]];
          node.name = tname;
          node.isThread = YES;
          node.tid = g->tid;
          node.totalWeight += w;
          node.sampleCount += g->count;
        }

      if (top)
        {
          /* Top Functions: every function once per sample, self weight for
             the leaf, total weight for any appearance.  */
          NSMutableSet *seen = [NSMutableSet set];
          NSUInteger nf = [frames count];
          for (NSUInteger k = 0; k < nf; k++)
            {
              GSPSymbol *s = [frames objectAtIndex: k];
              if ([seen containsObject: s.key])
                continue;
              [seen addObject: s.key];
              GSPCallTreeNode *c = [node childFor: s.key];
              c.name = s.name;
              c.imageName = s.imageName;
              c.symbol = s;
              c.totalWeight += w;
              c.sampleCount += g->count;
              if (k == nf - 1)
                c.selfWeight += w;
              if (g->maxWeight > c.heaviestStackWeight
                  || (c.heaviestStack != 0 && g->maxWeight == c.heaviestStackWeight
                      && g->maxIndex < c.heaviestIndex))
                {
                  c.heaviestStackWeight = g->maxWeight;
                  c.heaviestStack = g->stack;
                  c.heaviestIndex = g->maxIndex;
                }
            }
          continue;
        }

      NSUInteger nf = [frames count];
      for (NSUInteger k = 0; k < nf; k++)
        {
          GSPSymbol *s = [frames objectAtIndex: invert ? nf - 1 - k : k];
          node = [node childFor: s.key];
          node.name = s.name;
          node.imageName = s.imageName;
          node.symbol = s;
          node.totalWeight += w;
          node.sampleCount += g->count;
          if (heavier(g, node))
            {
              node.heaviestStackWeight = g->maxWeight;
              node.heaviestStack = g->stack;
              node.heaviestIndex = g->maxIndex;
            }
        }
      if (nf > 0)
        {
          /* inverted: self time belongs to the first level (the leaf) */
          if (invert)
            {
              GSPCallTreeNode *leaf = node;
              for (NSUInteger k = 1; k < nf; k++)
                leaf = leaf.parent;
              leaf.selfWeight += w;
            }
          else
            node.selfWeight += w;
        }
      else
        _root.selfWeight += w;
    }
  free(groups);
}

static void
render(GSPCallTreeNode *node, NSMutableString *out, NSUInteger depth,
       NSUInteger maxDepth, double minPercent, uint64_t total,
       NSString *(^fmt)(uint64_t))
{
  for (GSPCallTreeNode *c in node.children)
    {
      double pct = total ? 100.0 * (double)c.totalWeight / (double)total : 0;
      if (pct < minPercent)
        continue;
      NSMutableString *indent = [NSMutableString string];
      for (NSUInteger i = 0; i < depth; i++)
        [indent appendString: @"  "];
      [out appendFormat: @"%10@ %6.1f%% %10@  %@%@%@\n",
        fmt(c.totalWeight), pct, fmt(c.selfWeight), indent, c.name,
        c.imageName ? [NSString stringWithFormat: @"  (%@)", c.imageName] : @""];
      if (depth + 1 < maxDepth)
        render(c, out, depth + 1, maxDepth, minPercent, total, fmt);
    }
}

- (NSString *) textWithMaxDepth: (NSUInteger)depth
                     minPercent: (double)minPercent
                 weightFormatter: (NSString *(^)(uint64_t weight))formatter
{
  NSMutableString *out = [NSMutableString string];
  if (formatter == nil)
    formatter = ^NSString *(uint64_t w) {
      return [NSString stringWithFormat: @"%llu", (unsigned long long)w];
    };
  [out appendFormat: @"%10@ %7@ %10@  %@\n", @"Weight", @"", @"Self", @"Symbol"];
  render(_root, out, 0, depth ? depth : NSUIntegerMax, minPercent, _total, formatter);
  return out;
}

@end
