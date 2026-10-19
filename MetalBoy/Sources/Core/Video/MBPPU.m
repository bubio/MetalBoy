#import "MBPPU.h"

NS_ASSUME_NONNULL_BEGIN

// DMG PPU(スキャンライン型):
//   1 ライン = 456 dots( OAM scan 80 / draw 168 / hblank 208 準拠の 80+172+204 簡略 )
//   1 フレーム = 154 ライン(144 表示 + 10 VBlank)
// LCD OFF 中は LY=0・mode=0 に固定(Pan Docs 準拠)。

typedef NS_ENUM(uint8_t, MBPPUMode) {
    MBPPUModeHBlank  = 0,
    MBPPUModeVBlank  = 1,
    MBPPUModeOAMScan = 2,
    MBPPUModeDraw    = 3,
};

// スキャンライン構成 dots(mode3 長は SCX&7 により伸縮 → _mode3Length ivar)
static const uint32_t MBPPULineDots        = 456;
static const uint32_t MBPPUMode2Length     = 80;
static const uint32_t MBPPUMode3BaseLength = 172;

#pragma mark - DMG 初期値(電源投入相当)

static const uint8_t kDefaultLCDC = 0x91;

// 4 色パレット(RGBA・0=白 1=淡灰 2=濃灰 3=黒)
static const uint32_t kColorRGBA[4] = { 0xFFFFFFFF, 0xFFB0B0B0, 0xFF606060, 0xFF000000 };

@interface MBPPU ()
{
    NSMutableData *_vram;   // 8KiB
    NSMutableData *_oam;    // 160 bytes
    uint8_t _ly;
    uint8_t _stat;
    MBPPUMode _mode;
    uint32_t _dotsInMode;
    uint32_t _mode3Length;   // 現ラインの mode 3 長(SCX&7 で伸縮、実機。hblank_ly_scx_timing-GS)
    BOOL _frameSignaled;
    BOOL _statIrqLine;       // 内部 STAT 割込みライン(エッジ判定用)
    BOOL _coincidenceLatch;  // LCD OFF 中に保持される LY==LYC 最終比較結果
}
@property (nonatomic, readwrite, strong) NSMutableData *framebuffer;
@property (nonatomic, readwrite) NSUInteger completedFrameCount;
@property (nonatomic, readwrite, strong) NSMutableData *vram;
@property (nonatomic, readwrite, strong) NSMutableData *oam;
@property (nonatomic, readwrite) uint8_t ly;
@property (nonatomic, readwrite) MBPPUMode mode;
@property (nonatomic, readwrite) uint32_t dotsInMode;
@end

@implementation MBPPU

- (instancetype)init {
    self = [super init];
    if (self) {
        _framebuffer = [NSMutableData dataWithLength:160 * 144 * 4];
        _vram = [NSMutableData dataWithLength:0x2000];
        _oam = [NSMutableData dataWithLength:0xA0];
        _lcdc = kDefaultLCDC;
        _bgp = 0xE4;
        _obp0 = 0xFF; // 電源投入既定(実機: 未書込の OBP0/OBP1 は $FF)
        _obp1 = 0xFF;
        _ly = 0;
        _stat = 0x00;
        _mode = MBPPUModeOAMScan;
        _dotsInMode = 0;
        _mode3Length = MBPPUMode3BaseLength;
        _completedFrameCount = 0;
        _frameSignaled = NO;
        _statIrqLine = NO;
        _coincidenceLatch = NO;
    }
    return self;
}

#pragma mark - VRAM / OAM

- (uint8_t)readVRAM:(uint16_t)address {
    address &= 0x1FFF;
    return ((const uint8_t *)_vram.bytes)[address];
}

- (void)writeVRAM:(uint8_t)value address:(uint16_t)address {
    address &= 0x1FFF;
    ((uint8_t *)_vram.mutableBytes)[address] = value;
}

- (uint8_t)readOAM:(uint16_t)address {
    address &= 0xFF;
    // mode 3 中の OAM 読み出しは不可 = 0xFF を返す(実機。Mooneye intr_2_oam_ok_timing)
    if (self.lcdc & 0x80 && _mode == MBPPUModeDraw) return 0xFF;
    return ((const uint8_t *)_oam.bytes)[address];
}

- (void)writeOAM:(uint8_t)value address:(uint16_t)address {
    address &= 0xFF;
    // mode 3 中の OAM 書込みは捨てられる(実機同)
    if (self.lcdc & 0x80 && _mode == MBPPUModeDraw) return;
    ((uint8_t *)_oam.mutableBytes)[address] = value;
}

- (void)writeSTAT:(uint8_t)value {
    // 下位 3bit(モード/coincidence)は読み取り専用。bit6..3(割り込みソース)は書込み可
    _stat = (uint8_t)(value & 0x78);
}

