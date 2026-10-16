/* PDDetailController.h - the detail pane under the timeline: per-instrument
   modes (call tree, statistics, lists), call tree options, filtering, and
   feeding the inspector.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@class PDTrackRenderer;
@class PDInspectorView;
@class PDDetailController;

@protocol PDDetailControllerDelegate <NSObject>
/* Highlight a time range on the timeline (e.g. a selected hang). */
- (void) detailController: (PDDetailController *)dc
       showTimeRangeStart: (GSPTime)start end: (GSPTime)end;
@end

@interface PDDetailController : NSObject

- (instancetype) initWithFrame: (NSRect)frame inspector: (PDInspectorView *)inspector;

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, weak) id<PDDetailControllerDelegate> delegate;
@property (nonatomic, strong) PDTrackRenderer *renderer;

/* What to show. */
- (void) showInstrument: (NSString *)identifier;
/* Inspection range (0, 0 = everything) or thread changes, or new data. */
- (void) setRangeStart: (GSPTime)start end: (GSPTime)end;
- (void) reload;
/* Restrict CPU call trees to one thread (0 = all threads). */
- (void) showThread: (uint32_t)tid;
@property (nonatomic, readonly) NSString *instrument;

@end
