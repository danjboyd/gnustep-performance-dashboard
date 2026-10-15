/* GSPRecorder.h - launching a target with the recording agent, or
   attaching to a running process through the privileged helper.  */

#import <Foundation/Foundation.h>

@class GSPRecorder;

@interface GSPRecordingOptions : NSObject
@property (nonatomic, copy) NSString *templateName;
@property (nonatomic, copy) NSArray *instrumentIdentifiers;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, copy) NSArray *arguments;
@property (nonatomic, copy) NSDictionary *environment;  /* added to the target's */
@property (nonatomic, copy) NSString *workingDirectory;
@property (nonatomic, copy) NSString *outputPath;       /* .gstrace bundle */
@property (nonatomic) NSTimeInterval timeLimit;         /* 0 = until exit/stop */
@property (nonatomic) unsigned sampleIntervalMicroseconds;
@property (nonatomic) unsigned leakIntervalSeconds;
@property (nonatomic) BOOL followChildren;
/* Write the target's stdout/stderr to <bundle>/output.txt instead of
   inheriting the recorder's (the app does this). */
@property (nonatomic) BOOL captureOutput;
@property (nonatomic) int attachPID;                    /* System Time Profiler */
@property (nonatomic) unsigned perfFrequency;           /* Hz, attach only */
@end

@protocol GSPRecorderDelegate <NSObject>
@optional
- (void) recorderDidStart: (GSPRecorder *)recorder;
- (void) recorder: (GSPRecorder *)recorder didFinishWithError: (NSError *)error;
@end

@interface GSPRecorder : NSObject

- (instancetype) initWithOptions: (GSPRecordingOptions *)options;

@property (nonatomic, readonly) GSPRecordingOptions *options;
@property (nonatomic, weak) id<GSPRecorderDelegate> delegate;
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) BOOL isRecording;
@property (nonatomic, readonly) NSDate *startDate;
@property (nonatomic, readonly) int exitStatus;    /* wait status, -1 unknown */
@property (nonatomic, readonly, copy) NSString *tracePath;

- (BOOL) start: (NSError **)error;
/* Ask the agent to finish, then end the target.  Returns at once;
   completion is reported to the delegate (and -waitUntilFinished). */
- (void) stop;
- (void) waitUntilFinished;
/* Ask for an immediate leak snapshot (Leaks "Check for Leaks Now"). */
- (void) requestLeakCheck;
- (void) addMark;

/* Locates libgsperf-agent.so (next to libGSPerformance, in the GNUstep
   library directories, or $GSP_AGENT_PATH). */
+ (NSString *) agentLibraryPath;
/* Path of the installed privileged helper, nil if not installed. */
+ (NSString *) installedHelperPath;
+ (NSString *) helperInstallLocation;   /* /usr/local/libexec/gstrace-helper */
/* The helper shipped next to gstrace / inside the app (not root-owned). */
+ (NSString *) bundledHelperPath;
/* kernel.perf_event_paranoid, or 3 if unreadable. */
+ (int) perfEventParanoid;
/* YES when attaching can run without pkexec (paranoid <= 2). */
+ (BOOL) canAttachWithoutPrivileges;
/* Explains why launching `path` with the agent cannot work (setuid and
   setcap binaries ignore LD_PRELOAD), or nil. */
+ (NSString *) preloadProblemForExecutable: (NSString *)path;
/* The environment a target gets: the recorder's own, minus anything an
   AppImage runtime injected, plus `additions`. */
+ (NSDictionary *) targetEnvironmentWithAdditions: (NSDictionary *)additions;
+ (NSString *) defaultTracePathForExecutable: (NSString *)path
                                    template: (NSString *)templateName;

@end

extern NSString * const GSPRecorderErrorDomain;
