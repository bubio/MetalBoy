#import <XCTest/XCTest.h>
#import "MBJoypad.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBJoypadTests : XCTestCase
@end

@implementation MBJoypadTests

- (void)testNothingPressedReadsAllOne {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    // どの行も選択していないときは 0xFF 相当の上位 + 未選択
    joypad.selectDirectionKeys = NO;
    joypad.selectButtonKeys = NO;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0F, "未選択時は低 4bit = 1");
}

- (void)testDirectionRowReflectsPressed {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.selectDirectionKeys = YES;
    joypad.selectButtonKeys = NO;
    joypad.pressedMask = MBJoypadButtonUp | MBJoypadButtonA;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0B, "bit2(Up) が押下で 0・残り 1");
}

- (void)testButtonRowReflectsPressed {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.selectDirectionKeys = NO;
    joypad.selectButtonKeys = YES;
    joypad.pressedMask = MBJoypadButtonA | MBJoypadButtonStart;
    uint8_t low = joypad.registerValue & 0x0F;
    XCTAssertEqual(low, 0x06, "bit0(A) と bit3(Start) が押下 → それぞれ 0 に落ちる");
}

- (void)testUnpressedRemaining {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.selectDirectionKeys = YES;
    joypad.pressedMask = 0;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0F);
}

@end

NS_ASSUME_NONNULL_END
