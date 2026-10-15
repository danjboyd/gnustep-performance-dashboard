/* INTimelineView.h - the track area: ruler, track headers, graphs,
   inspection-range selection, pan and zoom.  Track contents are drawn by a
   data source, so the view knows nothing about instruments.  */

#import <AppKit/AppKit.h>

@class INTimelineView;

@protocol INTimelineDataSource <NSObject>
- (NSUInteger) numberOfTracksInTimeline: (INTimelineView *)view;
- (NSString *) timeline: (INTimelineView *)view titleOfTrack: (NSUInteger)track;
- (NSString *) timeline: (INTimelineView *)view subtitleOfTrack: (NSUInteger)track;
- (CGFloat) timeline: (INTimelineView *)view heightOfTrack: (NSUInteger)track;
/* Draw track contents for [start, end] seconds into rect. */
- (void) timeline: (INTimelineView *)view drawTrack: (NSUInteger)track
           inRect: (NSRect)rect from: (double)start to: (double)end;
@optional
/* Text for a tooltip-like hover readout, or nil. */
- (NSString *) timeline: (INTimelineView *)view describeTrack: (NSUInteger)track
                 atTime: (double)seconds;
@end

@protocol INTimelineDelegate <NSObject>
@optional
- (void) timelineSelectionDidChange: (INTimelineView *)view;
- (void) timeline: (INTimelineView *)view didSelectTrack: (NSUInteger)track;
@end

@interface INTimelineView : NSView

@property (nonatomic, weak) id<INTimelineDataSource> dataSource;
@property (nonatomic, weak) id<INTimelineDelegate> delegate;

@property (nonatomic) double duration;          /* seconds of data */
@property (nonatomic) double visibleStart;      /* seconds */
@property (nonatomic) double visibleDuration;   /* seconds */
@property (nonatomic) NSUInteger selectedTrack;
@property (nonatomic) BOOL following;           /* keep the end visible (recording) */

/* Inspection range; hasSelection NO means "whole trace". */
@property (nonatomic, readonly) BOOL hasSelection;
@property (nonatomic, readonly) double selectionStart;
@property (nonatomic, readonly) double selectionEnd;
- (void) setSelectionFrom: (double)start to: (double)end;
- (void) clearSelection;

- (void) zoomIn: (id)sender;
- (void) zoomOut: (id)sender;
- (void) zoomToFit: (id)sender;
- (void) zoomToSelection: (id)sender;
- (void) reloadData;

+ (CGFloat) headerWidth;
+ (CGFloat) rulerHeight;
+ (NSString *) formatTime: (double)seconds;

@end