- (uint8_t)statValue {
    uint8_t result = (uint8_t)(0x80 | (_stat & 0x78)); // bit7 は常時 1(実機仕様)
    if (self.lcdc & 0x80) {
        result |= (uint8_t)(_mode & 0x03);
        if (_ly == self.lyc) result |= 0x04;
    } else {
        // LCD OFF: モード読出し 0・比較クロック停止(latch 保持)
        if (_coincidenceLatch) result |= 0x04;
    }
    return result;
}

- (BOOL)inVBlank {
    return _mode == MBPPUModeVBlank;
}

#pragma mark - tick(1 dot 単位で進行)

- (BOOL)tickDots:(uint32_t)dots ifRequest:(uint8_t *)ifRequest {    if (!(self.lcdc & 0x80)) {
        // LCD OFF: LY=0・モード 0 に固定。直前のフレーム完了は 1 度だけ通知
        _mode = MBPPUModeHBlank;
        _ly = 0;
        _dotsInMode = 0;
        if (_frameSignaled) {
            _frameSignaled = NO;
            return YES;
        }
        return NO;
    }

    BOOL frameCompleted = NO;
    for (uint32_t i = 0; i < dots; i++) {
        _dotsInMode++;
        switch (_mode) {
            case MBPPUModeOAMScan:
                if (_dotsInMode >= MBPPUMode2Length) {
                    _dotsInMode = 0;
                    _mode = MBPPUModeDraw;
                    // mode 3 長は SCX&7 で伸縮(実機。Mooneye hblank_ly_scx_timing-GS:
                    // SCX&7=0 → +0 / 1-4 → +4 dots / 5-7 → +8 dots)
                    uint32_t n = self.scx & 0x07;
                    _mode3Length = MBPPUMode3BaseLength + (n == 0 ? 0 : (4 * ((n + 3) / 4)));
                }
                break;
            case MBPPUModeDraw:
                if (_dotsInMode >= _mode3Length) {
                    _dotsInMode = 0;
                    _mode = MBPPUModeHBlank;
                    [self renderCurrentScanline];
                }
                break;
            case MBPPUModeHBlank:
                if (_dotsInMode >= MBPPULineDots - 80 - _mode3Length) {
                    _dotsInMode = 0;
                    if (_ly == 143) {
                        _ly = 144;
                        _mode = MBPPUModeVBlank;
                        if (ifRequest) *ifRequest |= 0x01; // VBlank 割り込み要求
                    } else {
                        _ly++;
                        _mode = MBPPUModeOAMScan;
                    }
                }
                break;
            case MBPPUModeVBlank:
                if (_dotsInMode >= 456) {
                    _dotsInMode = 0;
                    if (_ly == 153) {
                        _ly = 0;
                        _mode = MBPPUModeOAMScan;
                    } else {
                        _ly++;
                    }
                }
                break;
        }
        [self fireSTATIfRequest:ifRequest];
        if (_mode == MBPPUModeVBlank && _ly == 144 && _dotsInMode <= 1 && !_frameSignaled) {
            _frameSignaled = YES;
            frameCompleted = YES;
        }
    }
    return frameCompleted;
}

- (void)fireSTATIfRequest:(uint8_t *)ifRequest {
    // STAT 割込みライン = 発生源条件の OR。IF bit1 はラインの立下がりのみで立てる
    // (エッジトリガ: 十分に残り続ける限り同じ発生源では再発火しない = stat_irq_blocking)。
    // LCD OFF 中は比較クロック停止。モード読出し 0・LY==LYC は latch で保持(stat_lyc_onoff)。
    BOOL line;
    if (self.lcdc & 0x80) {
        BOOL coincidence = (_ly == self.lyc);
        _coincidenceLatch = coincidence; // OFF 遷移時の保持値を常時更新
        // bit5(OAM mode2): LY=144 の VBlank 開始でも同一 dot で発火する(実機。
        // Mooneye vblank_stat_intr-GS: vblank IF と stat m2 IF が同時)
        BOOL m2Window = (_mode == MBPPUModeOAMScan) || (_ly == 144 && _mode == MBPPUModeVBlank);
        line = (((_stat & 0x08) && _mode == MBPPUModeHBlank)
             || ((_stat & 0x10) && _mode == MBPPUModeVBlank)
             || ((_stat & 0x20) && m2Window)
             || ((_stat & 0x40) && coincidence));
    } else {
        line = ((_stat & 0x40) && _coincidenceLatch);
    }
    if (line && !_statIrqLine && ifRequest) *ifRequest |= 0x02;
    _statIrqLine = line;
}

#pragma mark - 描画(1 ライン = 160 ピクセル)

