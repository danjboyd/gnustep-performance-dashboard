/* GSPerformanceTests - unit tests for the analysis framework, run with
   tools-xctest (`make check` in this directory).  */

#import <XCTest/XCTest.h>
#import <GSPerformance/GSPerformance.h>
#import "TraceBuilder.h"

#define MS 1000000ull

enum
{
  A_MAIN = 0x1000, A_RUN = 0x2000, A_COMPUTE = 0x3000, A_HELPER = 0x4000,
  A_POLL = 0x5000, A_RUNLOOP = 0x6000, A_RECURSE = 0x7000
};

static TraceBuilder *
named_builder(void)
{
  TraceBuilder *b = [[TraceBuilder alloc] initWithPID: 4242];
  [b name: A_MAIN as: @"main"];
  [b name: A_RUN as: @"-[Worker run]"];
  [b name: A_COMPUTE as: @"-[Worker compute]"];
  [b name: A_HELPER as: @"helper"];
  [b name: A_POLL as: @"poll"];
  [b name: A_RUNLOOP as: @"-[NSRunLoop runMode:beforeDate:]"];
  [b name: A_RECURSE as: @"recurse"];
  [b thread: 4242 name: "synthetic" main: YES at: b.start];
  return b;
}

static GSPCallTreeNode *
child(GSPCallTreeNode *n, NSString *name)
{
  for (GSPCallTreeNode *c in n.children)
    if ([c.name isEqual: name])
      return c;
  return nil;
}

@interface GSPerformanceTests : XCTestCase
@end

@implementation GSPerformanceTests
{
  NSMutableArray *_bundles;
}

- (void) setUp
{
  _bundles = [NSMutableArray array];
}

- (void) tearDown
{
  for (NSString *p in _bundles)
    [[NSFileManager defaultManager] removeItemAtPath: p error: NULL];
}

- (GSPTrace *) traceFrom: (TraceBuilder *)b name: (NSString *)name instruments: (NSArray *)ids
{
  NSString *path = [b writeBundleNamed: name instruments: ids];
  [_bundles addObject: path];
  NSError *error = nil;
  GSPTrace *t = [GSPTrace traceWithPath: path error: &error];
  XCTAssertNotNil(t, @"%@", error);
  return t;
}

- (TraceBuilder *) cpuBuilder
{
  TraceBuilder *b = named_builder();
  uint64_t s = b.start;
  uint64_t a[] = { A_COMPUTE + 0x10, A_RUN + 0x10, A_MAIN + 0x10 };
  uint64_t h[] = { A_HELPER + 0x10, A_RUN + 0x10, A_MAIN + 0x10 };
  /* written out of time order on purpose */
  [b sampleAt: s + 30 * MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 1 frames: a count: 3];
  [b sampleAt: s + 10 * MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 1 frames: a count: 3];
  [b sampleAt: s + 40 * MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 1 frames: h count: 3];
  [b sampleAt: s + 20 * MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 1 frames: a count: 3];
  return b;
}


- (void) testGenerationSurvivalUsesIndependentCheckpoint
{
  TraceBuilder *b = named_builder();
  uint64_t frames[] = { A_HELPER + 0x10, A_MAIN + 0x10 };
  [b stack: 1 frames: frames count: 2];
  [b allocAt: b.start + MS address: 0x10000 size: 32 stack: 1];
  [b allocAt: b.start + 2 * MS address: 0x20000 size: 64 stack: 1];
  [b freeAt: b.start + 3 * MS address: 0x10000];
  /* Reuse must not resurrect the first allocation in its generation. */
  [b allocAt: b.start + 4 * MS address: 0x10000 size: 128 stack: 1];
  [b freeAt: b.start + 5 * MS address: 0x20000];
  [b end: b.start + 6 * MS];
  GSPTrace *t = [self traceFrom: b name: @"generations" instruments: nil];
  GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: t.targetProcess];
  GSPAllocationCategory *early = [a categoriesFrom: b.start to: b.start + 2 * MS][0];
  XCTAssertEqual(early.persistentBytes, (uint64_t)96);
  GSPAllocationCategory *later = [a categoriesFrom: b.start to: b.start + 2 * MS survivingAt: b.start + 4 * MS][0];
  XCTAssertEqual(later.totalBytes, (uint64_t)96);
  XCTAssertEqual(later.persistentBytes, (uint64_t)64);
  XCTAssertEqual([a recordsInCategory: UINT32_MAX from: b.start to: b.start + 2 * MS
    survivingAt: b.start + 4 * MS persistentOnly: YES].count, (NSUInteger)1);
  GSPCallTree *tree = [a callTreeFrom: b.start to: b.start + 2 * MS
    survivingAt: b.start + 4 * MS persistentOnly: YES options: 0];
  XCTAssertEqual(tree.totalWeight, (uint64_t)64);
  GSPAllocationCategory *atFree = [a categoriesFrom: b.start to: b.start + 2 * MS survivingAt: b.start + 5 * MS][0];
  XCTAssertEqual(atFree.persistentBytes, (uint64_t)0);
  GSPAllocationCategory *adjacent = [a categoriesFrom: b.start + 2 * MS + 1 to: 0 survivingAt: 0][0];
  XCTAssertEqual(adjacent.totalBytes, (uint64_t)128);
}

