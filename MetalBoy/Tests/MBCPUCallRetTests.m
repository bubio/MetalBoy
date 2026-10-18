#import <XCTest/XCTest.h>
#import "MBCPU.h"
#import "MBTestBus.h"

NS_ASSUME_NONNULL_BEGIN

/// CALL/RET と SP 動作のテスト(実 ROM(Tetris)で RST28→RET 破壊が起きた回帰の切り分け)
@interface MBCPUCallRetTests : XCTestCase
@end

@implementation MBCPUCallRetTests

- (MBTestBus *)makeBus { return [[MBTestBus alloc] init]; }

// LD SP,$CFFF / LD C,$B6 / LD A,$7B / LDH (C),A / CALL $0300 / LD A,$99 / RET($0300)
- (void)testCallRetRoundTrip {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[
        @0x31, @0xFF, @0xCF,          // $0100: LD SP,$CFFF
        @0x0E, @0xB6,                 // LD C,$B6
        @0x3E, @0x7B,                 // LD A,$7B
        @0xE2,                        // LDH (C),A
        @0xCD, @0x00, @0x03,          // CALL $0300
        @0x3E, @0x99                  // LD A,$99(RET 経由で到達すべき)
    ] atAddress:0x0100];
    [bus loadProgram:@[@0xC9] atAddress:0x0300]; // RET
    for (int i = 0; i < 10; i++) [cpu stepWithBus:bus];
    XCTAssertEqual([bus byteAt:0xFFB6], 0x7B, "LDH (C),A が $FFB6 に書けている");
    XCTAssertEqual(cpu.registerA, 0x99, "CALL→RET→後続命令に到達(RET が push 値を正しくポップ)");
    XCTAssertEqual(cpu.sp, 0xCFFF, "CALL+RET で SP が元に戻る");
}

// PUSH DE → POP HL で同じ値が受け渡される
- (void)testPushDePopHlExchange {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[
        @0x31, @0xFF, @0xCF,          // $0100: LD SP,$CFFF
        @0x11, @0x34, @0x12,          // LD DE,$1234
        @0xD5,                        // PUSH DE
        @0xE1,                        // POP HL
        @0x7C                         // LD A,H
    ] atAddress:0x0100];
    for (int i = 0; i < 5; i++) [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x12, "PUSH DE→POP HL:H=$12");
    XCTAssertEqual(cpu.registerL, 0x34);
    XCTAssertEqual(cpu.sp, 0xCFFF, "PUSH+POP で SP 復帰");
}

// CALL 先から RET するまでのスタック書込みバイト列が実機相当(CFFF から下降)
- (void)testCallWritesReturnAtSpMinusTwo {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[
        @0x31, @0xFF, @0xCF,          // $0100: LD SP,$CFFF
        @0xCD, @0x00, @0x03           // CALL $0300
    ] atAddress:0x0100];
    [bus loadProgram:@[@0xC9] atAddress:0x0300];
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    XCTAssertEqual([bus byteAt:0xCFFE], 0x01, "CALL が $CFFE に戻り先上位バイト");
    XCTAssertEqual([bus byteAt:0xCFFD], 0x06, "CALL が $CFFD に戻り先下位バイト");
    XCTAssertEqual(cpu.sp, 0xCFFD);
    for (int i = 0; i < 3; i++) [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.sp, 0xCFFF, "RET で SP 復帰");
}

// 0xE9 JP (HL)(実 Tetris で RST28 ディスパッチの最終命令が未実装→NOP 扱いで $0034 へ落ちる回帰)
- (void)testJPHl {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[
        @0x21, @0x10, @0x01,          // $0100: LD HL,$0110
        @0xE9                         // $0103: JP (HL)
    ] atAddress:0x0100];
    [bus loadProgram:@[@0x3E, @0x42, @0x76] atAddress:0x0110]; // LD A,$42 / HALT
    [cpu stepWithBus:bus]; // LD HL
    [cpu stepWithBus:bus]; // JP (HL)
    XCTAssertEqual(cpu.pc, 0x0110, "JP (HL) で HL へ分岐する");
    [cpu stepWithBus:bus]; // LD A,$42
    XCTAssertEqual(cpu.registerA, 0x42, "分岐後に HL 先の命令を実行");
}

// 0xE8 ADD SP,e8(実 Tetris でスタック操作が使用。Z=N=0, H/C は下位半端比較)
- (void)testAddSpSigned {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[
        @0x31, @0xFF, @0xCF,          // $0100: LD SP,$CFFF
        @0xE8, @0x01                  // $0103: ADD SP,1 → $D000
    ] atAddress:0x0100];
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.sp, 0xD000, "ADD SP,1 で SP が進む");
    XCTAssertEqual(cpu.registerF & 0x30, 0x30, "FF+1 は H と C が立つ");
    XCTAssertEqual(cpu.registerF & 0x80, 0, "Z=0");
    XCTAssertEqual(cpu.registerF & 0x40, 0, "N=0");
}
@end

NS_ASSUME_NONNULL_END
