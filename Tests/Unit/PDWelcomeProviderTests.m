/* SPDX-License-Identifier: GPL-3.0-or-later */
#import <XCTest/XCTest.h>
#import "Dashboard/PDWelcomeProcessProvider.h"
#if defined(__linux__)
#include <unistd.h>
#endif

@interface WelcomeMapsReader : PDWelcomeProcessProvider
@property (nonatomic, strong) NSData *maps;
@property (nonatomic) NSUInteger reads;
@end
@implementation WelcomeMapsReader
- (NSData *) processMapsDataForPID: (int)pid { _reads++; return _maps; }
@end

@interface PDWelcomeProviderTests : XCTestCase
@end
@implementation PDWelcomeProviderTests
- (NSData *) statWithComm: (NSData *)comm
{
  NSMutableData *data = [[@"123 (" dataUsingEncoding: NSASCIIStringEncoding] mutableCopy];
  [data appendData: comm];
  /* State is field 3, followed by 18 fields before starttime (field 22). */
  [data appendData: [@") S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123456 0\n"
    dataUsingEncoding: NSASCIIStringEncoding]];
  return data;
}
- (void) testStatParserUsesLastClosingParenthesis
{
  NSData *data = [self statWithComm: [@"a) (b" dataUsingEncoding: NSUTF8StringEncoding]];
  XCTAssertEqualObjects([PDWelcomeProcessProvider identityFromStatData: data], @"123456");
}
- (void) testStatAndCommAcceptNonUTF8Name
{
  unsigned char bytes[] = { 'a', ')', ' ', '(', 255, 'b' };
  NSData *comm = [NSData dataWithBytes: bytes length: sizeof(bytes)];
  XCTAssertEqualObjects([PDWelcomeProcessProvider identityFromStatData: [self statWithComm: comm]], @"123456");
  XCTAssertTrue([[PDWelcomeProcessProvider processNameFromData: comm] length] > 0);
}
- (void) testMalformedOrMissingStatRefusesIdentity
{
  XCTAssertNil([PDWelcomeProcessProvider identityFromStatData: nil]);
  XCTAssertNil([PDWelcomeProcessProvider identityFromStatData: [@"1 (bad) S 1" dataUsingEncoding: NSASCIIStringEncoding]]);
  XCTAssertNil([PDWelcomeProcessProvider identityFromStatData: [@"not a stat" dataUsingEncoding: NSASCIIStringEncoding]]);
}
- (void) testRealUIDAndAttachPolicyUseActualUIDNotProcDirectoryOwner
{
  NSData *status = [@"Name:\tfixture\nUid:\t1000\t0\t0\t0\n" dataUsingEncoding: NSASCIIStringEncoding];
  NSNumber *uid = [PDWelcomeProcessProvider realUIDFromStatusData: status];
  XCTAssertEqualObjects(uid, @1000);
  XCTAssertNil([PDWelcomeProcessProvider attachProblemForRealUID: uid currentUID: 1000 helperAvailable: YES]);
  XCTAssertEqualObjects([PDWelcomeProcessProvider attachProblemForRealUID: uid currentUID: 999 helperAvailable: YES], @"Owned by another user");
  XCTAssertEqualObjects([PDWelcomeProcessProvider attachProblemForRealUID: uid currentUID: 1000 helperAvailable: NO], @"Profiling helper not installed");
  XCTAssertNil([PDWelcomeProcessProvider attachProblemForRealUID: nil currentUID: 1000 helperAvailable: YES]);
}
- (void) testRealProviderTemplateCapabilities
{
  PDWelcomeProcessProvider *provider = [PDWelcomeProcessProvider new];
  for (GSPTemplate *t in [GSPTemplate allTemplates])
    {
#if defined(__linux__)
      XCTAssertEqual([provider templateProblemForTemplate: t mode: PDWelcomeAttach] == nil,
        [t.name isEqual: @"System Time Profiler"]);
#endif
      XCTAssertEqual([provider templateProblemForTemplate: t mode: PDWelcomeLaunch] == nil,
        ![t.instrumentIdentifiers containsObject: GSPInstrumentSystemProfiler]);
    }
}
- (void) testMapsBytesAreCachedPerProcessIncarnation
{
#if defined(__linux__)
  WelcomeMapsReader *provider = [WelcomeMapsReader new];
  unsigned char prefix[] = { 255, 0, 254 };
  NSMutableData *maps = [NSMutableData dataWithBytes: prefix length: sizeof(prefix)];
  [maps appendData: [@"/lib/libgnustep-base.so" dataUsingEncoding: NSASCIIStringEncoding]];
  provider.maps = maps;
  XCTAssertEqual([provider GNUstepIdentityForPID: 41 identity: @"one"], PDGNUstepYes);
  provider.maps = nil;
  XCTAssertEqual([provider GNUstepIdentityForPID: 41 identity: @"one"], PDGNUstepYes);
  XCTAssertEqual(provider.reads, (NSUInteger)1);
  XCTAssertEqual([provider GNUstepIdentityForPID: 41 identity: @"two"], PDGNUstepUnknown);
  XCTAssertEqual(provider.reads, (NSUInteger)2);
#endif
}
@end