- (void) testComparisonIndependentRangesAndCallPaths
{
  TraceBuilder *b = [self cpuBuilder];
  [b end: b.start + 50 * MS];
  GSPTrace *t = [self traceFrom: b name: @"comparison" instruments: nil];
  NSArray *rows = [GSPComparison compare: t start: b.start end: b.start + 30 * MS
    with: t start: b.start + 31 * MS end: b.start + 50 * MS kind: GSPCompareCPU];
  XCTAssertEqual(rows.count, (NSUInteger)2);
  GSPComparisonRow *compute = rows[0];
  XCTAssertTrue([compute.name hasPrefix: @"-[Worker compute]"]);
  XCTAssertEqualWithAccuracy(compute.before, .003, .000001);
  XCTAssertEqualWithAccuracy(compute.after, 0, .000001);
  NSArray *paths = [GSPComparison compare: t start: b.start end: b.start + 30 * MS
    with: t start: b.start + 31 * MS end: b.start + 50 * MS kind: GSPCompareCPUCallPaths];
  BOOL found = NO;
  for (GSPComparisonRow *row in paths)
    if ([row.name containsString: @" → -[Worker run]"] && [row.name containsString: @" → -[Worker compute]"])
      { found = YES; XCTAssertEqualWithAccuracy(row.before, .003, .000001); }
  XCTAssertTrue(found);
  XCTAssertEqual([GSPComparison compare: t with: t kind: GSPCompareCPUCallPaths].count, (NSUInteger)0);
}

- (void) testComparisonExcludesPartialSignpostsAndLaterLeaks
{
  TraceBuilder *b = named_builder();
  [b string: 1 value: "Work"]; [b string: 2 value: "PointsOfInterest"];
  [b signpostAt: b.start + MS kind: GSP_SIGNPOST_BEGIN spid: 1 name: 1 category: 2 message: ""];
  [b signpostAt: b.start + 4 * MS kind: GSP_SIGNPOST_END spid: 1 name: 1 category: 2 message: ""];
  [b signpostAt: b.start + 5 * MS kind: GSP_SIGNPOST_BEGIN spid: 2 name: 1 category: 2 message: ""];
  [b leakSnapshot: 1 at: b.start + 2 * MS leaks: @[@[@0x10000, @32, @0, @0]]];
  [b leakSnapshot: 2 at: b.start + 6 * MS leaks: @[@[@0x10000, @32, @0, @0], @[@0x20000, @32, @0, @0]]];
  [b end: b.start + 7 * MS];
  GSPTrace *t = [self traceFrom: b name: @"comparison-boundaries" instruments: nil];
  NSArray *rows = [GSPComparison compare: t start: b.start end: b.start + 3 * MS
    with: t start: b.start end: b.start + 7 * MS kind: GSPCompareSignposts];
  XCTAssertEqual(rows.count, (NSUInteger)1);
  XCTAssertEqualWithAccuracy([(GSPComparisonRow *)rows[0] after], .003, .000001);
  rows = [GSPComparison compare: t start: b.start end: b.start + 3 * MS
    with: t start: b.start end: b.start + 7 * MS kind: GSPCompareLeaks];
  XCTAssertEqual(rows.count, (NSUInteger)1);
  XCTAssertEqualWithAccuracy([(GSPComparisonRow *)rows[0] before], 32, .001);
  XCTAssertEqualWithAccuracy([(GSPComparisonRow *)rows[0] after], 64, .001);
}

- (void) testHangEvidenceUsesMainThreadAndOverlappingIO
{
  TraceBuilder *b = named_builder();
  uint64_t frames[] = { A_HELPER + 0x10, A_MAIN + 0x10 };
  [b sampleAt: b.start + 10 * MS tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: frames count: 2];
  [b sampleAt: b.start + 20 * MS tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: frames count: 2];
  [b sampleAt: b.start + 15 * MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 7 frames: frames count: 2];
  [b sampleAt: b.start + 15 * MS tid: 9999 kind: GSP_SAMPLE_CPU weight: 100 frames: frames count: 2];
  [b ioAt: b.start duration: 15 * MS tid: 4242];
  [b ioAt: b.start duration: MS tid: 4242];
  [b ioAt: b.start + 15 * MS duration: MS tid: 9999];
  [b end: b.start + 30 * MS];
  GSPTrace *t = [self traceFrom: b name: @"hang-evidence" instruments: nil];
  GSPHangAnalysis *a = [[GSPHangAnalysis alloc] initWithProcess: t.targetProcess thresholdSeconds: .25];
  GSPHang *h = [GSPHang new]; h.startTime = b.start + 10 * MS; h.endTime = b.start + 20 * MS;
  NSDictionary *e = [a evidenceForHang: h];
  XCTAssertEqual([e[@"wallSamples"] unsignedIntegerValue], (NSUInteger)2);
  XCTAssertEqualWithAccuracy([e[@"cpuSeconds"] doubleValue], .007, .000001);
  XCTAssertEqual([e[@"ioIndices"] count], (NSUInteger)1);
  XCTAssertEqual([a wallTreeForHang: h options: 0].totalWeight, (uint64_t)2);
}

