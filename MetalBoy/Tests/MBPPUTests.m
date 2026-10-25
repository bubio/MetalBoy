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

// OAM ロック: mode 2/3 中の読み 0xFF・mode3 中の CPU 書込み捨て(実機。
// lcdon_timing-GS OAM グループ: mode2 中も FF / intr_2_oam_ok_timing: mode0 開始で解放)
// モード観測は公開 API statValue($FF41 読み値)の bit1-0
- (void)testOAMLockedDuringMode3 {    MBPPU *ppu = [[MBPPU alloc] init];
    ppu.lcdc = 0x91; // LCD on

    uint8_t ifRequest = 0;
    BOOL checkedMode2 = NO;   // mode2 = $FF41&3 == 2
    BOOL checkedMode3 = NO;   // mode3 = $FF41&3 == 3
    BOOL checkedMode0 = NO;   // mode0 = $FF41&3 == 0
    for (NSInteger dot = 0; dot < 456 * 2 && !(checkedMode2 && checkedMode3 && checkedMode0); dot++) {
        switch (ppu.statValue & 0x03) {
            case 0x00: // HBlank: アクセス可
                if (!checkedMode0) {
                    checkedMode0 = YES;
                    [ppu writeOAM:0xCD address:4];
                    XCTAssertEqual([ppu readOAM:4], 0xCD, "mode0 中は OAM 書込み有効");
                }
                break;
            case 0x02: // OAMScan: 読みロック(実機。lcdon_timing-GS OAM グループ)
                if (!checkedMode2) {
                    checkedMode2 = YES;
                    XCTAssertEqual([ppu readOAM:2], 0xFF, "mode2 中の OAM 読みは 0xFF");
                    // mode2 前 76 dot の OAM 書込みは捨てられる(実機。
                    // lcdon_write_timing-GS OAM 群 19 サンプル実測)
                    [ppu writeOAM:0xAB address:2];
                }
                break;
            case 0x03: // Draw: ロック
                if (!checkedMode3) {
                    checkedMode3 = YES;
                    XCTAssertEqual([ppu readOAM:0], 0xFF, "mode3 中の OAM 読みは 0xFF");
                    [ppu writeOAM:0x77 address:3];
                    XCTAssertEqual([ppu readOAM:3], 0xFF, "mode3 中の OAM 書込みは捨てられる");
                }
                break;
            default: // mode1 = VBlank
                break;
        }
        [ppu tickDots:1 ifRequest:&ifRequest];
    }
    XCTAssertTrue(checkedMode2 && checkedMode3 && checkedMode0, "3 モードすべて観測");

    // 値の確定確認は mode0(HBlank)中に(HBlank を待つ)
    while ((ppu.statValue & 0x03) != 0x00) [ppu tickDots:1 ifRequest:&ifRequest];
    XCTAssertEqual([ppu readOAM:2], 0x00, "mode2 前 76 dot に書んだ値は破棄されている(lcdon_write_timing-GS)");
    XCTAssertEqual([ppu readOAM:3], 0x00, "mode3 中に書んだ値は破棄されている");
}

/// LY=144 の VBlank 開始 dot で STAT bit5(OAM form2)割込みが VBlank IF(bit0)と
/// 同時に立つ(実機。Mooneye vblank_stat_intr-GS)
- (void)testSTATMode2InterruptAtVBlankStart {
    MBPPU *ppu = [[MBPPU alloc] init];
    ppu.lcdc = 0x91; // LCD on
    [ppu writeSTAT:0x20]; // bit5(OAM mode2 割込み)のみ

    uint8_t ifRequest = 0;
    // LY 143 に到達するまで進める(LY 増分は HBlank 終端の 4 dot 前 →
    // LY=143 の初観測は line 143 開始の 4 dot 手前)
    while (ppu.ly < 143) {
        [ppu tickDots:1 ifRequest:&ifRequest];
    }
    // 残り HBlank 4 dot + line 143 の 456 dots。遷移 dot 直前の状態に整えてから 1 dot 進める
    for (NSUInteger i = 0; i < 459; i++) [ppu tickDots:1 ifRequest:&ifRequest];
    ifRequest = 0;
    [ppu tickDots:1 ifRequest:&ifRequest];

    XCTAssertEqual(ppu.ly, 144);
    XCTAssertEqual(ifRequest & 0x01, 0x01, "VBlank IF bit0");
    XCTAssertEqual(ifRequest & 0x02, 0x02, "STAT m2 IF bit1 も同一 dot で立つ");
}

