/* GSPInstruments.h - the instruments and templates GNUstep Instruments
   offers, and how each maps onto agent configuration.  */

#import <Foundation/Foundation.h>

extern NSString * const GSPInstrumentTimeProfiler;       /* "time-profiler" */
extern NSString * const GSPInstrumentHangs;              /* "hangs" */
extern NSString * const GSPInstrumentPointsOfInterest;   /* "points-of-interest" */
extern NSString * const GSPInstrumentLogging;            /* "os-log" */
extern NSString * const GSPInstrumentAllocations;        /* "allocations" */
extern NSString * const GSPInstrumentLeaks;              /* "leaks" */
extern NSString * const GSPInstrumentZombies;            /* "zombies" */
extern NSString * const GSPInstrumentSystemProfiler;     /* "system-time-profiler" */
extern NSString * const GSPInstrumentFileActivity;       /* "file-activity" */
extern NSString * const GSPInstrumentNetwork;            /* "network" */

@interface GSPInstrument : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic) BOOL requiresPrivilegedHelper;
@property (nonatomic) BOOL supportsLaunch;
@property (nonatomic) BOOL supportsAttach;

+ (NSArray *) allInstruments;
+ (GSPInstrument *) instrumentWithIdentifier: (NSString *)identifier;
@end

@interface GSPTemplate : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSArray *instrumentIdentifiers;

+ (NSArray *) allTemplates;
+ (GSPTemplate *) templateNamed: (NSString *)name;   /* case-insensitive */
@end

/* Agent environment for a set of instruments (GSP_* variables, plus
   NSZombieEnabled for Zombies). */
NSDictionary *GSPAgentEnvironmentForInstruments(NSArray *identifiers,
                                                unsigned sampleIntervalUs,
                                                unsigned leakIntervalSeconds);
