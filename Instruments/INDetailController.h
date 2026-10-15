/* INDetailController.h - the detail pane under the timeline: per-instrument
   modes (call tree, statistics, lists), call tree options, filtering, and
   feeding the inspector.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@class INTrackRenderer;
@class INInspectorView;
@class INDetailController;

@protocol INDetailControllerDelegate <NSObject>
/* Highlight a time range on the timeline (e.g. a selected hang). */
- (void) detailController: (INDetailController *)dc
       showTimeRangeStart: (GSPTime)start end: (GSPTime)end;
@end

@interface INDetailController : NSObject

- (instancetype) initWithFrame: (NSRect)frame inspector: (INInspectorView *)inspector;

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, weak) id<INDetailControllerDelegate> delegate;
@property (nonatomic, strong) INTrackRenderer *renderer;

/* What to show. */
- (void) showInstrument: (NSString *)identifier;
/* Inspection range (0, 0 = everything) or thread changes, or new data. */
- (void) setRangeStart: (GSPTime)start end: (GSPTime)end;
- (void) reload;
@property (nonatomic, readonly) NSString *instrument;

@end
