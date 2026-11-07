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

/// 未使用 IO ビットの読み出し(Mooneye unused_hwio-GS): NR44 bit0-5・NR52 bit4-6 は常に 1、
/// NR13 相当の FF18(ch2 周波数下位)は書込み専用 → 0xFF、NR10 は sweep 格納値を反映
- (void)testUnusedIORegisterBits {
    MBApu *apu = [[MBApu alloc] initWithDefaults];

    // NR44(FF23): 未使用 bit0-5 = 1(電源 ON のまま)
    XCTAssertEqual([apu readRegister:0xFF23] & 0x3F, 0x3F, "NR44 未使用ビット読み 1");

    // NR52(FF26): 未使用 bit4-6 = 1
    XCTAssertEqual(apu.nr52Value & 0x70, 0x70, "NR52 未使用ビット読み 1");

    // 電源 OFF 中も bit4-6 = 1(チャンネル bit0-3 と bit7 は 0)
    [apu writeRegister:0x00 address:0xFF26];
    XCTAssertEqual(apu.nr52Value, 0x70, "APU 電源 OFF 中の NR52 = 0x70");
    [apu writeRegister:0x80 address:0xFF26];

    // FF18(NR23 相当, ch2 周波数下位)は書込み専用: 読み 0xFF(FF13/FF1D と同型)
    XCTAssertEqual([apu readRegister:0xFF18], 0xFF, "FF18 読みは 0xFF");

    // NR10(FF10): bit7=1 + sweep 格納値
    [apu writeRegister:0x2A address:0xFF10]; // period=2, dir=down(bit3=1), shift=2
    XCTAssertEqual([apu readRegister:0xFF10], 0xAA, "NR10 = 0x80|sweep格納値");
}

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

#pragma mark - ミキサー / ノイズ区間平均(BubiBoyLite apu.odin 準拠)
static int32_t MBPeakAbs(const int16_t *samples, NSUInteger frames, NSUInteger channel) {
    int32_t peak = 0;
    for (NSUInteger i = 0; i < frames; i++) {
        int32_t v = samples[i * 2 + channel];
        if (v < 0) v = -v;
        if (v > peak) peak = v;
    }
    return peak;
}

/// NR51 パンニング: ch1 を左のみに割り当てると右チャンネルは完全無音(実機のステレオ)
- (void)testNR51PansChannelToLeftOnly {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0xC0 address:0xFF11]; // duty=3
    [apu writeRegister:0xF0 address:0xFF12]; // volume=15(エンベロープ無し)
    [apu writeRegister:0x10 address:0xFF25]; // ch1 → 左のみ
    [apu writeRegister:0x80 address:0xFF14]; // trigger
    [apu tickDots:8192];

    NSUInteger frames = apu.pendingSampleCount / 2;
    XCTAssertGreaterThan(frames, (NSUInteger)0);
    const int16_t *samples = (const int16_t *)apu.pendingSamples.bytes;
    XCTAssertGreaterThan(MBPeakAbs(samples, frames, 0), 1000, "左は鳴る");
    XCTAssertEqual(MBPeakAbs(samples, frames, 1), 0, "右は無音");
}

/// NR50 マスター音量: 右音量 7(最大)と 0(1/8)で振幅が 8 倍異なる
- (void)testNR50MasterVolumeScalesOutput {
    int32_t peakFull = 0;
    int32_t peakLow = 0;
    for (NSInteger pass = 0; pass < 2; pass++) {
        MBApu *apu = [[MBApu alloc] initWithDefaults];
        [apu writeRegister:0xC0 address:0xFF11];
        [apu writeRegister:0xF0 address:0xFF12];
        [apu writeRegister:0x01 address:0xFF25];           // ch1 → 右のみ
        [apu writeRegister:(pass == 0 ? 0x77 : 0x00) address:0xFF24]; // NR50
        [apu writeRegister:0x80 address:0xFF14];
        [apu tickDots:8192];
        const int16_t *samples = (const int16_t *)apu.pendingSamples.bytes;
        int32_t peak = MBPeakAbs(samples, apu.pendingSampleCount / 2, 1);
        if (pass == 0) peakFull = peak; else peakLow = peak;
    }
    XCTAssertGreaterThan(peakFull, 1000);
    XCTAssertEqualWithAccuracy((double)peakFull / (double)peakLow, 8.0, 0.1,
                               "NR50 音量 7 vs 0 は 8 倍");
}

