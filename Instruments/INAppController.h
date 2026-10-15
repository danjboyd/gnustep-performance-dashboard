/* INAppController.h - application delegate: menus, opening and recording
   traces, and installing the profiling helper.  */

#import <AppKit/AppKit.h>

@interface INAppController : NSObject <NSApplicationDelegate>
- (void) newRecording: (id)sender;
- (void) openTrace: (id)sender;
- (void) attachToProcess: (id)sender;
- (void) installHelper: (id)sender;
- (BOOL) openTraceAtPath: (NSString *)path;
@end
