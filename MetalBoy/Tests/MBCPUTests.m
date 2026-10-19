#import <XCTest/XCTest.h>
#import "MBCPU.h"
#import "MBTestBus.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBCPUTests : XCTestCase
@end

@implementation MBCPUTests

- (MBTestBus *)makeBus {
    return [[MBTestBus alloc] init];
}

- (void)testPowerOnRegisterValues {
    MBCPU *cpu = [[MBCPU alloc] init];
    XCTAssertEqual(cpu.registerA, 0x01);
    XCTAssertEqual(cpu.registerF, 0xB0);
    XCTAssertEqual(cpu.registerB, 0x00);
    XCTAssertEqual(cpu.registerC, 0x13);
    XCTAssertEqual(cpu.registerD, 0x00);
    XCTAssertEqual(cpu.registerE, 0xD8);
    XCTAssertEqual(cpu.registerH, 0x01);
    XCTAssertEqual(cpu.registerL, 0x4D);
    XCTAssertEqual(cpu.sp, 0xFFFE);
    XCTAssertEqual(cpu.pc, 0x0100);   // BIOS なし → $0100 開始(research R-5)
    XCTAssertFalse(cpu.ime);
}

- (void)testLoadImmediateBThenIncrement {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD B, $01 / INC B / INC B / DEC B
    [bus loadProgram:@[@0x06, @0x01, @0x04, @0x04, @0x05] atAddress:0x0100];
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerB, 0x01);
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerB, 0x02);
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerB, 0x03);
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerB, 0x02);
}

- (void)testAddSetFlags {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD B, $01 / LD A, $FF / ADD A, B(→ $00, Z=1 H=1 C=1。$FF+$01=$100 で繰り上がり)
    [bus loadProgram:@[@0x06, @0x01, @0x3E, @0xFF, @0x80] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x00);
    XCTAssertTrue(cpu.registerF & 0x80, "Z フラグ");
    XCTAssertTrue(cpu.registerF & 0x20, "H フラグ(下位 4bit の繰り上がり)");
    XCTAssertTrue(cpu.registerF & 0x10, "C フラグ(8bit の繰り上がり)");
}

- (void)testCarryAdd {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD A,$FF / ADD A,$01(→ $00, C=1 H=1)
    [bus loadProgram:@[@0x3E, @0xFF, @0xC6, @0x01] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x00);
    XCTAssertTrue(cpu.registerF & 0x10, "C フラグ");
}

