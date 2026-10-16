/* GSPCallTree.h - call trees over weighted stacks, with Apple Instruments'
   "Call Tree" options (invert, separate by thread, hide system libraries,
   flatten recursion, top functions) and data mining (charge to caller,
   prune, focus).  */

#import <Foundation/Foundation.h>
#import "GSPTrace.h"

@class GSPSymbol;

typedef NS_OPTIONS(NSUInteger, GSPCallTreeOptions)
{
  GSPCallTreeInvert = 1 << 0,
  GSPCallTreeSeparateByThread = 1 << 1,
  GSPCallTreeHideSystemLibraries = 1 << 2,
  GSPCallTreeFlattenRecursion = 1 << 3,
  GSPCallTreeTopFunctions = 1 << 4
};

@interface GSPCallTreeNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, strong) GSPSymbol *symbol;   /* nil for thread/root nodes */
@property (nonatomic) uint64_t totalWeight;
@property (nonatomic) uint64_t selfWeight;
@property (nonatomic) uint64_t sampleCount;
@property (nonatomic, weak) GSPCallTreeNode *parent;
@property (nonatomic, readonly) NSArray *children;  /* sorted by totalWeight, desc */
@property (nonatomic) BOOL isThread;
@property (nonatomic) uint32_t tid;
/* A representative stack through this node, for the stack inspector. */
@property (nonatomic) uint32_t heaviestStack;
@property (nonatomic) uint64_t heaviestStackWeight;

- (GSPCallTreeNode *) heaviestPathLeaf;
- (NSArray *) pathFromRoot;   /* excluding the root */
@end

/* One weighted stack input. */
typedef struct GSPWeightedStack
{
  uint32_t stack;
  uint32_t tid;
  uint64_t weight;
} GSPWeightedStack;

@interface GSPCallTree : NSObject

@property (nonatomic) GSPCallTreeOptions options;
@property (nonatomic, copy) NSSet *chargedToCaller;  /* symbol names */
@property (nonatomic, copy) NSSet *pruned;           /* symbol names: drop samples */
@property (nonatomic, copy) NSString *focusSymbol;   /* only stacks through it, rooted there */
@property (nonatomic, copy) NSString *weightUnit;    /* "ms", "bytes", "samples" */

/* Time Profiler tree from a process' CPU samples within [start, end]
   (0, 0 = everything).  `tids` limits threads (nil = all).  Weight is in
   sample intervals (multiply by the interval for time). */
+ (GSPCallTree *) cpuTreeForProcess: (GSPProcess *)process
                              start: (GSPTime)start
                                end: (GSPTime)end
                            threads: (NSSet *)tids
                            options: (GSPCallTreeOptions)options;

- (instancetype) initWithProcess: (GSPProcess *)process;
- (void) buildFromStacks: (const GSPWeightedStack *)stacks count: (NSUInteger)count;
/* Build again from the last input, e.g. after changing the options or the
   data-mining sets. */
- (void) rebuild;

@property (nonatomic, readonly) GSPCallTreeNode *root;
@property (nonatomic, readonly) uint64_t totalWeight;
@property (nonatomic, readonly) GSPProcess *process;

/* Text rendering for the CLI. */
- (NSString *) textWithMaxDepth: (NSUInteger)depth
                     minPercent: (double)minPercent
                 weightFormatter: (NSString *(^)(uint64_t weight))formatter;

@end
