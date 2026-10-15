/* GSPAnalysis.h - Hangs, Allocations, Leaks, Points of Interest.  */

#import <Foundation/Foundation.h>
#import "GSPTrace.h"

@class GSPCallTree;

/* ------------------------------------------------------------------ */
/* Hangs                                                               */

typedef NS_ENUM(NSInteger, GSPHangSeverity)
{
  GSPHangMicrohang = 0,    /* 250 ms - 500 ms: brief unresponsiveness */
  GSPHangHang = 1,         /* 500 ms - 2 s */
  GSPHangSevere = 2        /* >= 2 s */
};

@interface GSPHang : NSObject
@property (nonatomic) GSPTime startTime;
@property (nonatomic) GSPTime endTime;
@property (nonatomic) GSPHangSeverity severity;
@property (nonatomic) NSUInteger sampleCount;
@property (nonatomic) uint32_t representativeStack;  /* most frequent stack */
@property (nonatomic, readonly) double duration;      /* seconds */
@property (nonatomic, readonly) NSString *severityName;
@end

@interface GSPHangAnalysis : NSObject
- (instancetype) initWithProcess: (GSPProcess *)process thresholdSeconds: (double)threshold;
@property (nonatomic, readonly) NSArray *hangs;          /* GSPHang */
/* NO when no main-thread wall samples show a run loop waiting for events
   (command-line tools, or wall sampling was off): hangs are not
   meaningful then.  */
@property (nonatomic, readonly) BOOL runLoopDetected;
@property (nonatomic, readonly) BOOL hasWallSamples;
/* Main-thread busy fraction (0..1) per bucket, for the track graph. */
- (void) busyFraction: (double *)out buckets: (NSUInteger)n
                start: (GSPTime)start end: (GSPTime)end;
- (BOOL) isIdleStack: (uint32_t)stack;
@end

/* ------------------------------------------------------------------ */
/* Allocations                                                         */

typedef struct GSPAllocationRecord
{
  GSPTime allocTime;
  GSPTime freeTime;      /* 0 = still alive at end of recording */
  uint64_t address;
  uint64_t size;
  uint32_t stack;
  uint32_t category;     /* index into categoryNames */
  uint32_t tid;
  uint32_t reserved;
} GSPAllocationRecord;

@interface GSPAllocationCategory : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t index;
@property (nonatomic) BOOL isObject;           /* tagged Objective-C instance */
@property (nonatomic) uint64_t persistentCount, persistentBytes;
@property (nonatomic) uint64_t transientCount, transientBytes;
@property (nonatomic) uint64_t totalCount, totalBytes;
@end

@interface GSPAllocationAnalysis : NSObject

- (instancetype) initWithProcess: (GSPProcess *)process;

@property (nonatomic, readonly) const GSPAllocationRecord *records;
@property (nonatomic, readonly) NSUInteger recordCount;
@property (nonatomic, readonly) NSArray *categoryNames;   /* NSString */
@property (nonatomic, readonly) uint64_t peakLiveBytes;

/* Allocations created in [start, end]; persistent = still alive at end.
   end == 0 means the end of the recording.  First element is the
   "All Heap Allocations" summary.  Sorted by persistent bytes. */
- (NSArray *) categoriesFrom: (GSPTime)start to: (GSPTime)end;

/* Indices into `records` for one category (UINT32_MAX = all), created in
   the range; persistentOnly keeps those alive at `end`. */
- (NSIndexSet *) recordsInCategory: (uint32_t)category from: (GSPTime)start
                                to: (GSPTime)end persistentOnly: (BOOL)persistent;

- (GSPCallTree *) callTreeFrom: (GSPTime)start to: (GSPTime)end
                persistentOnly: (BOOL)persistent options: (NSUInteger)options;

/* Live heap bytes at the end of each bucket. */
- (void) liveBytes: (double *)out buckets: (NSUInteger)n
             start: (GSPTime)start end: (GSPTime)end;

+ (NSString *) mallocCategoryNameForSize: (uint64_t)size;
+ (NSString *) formatBytes: (uint64_t)bytes;

@end

/* ------------------------------------------------------------------ */
/* Leaks                                                               */

@interface GSPLeakGroup : NSObject
@property (nonatomic, copy) NSString *name;   /* class or "Malloc N Bytes" */
@property (nonatomic) uint64_t count;
@property (nonatomic) uint64_t bytes;
@property (nonatomic, strong) NSMutableArray *leaks;
@end

@interface GSPLeakAnalysis : NSObject
- (instancetype) initWithProcess: (GSPProcess *)process;
@property (nonatomic, readonly) GSPLeakSnapshot *latestSnapshot;
/* Groups for a snapshot (nil = latest), sorted by bytes. */
- (NSArray *) groupsForSnapshot: (GSPLeakSnapshot *)snapshot;
/* Leaks in `snapshot` that were not leaked in the previous snapshot. */
- (NSArray *) newLeaksInSnapshot: (GSPLeakSnapshot *)snapshot;
- (GSPCallTree *) callTreeForSnapshot: (GSPLeakSnapshot *)snapshot options: (NSUInteger)options;
@end

/* ------------------------------------------------------------------ */
/* Points of Interest / signposts                                      */

@interface GSPSignpostSummary : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *subsystem;
@property (nonatomic, copy) NSString *category;
@property (nonatomic) NSUInteger count;
@property (nonatomic) double totalDuration, minDuration, maxDuration;
@property (nonatomic, readonly) double averageDuration;
@property (nonatomic) BOOL isEvent;
@end

@interface GSPSignpostAnalysis : NSObject
+ (NSArray *) summariesForSignposts: (NSArray *)signposts;  /* GSPSignpostSummary */
+ (NSArray *) signposts: (NSArray *)signposts from: (GSPTime)start to: (GSPTime)end;
+ (BOOL) isPointOfInterest: (GSPSignpost *)signpost;
@end

/* ------------------------------------------------------------------ */
/* Zombies                                                             */

@interface GSPHistoryEvent : NSObject
@property (nonatomic) GSPTime time;
@property (nonatomic, copy) NSString *kind;   /* Malloc, Retain, Release, Autorelease, Free, Zombie */
@property (nonatomic) uint32_t stack;
@end

/* Malloc/retain/release/free history of the object a zombie event names,
   up to and including the zombie message, oldest first. */
NSArray *GSPZombieHistory(GSPProcess *process, GSPZombieEvent *zombie);

/* Formatting helpers shared by the CLI and the app. */
NSString *GSPFormatDuration(double seconds);