- (void)testLoadThenStoreHL {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD HL,$C000 / LD (HL),$55 / LD A,(HL)
    [bus loadProgram:@[@0x21, @0x00, @0xC0, @0x36, @0x55, @0x7E] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertEqual([bus byteAt:0xC000], 0x55);
    XCTAssertEqual(cpu.registerA, 0x55);
}

- (void)testJPAndLoop {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD B,$02 / DEC B / JR NZ,-3(DEC に戻る) → B が 0 になるまで 2 回減算
    [bus loadProgram:@[@0x06, @0x02, @0x05, @0x20, @0xFD] atAddress:0x0100];
    [cpu stepWithBus:bus]; // LD B,2
    [cpu stepWithBus:bus]; // DEC B → 1・Z=0
    [cpu stepWithBus:bus]; // JR NZ → DEC へ分岐
    [cpu stepWithBus:bus]; // DEC B → 0・Z=1
    [cpu stepWithBus:bus]; // JR NZ 未成立 → 次命令へ
    XCTAssertEqual(cpu.registerB, 0x00);
    XCTAssertTrue(cpu.registerF & 0x80, "Z フラグ");
}

- (void)testXORBSetProcessing {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD B,$0F / XOR B
    [bus loadProgram:@[@0x06, @0x0F, @0xA8] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x0E);
}

#pragma mark - CB 命令(x=BIT/RES/SET の境界・実 ROM 不具合の回帰防止)

/// BIT y,r($40-$7F の x=1)は Z=bit が 0 時に立つ(CB 4F = BIT 1,A など)
- (void)testCBBitSetsFlagsCorrectly {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // BIT 1,A(=CB 0x4F)。A=0x20(bit1=0)→ Z=1 で JR NZ を抜ける
    // LD A,$20 / BIT 1,A / LD ($8000),A(結果確認用に到達可否を見る)
    [bus loadProgram:@[@0x3E, @0x20, @0xCB, @0x4F, @0xEA, @0x00, @0x80] atAddress:0x0100];
    [cpu stepWithBus:bus];           // LD A,$20
    [cpu stepWithBus:bus];           // BIT 1,A
    XCTAssertTrue(cpu.registerF & 0x80, "bit が 0 なので Z=1");
    XCTAssertTrue(cpu.registerF & 0x20, "BIT は H=1");
    XCTAssertTrue(cpu.registerF & 0x10, "BIT は C を変更しない(電源投入時 C=1 が保持)");
    XCTAssertEqual(cpu.registerA, 0x20, "BIT は A を変えない");
    [cpu stepWithBus:bus];           // LD ($8000),A(Z=1 → JR NZ 相当の分岐なしで到達)
    XCTAssertEqual([bus byteAt:0x8000], 0x20, "A=$20 が ($8000) に書込まれた");
}

/// A=0x21(bit1=1)のとき Z=0 になること(JR NZ が取れる側)
- (void)testCBBitClearsZWhenBitSet {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[@0x3E, @0x02, @0xCB, @0x4F] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertFalse(cpu.registerF & 0x80, "bit が 1 なので Z=0");
    XCTAssertEqual(cpu.registerA, 0x02);
}

/// x=0 の y=4-7(SLA/SRA/SWAP/SRL)も case 0 内で動く(CB 30 = SWAP B)
- (void)testCBSwapWorks {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD B,$3C / SWAP B → B=0xC3, Z=0
    [bus loadProgram:@[@0x06, @0x3C, @0xCB, @0x30] atAddress:0x0100];
    [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerB, 0xC3);
    XCTAssertFalse(cpu.registerF & 0x80);
}

/// RES/SET($80-$FF)も正しく動く
- (void)testCBResAndSet {
    // LD A,$FF / RES 1,A(CB 0x8F)→ A=0xFD
    {
        MBCPU *cpu = [[MBCPU alloc] init];
        MBTestBus *bus = [self makeBus];
        [bus loadProgram:@[@0x3E, @0xFF, @0xCB, @0x8F] atAddress:0x0100];
        [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
        XCTAssertEqual(cpu.registerA, 0xFD);
    }
    // SET 7,A(CB 0xFF)→ A=0x80
    {
        MBCPU *cpu = [[MBCPU alloc] init];
        MBTestBus *bus = [self makeBus];
        [bus loadProgram:@[@0x3E, @0x00, @0xCB, @0xFF] atAddress:0x0100];
        [cpu stepWithBus:bus]; [cpu stepWithBus:bus];
        XCTAssertEqual(cpu.registerA, 0x80);
    }
}

#pragma mark - HALT 唤醒(実 ROM 不具合の回帰防止)

/// IME=0 の HALT も (IF & IE) != 0 で解除される(Pan Docs 仕様)
- (void)testHaltWakesWithoutIME {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // HALTのみ
    [bus loadProgram:@[@0x76, @0x3E, @0x42, @0xEA, @0x00, @0x80] atAddress:0x0100];
    [cpu stepWithBus:bus];           // HALT実行(以後 halt 状態)
    bus.ieRegisterValue = 0x0C;      // IME=0 のまま
    bus.busIfRegister = 0x0C;        // 要求あり → halt 解除条件を満たす
    [cpu stepWithBus:bus];           // 解除ステップ
    [cpu stepWithBus:bus];           // 次の命令(LD A,$42)
    [cpu stepWithBus:bus];           // LD ($8000),A
    XCTAssertEqual(cpu.registerA, 0x42, "IME=0 でも HALT から抜けて後続命令が実行される");
}

/// (IF & IE) == 0 なら halt し続ける
- (void)testHaltStaysWhenNothingEnabled {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    [bus loadProgram:@[@0x76, @0x3E, @0x42, @0xEA, @0x00, @0x80] atAddress:0x0100];
    [cpu stepWithBus:bus];           // HALT
    bus.ieRegisterValue = 0x0C;
    bus.busIfRegister = 0x01;        // VBlank のみ要求・ほか未許可 → 継続
    NSUInteger ticks = 0;
    for (NSUInteger i = 0; i < 40; i++) ticks += [cpu stepWithBus:bus];
    XCTAssertGreaterThan(ticks, 0, "halt 状態では tick のみ繰り返す");
    XCTAssertEqual(cpu.registerA, 0x01, "電源投入初期値のまま(後続命令に進まない)");
}

// LDH (C),A / LDH A,(C): 実 ROM(Tetris 等)の OAM DMA スタブコピーが壊れていた回帰
- (void)testLDHCWriteAndRead {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD C,$B6 / LD A,$3E / LDH (C),A / LD A,$00 / LDH A,(C)
    [bus loadProgram:@[@0x0E, @0xB6, @0x3E, @0x3E, @0xE2, @0x3E, @0x00, @0xF2] atAddress:0x0100];
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    XCTAssertEqual([bus byteAt:0xFFB6], 0x3E, "LDH (C),A は $FF00+C へ書き込む");
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x3E, "LDH A,(C) は $FF00+C から読む");
}

/// 実機仕様: IME=1 でも (IF & IE) == 0 なら割込みは発生しない。
/// 実 Tetris で IE=08(Timer のみ)・LY ポーリング中に VBlank ISR が毎フレーム誤発火して
/// 停滞した問題の回帰(発火しないこと、ベクタに到達しないこと)。
- (void)testInterruptRequiresIEEntry {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // EI / NOP ×3
    [bus loadProgram:@[@0xFB, @0x00, @0x00, @0x00] atAddress:0x0100];
    bus.ieRegisterValue = 0x08;   // Timer のみ許可
    bus.busIfRegister = 0x01;     // VBlank だけ要求(未許可)
    // ベクタ $0040 に目印(LD A,$77)を仕込む(JP 先 $0043 に LD を置く: ベクタ 3 バイトとの衝突回避)
    [bus loadProgram:@[@0xC3, @0x43, @0x00] atAddress:0x0040];
    [bus loadProgram:@[@0x3E, @0x77] atAddress:0x0043];
    uint16_t spBefore = cpu.sp;
    [cpu stepWithBus:bus];  // EI
    [cpu stepWithBus:bus];  // NOP(imeDelayed が解消され IME=1)
    [cpu stepWithBus:bus];  // NOP
    [cpu stepWithBus:bus];  // NOP
    XCTAssertNotEqual(cpu.pc, 0x0042, "許可していない割込みのベクタに分岐しない");
    XCTAssertEqual(cpu.registerA, 0x01, "ベクタ先の LD A,$77 は実行されない");
    XCTAssertEqual(cpu.sp, spBefore, "割込み push が発生しない(SP 変化なし)");
    XCTAssertEqual(bus.busIfRegister & 0x01, 0x01, "未許可の要求 IF ビットはクリアされない");

    // 比較用: IE に VBlank を足すと同じ IF で発火する(ベクタ先で LD A,$77 が走る)
    bus.ieRegisterValue = 0x09;
    [cpu stepWithBus:bus];  // 割込み受け付け($0040 分岐)
    XCTAssertEqual(cpu.pc, 0x0040, "割込み受け付けでベクタへ分岐");
    [cpu stepWithBus:bus];  // $0040: JMP $0042
    XCTAssertEqual(cpu.pc, 0x0043, "ベクタの JMP が通る");
    [cpu stepWithBus:bus];  // $0042: LD A,$77
    XCTAssertEqual(cpu.pc, 0x0045, "LD A,$77 を実行後の pc");
    XCTAssertEqual(cpu.registerA, 0x77, "IE を許可すると同じ IF で割込みが発効する");
}

#pragma mark - DAA / INC (HL) / DEC (HL)(実 ROM デバッグで発見したバグの回帰)

/// 旧実装は DAA 減算後(N=1)に C をクリアしていた(SM83 では C は変化させない)。
/// blargg 01-special #6 / 11-op a,(hl) が Failed していた回帰。
- (void)testDAASubtractionPreservesCarry {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // SUB $7B(N=1, H=1, C=1) の後 DAA: 0x45-0x7B=0xCA → 0xCA-0x06-0x60 = 0x64
    [bus loadProgram:@[@0x3E, @0x45, @0xD6, @0x7B, @0x27, @0x18, @0xFE] atAddress:0x0100];
    for (NSInteger i = 0; i < 2; i++) { [cpu stepWithBus:bus]; } // LD A, SUB
    [cpu stepWithBus:bus]; // DAA
    XCTAssertEqual(cpu.registerA, 0x64, "減算後 DAA: 0x45-$7B=0xCA → 0x64");
    XCTAssertEqual((cpu.registerF & 0x10), 0x10, "N=1 の DAA では C は変化しない(旧実装はクリアしていた)");
    XCTAssertEqual((cpu.registerF & 0x20), 0x00, "DAA で H はクリア");
    XCTAssertEqual((cpu.registerF & 0x40), 0x40, "DAA で N は不変");

    // ADD A,$01 で A=0x9B(H: 下位ニブル 0xB>9、N=0、C=0)。DAA は +0x66 → 0x01・C=1
    [bus loadProgram:@[@0x3E, @0x9A, @0xC6, @0x01, @0x27, @0x18, @0xFE] atAddress:0x0200];
    [cpu setPC:0x0200];
    for (NSInteger i = 0; i < 2; i++) { [cpu stepWithBus:bus]; }
    [cpu stepWithBus:bus];
    XCTAssertEqual(cpu.registerA, 0x01);
    XCTAssertEqual((cpu.registerF & 0x10), 0x10, "加算後 DAA: A>0x99 で C を立てる");
    XCTAssertEqual((cpu.registerF & 0x20), 0x00, "DAA で H はクリア");
}

/// 旧実装は 0x34/0x35(INC/DEC (HL))を switch に欠落(NOP 相当)していた。
/// blargg 11-op a,(hl) が Failed(35 34)していた回帰。
- (void)testIncDecHLThroughMemory {
    MBCPU *cpu = [[MBCPU alloc] init];
    MBTestBus *bus = [self makeBus];
    // LD HL,$D400 / LD (HL),$5A / INC (HL) / JR -2
    [bus loadProgram:@[@0x21, @0x00, @0xD4, @0x36, @0x5A, @0x34, @0x18, @0xFE] atAddress:0x0100];
    for (NSInteger i = 0; i < 4; i++) { [cpu stepWithBus:bus]; }
    XCTAssertEqual([bus byteAt:0xD400], 0x5B, "INC (HL) がメモリ経由で +1(NOP なら 0x5A のまま)");
    XCTAssertEqual((cpu.registerF & 0x20), 0x00, "0x5A→0x5B: H 立ちなし");

    // LD HL,$D400 / LD (HL),$00 / DEC (HL) / JR -2: 0x00 → 0xFF、N=1・H(貸借)=1
    [bus loadProgram:@[@0x21, @0x00, @0xD4, @0x36, @0x00, @0x35, @0x18, @0xFE] atAddress:0x0300];
    [cpu setPC:0x0300];
    for (NSInteger i = 0; i < 4; i++) { [cpu stepWithBus:bus]; }
    XCTAssertEqual([bus byteAt:0xD400], 0xFF, "DEC (HL) がメモリ経由で -1");
    XCTAssertEqual((cpu.registerF & 0x40), 0x40, "DEC (HL): N");
    XCTAssertEqual((cpu.registerF & 0x20), 0x20, "DEC (HL): 貸借 H");
}
@end

NS_ASSUME_NONNULL_END