- (void) testSourceMappingsPreserveDrivesAndDirectoryBoundaries
{
  XCTAssertEqualObjects([GSPSymbolicator executableSearchPathInEnvironment: @{ @"PATH": @"/tools" }], @"/tools");
#if defined(_WIN32)
  XCTAssertEqualObjects([GSPSymbolicator executableSearchPathInEnvironment: @{ @"Path": @"C:/tools" }], @"C:/tools");
#else
  XCTAssertNil([GSPSymbolicator executableSearchPathInEnvironment: @{ @"Path": @"/tools" }]);
#endif
  NSDictionary *maps = @{ @"C:/build": @"/local", @"C:/build/project": @"/chosen" };
  NSDictionary *info = [GSPSymbolicator sourceFileAndLine: @"C:\\build\\project\\file.m:42" mappings: maps];
  XCTAssertEqualObjects(info[@"path"], @"/chosen/file.m");
  XCTAssertEqual([info[@"line"] integerValue], (NSInteger)42);
  info = [GSPSymbolicator sourceFileAndLine: @"C:/builder/file.m:3" mappings: maps];
  XCTAssertEqualObjects(info[@"path"], @"C:/builder/file.m");
  info = [GSPSymbolicator sourceFileAndLine: @"file.m:2" mappings: @{ @".": @"/checkout" }];
  XCTAssertEqualObjects(info[@"path"], @"/checkout/file.m");
  XCTAssertNil([GSPSymbolicator sourceFileAndLine: @"??:0" mappings: maps]);
  XCTAssertNil([GSPSymbolicator sourceFileAndLine: @"file.m:-1" mappings: maps]);
  XCTAssertNil([GSPSymbolicator sourceFileAndLine: @"file.m:12junk" mappings: maps]);
  XCTAssertNil([GSPSymbolicator sourceFileAndLine: nil mappings: maps]);
}

/* ------------------------------------------------------------------ */

- (void) testReaderSortsSamplesAndToleratesTornRecord
{
  TraceBuilder *b = [self cpuBuilder];
  [b end: b.start + 50 * MS];
  [b appendGarbage: 12];
  GSPTrace *t = [self traceFrom: b name: @"reader" instruments: nil];
  GSPProcess *p = t.targetProcess;

  XCTAssertEqual(p.pid, 4242);
  XCTAssertEqual(p.sampleCount, (NSUInteger)4);
  XCTAssertTrue(p.finishedCleanly);
  for (NSUInteger i = 1; i < p.sampleCount; i++)
    XCTAssertTrue(p.samples[i - 1].time <= p.samples[i].time);
  XCTAssertEqualObjects([p.mainThread name], @"synthetic");
  XCTAssertEqualWithAccuracy(t.duration, 0.05, 0.0001);
}

- (void) testUnavailableScanAndRecordingWarnings
{
  TraceBuilder *b = [self cpuBuilder];
  [b dropped: 7];
  [b diagnosticAt: b.start + 50 * MS message: "Leak scan unavailable: denied."];
  [b diagnosticAt: b.start + 60 * MS message: "Leak scan unavailable: denied."];
  GSPTrace *t = [self traceFrom: b name: @"unavailable" instruments: nil];
  XCTAssertTrue(t.targetProcess.leakScanUnavailable);
  XCTAssertEqual([t.targetProcess.leakSnapshots count], (NSUInteger)0);
  XCTAssertEqual([t qualityWarningsIncludingIncomplete: NO].count, (NSUInteger)2);
  XCTAssertEqual([t qualityWarningsIncludingIncomplete: YES].count, (NSUInteger)3);
  NSDictionary *summary = [GSPExporter summaryOfTrace: t process: t.targetProcess];
  XCTAssertTrue([[summary objectForKey: @"leakScanUnavailable"] boolValue]);
  XCTAssertNil([summary objectForKey: @"leaks"]);
  /* A later successful attempt restores the result, but preserves the warning. */
  [b leakSnapshot: 2 at: b.start + 70 * MS leaks: [NSArray array]];
  [b end: b.start + 80 * MS];
  t = [self traceFrom: b name: @"recovered-scan" instruments: nil];
  XCTAssertFalse(t.targetProcess.leakScanUnavailable);
  XCTAssertEqual([t qualityWarningsIncludingIncomplete: YES].count, (NSUInteger)2);
}

- (void) testSavingPreservesSourceAndDestination
{
  GSPTrace *source = [self traceFrom: [self cpuBuilder] name: @"save-source" instruments: nil];
  GSPTrace *dest = [self traceFrom: named_builder() name: @"save-dest" instruments: nil];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  XCTAssertTrue([source copyToPath: source.path error: &error], @"%@", error);
  XCTAssertNotNil([GSPTrace traceWithPath: source.path error: NULL]);
  NSString *alias = [source.path stringByAppendingString: @"-alias"];
  [_bundles addObject: alias];
  BOOL linked = [fm createSymbolicLinkAtPath: alias withDestinationPath: source.path error: &error];
#if defined(_WIN32)
  /* Windows runners need Developer Mode or a privilege to create symlinks.
     Keep all ordinary save-preservation checks active without that facility. */
  if (!linked)
    NSLog(@"Symlink alias subcheck unavailable on this Windows host: %@", error);
#else
  XCTAssertTrue(linked, @"%@", error);
#endif
  if (linked)
    XCTAssertTrue([source copyToPath: alias error: &error]);
  XCTAssertFalse([source copyToPath: [source.path stringByAppendingPathComponent: @"nested.gstrace"] error: &error]);
  XCTAssertTrue([source copyToPath: dest.path error: &error], @"%@", error);
  XCTAssertEqual([GSPTrace traceWithPath: dest.path error: NULL].targetProcess.sampleCount, (NSUInteger)4);
  XCTAssertEqual([GSPTrace traceWithPath: source.path error: NULL].targetProcess.sampleCount, (NSUInteger)4);
  /* Failed copying must not remove an existing destination. */
  [fm removeItemAtPath: source.path error: NULL];
  XCTAssertFalse([source copyToPath: dest.path error: &error]);
  XCTAssertEqual([GSPTrace traceWithPath: dest.path error: NULL].targetProcess.sampleCount, (NSUInteger)4);
}

