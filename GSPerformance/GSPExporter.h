/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* GSPExporter.h - exporting traces to other tools.

   json       summary and tables (stable schema, for scripts and tests)
   chrome     Chrome Trace Event JSON: opens in Perfetto UI and chrome://tracing
   speedscope speedscope.app sampled profiles, one per thread
   collapsed  folded stacks for flamegraph.pl / inferno
   csv        one table (samples, allocations, signposts, hangs, leaks) */

#import <Foundation/Foundation.h>

@class GSPTrace;
@class GSPProcess;

@interface GSPExporter : NSObject

+ (NSArray *) formats;
+ (NSArray *) csvTables;

+ (NSData *) exportTrace: (GSPTrace *)trace
                 process: (GSPProcess *)process
                  format: (NSString *)format
                   table: (NSString *)table      /* csv only */
                   error: (NSError **)error;

+ (NSDictionary *) summaryOfTrace: (GSPTrace *)trace process: (GSPProcess *)process;

@end
