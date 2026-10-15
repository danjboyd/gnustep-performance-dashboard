/* GSPStackTable.h - deduplicated call stacks of one process.

   Index 0 is the empty stack.  Frames are stored leaf first: frame 0 is the
   sampled PC (or allocation call site) and later frames are return
   addresses.  */

#import <Foundation/Foundation.h>

@interface GSPStackTable : NSObject

- (uint32_t) internFrames: (const uint64_t *)frames count: (NSUInteger)count;
- (const uint64_t *) framesForStack: (uint32_t)index count: (NSUInteger *)count;
- (NSUInteger) count;

/* Every distinct address used by any stack (for symbolication caches). */
- (NSSet *) allAddresses;

@end