/// mode 3 長の SCX 依存伸縮(実機。Mooneye hblank_ly_scx_timing-GS):
/// SCX&7 = 0 → 172 / 1-4 → 176 / 5-7 → 180 dots(mode0 は 204 から対応分減る)
- (void)testMode3LengthSCXExtension {
    MBPPU *ppu = [[MBPPU alloc] init];
    ppu.lcdc = 0x91;
    [ppu writeSTAT:0x00];

    static const uint32_t expected[8] = {172, 176, 176, 176, 176, 180, 180, 180};
    for (NSUInteger n = 0; n <= 7; n++) {
        ppu.scx = (uint8_t)n;
        // mode2 開始を捕捉(ライン開始)
        uint8_t ifRequest = 0;
        while ((ppu.statValue & 0x03) != 0x02) [ppu tickDots:1 ifRequest:&ifRequest];
        // mode3 開始まで
        while ((ppu.statValue & 0x03) != 0x03) [ppu tickDots:1 ifRequest:&ifRequest];
        // mode3 長を dots 計数
        uint32_t len = 0;
        do {
            [ppu tickDots:1 ifRequest:&ifRequest];
            len++;
        } while ((ppu.statValue & 0x03) == 0x03 && len < 250);
        XCTAssertEqual(len, expected[n], "SCX&7=%lu", n);
    }
}

/// OAM 書込み禁止窓(実機。Mooneye lcdon_write_timing-GS OAM 群 19 サンプル実測):
/// line0(LCD ON 直後の死相)= [dsd+80, dsd+252)(読出し窓と同一)。
/// dsd = 直近 anchor(LCD ON dot / LY 増分 dot)からの dots。
- (void)testOAMWriteLockedAtLcdOn {
    MBPPU *ppu = [[MBPPU alloc] init];
    uint8_t ifRequest = 0;
    ppu.lcdc = 0x11; // LCD OFF
    for (int i = 0; i < 60; i++) [ppu tickDots:4 ifRequest:&ifRequest];
    ppu.lcdc = 0x81; // LCD ON → 死相
    [ppu writeOAM:0x12 address:0];

    // dsd 79(死相内): 書込み可・読出し可
    for (int i = 0; i < 79; i++) [ppu tickDots:1 ifRequest:&ifRequest];
    [ppu writeOAM:0xCD address:0];
    XCTAssertEqual([ppu readOAM:0], 0xCD, "死相内(dsd<80)は OAM 書込み可");

    // dsd 159(可視 mode3 相当): 書込み捨て(読出し禁止なので後段の読出しで検証)
    for (int i = 0; i < 80; i++) [ppu tickDots:1 ifRequest:&ifRequest];
    [ppu writeOAM:0xAB address:0];

    // dsd 252(mode0 開始): 解放。読出して 0xAB が入っていないことを確認
    for (int i = 0; i < 93; i++) [ppu tickDots:1 ifRequest:&ifRequest];
    XCTAssertEqual([ppu readOAM:0], 0xCD, "line0 mode3 中の OAM 書込みは捨て");

    // dsd 252+: 書込み・読出しとも可
    [ppu writeOAM:0x77 address:1];
    XCTAssertEqual([ppu readOAM:1], 0x77, "line0 mode0 開始(dsd>=252)で書込み可");
}

/// OAM 書込み禁止窓/通常 line(実機。lcdon_write_timing-GS OAM 群):
/// [dsd+4, dsd+80)(mode2 前 76 dot)と [dsd+84, dsd+256)(mode3)は捨て。
/// mode2 最後の 4 dot([dsd+80, dsd+84))は書込み可(読出しとの差)。
- (void)testOAMWriteLockedDuringMode2NormalLine {
    MBPPU *ppu = [[MBPPU alloc] init];
    uint8_t ifRequest = 0;
    ppu.lcdc = 0x91;
    // line1 の mode2(subsequent line)まで進める(dsd≈5)
    while (ppu.ly != 1 || (ppu.statValue & 0x03) != 0x02) [ppu tickDots:1 ifRequest:&ifRequest];
    // mode2 前 76 dot(raster 0-75): 書込み捨て(読出し禁止なので後段の読出しで検証)
    [ppu writeOAM:0xAB address:2];

    // mode2 最後の 4 dot(dsd 80-83): 書込み可
    for (int i = 0; i < 76; i++) [ppu tickDots:1 ifRequest:&ifRequest];
    [ppu writeOAM:0xCD address:2];
    XCTAssertEqual(ppu.statValue & 0x03, 0x02, "書込み可窓はまだ mode2 中");

    // mode3(dsd+84 以降): 書込み捨て
    while ((ppu.statValue & 0x03) != 0x03) [ppu tickDots:1 ifRequest:&ifRequest];
    [ppu writeOAM:0x88 address:2];

    // mode0(書込み・読出しとも可)で照合: 0xAB/0x88 は捨て、0xCD のみ有効
    while ((ppu.statValue & 0x03) != 0x00) [ppu tickDots:1 ifRequest:&ifRequest];
    XCTAssertEqual([ppu readOAM:2], 0xCD, "mode2 前 76 dot と mode3 の OAM 書込みは捨て、mode2 最後 4 dot は有効");

    [ppu writeOAM:0x5A address:2];
    XCTAssertEqual([ppu readOAM:2], 0x5A, "mode0 中は OAM 書込み可");
}