- (void)renderCurrentScanline {
    if (!(self.lcdc & 0x80)) return;
    uint8_t y = _ly;
    if (y >= 144) return;

    uint32_t *pixels = (uint32_t *)self.framebuffer.mutableBytes;
    uint32_t *row = pixels + (uint32_t)(y * 160);
    const uint8_t *vram = (const uint8_t *)_vram.bytes;
    const uint8_t *oam = (const uint8_t *)_oam.bytes;

    BOOL bgOn = (self.lcdc & 0x01) != 0;
    BOOL winOn = (self.lcdc & 0x20) != 0;
    BOOL tileData8000 = (self.lcdc & 0x10) != 0;
    BOOL bgMap9C00 = (self.lcdc & 0x08) != 0;
    BOOL winMap9C00 = (self.lcdc & 0x40) != 0;

    uint8_t paletteColors[4];
    for (NSInteger i = 0; i < 4; i++) {
        paletteColors[i] = (uint8_t)((self.bgp >> (i * 2)) & 0x03);
    }

    // BG / Window
    for (uint8_t x = 0; x < 160; x++) {
        if (!bgOn) {
            row[x] = kColorRGBA[0];                    // DMG: BG OFF 時は白固定
            continue;
        }
        BOOL useWindow = winOn && y >= self.wy && (x + 7) >= self.wx;
        uint16_t mapBase = useWindow ? (winMap9C00 ? 0x1C00 : 0x1800) : (bgMap9C00 ? 0x1C00 : 0x1800);
        uint8_t xx = useWindow ? (uint8_t)(x - (self.wx - 7)) : (uint8_t)(x + self.scx);
        uint8_t yy = useWindow ? (uint8_t)(y - self.wy) : (uint8_t)(y + self.scy);
        uint16_t mapIndex = mapBase + (uint16_t)((yy / 8) * 32 + (xx / 8));
        uint8_t tileIndex = vram[mapIndex];
        uint8_t colorIndex = [self tileColorIndex:vram tileIndex:tileIndex fx:(uint8_t)(xx & 7) fy:(uint8_t)(yy & 7) tileData8000:tileData8000];
        row[x] = kColorRGBA[paletteColors[colorIndex]];
    }

    // スプライト: OAM 順(line あたり最大 10 体・Y/X 判定で通過者み描画 OAM 優先)
    if (self.lcdc & 0x02) {
        BOOL tall = (self.lcdc & 0x04) != 0;
        uint8_t height = tall ? 16 : 8;
        for (NSInteger drawn = 0, si = 0; si < 40 && drawn < 10; si++) {
            uint8_t sy = oam[si * 4];
            uint8_t sx = oam[si * 4 + 1];
            int32_t screenY = (int32_t)sy - 16;
            if ((int32_t)y < screenY || (int32_t)y >= screenY + height) continue;
            drawn++;
            int32_t screenX = (int32_t)sx - 8;
            int32_t lineTop = screenY;
            if (lineTop < 0) lineTop = 0;
            for (int32_t px = MAX(0, screenX); px < MIN(160, screenX + 8); px++) {
                uint8_t fx = (uint8_t)(px - screenX);
                uint8_t fy = (uint8_t)(y - screenY);
                if (oam[si * 4 + 3] & 0x40) fy = (uint8_t)(height - 1 - fy); // 縦フリップ
                if (oam[si * 4 + 3] & 0x20) fx = (uint8_t)(7 - fx);          // 横フリップ
                uint16_t tileAddr = oam[si * 4 + 2];
                if (tall) tileAddr = (uint16_t)(tileAddr & 0xFE);
                uint8_t raw = [self tileColorIndex:vram tileIndex:(uint8_t)tileAddr fx:fx fy:fy tileData8000:YES];
                if (raw == 0) continue;                                   // 透過
                if (oam[si * 4 + 3] & 0x80 && (row[px] != kColorRGBA[0])) continue; // BG 優先
                uint8_t palette = (oam[si * 4 + 3] & 0x10) ? self.obp1 : self.obp0;
                row[px] = kColorRGBA[(palette >> (raw * 2)) & 0x03];
            }
        }
    }
    self.completedFrameCount += 1;
}

/// タイル 1 ピクセルの 2bpp カラーナンバー(0-3)。tileData8000: $8000 起点の無符号
- (uint8_t)tileColorIndex:(const uint8_t *)vram tileIndex:(uint8_t)tileIndex fx:(uint8_t)fx fy:(uint8_t)fy tileData8000:(BOOL)tileData8000 {
    uint16_t addr;
    if (tileData8000) {
        addr = (uint16_t)(tileIndex * 16);
    } else {
        int8_t sIdx = (int8_t)tileIndex;
        addr = (uint16_t)(0x1000 + (int32_t)sIdx * 16);
    }
    const uint8_t *tileData = vram + addr;
    uint8_t lo = tileData[fy * 2];
    uint8_t hi = tileData[fy * 2 + 1];
    uint8_t bit = 7 - fx;
    return (uint8_t)((((hi >> bit) & 1) << 1) | ((lo >> bit) & 1));
}

@end

NS_ASSUME_NONNULL_END