/// ch3 の 50% 出力は「4bit を右シフト」した値(2*shifted-15)。
/// wave RAM 全 0xFF(ニブル 15)なら 50% は 7 → 出力は -1/15 で負に振れる。
- (void)testWaveVolumeUsesHardwareShift {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    for (uint16_t addr = 0xFF30; addr <= 0xFF3F; addr++) {
        [apu writeRegister:0xFF address:addr];
    }
    [apu writeRegister:0x80 address:0xFF1A]; // DAC on
    [apu writeRegister:0x40 address:0xFF1C]; // 50%
    [apu writeRegister:0x04 address:0xFF25]; // ch3 → 右のみ(bit3=ch4 なので 0x04 が正)
    [apu writeRegister:0x80 address:0xFF1E]; // trigger(freq 0)
    [apu tickDots:8192];

    NSUInteger frames = apu.pendingSampleCount / 2;
    const int16_t *samples = (const int16_t *)apu.pendingSamples.bytes;
    XCTAssertGreaterThan(frames, (NSUInteger)0);
    for (NSUInteger i = 0; i < frames; i++) {
        XCTAssertLessThanOrEqual(samples[i * 2 + 1], 0, "50% の 15 は -1/15");
    }
    XCTAssertLessThan(MBPeakAbs(samples, frames, 1), 1000, "振幅は 1/15 相当");
}

/// ノイズは 1 サンプル区間の区間平均(ボックスフィルタ)で出力する。
/// 最高周波数(divisor=8, shift=0)を点サンプルすると RMS はフルスケール(≈8192)に
/// なるが、区間平均では大幅に小さくなる(エイリアシング抑制)。
- (void)testNoiseHighFrequencyIsBandLimited {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0xF0 address:0xFF21]; // 音量 15・エンベロープ無し
    [apu writeRegister:0x00 address:0xFF22]; // divisor=8, shift=0(最高周波数)
    [apu writeRegister:0x08 address:0xFF25]; // ch4 → 右のみ
    [apu writeRegister:0x80 address:0xFF23]; // trigger
    [apu tickDots:8192];

    NSUInteger frames = apu.pendingSampleCount / 2;
    const int16_t *samples = (const int16_t *)apu.pendingSamples.bytes;
    XCTAssertGreaterThan(frames, (NSUInteger)0);
    double sumSq = 0.0;
    for (NSUInteger i = 0; i < frames; i++) {
        double v = (double)samples[i * 2 + 1];
        sumSq += v * v;
    }
    double rms = sqrt(sumSq / (double)frames);
    XCTAssertGreaterThan(rms, 300.0, "ノイズが鳴っている");
    XCTAssertLessThan(rms, 6000.0, "区間平均で点サンプルより小さくなる");
}

/// ノイズ DAC off(NR42=0)でチャンネルが停止する
- (void)testNoiseDACOffDisablesChannel {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0xF0 address:0xFF21];
    [apu writeRegister:0x80 address:0xFF23];
    XCTAssertTrue(apu.nr52Value & 0x08, "ノイズ ch 有効");
    [apu writeRegister:0x00 address:0xFF21];
    XCTAssertFalse(apu.nr52Value & 0x08, "DAC off で停止");
}

/// 電源 off/on は length カウンタを保持するが length enable は 0 に戻る
/// (dmg_sound 01-registers test 5 / 08-len ctr during power / Pan Docs)。
- (void)testPowerOffPreservesLengthButClearsEnable {
    MBApu *apu = [[MBApu alloc] initWithDefaults];
    [apu writeRegister:0x3E address:0xFF16]; // NR21: length = 2
    [apu writeRegister:0x40 address:0xFF19]; // length enable(トリガーなし)
    XCTAssertEqual([apu readRegister:0xFF19] & 0x40, 0x40);

    [apu writeRegister:0x00 address:0xFF26]; // 電源 off
    [apu writeRegister:0x80 address:0xFF26]; // 電源 on
    XCTAssertEqual([apu readRegister:0xFF19] & 0x40, 0x00, "length enable は消える");

    // 保持された length(2)で trigger + length enable する(64 にリロードされない)
    [apu writeRegister:0xF0 address:0xFF17];
    [apu writeRegister:0xC0 address:0xFF19];
    XCTAssertTrue(apu.nr52Value & 0x02, "trigger で ch2 有効");
    [apu tickDots:(uint32_t)(6 * 8192)]; // length clock 3 回分
    XCTAssertFalse(apu.nr52Value & 0x02, "保持されていた length(2)で停止する");
}
@end

NS_ASSUME_NONNULL_END
