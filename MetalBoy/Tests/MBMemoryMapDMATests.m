#import <XCTest/XCTest.h>
#import "MBMemoryMap.h"
#import "MBPPU.h"

NS_ASSUME_NONNULL_BEGIN

/// DMA 回帰テスト用の極小 PPU スタブ(OAM 0xA0 バイトを保持するだけ)
@interface MBFakeOAM : NSObject
@property (nonatomic, readonly) uint8_t *oamBytes;
@end
@implementation MBFakeOAM {
    uint8_t _oam[0xA0];
}
- (uint8_t *)oamBytes { return _oam; }
- (uint8_t)readOAM:(uint16_t)address { return _oam[address & 0xFF]; }
- (void)writeOAM:(uint8_t)value address:(uint16_t)address {
    _oam[address & 0xFF] = value;
}
- (void)dmaWriteOAM:(uint8_t)value address:(uint16_t)address {
    _oam[address & 0xFF] = value;
}
@end

/// OAM DMA の精密タイミング回帰(Mooneye oam_dma_start / oam_dma_restart /
/// oam_dma_timing / push_timing で発見した仕様を単体で固定する)。
///
/// 確立したモデル:
///   - M_w = $FF46 書込み M-cycle。delay=2 をセット
///   - M_{w+1} 終端 tick: delay 1→0、active 化のみ(この tick では転送しない)
///   - 準備 M(=隔離 1 M)を挟み、byte k は M_{w+2+k} の終端 tick で OAM に載る
///   - 読出し FF ウィンドウ = M_{w+2}..M_{w+161}(byte159 の書込み M そのものまで)
///   - 書込み抑止ウィンドウも同一(dmaActive のみで判定)
@interface MBMemoryMapDMATests : XCTestCase
@end

@implementation MBMemoryMapDMATests

- (MBMemoryMap *)makeMapWithSource:(uint8_t)sourceByte value:(uint8_t)value {
    MBMemoryMap *map = [[MBMemoryMap alloc] init];
    MBFakeOAM *oam = [[MBFakeOAM alloc] init];
    map.ppuTarget = oam;
    map.oamTarget = oam;
    // DMA ソース(WRAM $C000)に既知値を用意($C000 と末尾 $C09F)
    [map write8:value address:0xC000];
    [map write8:0x81 address:0xC09F];
    [map write8:sourceByte address:0xFF46];
    return map;
}

/// 書込み直後(OAM はまだアクセス可)→ 2 M-cycle 後に FF ウィンドウが開く
- (void)testDMAStartDelayAndConflictWindow {
    MBMemoryMap *map = [self makeMapWithSource:0xC0 value:0x7A];
    // M_w 直後(Fetch 直前の状態を模擬): DMA 未開始なので OAM は実値
    XCTAssertEqual([map read8:0xFE00], 0x00, "DMA 未開始の OAM 読み出しは実値");
    [map tickCycle]; // delay 2→1
    [map tickCycle]; // delay 1→0、active 化(転送はまだ)
    XCTAssertEqual([map read8:0xFE00], 0xFF, "M_{w+2} の OAM 読み出しは FF(転送開始)");
    // この M での CPU 書込みは捨てられる
    [map write8:0x5A address:0xFE00];
    XCTAssertEqual([map read8:0xFE00], 0xFF, "書込みは無視され FF のまま");
    [map tickCycle]; // byte0 が載る(OAM 読み出しは引き続き FF ウィンドウ内)
    MBFakeOAM *oam = (MBFakeOAM *)map.ppuTarget;
    XCTAssertEqual(oam.oamBytes[0], 0x7A, "byte0 は M_{w+3} 相当で OAM へ載る");
}

/// 160 バイト転送の終端: byte159 の M そのものは FF、次の M からは載った値を返す
- (void)testDMAEndBoundary {
    MBMemoryMap *map = [self makeMapWithSource:0xC0 value:0x7A];
    [map tickCycle]; // M_{w+1}(active 化)
    [map tickCycle]; // M_{w+2}(FF ウィンドウ開始、転送なし)
    // byte0..byte159 を載せる 160 tick
    for (int i = 0; i < 160; i++) {
        [map tickCycle];
    }
    // byte159 が載った直後: DMA 完了 → OAM 読み出しは実値
    XCTAssertEqual([map read8:0xFE00], 0x7A, "転送完了後の OAM 読み出しはソース値");
    XCTAssertEqual([map read8:0xFE9F], 0x81, "最終 byte159 も載っている");
}

/// 準備 M(隔離 1 M)を挟むため、active 化 tick の段階では byte0 はまだ載っていない
- (void)testActivationTickDoesNotTransfer {
    MBMemoryMap *map = [self makeMapWithSource:0xC0 value:0x7A];
    [map tickCycle]; // delay 2→1
    [map tickCycle]; // delay 1→0(転送なし)
    MBFakeOAM *oam = (MBFakeOAM *)map.ppuTarget;
    XCTAssertEqual(oam.oamBytes[0], 0x00, "active 化 tick では転送が発生しない");
    XCTAssertEqual([map read8:0xFE00], 0xFF, "とはいえ読み出し衝突はすでに有効");
    [map tickCycle];
    XCTAssertEqual(oam.oamBytes[0], 0x7A, "次の tick で byte0 が載る");
}

