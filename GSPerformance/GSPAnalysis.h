/* SPDX-License-Identifier: LGPL-2.1-or-later */
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
/* Evidence only: wall sample counts by stack, estimated main-thread CPU
   seconds, and indices of main-thread I/O overlapping the interval.
   Wall samples are not scheduler states or proof of lock ownership. */
- (NSDictionary *) evidenceForHang: (GSPHang *)hang;
- (GSPCallTree *) wallTreeForHang: (GSPHang *)hang options: (NSUInteger)options;
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

/* Generation window is [start, end], independently observed at checkpoint.
   Zero checkpoint means the end of the recording. checkpoint must be >= end.
   For adjacent generations use previous end + 1 as the next start. */
- (NSArray *) categoriesFrom: (GSPTime)start to: (GSPTime)end
                survivingAt: (GSPTime)checkpoint;
- (NSIndexSet *) recordsInCategory: (uint32_t)category from: (GSPTime)start
                                to: (GSPTime)end survivingAt: (GSPTime)checkpoint
                    persistentOnly: (BOOL)persistent;
- (GSPCallTree *) callTreeFrom: (GSPTime)start to: (GSPTime)end
                 survivingAt: (GSPTime)checkpoint persistentOnly: (BOOL)persistent
                     options: (NSUInteger)options;

/* Live heap bytes at the end of each bucket. */
- (void) liveBytes: (double *)out buckets: (NSUInteger)n
             start: (GSPTime)start end: (GSPTime)end;

+ (NSString *) mallocCategoryNameForSize: (uint64_t)size;
+ (NSString *) formatBytes: (uint64_t)bytes;

@end

/* ------------------------------------------------------------------ */
/* Leaks                                                               */

/* A leak in a GNUstep library that has been reported upstream: not the
   recorded program's fault.  Recognised by a function in the leak's
   allocation stack.  */
@interface GSPKnownLeak : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;  /* "libs-gui#1010" */
@property (nonatomic, readonly, copy) NSString *summary;
@property (nonatomic, readonly, copy) NSString *URL;
@property (nonatomic, readonly, copy) NSArray *functions;    /* any one of them */
+ (NSArray *) allKnownLeaks;
@end

@interface GSPLeakGroup : NSObject
@property (nonatomic, copy) NSString *name;   /* class or "Malloc N Bytes" */
@property (nonatomic) uint64_t count;
@property (nonatomic) uint64_t bytes;
@property (nonatomic, strong) NSMutableArray *leaks;
@property (nonatomic, strong) GSPKnownLeak *knownLeak;  /* nil unless all are known */
@end

@interface GSPLeakAnalysis : NSObject
- (instancetype) initWithProcess: (GSPProcess *)process;
@property (nonatomic, readonly) GSPLeakSnapshot *latestSnapshot;
/* Leave known GNUstep leaks out of the groups and the call tree.  */
@property (nonatomic) BOOL hidesKnownLeaks;
/* Groups for a snapshot (nil = latest), sorted by bytes.  Known leaks are
   grouped apart from the program's own leaks of the same class.  */
- (NSArray *) groupsForSnapshot: (GSPLeakSnapshot *)snapshot;
/* Leaks in `snapshot` that were not leaked in the previous snapshot. */
- (NSArray *) newLeaksInSnapshot: (GSPLeakSnapshot *)snapshot;
- (GSPCallTree *) callTreeForSnapshot: (GSPLeakSnapshot *)snapshot options: (NSUInteger)options;
/* The known GNUstep leak `leak` is, or nil.  */
- (GSPKnownLeak *) knownLeakForLeak: (GSPLeak *)leak;
/* How many leaks in `snapshot` (nil = latest) are known GNUstep leaks.  */
- (NSUInteger) knownLeakCountInSnapshot: (GSPLeakSnapshot *)snapshot;
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
/* File Activity and Network                                           */

@interface GSPIOSummary : NSObject
@property (nonatomic, copy) NSString *name;        /* path, peer, or "fd N" */
@property (nonatomic) BOOL isNetwork;
@property (nonatomic) uint64_t opens;              /* open/connect/accept */
@property (nonatomic) uint64_t reads, bytesRead;   /* read or recv */
@property (nonatomic) uint64_t writes, bytesWritten; /* write or send */
@property (nonatomic) uint64_t syncs;
@property (nonatomic) uint64_t errors;
@property (nonatomic) uint64_t totalDuration;      /* ns */
@end

@interface GSPIOAnalysis : NSObject
- (instancetype) initWithProcess: (GSPProcess *)process;
/* For each event (same order as process.ioEvents): the resolved name. */
- (NSString *) nameOfEvent: (NSUInteger)index;
- (BOOL) isNetworkEvent: (NSUInteger)index;
/* Summaries per file (network NO) or per peer (YES), sorted by total
   duration, for events starting in [start, end] (0, 0 = all). */
- (NSArray *) summariesForNetwork: (BOOL)network from: (GSPTime)start to: (GSPTime)end;
- (NSIndexSet *) eventsForNetwork: (BOOL)network from: (GSPTime)start to: (GSPTime)end;
/* Bytes read/received and written/sent per bucket. */
- (void) bytesForNetwork: (BOOL)network read: (double *)rd written: (double *)wr
                 buckets: (NSUInteger)n start: (GSPTime)start end: (GSPTime)end;
/* Call tree weighted by time spent in the calls (ns). */
- (GSPCallTree *) callTreeForNetwork: (BOOL)network from: (GSPTime)start
                                  to: (GSPTime)end options: (NSUInteger)options;
@property (nonatomic, readonly) BOOL hasFileEvents;
@property (nonatomic, readonly) BOOL hasNetworkEvents;
+ (NSString *) operationName: (uint16_t)op;
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
