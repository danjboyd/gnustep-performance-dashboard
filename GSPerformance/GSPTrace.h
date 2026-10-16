/* GSPTrace.h - reading GNUstep Instruments trace bundles.  */

#import <Foundation/Foundation.h>

@class GSPSymbolicator;
@class GSPStackTable;

/* Times are CLOCK_MONOTONIC nanoseconds, as recorded.  Use
   -[GSPTrace relativeTime:] for display. */
typedef uint64_t GSPTime;

typedef struct GSPSample
{
  GSPTime time;
  uint32_t tid;
  uint32_t stack;    /* index into the process stack table */
  uint16_t kind;     /* GSP_SAMPLE_* */
  uint16_t weight;   /* >= 1 */
  uint32_t reserved;
} GSPSample;

typedef struct GSPAllocationEvent
{
  GSPTime time;
  uint64_t address;
  uint64_t size;
  uint64_t oldAddress;  /* realloc source, 0 otherwise */
  uint32_t stack;       /* stack table index, 0 = none */
  uint32_t tid;
  uint8_t isFree;
  uint8_t reserved[7];
} GSPAllocationEvent;

typedef struct GSPTagEvent
{
  GSPTime time;
  uint64_t address;
  uint32_t className;   /* process string id */
  uint32_t reserved;
} GSPTagEvent;

typedef struct GSPRefCountEvent
{
  GSPTime time;
  uint64_t address;
  uint32_t stack;
  uint32_t tid;
  int32_t kind;         /* GSP_RC_* */
  int32_t refcount;
} GSPRefCountEvent;

typedef struct GSPIOEvent
{
  GSPTime time;          /* start */
  uint64_t duration;     /* ns */
  int64_t result;        /* bytes, new fd, 0, or -errno */
  int32_t fd;
  uint32_t name;         /* process string id (path or peer), 0 if none */
  uint32_t stack;
  uint32_t tid;
  uint16_t op;           /* GSP_IO_* */
  uint16_t reserved;
  uint32_t flags;
} GSPIOEvent;

@interface GSPThreadInfo : NSObject
@property (nonatomic) uint32_t tid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isMain;
@property (nonatomic) GSPTime startTime;
@property (nonatomic) GSPTime endTime;     /* 0 if still running */
@property (nonatomic, readonly) NSString *displayName;
@end

@interface GSPImage : NSObject
@property (nonatomic) uint64_t base;
@property (nonatomic) uint64_t start;
@property (nonatomic) uint64_t end;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, readonly) NSString *name;
@end

@interface GSPSignpost : NSObject
@property (nonatomic, copy) NSString *subsystem;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint64_t signpostID;
@property (nonatomic) uint32_t tid;
@property (nonatomic) GSPTime beginTime;
@property (nonatomic) GSPTime endTime;     /* == beginTime for events */
@property (nonatomic, copy) NSString *beginMessage;
@property (nonatomic, copy) NSString *endMessage;
@property (nonatomic) BOOL isEvent;
@property (nonatomic) BOOL isOpen;         /* begin without end */
@property (nonatomic, readonly) GSPTime duration;
@end

@interface GSPLogMessage : NSObject
@property (nonatomic) GSPTime time;
@property (nonatomic) uint32_t tid;
@property (nonatomic) int level;
@property (nonatomic, copy) NSString *subsystem;
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *message;
@end

@interface GSPLeak : NSObject
@property (nonatomic) uint64_t address;
@property (nonatomic) uint64_t size;
@property (nonatomic) uint32_t stack;
@property (nonatomic, copy) NSString *className;   /* nil for malloc */
@end

@interface GSPLeakSnapshot : NSObject
@property (nonatomic) uint32_t ordinal;
@property (nonatomic) GSPTime time;
@property (nonatomic) uint64_t liveCount;
@property (nonatomic) uint64_t liveBytes;
@property (nonatomic) uint64_t leakedBytes;
@property (nonatomic) uint64_t scanMicroseconds;
@property (nonatomic, strong) NSMutableArray *leaks;  /* GSPLeak */
@end

