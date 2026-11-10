/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Private Linux launcher. NSTask exclusively owns collection of the child. */
#import <Foundation/Foundation.h>
#if defined(__linux__)
@interface GSPChildTask : NSObject
@property (nonatomic, readonly) int pid;
- (BOOL) launchHelper: (NSString *)helper executable: (NSString *)executable
           arguments: (NSArray *)arguments environment: (NSDictionary *)environment
    workingDirectory: (NSString *)directory descriptors: (const int *)descriptors
               error: (NSError **)error;
/* NO while running. A completed status is wait-compatible (exit << 8 or
   signal), not original kernel bits: NSTask does not expose the core flag. */
- (BOOL) pollStatus: (int *)status;
@end
#endif
