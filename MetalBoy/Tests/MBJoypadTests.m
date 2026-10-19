#import <XCTest/XCTest.h>
#import "MBJoypad.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBJoypadTests : XCTestCase
@end

@implementation MBJoypadTests

- (void)testNothingPressedReadsAllOne {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    // bit5/4=1(両行とも駆動せず)なら低 4bit = 1
    joypad.registerLatch = 0x30;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0F, "未選択時は低 4bit = 1");
}

- (void)testDirectionRowReflectsPressed {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.registerLatch = 0x20; // bit4=0(駆動)・bit5=1
    joypad.pressedMask = MBJoypadButtonUp | MBJoypadButtonA;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0B, "bit2(Up) が押下で 0・残り 1");
}

- (void)testButtonRowReflectsPressed {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.registerLatch = 0x10; // bit4=1・bit5=0(駆動)
    joypad.pressedMask = MBJoypadButtonA | MBJoypadButtonStart;
    uint8_t low = joypad.registerValue & 0x0F;
    XCTAssertEqual(low, 0x06, "bit0(A) と bit3(Start) が押下 → それぞれ 0 に落ちる");
}

- (void)testUnpressedRemaining {
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.registerLatch = 0x20;
    joypad.pressedMask = 0;
    XCTAssertEqual(joypad.registerValue & 0x0F, 0x0F);
}

- (void)testWrittenSelectBitsAreReadBack {
    // 実機: bit5/4 は書込んだ値そのものが読み戻される(両行駆動(0,0)時は 0xC0|0x0F)
    MBJoypad *joypad = [[MBJoypad alloc] init];
    joypad.registerLatch = 0x00;
    joypad.pressedMask = 0;
    XCTAssertEqual(joypad.registerValue, 0xCF, "両行駆動+未押下は 0xCF を返す");
    XCTAssertEqual(joypad.registerValue & 0x30, 0x00, "bit5/4 は書込みラッチ");
}

@end

NS_ASSUME_NONNULL_END
