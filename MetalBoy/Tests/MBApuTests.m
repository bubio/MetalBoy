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

@end

NS_ASSUME_NONNULL_END
