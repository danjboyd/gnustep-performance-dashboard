/* SPDX-License-Identifier: GPL-3.0-or-later */
/* PDTraceWindowController.h - one trace document window: control bar,
   timeline, detail pane and inspector, plus live recording.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@interface PDTraceWindowController : NSWindowController

/* Open an existing trace bundle. */
- (instancetype) initWithTracePath: (NSString *)path error: (NSError **)error;
/* Show progress immediately; parsing and initial analyses run on a worker.
   Completion runs on the main thread. NO with nil error means window closed. */
- (instancetype) initForLoadingTraceAtPath: (NSString *)path
                              completion: (void (^)(BOOL, NSError *))completion;
@property (nonatomic, readonly) BOOL isLoading;
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
- (void) showGenerations: (id)sender;
- (void) compareRecording: (id)sender;
- (void) checkForLeaksNow: (id)sender;

@end
