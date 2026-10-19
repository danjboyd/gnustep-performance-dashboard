/* An isolated distro GCC/libobjc target. Never link this with libobjc2. */
#import <Foundation/Foundation.h>
#include <time.h>

@interface LegacyWork : NSObject
- (unsigned long)busyWork;
@end
@implementation LegacyWork
- (unsigned long)busyWork
{
  volatile unsigned long sum = 0;
  unsigned long i;
  for (i = 0; i < 10000000; i++)
    sum += i % 97;
  return sum;
}
@end

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  LegacyWork *worker = [LegacyWork new];
  clock_t start = clock();
  while ((double)(clock() - start) / CLOCKS_PER_SEC < 2.0)
    [worker busyWork];
  [worker release];
  [pool drain];
  return 0;
}
