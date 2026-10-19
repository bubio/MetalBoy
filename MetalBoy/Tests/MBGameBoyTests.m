#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import "MBGameBoy.h"
#import "MBCPU.h"

NS_ASSUME_NONNULL_BEGIN

/// MBGameBoy runFrame の時間配分(実 ROM で発見した 4 倍速バグの回帰)。
///
/// 問題: runFrame が dots 残量(70224)に対して CPU 命令の M-cycle 数を直接減算し、
/// 1 フレーム分の CPU 駆動が 70224 M-cycle(= 実機の 4 倍)回っていた。PPU/timer/APU
/// は tick ごとに 4 dots 進むため、ゲーム内部時間が 4 倍速で流れ、APU の波形/フレーム
/// シーケンサも 4 倍速(音が 2 オクターブ上・テンポ 4 倍)になっていた。
/// 回帰の観点:
///   1. DIV($FF04): 1 runFrame = 70224 dots → 64 フレームで 8bit DIV が正確に
///      70224*64/256 = 17556 回進む(mod 256 = 148)
///   2. APU: 1 runFrame で 48kHz 相当 ~803 ステレオペアだけ生成される
@interface MBGameBoyTests : XCTestCase
@end

@implementation MBGameBoyTests

/// 全領域が NOP($00) の ROM only カートリッジ。ヘッダの型/サイズのみ規定する。
/// PC は $0100 から NOP を踏み続けるため、1 命令 = 1 M-cycle 前提で推計できる。
- (MBGameBoy *)makeMachine {
    uint8_t rom[0x8000];
    memset(rom, 0x00, sizeof(rom));
    rom[0x0147] = 0x00; // カートリッジタイプ: ROM only
    rom[0x0149] = 0x00; // RAM サイズ
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:[NSData dataWithBytes:rom length:sizeof(rom)]
                                                       error:&error];
    XCTAssertNil(error, @"カートリッジ解析に失敗: %@", error);
    XCTAssertNotNil(cart);
    MBGameBoy *machine = [[MBGameBoy alloc] initWithCartridge:cart error:&error];
    XCTAssertNil(error, @"マシン生成に失敗: %@", error);
    XCTAssertNotNil(machine);
    return machine;
}

/// runFrame 1 回 = 70224 dots(17556 M-cycle)。DIV の進みでエミュレーション時間を検証する。
/// DIV 内部カウンタは 4 dots 単位で進み、上位 8bit が $FF04 に読める
/// (旧実装は 1 runFrame が 4 倍の 280896 dots 進み、DIV 進みも 4 倍になった)。
- (void)testRunFrameAdvancesExactlyOneFrameOfDots {
    MBGameBoy *machine = [self makeMachine];
    for (NSInteger i = 0; i < 64; i++) {
        [machine runFrame];
    }
    // 70224 dots × 64 frames = 4,494,336 dots → DIV 値は 4,494,336/256 = 17,556 進み
    XCTAssertEqual((uint32_t)[(id<MBCPUBus>)machine cpuReadAddress:0xFF04], (uint32_t)(17556 & 0xFF),
                   @"64 runFrame で DIV は 17556(mod 256=148)進むべき(4 倍速なら別の値になる)");
}

/// runFrame 1 回で APU が生成するサンプルは 48kHz 相当(~803.6 ペア)。
/// 旧実装は 4 倍量を生成し、オーディオバッファの 200ms 上限切り詰めで音割れしていた。
- (void)testRunFrameEmitsAboutOneFrameOfAudio {
    MBGameBoy *machine = [self makeMachine];
    [(id<MBCPUBus>)machine cpuWrite:0x80 address:0xFF26]; // APU 有効
    [machine runFrame];
    NSUInteger int16Count = machine.apu.pendingSampleCount;
    // 70224 dots / (4194304/48000) ≒ 803.4 emit × 2ch。誤差は tick 起点の丸め分を許容
    XCTAssertTrue(int16Count >= 1600 && int16Count <= 1616,
                  @"1 フレーム分の APU 出力は ~1606 int16(実測 %lu)", (unsigned long)int16Count);
}

/* 旧実装(4 倍速バグ): 1 runFrame が 70224 M-cycle 分 CPU を回していた。
 * dots 残量(70224)に対して命令の M-cycle 数を直接減算していたため、PPU/timer/APU が
 * 1 runFrame で 4 フレーム分進行し、ゲーム内部時間が 4 倍速になった。
 * 修正: kDotsPerFrame/4 = 17556 M-cycle で CPU を駆動。 */

@end

NS_ASSUME_NONNULL_END
