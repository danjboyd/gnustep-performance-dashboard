/* INTrackRenderer.h - draws one timeline track per instrument and owns the
   analyses those tracks (and the detail views) share.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>
#import "INTimelineView.h"

@interface INTrackRenderer : NSObject <INTimelineDataSource>

- (instancetype) initWithTrace: (GSPTrace *)trace;

@property (nonatomic, strong) GSPTrace *trace;
@property (nonatomic, strong) GSPProcess *process;
@property (nonatomic, readonly) NSArray *trackIdentifiers;   /* instrument ids */

/* Shared analyses, rebuilt lazily after -invalidate. */
@property (nonatomic, readonly) GSPHangAnalysis *hangAnalysis;
@property (nonatomic, readonly) GSPAllocationAnalysis *allocationAnalysis;
@property (nonatomic, readonly) GSPLeakAnalysis *leakAnalysis;
@property (nonatomic, readonly) GSPIOAnalysis *ioAnalysis;

- (void) invalidate;
- (NSString *) instrumentForTrack: (NSUInteger)track;
- (NSUInteger) trackForInstrument: (NSString *)identifier;
/* Per-thread CPU sub-tracks: the thread id, or 0 for instrument tracks. */
- (uint32_t) threadForTrack: (NSUInteger)track;

@end
