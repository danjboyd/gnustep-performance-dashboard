/* SPDX-License-Identifier: GPL-3.0-or-later */
/* View-independent recording selection, history and process identity. */
#import <Foundation/Foundation.h>
#import <GSPerformance/GSPerformance.h>

typedef NS_ENUM(NSUInteger, PDWelcomeTargetMode)
{
  PDWelcomeLaunch,
  PDWelcomeAttach
};
typedef NS_ENUM(NSUInteger, PDGNUstepIdentity)
{
  PDGNUstepUnknown,
  PDGNUstepNo,
  PDGNUstepYes
};

@interface PDWelcomeProcess : NSObject
@property (nonatomic) int pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *executablePath;
/* A provider-specific process incarnation, not just a PID. */
@property (nonatomic, copy) NSString *identity;
@property (nonatomic) PDGNUstepIdentity GNUstepIdentity;
@property (nonatomic, copy) NSString *unavailableReason;
@end

@protocol PDWelcomeTargetProvider <NSObject>
- (NSArray *) runningProcesses;
- (NSString *) currentIdentityForPID: (int)pid;
- (NSString *) attachProblemForProcess: (PDWelcomeProcess *)process;
- (NSString *) executableForPath: (NSString *)path;
- (NSString *) launchProblemForExecutable: (NSString *)path;
- (NSString *) templateProblemForTemplate: (GSPTemplate *)recordingTemplate
                                  mode: (PDWelcomeTargetMode)mode;
@end

@interface PDWelcomeHistory : NSObject
/* DEFAULTS implements objectForKey:/setObject:forKey: (NSUserDefaults in the
   app, an isolated dictionary in tests). EXISTS makes pruning testable. */
- (instancetype) initWithDefaults: (id)defaults
                      fileExists: (BOOL (^)(NSString *))exists;
@property (nonatomic) BOOL showAtLaunch;
- (NSArray *) recentTargets;
- (NSArray *) recentTraces;
- (void) noteTarget: (GSPRecordingOptions *)options mode: (PDWelcomeTargetMode)mode;
- (void) noteTrace: (NSString *)path;
@end

@interface PDWelcomeModel : NSObject
- (instancetype) initWithProvider: (id<PDWelcomeTargetProvider>)provider
                         history: (PDWelcomeHistory *)history;
@property (nonatomic, readonly, strong) id<PDWelcomeTargetProvider> provider;
@property (nonatomic, readonly, strong) PDWelcomeHistory *history;
@property (nonatomic) PDWelcomeTargetMode mode;
@property (nonatomic, copy) NSString *templateName;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, copy) NSArray *arguments;
@property (nonatomic, copy) NSDictionary *environment;
@property (nonatomic, copy) NSString *workingDirectory;
@property (nonatomic) NSTimeInterval timeLimit;
@property (nonatomic) unsigned sampleIntervalMicroseconds;
@property (nonatomic) unsigned perfFrequency;
@property (nonatomic, strong) PDWelcomeProcess *selectedProcess;
@property (nonatomic, copy) NSSet *activeRecordingPIDs;
@property (nonatomic) BOOL GNUstepOnly;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, readonly, copy) NSArray *processes;
+ (NSArray *) commonTemplateNames;
+ (NSArray *) moreTemplateNames;
- (void) refreshProcesses;
- (NSArray *) filteredProcesses;
- (NSString *) templateDisabledReason: (NSString *)name;
- (NSString *) unavailableReasonForProcess: (PDWelcomeProcess *)process;
- (NSString *) recordDisabledReason;
- (NSString *) selectionSummary;
/* Revalidates the process incarnation immediately before constructing options;
   does not start a recorder or mutate history. */
- (GSPRecordingOptions *) recordingOptionsWithError: (NSError **)error;
@end