- (void) testCallTreeTopDown
{
  GSPTrace *t = [self traceFrom: [self cpuBuilder] name: @"tree" instruments: nil];
  GSPCallTree *tree = [GSPCallTree cpuTreeForProcess: t.targetProcess start: 0 end: 0
                                             threads: nil options: 0];
  XCTAssertEqual(tree.totalWeight, (uint64_t)4);
  GSPCallTreeNode *main = child(tree.root, @"main");
  XCTAssertNotNil(main);
  XCTAssertEqual(main.totalWeight, (uint64_t)4);
  GSPCallTreeNode *run = child(main, @"-[Worker run]");
  XCTAssertEqual(child(run, @"-[Worker compute]").selfWeight, (uint64_t)3);
  XCTAssertEqual(child(run, @"helper").totalWeight, (uint64_t)1);
  /* heaviest first */
  XCTAssertEqualObjects([[run.children objectAtIndex: 0] name], @"-[Worker compute]");
}

- (void) testCallTreeInvertedAndTopFunctions
{
  GSPTrace *t = [self traceFrom: [self cpuBuilder] name: @"invert" instruments: nil];
  GSPCallTree *inv = [GSPCallTree cpuTreeForProcess: t.targetProcess start: 0 end: 0
                                            threads: nil options: GSPCallTreeInvert];
  GSPCallTreeNode *compute = child(inv.root, @"-[Worker compute]");
  XCTAssertEqual(compute.totalWeight, (uint64_t)3);
  XCTAssertEqual(compute.selfWeight, (uint64_t)3);
  XCTAssertNotNil(child(compute, @"-[Worker run]"));

  GSPCallTree *top = [GSPCallTree cpuTreeForProcess: t.targetProcess start: 0 end: 0
                                            threads: nil options: GSPCallTreeTopFunctions];
  XCTAssertEqual(child(top.root, @"-[Worker run]").totalWeight, (uint64_t)4);
  XCTAssertEqual(child(top.root, @"-[Worker run]").selfWeight, (uint64_t)0);
  XCTAssertEqual(child(top.root, @"helper").selfWeight, (uint64_t)1);
}

- (void) testCallTreeTimeRangeAndDataMining
{
  GSPTrace *t = [self traceFrom: [self cpuBuilder] name: @"mining" instruments: nil];
  GSPProcess *p = t.targetProcess;
  GSPTime s = t.startTime;
  GSPCallTree *range = [GSPCallTree cpuTreeForProcess: p start: s + 15 * MS end: s + 35 * MS
                                              threads: nil options: 0];
  XCTAssertEqual(range.totalWeight, (uint64_t)2);

  /* charge -[Worker compute] to its caller */
  GSPCallTree *tree = [[GSPCallTree alloc] initWithProcess: p];
  tree.chargedToCaller = [NSSet setWithObject: @"-[Worker compute]"];
  GSPWeightedStack in[4];
  for (NSUInteger i = 0; i < 4; i++)
    {
      in[i].stack = p.samples[i].stack;
      in[i].tid = p.samples[i].tid;
      in[i].weight = p.samples[i].weight;
    }
  [tree buildFromStacks: in count: 4];
  GSPCallTreeNode *run = child(child(tree.root, @"main"), @"-[Worker run]");
  XCTAssertEqual(run.selfWeight, (uint64_t)3);

  GSPCallTree *pruned = [[GSPCallTree alloc] initWithProcess: p];
  pruned.pruned = [NSSet setWithObject: @"helper"];
  [pruned buildFromStacks: in count: 4];
  XCTAssertEqual(pruned.totalWeight, (uint64_t)3);

  GSPCallTree *focus = [[GSPCallTree alloc] initWithProcess: p];
  focus.focusSymbol = @"-[Worker run]";
  [focus buildFromStacks: in count: 4];
  XCTAssertNotNil(child(focus.root, @"-[Worker run]"));
  XCTAssertNil(child(focus.root, @"main"));
}

- (void) testCallTreeGroupsRepeatedStacks
{
  /* The tree adds up the samples of each stack before walking it: counts,
     weights and the heaviest stack must be as if walked one by one.  */
  GSPTrace *t = [self traceFrom: [self cpuBuilder] name: @"groups" instruments: nil];
  GSPProcess *p = t.targetProcess;
  uint32_t a = p.samples[0].stack;   /* main > run > compute */
  uint32_t h = p.samples[3].stack;   /* main > run > helper */
  GSPWeightedStack in[] = {
    { a, 1, 1 }, { h, 1, 5 }, { a, 2, 5 }, { a, 1, 5 }, { h, 1, 2 }, { a, 1, 3 }
  };

  GSPCallTree *tree = [[GSPCallTree alloc] initWithProcess: p];
  [tree buildFromStacks: in count: 6];
  GSPCallTreeNode *run = child(child(tree.root, @"main"), @"-[Worker run]");
  GSPCallTreeNode *compute = child(run, @"-[Worker compute]");
  XCTAssertEqual(tree.totalWeight, (uint64_t)21);
  XCTAssertEqual(run.sampleCount, (uint64_t)6);
  XCTAssertEqual(compute.sampleCount, (uint64_t)4);
  XCTAssertEqual(compute.selfWeight, (uint64_t)14);
  XCTAssertEqual(child(run, @"helper").sampleCount, (uint64_t)2);
  /* the first sample of weight 5 is the helper's (index 1) */
  XCTAssertEqual(run.heaviestStack, h);
  XCTAssertEqual(run.heaviestStackWeight, (uint64_t)5);
  XCTAssertEqual(compute.heaviestStack, a);
  XCTAssertEqual(compute.heaviestStackWeight, (uint64_t)5);

  GSPCallTree *threads = [[GSPCallTree alloc] initWithProcess: p];
  threads.options = GSPCallTreeSeparateByThread;
  [threads buildFromStacks: in count: 6];
  NSUInteger samples = 0;
  for (GSPCallTreeNode *n in threads.root.children)
    {
      XCTAssertTrue(n.isThread);
      samples += n.sampleCount;
      if (n.tid == 2)
        XCTAssertEqual(n.totalWeight, (uint64_t)5);
    }
  XCTAssertEqual([threads.root.children count], (NSUInteger)2);
  XCTAssertEqual(samples, (NSUInteger)6);

  GSPCallTree *top = [[GSPCallTree alloc] initWithProcess: p];
  top.options = GSPCallTreeTopFunctions;
  [top buildFromStacks: in count: 6];
  XCTAssertEqual(child(top.root, @"-[Worker run]").sampleCount, (uint64_t)6);
  XCTAssertEqual(child(top.root, @"-[Worker run]").heaviestStack, h);
  XCTAssertEqual(child(top.root, @"-[Worker compute]").heaviestStack, a);
}