@interface GSPZombieEvent : NSObject
@property (nonatomic) GSPTime time;
@property (nonatomic) uint32_t tid;
@property (nonatomic) uint64_t address;
@property (nonatomic, copy) NSString *selector;
@property (nonatomic, copy) NSString *className;   /* from allocation history */
@property (nonatomic) uint32_t stack;
@end

/* One traced process (one event stream). */
@interface GSPProcess : NSObject
@property (nonatomic, readonly, copy) NSString *streamPath;
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) int ppid;
@property (nonatomic, readonly, copy) NSString *executablePath;
@property (nonatomic, readonly) GSPTime startTime;
@property (nonatomic, readonly) GSPTime endTime;
@property (nonatomic, readonly) BOOL finishedCleanly;
@property (nonatomic, readonly) BOOL fromPerf;
@property (nonatomic, readonly) uint32_t sampleIntervalMicroseconds;
@property (nonatomic, readonly) uint32_t wallIntervalMicroseconds;
@property (nonatomic, readonly) uint64_t droppedSamples;

@property (nonatomic, readonly) NSDictionary *threads;   /* NSNumber tid -> GSPThreadInfo */
@property (nonatomic, readonly) NSArray *images;         /* GSPImage, by start */
@property (nonatomic, readonly) NSArray *signposts;      /* GSPSignpost, by begin */
@property (nonatomic, readonly) NSArray *logMessages;
@property (nonatomic, readonly) NSArray *leakSnapshots;  /* GSPLeakSnapshot */
@property (nonatomic, readonly) NSArray *zombies;
@property (nonatomic, readonly) NSDictionary *methodNames; /* NSNumber imp -> NSString */
@property (nonatomic, readonly) GSPStackTable *stacks;

/* C tables, sorted by time. */
@property (nonatomic, readonly) const GSPSample *samples;
@property (nonatomic, readonly) NSUInteger sampleCount;
@property (nonatomic, readonly) const GSPAllocationEvent *allocationEvents;
@property (nonatomic, readonly) NSUInteger allocationEventCount;
@property (nonatomic, readonly) const GSPTagEvent *tagEvents;
@property (nonatomic, readonly) NSUInteger tagEventCount;
@property (nonatomic, readonly) const GSPRefCountEvent *refCountEvents;
@property (nonatomic, readonly) NSUInteger refCountEventCount;
@property (nonatomic, readonly) const GSPIOEvent *ioEvents;
@property (nonatomic, readonly) NSUInteger ioEventCount;

@property (nonatomic, readonly) GSPSymbolicator *symbolicator;

- (NSString *) stringForID: (uint32_t)identifier;
- (NSArray *) sortedThreads;   /* main thread first */
- (GSPThreadInfo *) mainThread;
@end

@interface GSPTrace : NSObject

+ (instancetype) traceWithPath: (NSString *)path error: (NSError **)error;

/* Re-read event streams that grew (live recording). */
- (BOOL) reload: (NSError **)error;
/* Whether the last -reload: found new data. */
@property (nonatomic, readonly) BOOL changedOnLastReload;

@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) NSDictionary *info;      /* Info.plist */
@property (nonatomic, readonly) NSArray *processes;      /* GSPProcess */
@property (nonatomic, readonly) GSPProcess *targetProcess;
@property (nonatomic, readonly) GSPTime startTime;
@property (nonatomic, readonly) GSPTime endTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSDate *startDate;
@property (nonatomic, readonly, copy) NSString *templateName;
@property (nonatomic, readonly) NSArray *instrumentIdentifiers;

- (double) relativeTime: (GSPTime)time;   /* seconds since startTime */
- (GSPTime) absoluteTime: (double)seconds;
- (GSPProcess *) processWithPID: (int)pid;

@end

extern NSString * const GSPTraceErrorDomain;
