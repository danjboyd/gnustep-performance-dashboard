/* SPDX-License-Identifier: GPL-3.0-or-later */
/* PDRecordPanel.h - "Choose a profiling template" and target setup.  */

#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>

@interface PDRecordPanel : NSObject
/* Runs modally; returns nil when cancelled. */
+ (GSPRecordingOptions *) runPanelWithTemplate: (NSString *)templateName;
/* The same, starting from the template, target, arguments, environment
   and directory in OPTIONS instead of the last ones used.  */
+ (GSPRecordingOptions *) runPanelWithOptions: (GSPRecordingOptions *)options;
@end

/* "Attach to Process": pick a running process of the current user. */
@interface PDAttachPanel : NSObject
+ (GSPRecordingOptions *) runPanel;
@end
