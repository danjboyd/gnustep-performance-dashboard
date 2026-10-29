/* SPDX-License-Identifier: GPL-3.0-or-later */
/* PDTrackRenderer.h - draws one timeline track per instrument and owns the
   analyses those tracks (and the detail views) share.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>
#import "PDTimelineView.h"

@interface PDTrackRenderer : NSObject <PDTimelineDataSource>

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
/* Prepare immutable loaded-trace analyses before publishing on the UI thread.
   The renderer must have no UI consumer while this runs. */
- (void) prepareAnalyses;
/* Transfers the default initial CPU tree once. Modified/ranged trees still
   use the ordinary builder, and invalidation discards the prepared tree. */
- (GSPCallTree *) takePreparedCPUCallTree;
- (NSString *) instrumentForTrack: (NSUInteger)track;
- (NSUInteger) trackForInstrument: (NSString *)identifier;
/* Per-thread CPU sub-tracks: the thread id, or 0 for instrument tracks. */
- (uint32_t) threadForTrack: (NSUInteger)track;

@end