/// DMG: ソース $E000-$FFFF は WRAM へミラーされる($FE00→$DE00, $FF00→$DF00。
/// Mooneye oam_dma/sources-GS)
- (void)testDMASourceAboveE000MirrorsWRAM {
    MBMemoryMap *map = [[MBMemoryMap alloc] init];
    MBFakeOAM *oam = [[MBFakeOAM alloc] init];
    map.ppuTarget = oam;
    map.oamTarget = oam;
    [map write8:0x3C address:0xDE00];
    [map write8:0x9D address:0xDF9F];
    [map write8:0xFE address:0xFF46];
    for (int i = 0; i < 2 + 0xA0; i++) [map tickCycle];
    XCTAssertEqual(oam.oamBytes[0], 0x3C, "$FE00 は $DE00 を読む");
    [map write8:0xFF address:0xFF46];
    for (int i = 0; i < 2 + 0xA0; i++) [map tickCycle];
    XCTAssertEqual(oam.oamBytes[0x9F], 0x9D, "$FF9F は $DF9F を読む");
}

/// DMA 転送中の PPU モードで DMA の OAM 書込みが抑制されてはならない。
/// Pan Docs "OAM DMA": 転送は表示モードに依存しない(BubiBoyLite bus.odin も
/// bus.oam[] 直書きで CPU 書込み抑制とは別経路)。実 ROM(SFII)は走査線途中に
/// OAM DMA を掛け、mode2/3 中のバイトが欠落するとスプライトが消える。
/// 回帰: DMA 経路が OAM 書込み禁止窓(mode3・mode2 前半)を通ると転送が欠落する。
- (void)testDMATransfersAllBytesAcrossPPUModes {
    MBPPU *ppu = [[MBPPU alloc] init];
    MBMemoryMap *map = [[MBMemoryMap alloc] init];
    map.ppuTarget = ppu;
    map.oamTarget = ppu;
    ppu.lcdc = 0x93; // LCD ON + BG/OBJ 有効
    // ソース $C000-$C09F に既知パターン
    for (int i = 0; i < 0xA0; i++) {
        [map write8:(uint8_t)(0x10 + i) address:(uint16_t)(0xC000 + i)];
    }
    // 実機構成(MBGameBoy.cpuTickCycle)と同じ合成 tick: メモリ(DMA)1 M-cycle +
    // PPU 4 dots。ブート窓(line0 死相)を越え通常ラインの mode2 へ
    uint8_t req = 0;
    int guard = 0;
    while ((ppu.ly == 0 || (ppu.statValue & 0x03) != 2) && guard++ < 40000) {
        [ppu tickDots:4 ifRequest:&req];
    }
    XCTAssertTrue(guard < 40000, "mode2 に到達できた");
    // DMA 開始($FF46 = 0xC0)→ 完了まで合成 tick(delay 2 + 0xA0 バイト)
    [map write8:0xC0 address:0xFF46];
    for (int i = 0; i < 2 + 0xA0; i++) {
        [map tickCycle];
        [ppu tickDots:4 ifRequest:&req];
    }
    // 160 M-cycle は複数ラインに跨り mode2/3(書込み禁止窓)も通過する。
    // 全 160 バイトが OAM に載っていなければならない(読出し拒否窓回避のため
    // VBlank まで進めてから検査)
    guard = 0;
    while ((ppu.statValue & 0x03) != 1 && guard++ < 40000) {
        [ppu tickDots:4 ifRequest:&req];
    }
    XCTAssertTrue((ppu.statValue & 0x03) == 1, "VBlank に到達した");
    for (int i = 0; i < 0xA0; i++) {
        XCTAssertEqual([ppu readOAM:(uint16_t)i], (uint8_t)(0x10 + i),
            "byte%03d: mode2/3 中の DMA 書込みが抑制された", i);
    }
}

/// DMA 自身のソース読み出しは書込み窓の影響を受けないことの姉妹確認:
/// mode3(描画中)に DMA を開始しても転送数は欠落しない
- (void)testDMADuringMode3KeepsAllBytes {
    MBPPU *ppu = [[MBPPU alloc] init];
    MBMemoryMap *map = [[MBMemoryMap alloc] init];
    map.ppuTarget = ppu;
    map.oamTarget = ppu;
    ppu.lcdc = 0x93;
    for (int i = 0; i < 0xA0; i++) {
        [map write8:(uint8_t)(0x30 + i) address:(uint16_t)(0xC000 + i)];
    }
    uint8_t req = 0;
    int guard = 0;
    // 通常ラインの mode3(=0x03)まで進める
    while ((ppu.ly == 0 || (ppu.statValue & 0x03) != 3) && guard++ < 40000) {
        [ppu tickDots:4 ifRequest:&req];
    }
    XCTAssertTrue((ppu.statValue & 0x03) == 3, "mode3 に到達できた");
    [map write8:0xC0 address:0xFF46];
    for (int i = 0; i < 2 + 0xA0; i++) {
        [map tickCycle];
        [ppu tickDots:4 ifRequest:&req];
    }
    guard = 0;
    while ((ppu.statValue & 0x03) != 1 && guard++ < 40000) {
        [ppu tickDots:4 ifRequest:&req];
    }
    XCTAssertTrue((ppu.statValue & 0x03) == 1, "VBlank に到達した");
    for (int i = 0; i < 0xA0; i++) {
        XCTAssertEqual([ppu readOAM:(uint16_t)i], (uint8_t)(0x30 + i),
            "byte%03d: mode3 中の DMA 書込みが抑制された", i);
    }
}

@end

NS_ASSUME_NONNULL_END
