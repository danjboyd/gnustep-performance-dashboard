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

- (void) invalidate;
- (NSString *) instrumentForTrack: (NSUInteger)track;
- (NSUInteger) trackForInstrument: (NSString *)identifier;

@end
