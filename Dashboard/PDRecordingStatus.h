/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PD_RECORDING_STATUS_H
#define PD_RECORDING_STATUS_H

#import <Foundation/Foundation.h>

/* Use persisted metadata so the notice also survives saving and reopening.
   Attach sessions do not reap a child, and Windows crash codes can be negative.
   Older Linux recordings have Host/Attached but no saved wait errno. */
static inline NSString *
PDRecordingStatusSummary(NSDictionary *info, NSString *summary)
{
  id status = [info objectForKey: @"ExitStatus"];
  id waitError = [info objectForKey: @"WaitPIDErrno"];
  id attached = [info objectForKey: @"Attached"];
  id host = [info objectForKey: @"Host"];
  BOOL savedWaitFailure = [waitError isKindOfClass: [NSNumber class]]
    && [waitError intValue] != 0;
  BOOL legacyLinuxFailure = [status isKindOfClass: [NSNumber class]]
    && [status intValue] == -1
    && [attached isKindOfClass: [NSNumber class]] && ![attached boolValue]
    && [host isKindOfClass: [NSString class]]
    && [host rangeOfString: @" Linux "].location != NSNotFound;
  if (savedWaitFailure || legacyLinuxFailure)
    return [@"Exit status unavailable · " stringByAppendingString: summary];
  return summary;
}

#endif
