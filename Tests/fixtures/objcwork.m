/* objcwork - Foundation fixture: CPU in Objective-C methods, object
   allocations and leaks, signposts and os_log, and (with "zombie") a
   message to a deallocated object.  Manual reference counting.  */

#import <Foundation/Foundation.h>
#include <os/signpost.h>
#include <os/log.h>

@interface Worker : NSObject
{
  NSMutableArray *items;
}
- (double) crunch: (int)n;
- (void) fill: (int)n;
@end

@interface Leaky : NSObject
{
@public
  Leaky *other;
}
@end

@implementation Leaky
@end

@implementation Worker
- (id) init
{
  if ((self = [super init]) != nil)
    items = [NSMutableArray new];
  return self;
}
- (void) dealloc
{
  [items release];
  [super dealloc];
}
- (double) crunch: (int)n
{
  double x = 0;
  for (int i = 0; i < n; i++)
    x += (double)(i % 7) * 0.25;
  return x;
}
- (void) fill: (int)n
{
  for (int i = 0; i < n; i++)
    {
      NSString *s = [[NSString alloc] initWithFormat: @"item %d", i];
      [items addObject: s];
      [s release];
    }
}
@end

/* Leaks: three lone objects and a two-object retain cycle.  Created in
   their own frame, then the stack is scrubbed so no stale copies keep
   them reachable to the conservative scanner.  */
__attribute__((noinline)) static void
make_leaks(void)
{
  for (int i = 0; i < 3; i++)
    {
      Leaky *a = [Leaky new];
      a = nil;
    }
  Leaky *c1 = [Leaky new], *c2 = [Leaky new];
  c1->other = c2;
  c2->other = c1;
}

__attribute__((noinline)) static void
scrub_stack(void)
{
  volatile char buf[32768];
  memset((char *)buf, 0, sizeof(buf));
}

int
main(int argc, char **argv)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  os_log_t log = os_log_create("org.gnustep.tests", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  os_log_t general = os_log_create("org.gnustep.tests", "general");
  Worker *w = [Worker new];
  volatile double sink = 0;

  os_log(general, "objcwork starting with %d args", argc);
  for (int round = 0; round < 5; round++)
    {
      os_signpost_id_t spid = os_signpost_id_generate(log);
      os_signpost_interval_begin(log, spid, "Round", "round %d", round);
      sink += [w crunch: 3000000];
      [w fill: 2000];
      os_signpost_interval_end(log, spid, "Round");
    }
  os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "Checkpoint", "filled");

  make_leaks();
  scrub_stack();

  if (argc > 1 && strcmp(argv[1], "zombie") == 0)
    {
      NSObject *o = [NSObject new];
      [o release];
      [o description];   /* message to a zombie */
    }
  [w release];
  printf("done %f\n", sink);
  [pool release];
  return 0;
}
