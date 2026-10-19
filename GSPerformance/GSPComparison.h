/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* GSPComparison.h - comparing two traces (before/after a change).  */

#import <Foundation/Foundation.h>

@class GSPTrace;

@interface GSPComparisonRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) double before;
@property (nonatomic) double after;
@property (nonatomic, readonly) double delta;          /* after - before */
@property (nonatomic, readonly) double percentChange;  /* NAN when before == 0 */
@end

typedef NS_ENUM(NSInteger, GSPComparisonKind)
{
  GSPCompareCPU,          /* self CPU seconds per function */
  GSPCompareAllocations,  /* total bytes per allocation category */
  GSPCompareLeaks,        /* leaked bytes per category (latest check) */
  GSPCompareSignposts,    /* average interval duration per signpost name */
  GSPCompareFiles,        /* bytes read + written per file */
  GSPCompareNetwork       /* bytes sent + received per peer */
};

@interface GSPComparison : NSObject
/* Rows sorted by absolute delta, largest first.  Values are seconds or
   bytes depending on the kind. */
+ (NSArray *) compare: (GSPTrace *)before with: (GSPTrace *)after
                 kind: (GSPComparisonKind)kind;
/* Whole-trace totals for the kind (CPU seconds, bytes, ...). */
+ (GSPComparisonRow *) totalFor: (GSPTrace *)before with: (GSPTrace *)after
                           kind: (GSPComparisonKind)kind;
+ (BOOL) kindFromString: (NSString *)s kind: (GSPComparisonKind *)kind;
+ (BOOL) kindIsTime: (GSPComparisonKind)kind;
@end
