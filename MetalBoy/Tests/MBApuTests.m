#import <XCTest/XCTest.h>
#import "MBApu.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBApuTests : XCTestCase
@end

@implementation MBApuTests

- (void)testSampleGenerationRate {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu tickDots:70224]; // 1 フレーム分
    // 出力レート 48kHz(research R-3)→ 1 フレーム(59.727fps)あたり約 800 サンプル×2(int16)
    NSUInteger pairs = apu.pendingSampleCount / 2;
    XCTAssertGreaterThan(pairs, (NSUInteger)700, "1 フレーム分のサンプル生成");
    XCTAssertLessThan(pairs, (NSUInteger)900);
}

- (void)testDisabledAPUProducesSilence {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0x00 address:0xFF26]; // NR52 電源 OFF
    [apu tickDots:70224];
    int16_t *samples = (int16_t *)apu.pendingSamples.bytes;
    NSUInteger count = apu.pendingSampleCount;
    for (NSUInteger i = 0; i < count; i++) {
        XCTAssertEqual(samples[i], 0, "APU 電源 OFF では無音");
    }
}

- (void)testChannelTriggerGeneratesAudio {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    // チャンネル 1: NR11 duty / NR12 volume / NR14 trigger
    [apu writeRegister:0xC0 address:0xFF11];   // duty=3
    [apu writeRegister:0xF0 address:0xFF12];   // volume=15
    [apu writeRegister:0x80 address:0xFF14];   // trigger
    [apu tickDots:70224];
    XCTAssertGreaterThan(apu.pendingSampleCount, (NSUInteger)100);
    // NR52 読み取りで電源ビット
    XCTAssertTrue(apu.nr52Value & 0x80);
}

#pragma mark - 精密化(2026-10-19): length / sweep / DAC-off の回帰

/// NR14 bit6(length enable)+trigger: length counter(64)分の FS step 後にチャンネルが停止する
- (void)testLengthCounterStopsChannel {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0xF0 address:0xFF12]; // volume 15, env なし
    [apu writeRegister:0xC0 address:0xFF14]; // bit7 trigger + bit6 length enable
    XCTAssertTrue(apu.nr52Value & 0x01, "trigger で ch1 が有効");
    // 64 個の length step(128Hz 間隔なので 64*2=128 FS step = 128*8192 dots)
    [apu tickDots:(uint32_t)(130 * 8192)];
    XCTAssertFalse(apu.nr52Value & 0x01, "length counter 尽きで ch1 停止");
}

/// スイープ: trigger 直後の計算で周波数オーバーフロー → 即座に ch1 停止(Pan Docs)
- (void)testSweepOverflowDisablesChannelOnTrigger {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0xF0 address:0xFF12];              // volume
    [apu writeRegister:0x01 address:0xFF10];              // sweep: period=0, negate=0, shift=1
    [apu writeRegister:0x07 address:0xFF13];              // freq bit10-8 部は NR14 で設定するのでこれは low=7
    [apu writeRegister:0x87 address:0xFF14];              // freq 0x707(1798), trigger
    [apu tickDots:1];
    XCTAssertFalse(apu.nr52Value & 0x01, "sweep 計算 1798+899>2047 → trigger 時点で ch1 停止");
}

/// NR12=0(DAC off)でチャンネル無効(DMG 挙動)
- (void)testDACOffDisablesChannel {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0x80 address:0xFF14]; // trigger(ch1 有効)
    XCTAssertTrue(apu.nr52Value & 0x01);
    [apu writeRegister:0x00 address:0xFF12]; // DAC off(0 純用)
    XCTAssertFalse(apu.nr52Value & 0x01, "DAC off で ch1 停止");
}
@end

NS_ASSUME_NONNULL_END
