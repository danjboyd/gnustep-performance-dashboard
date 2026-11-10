/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef PD_RECORDING_STATUS_H
#define PD_RECORDING_STATUS_H

#import <Foundation/Foundation.h>

/* Use persisted metadata so the notice also survives saving and reopening.
   An absent status belongs to an ongoing or older recording, not a wait error. */
static inline NSString *
PDRecordingStatusSummary(NSDictionary *info, NSString *summary)
{
  id status = [info objectForKey: @"ExitStatus"];
  if ([status isKindOfClass: [NSNumber class]] && [status intValue] < 0)
    return [@"Exit status unavailable · " stringByAppendingString: summary];
  return summary;
}

#endif
