/* Test-only adapter: use the actual GPUpdater feed parser/selection to produce
   the same asset fields passed by the UI to the real helper. No UI, key
   creation, payload trust decision or helper bypass lives in this adapter. */
#import <Foundation/Foundation.h>
#import "GPUpdater.h"

int
main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc != 3)
        return 2;
      NSError *error = nil;
      NSData *input = [NSData dataWithContentsOfFile:
        [NSString stringWithUTF8String: argv[1]]];
      NSDictionary *document = input == nil ? nil :
        [NSJSONSerialization JSONObjectWithData: input options: 0 error: &error];
      GPUpdaterConfiguration *configuration = document == nil ? nil :
        [GPUpdaterConfiguration configurationWithDictionary: document error: &error];
      if (configuration == nil)
        {
          fprintf(stderr, "fixture configuration: %s\n", [[error description] UTF8String]);
          return 3;
        }
      GPUpdater *updater = [[GPUpdater alloc] initWithConfiguration: configuration];
      GPUpdateCheckResult *result = [updater checkForUpdatesSynchronously: &error];
      if (result == nil || ![result hasUpdate])
        {
          fprintf(stderr, "fixture feed selection: %s\n", [[error description] UTF8String]);
          return 4;
        }
      GPUpdateAsset *selected = result.asset;
      /* The vendored MRC API names this getter "release", which ARC cannot
         call explicitly. KVC preserves that API without modifying it. */
      GPUpdateRelease *selectedRelease = [result valueForKey: @"release"];
      NSMutableDictionary *asset = [NSMutableDictionary dictionaryWithDictionary:
        @{ @"backend": selected.backend, @"name": selected.name,
           @"url": [selected.URL absoluteString], @"sha256": selected.SHA256,
           @"sizeBytes": @(selected.sizeBytes) }];
      if (selected.edSignature != nil)
        asset[@"edSignature"] = selected.edSignature;
      if (selected.updateInformation != nil)
        asset[@"updateInformation"] = selected.updateInformation;
      if (selected.zsyncURL != nil)
        asset[@"zsync"] = @{ @"url": [selected.zsyncURL absoluteString] };
      NSMutableDictionary *package = [NSMutableDictionary dictionaryWithDictionary:
        @{ @"version": configuration.currentVersion }];
      if (configuration.publicEDKey != nil)
        package[@"publicEDKey"] = configuration.publicEDKey;
      NSDictionary *plan = @{ @"package": package,
        @"release": @{ @"version": selectedRelease.version }, @"asset": asset,
        @"execution": document[@"execution"] };
      NSData *output = [NSJSONSerialization dataWithJSONObject: plan options: 0 error: &error];
      if (output == nil || ![output writeToFile:
            [NSString stringWithUTF8String: argv[2]] atomically: YES])
        return 5;
      printf("selected %s -> %s from local feed\n",
             [configuration.currentVersion UTF8String], [selectedRelease.version UTF8String]);
    }
  return 0;
}
