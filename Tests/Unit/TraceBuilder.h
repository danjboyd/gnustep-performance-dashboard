/* TraceBuilder.h - writes synthetic trace bundles for unit tests.

   Addresses are given names through METHOD records, so tests control
   symbolication without real binaries.  */

#import <Foundation/Foundation.h>
#include <GSPerformance/gsp_format.h>

@interface TraceBuilder : NSObject

- (instancetype) initWithPID: (int)pid;

@property (nonatomic, readonly) uint64_t start;   /* stream start time (ns) */

- (void) string: (uint32_t)identifier value: (const char *)value;
- (void) name: (uint64_t)address as: (NSString *)name;   /* METHOD record */
- (void) thread: (uint32_t)tid name: (const char *)name main: (BOOL)isMain at: (uint64_t)t;
- (void) stack: (uint32_t)identifier frames: (const uint64_t *)frames count: (unsigned)n;
- (void) sampleAt: (uint64_t)t tid: (uint32_t)tid kind: (uint32_t)kind weight: (uint16_t)w
           frames: (const uint64_t *)frames count: (unsigned)n;
- (void) allocAt: (uint64_t)t address: (uint64_t)a size: (uint64_t)size stack: (uint32_t)stack;
- (void) freeAt: (uint64_t)t address: (uint64_t)a;
- (void) tagAt: (uint64_t)t address: (uint64_t)a classString: (uint32_t)sid;
- (void) signpostAt: (uint64_t)t kind: (uint32_t)kind spid: (uint64_t)spid
               name: (uint32_t)nameID category: (uint32_t)catID message: (const char *)msg;
- (void) leakSnapshot: (uint32_t)ordinal at: (uint64_t)t leaks: (NSArray *)leaks; /* @[@[addr,size,stack,class]] */
- (void) end: (uint64_t)t;
- (void) diagnosticAt: (uint64_t)t message: (const char *)message;
- (void) dropped: (uint64_t)count;
- (void) appendGarbage: (NSUInteger)bytes;   /* a torn final record */

/* Writes <dir>/events-<pid>.bin and an Info.plist; returns the bundle path. */
- (NSString *) writeBundleNamed: (NSString *)name instruments: (NSArray *)instruments;

@end
