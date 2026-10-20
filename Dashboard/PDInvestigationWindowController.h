/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <AppKit/AppKit.h>
#import <GSPerformance/GSPerformance.h>
@interface PDInvestigationWindowController : NSWindowController
- (instancetype) initWithTrace: (GSPTrace *)trace process: (GSPProcess *)process
                   generations: (BOOL)generations start: (GSPTime)start end: (GSPTime)end;
@end