- (void) testFlattenRecursion
{
  TraceBuilder *b = named_builder();
  uint64_t r[] = { A_RECURSE + 0x10, A_RECURSE + 0x20, A_RECURSE + 0x30, A_MAIN + 0x10 };
  [b sampleAt: b.start + MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 2 frames: r count: 4];
  GSPTrace *t = [self traceFrom: b name: @"recursion" instruments: nil];
  GSPCallTree *flat = [GSPCallTree cpuTreeForProcess: t.targetProcess start: 0 end: 0
                                             threads: nil options: GSPCallTreeFlattenRecursion];
  GSPCallTreeNode *rec = child(child(flat.root, @"main"), @"recurse");
  XCTAssertEqual(rec.selfWeight, (uint64_t)2);
  XCTAssertEqual([rec.children count], (NSUInteger)0);
}

- (void) testSignpostMatching
{
  TraceBuilder *b = named_builder();
  uint64_t s = b.start;
  [b string: 1 value: "Load"];
  [b string: 2 value: "PointsOfInterest"];
  [b string: 3 value: "Tick"];
  [b signpostAt: s + 1 * MS kind: GSP_SIGNPOST_BEGIN spid: 7 name: 1 category: 2 message: "outer"];
  [b signpostAt: s + 2 * MS kind: GSP_SIGNPOST_BEGIN spid: 7 name: 1 category: 2 message: "inner"];
  [b signpostAt: s + 3 * MS kind: GSP_SIGNPOST_END spid: 7 name: 1 category: 2 message: NULL];
  [b signpostAt: s + 5 * MS kind: GSP_SIGNPOST_END spid: 7 name: 1 category: 2 message: "done"];
  [b signpostAt: s + 6 * MS kind: GSP_SIGNPOST_EVENT spid: 9 name: 3 category: 2 message: NULL];
  [b signpostAt: s + 7 * MS kind: GSP_SIGNPOST_BEGIN spid: 8 name: 1 category: 2 message: NULL];
  [b end: s + 10 * MS];
  GSPTrace *t = [self traceFrom: b name: @"signposts" instruments: nil];
  NSArray *sps = t.targetProcess.signposts;
  XCTAssertEqual([sps count], (NSUInteger)4);

  GSPSignpost *outer = [sps objectAtIndex: 0], *inner = [sps objectAtIndex: 1];
  XCTAssertEqualObjects(outer.beginMessage, @"outer");
  XCTAssertEqualObjects(outer.endMessage, @"done");
  XCTAssertEqual(outer.duration, (GSPTime)(4 * MS));
  XCTAssertEqual(inner.duration, (GSPTime)(1 * MS));
  XCTAssertTrue([[sps objectAtIndex: 2] isEvent]);
  XCTAssertTrue([[sps objectAtIndex: 3] isOpen]);
  XCTAssertTrue([GSPSignpostAnalysis isPointOfInterest: outer]);

  NSArray *sums = [GSPSignpostAnalysis summariesForSignposts: sps];
  GSPSignpostSummary *load = nil;
  for (GSPSignpostSummary *x in sums)
    if ([x.name isEqual: @"Load"])
      load = x;
  XCTAssertEqual(load.count, (NSUInteger)3);
}

