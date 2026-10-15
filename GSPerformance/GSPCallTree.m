#import "GSPCallTree.h"
#import "GSPStackTable.h"
#import "GSPSymbolicator.h"

#include <GSPerformance/gsp_format.h>

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
  NSUInteger n;
  const uint64_t *f = [_process.stacks framesForStack: stack count: &n];
  NSMutableArray *list = [NSMutableArray arrayWithCapacity: n];
  BOOL hideSystem = (_options & GSPCallTreeHideSystemLibraries) != 0;
  BOOL anyUser = NO;

  /* leaf first in storage; build root first */
  for (NSUInteger i = n; i-- > 0;)
    {
      GSPSymbol *s = [sym symbolForFrame: f[i] index: i];
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

- (void) buildFromStacks: (const GSPWeightedStack *)stacks count: (NSUInteger)count
{
  NSMutableDictionary *cache = [NSMutableDictionary dictionary];
  BOOL invert = (_options & GSPCallTreeInvert) != 0;
  BOOL byThread = (_options & GSPCallTreeSeparateByThread) != 0;
  BOOL top = (_options & GSPCallTreeTopFunctions) != 0;

  _root = [GSPCallTreeNode new];
  _root.name = @"All";
  _total = 0;

  for (NSUInteger i = 0; i < count; i++)
    {
      id framesObj = [self framesFor: stacks[i].stack cache: cache];
      if (framesObj == (id)[NSNull null])
        continue;
      NSArray *frames = framesObj;
      uint64_t w = stacks[i].weight;
      GSPCallTreeNode *node = _root;

      _total += w;
      _root.totalWeight += w;
      _root.sampleCount++;

      if (byThread)
        {
          GSPThreadInfo *t = [_process.threads objectForKey:
            [NSNumber numberWithUnsignedInt: stacks[i].tid]];
          NSString *tname = t ? t.displayName
            : [NSString stringWithFormat: @"Thread %u", stacks[i].tid];
          node = [node childFor: [NSString stringWithFormat: @"thread:%u", stacks[i].tid]];
          node.name = tname;
          node.isThread = YES;
          node.tid = stacks[i].tid;
          node.totalWeight += w;
          node.sampleCount++;
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
              c.sampleCount++;
              if (k == nf - 1)
                c.selfWeight += w;
              if (w > c.heaviestStackWeight)
                {
                  c.heaviestStackWeight = w;
                  c.heaviestStack = stacks[i].stack;
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
          node.sampleCount++;
          if (w > node.heaviestStackWeight || node.heaviestStack == 0)
            {
              node.heaviestStackWeight = w;
              node.heaviestStack = stacks[i].stack;
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
