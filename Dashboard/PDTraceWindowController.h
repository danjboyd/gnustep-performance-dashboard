/* PDTraceWindowController.h - one trace document window: control bar,
   timeline, detail pane and inspector, plus live recording.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@interface PDTraceWindowController : NSWindowController

/* Open an existing trace bundle. */
- (instancetype) initWithTracePath: (NSString *)path error: (NSError **)error;
/* Record a new trace; the window shows it live. */
- (instancetype) initWithRecordingOptions: (GSPRecordingOptions *)options;

@property (nonatomic, readonly) NSString *tracePath;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) BOOL isTemporary;   /* unsaved recording */

- (void) startRecording: (id)sender;
- (void) stopRecording: (id)sender;
/* Stop a running recording and wait until its trace is complete.  */
- (void) finishRecording;
- (void) saveTraceAs: (id)sender;
- (void) exportTrace: (id)sender;
- (void) checkForLeaksNow: (id)sender;

@end
