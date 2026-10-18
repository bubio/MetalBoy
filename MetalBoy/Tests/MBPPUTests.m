#import <XCTest/XCTest.h>
#import "MBPPU.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBPPUTests : XCTestCase
@end

@implementation MBPPUTests

- (void)testFramebufferDimensions {
    MBPPU *ppu = [[MBPPU alloc] init];
    XCTAssertEqual(ppu.framebuffer.length, (NSUInteger)(160 * 144 * 4));
    // 初期値は黒(0x00000000)
    uint32_t *pixels = (uint32_t *)ppu.framebuffer.mutableBytes;
    XCTAssertEqual(pixels[0], (uint32_t)0x00000000);
}

- (void)testEnabledDisplayGeneratesFrame {
    MBPPU *ppu = [[MBPPU alloc] init];
    // 白い四角いタイル($8000 にタイル 0 データ)
    uint8_t *vram = ppu.framebuffer ? NULL : NULL;
    (void)vram;
    // タイル 0 を「全ビット 1」(黒)にする: lo=hi=0xFF
    uint8_t tileData[16];
    memset(tileData, 0xFF, sizeof(tileData));
    for (NSInteger i = 0; i < 16; i++) {
        [ppu writeVRAM:tileData[i] address:i];
    }
    // BG マップ($9800)の最初の32エントリをタイル 0 に
    for (NSInteger i = 0; i < 32; i++) {
        [ppu writeVRAM:0x00 address:0x1800 + i];
    }
    ppu.lcdc = 0x91; // LCD on, BG on 等

    uint8_t ifRequest = 0;
    NSUInteger frameDots = 154 * 456;
    BOOL completed = [ppu tickDots:(uint32_t)frameDots ifRequest:&ifRequest];
    XCTAssertTrue(completed, "1 フレーム ドット数で VBlank へ到達");
    XCTAssertTrue(ifRequest & 0x01, "VBlank 割り込み要求");

    // LY は 0 に戻り、フレーム完成
    XCTAssertEqual(ppu.ly, 0);

    // BG タイル 0 = 全部 1？ 実際は 0xFF 入力タイルは index 3 (黒)
    // 初期バッファがクリアされていた場合、フレームバッファの最初の行に 黒(RGBA 0xFF000000)
    uint32_t *pixels = (uint32_t *)ppu.framebuffer.mutableBytes;
    XCTAssertEqual(pixels[0], (uint32_t)0xFF000000);
}

- (void)testDisabledDisplayKeepsBlank {
    MBPPU *ppu = [[MBPPU alloc] init];
    ppu.lcdc = 0x11; // LCD off(bit7=0)
    uint8_t ifRequest = 0;
    [ppu tickDots:154 * 456 ifRequest:&ifRequest];
    XCTAssertFalse(ifRequest & 0x01, "LCD OFF では VBlank 割り込みなし");
}

@end

NS_ASSUME_NONNULL_END
