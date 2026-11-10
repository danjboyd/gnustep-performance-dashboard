/* Private qualification adapter for the actual updater HTTPS feed path.
 * URLs, CA details and raw errors belong in private test evidence, not docs.
 * No update prepare/apply operation, key access or verification bypass. */
#import <Foundation/Foundation.h>
#import "GPUpdater.h"
#include <stdio.h>

int
main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc != 4)
        return 2;
      FILE *maps = fopen("/proc/self/maps", "r");
      FILE *saved = fopen(argv[3], "wx");
      if (maps == NULL || saved == NULL)
        return 3;
      char block[4096];
      size_t count;
      while ((count = fread(block, 1, sizeof(block), maps)) != 0)
        if (fwrite(block, 1, count, saved) != count)
          return 3;
      if (ferror(maps) || fclose(maps) != 0 || fclose(saved) != 0)
        return 3;
      NSError *error = nil;
      NSData *input = [NSData dataWithContentsOfFile:
        [NSString stringWithUTF8String: argv[1]]];
      NSDictionary *document = input ? [NSJSONSerialization
        JSONObjectWithData: input options: 0 error: &error] : nil;
      NSString *feed = [[document objectForKey: @"updates"] objectForKey: @"feedUrl"];
      if (![[[NSURL URLWithString: feed] scheme] isEqualToString: @"https"])
        return 2;
      GPUpdaterConfiguration *configuration = [GPUpdaterConfiguration
        configurationWithDictionary: document error: &error];
      GPUpdateCheckResult *result = configuration ? [[[GPUpdater alloc]
        initWithConfiguration: configuration] checkForUpdatesSynchronously: &error] : nil;
      NSMutableDictionary *receipt = [NSMutableDictionary dictionary];
      NSString *verify = [[[NSProcessInfo processInfo] environment] objectForKey: @"GS_TLS_VERIFY_S"];
      [receipt setObject: verify ?: @"<unset>" forKey: @"serverVerificationEnvironment"];
      id configured = [[NSUserDefaults standardUserDefaults] objectForKey: @"GSTLSVerifyServer"];
      if (configured) [receipt setObject: [configured description] forKey: @"serverVerificationDefault"];
      [receipt setObject: [NSNumber numberWithBool: result != nil] forKey: @"feedReadSucceeded"];
      [receipt setObject: [NSNumber numberWithBool: [result hasUpdate]] forKey: @"hasUpdate"];
      if (error)
        {
          [receipt setObject: [error domain] forKey: @"errorDomain"];
          [receipt setObject: [NSNumber numberWithInteger: [error code]] forKey: @"errorCode"];
          [receipt setObject: [error description] forKey: @"privateErrorDetail"];
        }
      NSData *output = [NSJSONSerialization dataWithJSONObject: receipt options: 0 error: NULL];
      if (![output writeToFile: [NSString stringWithUTF8String: argv[2]] atomically: YES])
        return 3;
      return result ? 0 : 1;
    }
}
