#import "GSPInstruments.h"

NSString * const GSPInstrumentTimeProfiler = @"time-profiler";
NSString * const GSPInstrumentHangs = @"hangs";
NSString * const GSPInstrumentPointsOfInterest = @"points-of-interest";
NSString * const GSPInstrumentLogging = @"os-log";
NSString * const GSPInstrumentAllocations = @"allocations";
NSString * const GSPInstrumentLeaks = @"leaks";
NSString * const GSPInstrumentZombies = @"zombies";
NSString * const GSPInstrumentSystemProfiler = @"system-time-profiler";

static GSPInstrument *
make_instrument(NSString *ident, NSString *name, NSString *summary,
                BOOL privileged, BOOL launch, BOOL attach)
{
  GSPInstrument *i = [GSPInstrument new];
  i.identifier = ident;
  i.name = name;
  i.summary = summary;
  i.requiresPrivilegedHelper = privileged;
  i.supportsLaunch = launch;
  i.supportsAttach = attach;
  return i;
}

@implementation GSPInstrument

+ (NSArray *) allInstruments
{
  static NSArray *all;
  if (all == nil)
    all = [NSArray arrayWithObjects:
      make_instrument(GSPInstrumentTimeProfiler, @"Time Profiler",
        @"Samples the call stacks of running threads to show where CPU time goes.",
        NO, YES, NO),
      make_instrument(GSPInstrumentHangs, @"Hangs",
        @"Finds periods when the main run loop could not handle events for 250 ms or more.",
        NO, YES, NO),
      make_instrument(GSPInstrumentPointsOfInterest, @"Points of Interest",
        @"Shows os_signpost intervals and events emitted by the app.",
        NO, YES, NO),
      make_instrument(GSPInstrumentLogging, @"os_log",
        @"Collects os_log messages emitted by the app.",
        NO, YES, NO),
      make_instrument(GSPInstrumentAllocations, @"Allocations",
        @"Records every heap allocation with its call stack and Objective-C class.",
        NO, YES, NO),
      make_instrument(GSPInstrumentLeaks, @"Leaks",
        @"Periodically scans the heap for memory that is no longer referenced.",
        NO, YES, NO),
      make_instrument(GSPInstrumentZombies, @"Zombies",
        @"Keeps deallocated objects as zombies and records messages sent to them.",
        NO, YES, NO),
      make_instrument(GSPInstrumentSystemProfiler, @"System Time Profiler",
        @"Samples a running process with perf_event, including kernel stacks. Needs the profiling helper.",
        YES, NO, YES),
      nil];
  return all;
}

+ (GSPInstrument *) instrumentWithIdentifier: (NSString *)identifier
{
  for (GSPInstrument *i in [self allInstruments])
    if ([i.identifier isEqual: identifier])
      return i;
  return nil;
}

@end

static GSPTemplate *
make_template(NSString *name, NSString *summary, NSArray *ids)
{
  GSPTemplate *t = [GSPTemplate new];
  t.name = name;
  t.summary = summary;
  t.instrumentIdentifiers = ids;
  return t;
}

@implementation GSPTemplate

+ (NSArray *) allTemplates
{
  static NSArray *all;
  if (all == nil)
    all = [NSArray arrayWithObjects:
      make_template(@"Time Profiler",
        @"Where the app spends CPU time, with main-thread hangs and points of interest.",
        [NSArray arrayWithObjects: GSPInstrumentTimeProfiler, GSPInstrumentHangs,
          GSPInstrumentPointsOfInterest, nil]),
      make_template(@"Allocations",
        @"Heap allocations by class and call stack, with persistent and transient memory.",
        [NSArray arrayWithObjects: GSPInstrumentAllocations,
          GSPInstrumentPointsOfInterest, nil]),
      make_template(@"Leaks",
        @"Allocations plus periodic leak checks.",
        [NSArray arrayWithObjects: GSPInstrumentAllocations, GSPInstrumentLeaks,
          GSPInstrumentPointsOfInterest, nil]),
      make_template(@"Zombies",
        @"Detects messages sent to deallocated objects, with retain/release history.",
        [NSArray arrayWithObjects: GSPInstrumentAllocations, GSPInstrumentZombies, nil]),
      make_template(@"Hangs",
        @"Main-thread responsiveness with the stacks behind each hang.",
        [NSArray arrayWithObjects: GSPInstrumentHangs, GSPInstrumentTimeProfiler, nil]),
      make_template(@"Logging",
        @"Signposts and os_log messages.",
        [NSArray arrayWithObjects: GSPInstrumentPointsOfInterest, GSPInstrumentLogging, nil]),
      make_template(@"System Time Profiler",
        @"Attach to a running process and sample it with perf_event (needs the profiling helper).",
        [NSArray arrayWithObject: GSPInstrumentSystemProfiler]),
      make_template(@"Blank",
        @"Start empty and add instruments yourself.",
        [NSArray array]),
      nil];
  return all;
}

+ (GSPTemplate *) templateNamed: (NSString *)name
{
  NSString *want = [[name lowercaseString]
    stringByReplacingOccurrencesOfString: @"-" withString: @" "];
  for (GSPTemplate *t in [self allTemplates])
    if ([[t.name lowercaseString] isEqual: want])
      return t;
  return nil;
}

@end

NSDictionary *
GSPAgentEnvironmentForInstruments(NSArray *ids, unsigned sampleIntervalUs,
                                  unsigned leakIntervalSeconds)
{
  NSMutableDictionary *env = [NSMutableDictionary dictionary];
  BOOL cpu = [ids containsObject: GSPInstrumentTimeProfiler];
  BOOL hangs = [ids containsObject: GSPInstrumentHangs];
  BOOL signposts = [ids containsObject: GSPInstrumentPointsOfInterest]
    || [ids containsObject: GSPInstrumentLogging];
  BOOL allocs = [ids containsObject: GSPInstrumentAllocations];
  BOOL leaks = [ids containsObject: GSPInstrumentLeaks];
  BOOL zombies = [ids containsObject: GSPInstrumentZombies];

  [env setObject: cpu ? @"1" : @"0" forKey: @"GSP_CPU_SAMPLING"];
  [env setObject: hangs ? @"1" : @"0" forKey: @"GSP_WALL_SAMPLING"];
  [env setObject: signposts ? @"1" : @"0" forKey: @"GSP_SIGNPOSTS"];
  [env setObject: (allocs || leaks || zombies) ? @"1" : @"0" forKey: @"GSP_ALLOCATIONS"];
  [env setObject: leaks ? @"1" : @"0" forKey: @"GSP_LEAKS"];
  [env setObject: zombies ? @"1" : @"0" forKey: @"GSP_ZOMBIES"];
  [env setObject: zombies ? @"1" : @"0" forKey: @"GSP_REFCOUNTS"];
  if (zombies)
    [env setObject: @"YES" forKey: @"NSZombieEnabled"];
  if (sampleIntervalUs)
    [env setObject: [NSString stringWithFormat: @"%u", sampleIntervalUs]
            forKey: @"GSP_SAMPLE_INTERVAL_US"];
  if (leaks)
    [env setObject: [NSString stringWithFormat: @"%u",
                     leakIntervalSeconds ? leakIntervalSeconds : 10]
            forKey: @"GSP_LEAK_INTERVAL"];
  return env;
}
