/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <AppKit/AppKit.h>
#import "PDWelcomeModel.h"
@class PDAppController, TRBoxView;

@interface PDWelcomeWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
- (instancetype) initWithModel: (PDWelcomeModel *)model appController: (PDAppController *)controller;
- (void) showForMode: (PDWelcomeTargetMode)mode;
@property (nonatomic, readonly, strong) PDWelcomeModel *model;
@property (nonatomic, strong) TRBoxView *root;
@property (nonatomic, strong) TRBoxView *launchPane;
@property (nonatomic, strong) TRBoxView *attachPane;
@property (nonatomic, strong) TRBoxView *advancedPane;
@property (nonatomic, strong) TRBoxView *recentTargetsBox;
@property (nonatomic, strong) TRBoxView *recentTracesBox;
@property (nonatomic, strong) NSButton *launchMode;
@property (nonatomic, strong) NSButton *attachMode;
@property (nonatomic, strong) NSButton *cpuTemplate;
@property (nonatomic, strong) NSButton *allocationTemplate;
@property (nonatomic, strong) NSButton *leaksTemplate;
@property (nonatomic, strong) NSButton *hangsTemplate;
@property (nonatomic, strong) NSPopUpButton *moreTemplates;
@property (nonatomic, strong) NSScrollView *processScroll;
@property (nonatomic, strong) NSTextField *search;
@property (nonatomic, strong) NSPopUpButton *processFilter;
@property (nonatomic, strong) NSTextField *targetPath;
@property (nonatomic, strong) NSTextField *argumentsField;
@property (nonatomic, strong) NSTextField *environmentField;
@property (nonatomic, strong) NSTextField *directoryField;
@property (nonatomic, strong) NSTextField *durationField;
@property (nonatomic, strong) NSTextField *intervalField;
@property (nonatomic, strong) NSButton *showAdvanced;
@property (nonatomic, strong) NSButton *showAtLaunch;
@property (nonatomic, strong) NSTextField *summary;
@property (nonatomic, strong) NSButton *recordButton;
- (void) chooseLaunch: (id)sender;
- (void) chooseAttach: (id)sender;
- (void) chooseTemplate: (id)sender;
- (void) browseTarget: (id)sender;
- (void) filtersChanged: (id)sender;
- (void) fieldsChanged: (id)sender;
- (void) advancedChanged: (id)sender;
- (void) launchPreferenceChanged: (id)sender;
- (void) recentTarget: (id)sender;
- (void) recentTrace: (id)sender;
- (void) openTrace: (id)sender;
- (void) record: (id)sender;
- (void) cancel: (id)sender;
@end
