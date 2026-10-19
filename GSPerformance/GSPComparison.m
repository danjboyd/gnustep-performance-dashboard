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
  return kind == GSPCompareCPU || kind == GSPCompareSignposts;
}

+ (NSDictionary *) valuesFor: (GSPTrace *)trace kind: (GSPComparisonKind)kind
{
  NSMutableDictionary *v = [NSMutableDictionary dictionary];
  GSPProcess *p = trace.targetProcess;

  switch (kind)
    {
    case GSPCompareCPU:
      {
        double interval = (p.sampleIntervalMicroseconds ?: 1000) / 1e6;
        GSPCallTree *tree = [GSPCallTree cpuTreeForProcess: p start: 0 end: 0 threads: nil
                                                   options: GSPCallTreeTopFunctions];
        for (GSPCallTreeNode *n in tree.root.children)
          if (n.selfWeight)
            [v setObject: [NSNumber numberWithDouble: n.selfWeight * interval] forKey: n.name];
        break;
      }
    case GSPCompareAllocations:
      {
        GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: p];
        for (GSPAllocationCategory *c in [a categoriesFrom: 0 to: 0])
          if (c.index != UINT32_MAX)
            [v setObject: [NSNumber numberWithDouble: (double)c.totalBytes] forKey: c.name];
        break;
      }
    case GSPCompareLeaks:
      {
        GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: p];
        for (GSPLeakGroup *g in [la groupsForSnapshot: nil])
          [v setObject: [NSNumber numberWithDouble: (double)g.bytes] forKey: g.name];
        break;
      }
    case GSPCompareSignposts:
      for (GSPSignpostSummary *s in [GSPSignpostAnalysis summariesForSignposts: p.signposts])
        if (!s.isEvent)
          [v setObject: [NSNumber numberWithDouble: s.averageDuration] forKey: s.name];
      break;
    case GSPCompareFiles:
    case GSPCompareNetwork:
      {
        GSPIOAnalysis *io = [[GSPIOAnalysis alloc] initWithProcess: p];
        for (GSPIOSummary *s in [io summariesForNetwork: kind == GSPCompareNetwork from: 0 to: 0])
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
  NSDictionary *a = [self valuesFor: before kind: kind];
  NSDictionary *b = [self valuesFor: after kind: kind];
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
  for (NSNumber *n in [[self valuesFor: before kind: kind] allValues])
    r.before += [n doubleValue];
  for (NSNumber *n in [[self valuesFor: after kind: kind] allValues])
    r.after += [n doubleValue];
  return r;
}

@end