/// VRAM 書込み禁止窓(実機。lcdon_write_timing-GS VRAM 群 19 サンプル実測):
/// line0 = [dsd+80, dsd+252)(読出しと同一)/ 通常 line = [dsd+84, dsd+256)(mode3 のみ。
/// mode2 窓は書込み可 = 読出し([dsd+80, dsd+256))より START 側 4 dot 緩い。
- (void)testVRAMWriteLockedDuringMode3 {
    MBPPU *ppu = [[MBPPU alloc] init];
    uint8_t ifRequest = 0;
    ppu.lcdc = 0x91;
    while (ppu.ly != 1 || (ppu.statValue & 0x03) != 0x02) [ppu tickDots:1 ifRequest:&ifRequest];
    // mode2 窓(dsd<84 = raster<80): VRAM 書込み可・読出し可(OAM との違い)
    [ppu writeVRAM:0x11 address:0];
    XCTAssertEqual([ppu readVRAM:0], 0x11, "通常 line mode2 窓は VRAM 書込み可");

    // mode3(dsd>=84): 書込み捨て
    while ((ppu.statValue & 0x03) != 0x03) [ppu tickDots:1 ifRequest:&ifRequest];
    [ppu writeVRAM:0x22 address:0];

    // mode0: 読出し可に戻って照合
    while ((ppu.statValue & 0x03) != 0x00) [ppu tickDots:1 ifRequest:&ifRequest];
    XCTAssertEqual([ppu readVRAM:0], 0x11, "通常 line mode3 中の VRAM 書込みは捨て");

    [ppu writeVRAM:0x33 address:0];
    XCTAssertEqual([ppu readVRAM:0], 0x33, "mode0 開始で VRAM 書込み可");
}

/// LCD ON 直後の死相(実機。Mooneye lcdon_timing-GS 実測からの定数):
/// 死相 80 dots(LY=0 固定・モード読出し 0・OAM/VRAM アクセス可)→ mode3(172)
/// → mode0 204(LY 増分 = mode0 終端の 4 dot 前=452)。line1 以降は通常 456-dot ライン。
- (void)testLCDOnBootPhase {
    MBPPU *ppu = [[MBPPU alloc] init];
    uint8_t ifRequest = 0;

    ppu.lcdc = 0x11; // LCD OFF(0x81 相当を bit7 落とした状態)
    for (int i = 0; i < 60; i++) [ppu tickDots:4 ifRequest:&ifRequest];

    ppu.lcdc = 0x81; // LCD ON 遷移 → 死相 80 dots 設定
    // 死相中(60/240 dots): STAT = bit7+coincidence(bit2: LY=0==LYC=0)、モード 0
    for (int i = 0; i < 15; i++) [ppu tickDots:4 ifRequest:&ifRequest];
    XCTAssertEqual(ppu.ly, 0, "死相中 LY=0");
    XCTAssertEqual(ppu.statValue, 0x84, "死相: モード読出し 0 + coincidence");
    XCTAssertEqual([ppu readOAM:0], 0x00, "死相中 OAM 読み出し可");

    // 死相終端後: mode3
    for (int i = 0; i < 22; i++) [ppu tickDots:4 ifRequest:&ifRequest];
    XCTAssertEqual(ppu.statValue & 0x03, 0x03, "死相終端直後に mode3");

    // LY 増分 = 452-460 dots(1-dot 計数で実測範囲を確認)
    ppu = [[MBPPU alloc] init];
    ppu.lcdc = 0x11;
    for (int i = 0; i < 60; i++) [ppu tickDots:4 ifRequest:&ifRequest];
    ppu.lcdc = 0x81;
    uint32_t flipDots = 0;
    while (ppu.ly == 0 && flipDots < 600) {
        [ppu tickDots:1 ifRequest:&ifRequest];
        flipDots++;
    }
    XCTAssertGreaterThanOrEqual(flipDots, 440, "LY 増分は死相 80 + mode3 172 + mode0 204 ≈ 452");
    XCTAssertLessThanOrEqual(flipDots, 468, "LY 増分は死相 80 + mode3 172 + mode0 204 ≈ 452");
}

@end

NS_ASSUME_NONNULL_END
