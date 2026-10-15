/* INRecordPanel.h - "Choose a profiling template" and target setup.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@interface INRecordPanel : NSObject
/* Runs modally; returns nil when cancelled. */
+ (GSPRecordingOptions *) runPanelWithTemplate: (NSString *)templateName;
@end

/* "Attach to Process": pick a running process of the current user. */
@interface INAttachPanel : NSObject
+ (GSPRecordingOptions *) runPanel;
@end
