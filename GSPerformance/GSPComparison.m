/* SPDX-License-Identifier: LGPL-2.1-or-later */
#import "GSPComparison.h"
#import "GSPTrace.h"
#import "GSPCallTree.h"
#import "GSPAnalysis.h"

#include <math.h>

@implementation GSPComparisonRow
- (double) delta
{
  return _after - _before;
}
- (double) percentChange
{
  return _before != 0 ? 100.0 * (_after - _before) / _before : NAN;
}
@end

@implementation GSPComparison

+ (BOOL) kindFromString: (NSString *)s kind: (GSPComparisonKind *)kind
{
  NSDictionary *map = [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithInteger: GSPCompareCPU], @"cpu",
    [NSNumber numberWithInteger: GSPCompareCPU], @"top",
    [NSNumber numberWithInteger: GSPCompareAllocations], @"allocations",
    [NSNumber numberWithInteger: GSPCompareLeaks], @"leaks",
    [NSNumber numberWithInteger: GSPCompareSignposts], @"signposts",
    [NSNumber numberWithInteger: GSPCompareFiles], @"files",
    [NSNumber numberWithInteger: GSPCompareNetwork], @"network", nil];
  NSNumber *k = [map objectForKey: [s lowercaseString]];
  if (k == nil)
    return NO;
  *kind = (GSPComparisonKind)[k integerValue];
  return YES;
}

+ (BOOL) kindIsTime: (GSPComparisonKind)kind
{
  return kind == GSPCompareCPU || kind == GSPCompareCPUCallPaths || kind == GSPCompareSignposts;
}

+ (NSDictionary *) valuesFor: (GSPTrace *)trace kind: (GSPComparisonKind)kind
{
  return [self valuesFor: trace start: 0 end: 0 kind: kind];
}

static void
collect_paths(GSPCallTreeNode *node, NSString *prefix, double interval, NSMutableDictionary *values)
{
  for (GSPCallTreeNode *child in node.children)
    {
      NSString *name = [NSString stringWithFormat: @"%@%@%@ [%@]", prefix,
        prefix.length ? @" → " : @"", child.name, child.imageName ?: @""];
      values[name] = @(child.totalWeight * interval);
      collect_paths(child, name, interval, values);
    }
}

+ (NSDictionary *) valuesFor: (GSPTrace *)trace start: (GSPTime)start end: (GSPTime)end
                        kind: (GSPComparisonKind)kind
{
  NSMutableDictionary *v = [NSMutableDictionary dictionary];
  GSPProcess *p = trace.targetProcess;

  switch (kind)
    {
    case GSPCompareCPU:
    case GSPCompareCPUCallPaths:
      {
        double interval = (p.sampleIntervalMicroseconds ?: 1000) / 1e6;
        GSPCallTree *tree = [GSPCallTree cpuTreeForProcess: p start: start end: end threads: nil
          options: kind == GSPCompareCPU ? GSPCallTreeTopFunctions : 0];
        if (kind == GSPCompareCPUCallPaths)
          collect_paths(tree.root, @"", interval, v);
        else
          for (GSPCallTreeNode *n in tree.root.children)
            if (n.selfWeight)
              {
                NSString *key = [NSString stringWithFormat: @"%@ [%@]", n.name, n.imageName ?: @""];
                v[key] = @([v[key] doubleValue] + n.selfWeight * interval);
              }
        break;
      }
    case GSPCompareAllocations:
      {
        GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
        for (GSPAllocationCategory *c in [a categoriesFrom: start to: end])
          if (c.index != UINT32_MAX)
            [v setObject: [NSNumber numberWithDouble: (double)c.totalBytes] forKey: c.name];
        break;
      }
    case GSPCompareLeaks:
      {
        GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: p];
        GSPLeakSnapshot *snapshot = nil;
        for (GSPLeakSnapshot *candidate in p.leakSnapshots)
          if ((!end || candidate.time <= end) && (!snapshot || candidate.time > snapshot.time))
            snapshot = candidate;
        if (!snapshot) break;
        for (GSPLeakGroup *g in [la groupsForSnapshot: snapshot])
          [v setObject: [NSNumber numberWithDouble: (double)g.bytes] forKey: g.name];
        break;
      }
    case GSPCompareSignposts:
      {
        NSMutableArray *intervals = [NSMutableArray array];
        for (GSPSignpost *s in p.signposts)
          if (!s.isOpen && !s.isEvent && s.beginTime >= start && (!end || s.endTime <= end))
            [intervals addObject: s];
        for (GSPSignpostSummary *s in [GSPSignpostAnalysis summariesForSignposts: intervals])
          v[[NSString stringWithFormat: @"%@ / %@ / %@", s.subsystem, s.category, s.name]] = @(s.averageDuration);
        break;
      }
    case GSPCompareFiles:
    case GSPCompareNetwork:
      {
        GSPIOAnalysis *io = [[GSPIOAnalysis alloc] initWithProcess: p];
        for (GSPIOSummary *s in [io summariesForNetwork: kind == GSPCompareNetwork from: start to: end])
          [v setObject: [NSNumber numberWithDouble: (double)(s.bytesRead + s.bytesWritten)]
                forKey: s.name];
        break;
      }
    }
  return v;
}

+ (NSArray *) compare: (GSPTrace *)before with: (GSPTrace *)after
                 kind: (GSPComparisonKind)kind
{
  return [self compare: before start: 0 end: 0 with: after start: 0 end: 0 kind: kind];
}

+ (NSArray *) compare: (GSPTrace *)before start: (GSPTime)beforeStart end: (GSPTime)beforeEnd
                 with: (GSPTrace *)after start: (GSPTime)afterStart end: (GSPTime)afterEnd
                 kind: (GSPComparisonKind)kind
{
  NSParameterAssert((!beforeEnd || beforeStart <= beforeEnd) && (!afterEnd || afterStart <= afterEnd));
  NSDictionary *a = [self valuesFor: before start: beforeStart end: beforeEnd kind: kind];
  NSDictionary *b = [self valuesFor: after start: afterStart end: afterEnd kind: kind];
  NSMutableSet *names = [NSMutableSet setWithArray: [a allKeys]];
  NSMutableArray *rows = [NSMutableArray array];

  [names addObjectsFromArray: [b allKeys]];
  for (NSString *name in names)
    {
      GSPComparisonRow *r = [GSPComparisonRow new];
      r.name = name;
      r.before = [[a objectForKey: name] doubleValue];
      r.after = [[b objectForKey: name] doubleValue];
      if (r.before != r.after)
        [rows addObject: r];
    }
  [rows sortUsingComparator: ^NSComparisonResult(GSPComparisonRow *x, GSPComparisonRow *y) {
    double dx = fabs(x.delta), dy = fabs(y.delta);
    if (dx != dy)
      return dx > dy ? NSOrderedAscending : NSOrderedDescending;
    return [x.name compare: y.name];
  }];
  return rows;
}

+ (GSPComparisonRow *) totalFor: (GSPTrace *)before with: (GSPTrace *)after
                           kind: (GSPComparisonKind)kind
{
  GSPComparisonRow *r = [GSPComparisonRow new];
  r.name = @"Total";
  if (kind == GSPCompareCPUCallPaths) kind = GSPCompareCPU;
  for (NSNumber *n in [[self valuesFor: before kind: kind] allValues])
    r.before += [n doubleValue];
  for (NSNumber *n in [[self valuesFor: after kind: kind] allValues])
    r.after += [n doubleValue];
  return r;
}

@end