- (void) testAllocationsTagsAndLifetimes
{
  TraceBuilder *b = named_builder();
  uint64_t s = b.start;
  uint64_t st[] = { A_COMPUTE + 0x10, A_MAIN + 0x10 };
  [b stack: 1 frames: st count: 2];
  [b string: 5 value: "Widget"];
  /* an object: block at 0x10000, object pointer 8 bytes in (libobjc2) */
  [b allocAt: s + 1 * MS address: 0x10000 size: 24 stack: 1];
  [b tagAt: s + 1 * MS + 1000 address: 0x10008 classString: 5];
  /* a transient malloc */
  [b allocAt: s + 2 * MS address: 0x20000 size: 100 stack: 1];
  [b freeAt: s + 3 * MS address: 0x20000];
  /* a persistent malloc */
  [b allocAt: s + 4 * MS address: 0x30000 size: 1000 stack: 1];
  [b end: s + 10 * MS];
  GSPTrace *t = [self traceFrom: b name: @"allocs" instruments: nil];
  GSPAllocationAnalysis *a = [[GSPAllocationAnalysis alloc] initWithProcess: t.targetProcess];

  XCTAssertEqual(a.recordCount, (NSUInteger)3);
  XCTAssertEqual(a.peakLiveBytes, (uint64_t)1024);
  NSArray *cats = [a categoriesFrom: 0 to: 0];
  GSPAllocationCategory *all = [cats objectAtIndex: 0];
  XCTAssertEqualObjects(all.name, @"All Heap Allocations");
  XCTAssertEqual(all.totalCount, (uint64_t)3);
  XCTAssertEqual(all.persistentBytes, (uint64_t)1024);
  XCTAssertEqual(all.transientCount, (uint64_t)1);
  BOOL sawWidget = NO;
  for (GSPAllocationCategory *c in cats)
    if ([c.name isEqual: @"Widget"])
      {
        sawWidget = YES;
        XCTAssertTrue(c.isObject);
        XCTAssertEqual(c.persistentCount, (uint64_t)1);
      }
  XCTAssertTrue(sawWidget);

  /* in a range ending before the free, the 100-byte block is persistent */
  GSPTime e = t.startTime + (GSPTime)(2.5 * MS);
  NSArray *early = [a categoriesFrom: 0 to: e];
  XCTAssertEqual([(GSPAllocationCategory *)[early objectAtIndex: 0] persistentBytes], (uint64_t)124);

  GSPCallTree *tree = [a callTreeFrom: 0 to: 0 persistentOnly: YES options: 0];
  XCTAssertEqual(tree.totalWeight, (uint64_t)1024);

  double live[4];
  [a liveBytes: live buckets: 4 start: t.startTime end: t.startTime + 8 * MS];
  XCTAssertEqualWithAccuracy(live[3], 1024.0, 0.5);
}

- (void) testLeakSnapshotsResolveClassAndStack
{
  TraceBuilder *b = named_builder();
  uint64_t st[] = { A_HELPER + 0x10, A_MAIN + 0x10 };
  [b stack: 3 frames: st count: 2];
  [b string: 6 value: "Leaky"];
  [b leakSnapshot: 1 at: b.start + MS leaks: [NSArray arrayWithObject:
    [NSArray arrayWithObjects: @0x40000, @24, @3, @6, nil]]];
  [b leakSnapshot: 2 at: b.start + 2 * MS leaks: [NSArray arrayWithObjects:
    [NSArray arrayWithObjects: @0x40000, @24, @3, @6, nil],
    [NSArray arrayWithObjects: @0x50000, @48, @3, @0, nil], nil]];
  [b end: b.start + 3 * MS];
  GSPTrace *t = [self traceFrom: b name: @"leaks" instruments: nil];
  GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: t.targetProcess];

  XCTAssertEqual([t.targetProcess.leakSnapshots count], (NSUInteger)2);
  GSPLeakSnapshot *latest = la.latestSnapshot;
  XCTAssertEqual(latest.ordinal, (uint32_t)2);
  XCTAssertEqual(latest.leakedBytes, (uint64_t)72);
  XCTAssertEqual([[la newLeaksInSnapshot: latest] count], (NSUInteger)1);
  NSArray *groups = [la groupsForSnapshot: nil];
  XCTAssertEqualObjects([[groups objectAtIndex: 0] name], @"Malloc 48 Bytes");
  XCTAssertEqualObjects([[groups objectAtIndex: 1] name], @"Leaky");
  GSPLeak *leak = [[[groups objectAtIndex: 1] leaks] objectAtIndex: 0];
  NSArray *syms = [t.targetProcess.symbolicator symbolsForStack: leak.stack];
  XCTAssertEqualObjects([[syms objectAtIndex: 0] name], @"helper");
}

/* Two 72-byte malloc leaks, one allocated under libs-gui's JPEG check
   (libs-gui#1010) and one by the program: they are grouped apart, only
   the first is labelled, and hiding known leaks leaves the second.  */
- (void) testKnownGNUstepLeaksAreLabelledAndCanBeHidden
{
  TraceBuilder *b = named_builder();
  uint64_t jpeg = 0x8000;   /* after A_RECURSE */
  uint64_t known[] = { jpeg + 0x10, A_HELPER + 0x10, A_MAIN + 0x10 };
  uint64_t own[] = { A_HELPER + 0x20, A_MAIN + 0x10 };
  [b name: jpeg as: @"+[NSBitmapImageRep _bitmapIsJPEG:]"];
  [b stack: 3 frames: known count: 3];
  [b stack: 4 frames: own count: 2];
  [b leakSnapshot: 1 at: b.start + MS leaks: [NSArray arrayWithObjects:
    [NSArray arrayWithObjects: @0x40000, @72, @3, @0, nil],
    [NSArray arrayWithObjects: @0x50000, @72, @4, @0, nil], nil]];
  [b end: b.start + 2 * MS];
  GSPTrace *t = [self traceFrom: b name: @"knownleaks" instruments: nil];
  GSPLeakAnalysis *la = [[GSPLeakAnalysis alloc] initWithProcess: t.targetProcess];

  NSArray *groups = [la groupsForSnapshot: nil];
  XCTAssertEqual([groups count], (NSUInteger)2);
  NSUInteger labelled = 0;
  for (GSPLeakGroup *g in groups)
    {
      XCTAssertEqualObjects(g.name, @"Malloc 72 Bytes");
      XCTAssertEqual(g.count, (uint64_t)1);
      if (g.knownLeak != nil)
        {
          labelled++;
          XCTAssertEqualObjects(g.knownLeak.identifier, @"libs-gui#1010");
          XCTAssertEqual(((GSPLeak *)[g.leaks objectAtIndex: 0]).address, (uint64_t)0x40000);
        }
    }
  XCTAssertEqual(labelled, (NSUInteger)1);
  XCTAssertEqual([la knownLeakCountInSnapshot: nil], (NSUInteger)1);

  la.hidesKnownLeaks = YES;
  groups = [la groupsForSnapshot: nil];
  XCTAssertEqual([groups count], (NSUInteger)1);
  XCTAssertNil([[groups objectAtIndex: 0] knownLeak]);
  XCTAssertEqual(((GSPLeak *)[[[groups objectAtIndex: 0] leaks] objectAtIndex: 0]).address, (uint64_t)0x50000);
  GSPCallTree *tree = [la callTreeForSnapshot: nil options: 0];
  XCTAssertEqual(tree.root.totalWeight, (uint64_t)72);
}

