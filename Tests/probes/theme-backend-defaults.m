/* Local headless diagnostic: does not create NSApplication or a display. */
#import <Foundation/Foundation.h>
extern void GSThemeInstallBackendDefaults(void);
static id value(NSUserDefaults *defs, NSString *key)
{
  return [defs objectForKey:key] ?: (id)[NSNull null];
}
int main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc != 2) return 2;
      NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
      NSMutableDictionary *args = [NSMutableDictionary dictionaryWithDictionary:
        [defs volatileDomainForName:NSArgumentDomain] ?: @{}];
      [args setObject:[NSString stringWithUTF8String:argv[1]] forKey:@"GSTheme"];
      [defs removeVolatileDomainForName:NSArgumentDomain];
      [defs setVolatileDomain:args forName:NSArgumentDomain];
      NSDictionary *before = @{@"GSX11HandlesWindowDecorations":value(defs,@"GSX11HandlesWindowDecorations"),
        @"GSBackHandlesWindowDecorations":value(defs,@"GSBackHandlesWindowDecorations")};
      GSThemeInstallBackendDefaults();
      NSDictionary *result = @{@"before":before,
        @"afterGSBackHandlesWindowDecorations":value(defs,@"GSBackHandlesWindowDecorations"),
        @"themeDomain":[defs volatileDomainForName:@"GSThemeDomain"] ?: @{},
        @"searchList":[defs searchList]};
      NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
      fwrite([data bytes],1,[data length],stdout);putchar('\n');
    }
  return 0;
}
