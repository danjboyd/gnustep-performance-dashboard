/* Published gnustep-packager v0.1.10 test vector. Test key only.
 * Exercise the actual ObjC canonical-message function and the same vendored
 * Ed25519 verifier used by the helper. No product key or update operation. */
#import <Foundation/Foundation.h>
#import "GPUpdater.h"
#include "monocypher-ed25519.h"

int
main(int argc, char **argv)
{
  @autoreleasepool
    {
      if (argc != 2)
        return 2;
      NSData *message = GPUpdaterVersionSignatureMessage(@"com.example.MyGNUstepApp",
        @"1.2.3", @"stable", @"windows-x64",
        @"110499c3d4d34a94a1ea70ae7e7353d32708e043bc0ccee13ec9fbdb7a9d20b1");
      NSData *key = [[NSData alloc] initWithBase64EncodedString:
        @"Ll6BcPIwCiJWeu8fUhAG52rU62luKpZdTNsdJBfgxIs=" options: 0];
      NSData *signature = [[NSData alloc] initWithBase64EncodedString:
        @"OznddanxdN2fuBl7/hJlwqj+rFthQ+ItcaDcH25RKtjymCuDudMpn+23Ynocc+6d8im05LYjMhCWnaGyK39+BA=="
        options: 0];
      if ([message length] != 141 || [key length] != 32 || [signature length] != 64
          || crypto_ed25519_check([signature bytes], [key bytes],
                                  [message bytes], [message length]) != 0)
        return 1;
      return [message writeToFile: [NSString stringWithUTF8String: argv[1]]
                         atomically: YES] ? 0 : 3;
    }
}