- (void) testHangDetection
{
  TraceBuilder *b = named_builder();
  uint64_t s = b.start;
  uint64_t idle[] = { A_POLL + 0x10, A_RUNLOOP + 0x10, A_MAIN + 0x10 };
  uint64_t busy[] = { A_COMPUTE + 0x10, A_RUNLOOP + 0x10, A_MAIN + 0x10 };
  uint64_t t = s;
  /* launch: busy before the run loop ever waits -> not a hang */
  for (int i = 0; i < 40; i++, t += 10 * MS)
    [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: busy count: 3];
  for (int i = 0; i < 10; i++, t += 10 * MS)
    [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: idle count: 3];
  uint64_t hangStart = t;
  for (int i = 0; i < 60; i++, t += 10 * MS)   /* 600 ms busy */
    [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: busy count: 3];
  for (int i = 0; i < 10; i++, t += 10 * MS)
    [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: idle count: 3];
  for (int i = 0; i < 10; i++, t += 10 * MS)   /* 100 ms: below threshold */
    [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: busy count: 3];
  [b sampleAt: t tid: 4242 kind: GSP_SAMPLE_WALL weight: 1 frames: idle count: 3];
  [b end: t];
  GSPTrace *trace = [self traceFrom: b name: @"hangs" instruments: nil];
  GSPHangAnalysis *h = [[GSPHangAnalysis alloc] initWithProcess: trace.targetProcess
                                                thresholdSeconds: 0.25];
  XCTAssertTrue(h.runLoopDetected);
  XCTAssertEqual([h.hangs count], (NSUInteger)1);
  GSPHang *hang = [h.hangs objectAtIndex: 0];
  XCTAssertEqual(hang.startTime, (GSPTime)hangStart);
  XCTAssertEqualWithAccuracy(hang.duration, 0.6, 0.011);
  XCTAssertEqual(hang.severity, GSPHangHang);
}

- (void) testSymbolNames
{
  XCTAssertEqualObjects([GSPSymbolicator prettyObjCName: @"_i_Foo__doWork_with_"],
                        @"-[Foo doWork:with:]");
  XCTAssertEqualObjects([GSPSymbolicator prettyObjCName: @"_c_Foo_Cat_bar"],
                        @"+[Foo(Cat) bar]");
  XCTAssertNil([GSPSymbolicator prettyObjCName: @"main"]);
  XCTAssertEqualObjects([GSPSymbolicator demangle: @"_ZN3foo3barEv"], @"foo::bar()");
  XCTAssertTrue([GSPSymbolicator isSystemLibraryPath: @"/usr/lib/x86_64-linux-gnu/libc.so.6"]);
  XCTAssertTrue([GSPSymbolicator isSystemLibraryPath:
    @"/usr/GNUstep/System/Library/Libraries/libgnustep-base.so.1.31"]);
  XCTAssertFalse([GSPSymbolicator isSystemLibraryPath: @"/home/me/MyApp.app/MyApp"]);
}

- (void) testEmbeddedSymbolsPreserveUnknownFrames
{
  TraceBuilder *b = [[TraceBuilder alloc] initWithPID: 4242];
  uint64_t frames[] = { 0x140000010ull, 0x140000020ull, 0 };
  [b sampleAt: b.start + MS tid: 4242 kind: GSP_SAMPLE_CPU weight: 1
       frames: frames count: 3];
  [b end: b.start + 2 * MS];
  GSPTrace *t = [self traceFrom: b name: @"embed-unknown" instruments: nil];
  GSPSymbolicator *symbols = t.targetProcess.symbolicator;
  XCTAssertTrue([symbols symbolForFrame: frames[0] index: 0].isUnknown);
  NSDictionary *table = [symbols symbolTableForAllStacks];
  XCTAssertEqualObjects([table objectForKey: @"140000010"], @"0x140000010");
  XCTAssertEqualObjects([table objectForKey: @"14000001f"], @"0x14000001f");
  XCTAssertEqualObjects([table objectForKey: @"0"], @"0x0");
  XCTAssertNil([table objectForKey: @"ffffffffffffffff"]);
  NSString *file = [t.path stringByAppendingPathComponent: @"symbols-4242.plist"];
  XCTAssertTrue([table writeToFile: file atomically: YES]);
  GSPTrace *reopened = [GSPTrace traceWithPath: t.path error: NULL];
  for (NSUInteger i = 0; i < 3; i++)
    XCTAssertEqualObjects([symbols symbolForFrame: frames[i] index: i].name,
      [reopened.targetProcess.symbolicator symbolForFrame: frames[i] index: i].name);
}

