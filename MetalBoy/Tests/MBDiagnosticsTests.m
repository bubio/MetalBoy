#import <XCTest/XCTest.h>
#import "MBTestROMReport.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBDiagnosticsTests : XCTestCase
@end

@implementation MBDiagnosticsTests

/// 人間可読: シリアル出力そのまま + ログイベントは別経路(stderr)
- (void)testHumanReadableIsSerialText {
    MBTestROMReport *report = [[MBTestROMReport alloc] initWithROMPath:@"/r/a.gb" frames:900];
    [report appendSerialByte:'O'];
    [report appendSerialByte:'K'];
    XCTAssertEqualObjects(report.serialText, @"OK");
    XCTAssertFalse(report.passed);
}

/// 機械可読 JSON: rom / frames / passed / serial / events を持つ(憲法 V)
- (void)testJSONContainsResultAndEvents {
    MBTestROMReport *report = [[MBTestROMReport alloc] initWithROMPath:@"/r/a.gb" frames:900];
    for (const char *c = "Passed\n"; *c; c++) [report appendSerialByte:(uint8_t)*c];
    [report logEvent:MBLogEventUnimplementedBehavior message:@"未定義オペコード $D3"];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[report JSONData] options:0 error:nil];
    XCTAssertEqualObjects(json[@"rom"], @"/r/a.gb");
    XCTAssertEqualObjects(json[@"frames"], @900);
    XCTAssertEqualObjects(json[@"passed"], @YES);
    XCTAssertEqualObjects(json[@"serial"], @"Passed\n");
    NSArray *events = json[@"events"];
    XCTAssertEqual(events.count, 1u);
    XCTAssertEqualObjects(events[0][@"type"], @"unimplemented");
    XCTAssertEqualObjects(events[0][@"message"], @"未定義オペコード $D3");
}

@end

NS_ASSUME_NONNULL_END