- (void) testExporters
{
  TraceBuilder *b = [self cpuBuilder];
  [b end: b.start + 50 * MS];
  GSPTrace *t = [self traceFrom: b name: @"export" instruments: nil];
  NSError *error = nil;
  for (NSString *fmt in [NSArray arrayWithObjects: @"json", @"chrome", @"speedscope", nil])
    {
      NSData *d = [GSPExporter exportTrace: t process: nil format: fmt table: nil error: &error];
      XCTAssertNotNil(d, @"%@: %@", fmt, error);
      id obj = [NSJSONSerialization JSONObjectWithData: d options: 0 error: &error];
      XCTAssertNotNil(obj, @"%@ is not valid JSON: %@", fmt, error);
    }
  NSString *folded = [[NSString alloc] initWithData:
    [GSPExporter exportTrace: t process: nil format: @"collapsed" table: nil error: NULL]
                                           encoding: NSUTF8StringEncoding];
  XCTAssertTrue([folded rangeOfString: @"main;-[Worker_run];-[Worker_compute] 3"].location
                != NSNotFound, @"%@", folded);
  NSString *csv = [[NSString alloc] initWithData:
    [GSPExporter exportTrace: t process: nil format: @"csv" table: @"samples" error: NULL]
                                        encoding: NSUTF8StringEncoding];
  XCTAssertTrue([csv hasPrefix: @"time,tid,kind,weight,stack\n"]);
  XCTAssertNil([GSPExporter exportTrace: t process: nil format: @"bogus" table: nil error: &error]);
}

- (void) testTemplatesAndEnvironment
{
  XCTAssertEqualObjects([[GSPTemplate templateNamed: @"time-profiler"] name], @"Time Profiler");
  XCTAssertNil([GSPTemplate templateNamed: @"nope"]);
  NSDictionary *env = GSPAgentEnvironmentForInstruments(
    [[GSPTemplate templateNamed: @"Leaks"] instrumentIdentifiers], 0, 5);
  XCTAssertEqualObjects([env objectForKey: @"GSP_LEAKS"], @"1");
  XCTAssertEqualObjects([env objectForKey: @"GSP_ALLOCATIONS"], @"1");
  XCTAssertEqualObjects([env objectForKey: @"GSP_LEAK_INTERVAL"], @"5");
  XCTAssertEqualObjects([env objectForKey: @"GSP_CPU_SAMPLING"], @"0");
  env = GSPAgentEnvironmentForInstruments([NSArray arrayWithObject: GSPInstrumentZombies], 0, 0);
  XCTAssertEqualObjects([env objectForKey: @"NSZombieEnabled"], @"YES");
}

#if !defined(_WIN32)
- (void) testHelperStagingIsPrivate
{
  NSError *error = nil;
  NSString *dir = [GSPRecorder stageHelperForInstall: &error];
  XCTAssertNotNil(dir, @"%@", error);
  if (dir == nil)
    return;
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary *a = [fm attributesOfItemAtPath: dir error: NULL];
  XCTAssertEqual([a filePosixPermissions] & 077, (NSUInteger)0);
  NSDictionary *h = [fm attributesOfItemAtPath:
    [dir stringByAppendingPathComponent: @"gstrace-helper"] error: NULL];
  XCTAssertEqual([h filePosixPermissions], (NSUInteger)0755);
  XCTAssertTrue([fm fileExistsAtPath:
    [dir stringByAppendingPathComponent: @"org.gnustep.performancedashboard.policy"]]);
  /* two stagings never share a directory */
  NSString *again = [GSPRecorder stageHelperForInstall: NULL];
  XCTAssertFalse([again isEqual: dir]);
  [fm removeItemAtPath: dir error: NULL];
  [fm removeItemAtPath: again error: NULL];
}
#endif

- (void) testAppImageEnvironmentIsScrubbed
{
  NSDictionary *in = [NSDictionary dictionaryWithObjectsAndKeys:
    @"/tmp/.mount_X", @"APPDIR", @"/tmp/x.AppImage", @"APPIMAGE",
    @"/tmp/.mount_X/usr/lib:/usr/local/lib", @"LD_LIBRARY_PATH",
    @"/tmp/.mount_X/GNUstep", @"GNUSTEP_SYSTEM_ROOT",
    @"/usr/bin:/tmp/.mount_X/usr/bin", @"PATH",
    @":4", @"DISPLAY", @"https://example.invalid/feed", @"TEST_URL",
    @":/tmp/.mount_X/lib:/usr/lib:", @"TEST_PATH",
    @"stale", @"GSP_OUTPUT", @"kept", @"HOME", nil];
  NSDictionary *out = [GSPRecorder targetEnvironmentFrom: in
    additions: [NSDictionary dictionaryWithObject: @"/t.gstrace" forKey: @"GSP_OUTPUT"]];
  XCTAssertEqualObjects([out objectForKey: @"LD_LIBRARY_PATH"], @"/usr/local/lib");
  XCTAssertEqualObjects([out objectForKey: @"PATH"], @"/usr/bin");
  XCTAssertEqualObjects([out objectForKey: @"DISPLAY"], @":4");
  XCTAssertEqualObjects([out objectForKey: @"TEST_URL"], @"https://example.invalid/feed");
  XCTAssertEqualObjects([out objectForKey: @"TEST_PATH"], @":/usr/lib:");
  XCTAssertNil([out objectForKey: @"GNUSTEP_SYSTEM_ROOT"]);
  XCTAssertNil([out objectForKey: @"APPDIR"]);
  XCTAssertNil([out objectForKey: @"APPIMAGE"]);
  XCTAssertEqualObjects([out objectForKey: @"GSP_OUTPUT"], @"/t.gstrace");
  XCTAssertEqualObjects([out objectForKey: @"HOME"], @"kept");
}

@end
