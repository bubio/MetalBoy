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
    /// LCD ON 直後の「死相」残 dots(実機 72 dots: LCD OFF→ON 遷移で setting。
    /// dead 中 = LY=0 固定・モード読出し 0・OAM/VRAM アクセス可(lcdon_timing-GS)
    uint32_t _lcdBootDots;
    /// 直前の HBlank 中に LY 増分(終端 4 dot 前)を行ったか。VBlank 遷移判定用
    BOOL _hblankIncremented;
    uint8_t _stat;
    MBPPUMode _mode;
    uint32_t _dotsInMode;
    uint32_t _mode3Length;   // 現ラインの mode 3 長(SCX&7 で伸縮、実機。hblank_ly_scx_timing-GS)
    BOOL _frameSignaled;
    BOOL _statIrqLine;       // 内部 STAT 割込みライン(エッジ判定用)
    BOOL _coincidenceLatch;  // LCD OFF 中に保持される LY==LYC 最終比較結果
    /// LY 増分直後〜mode2 開始(HBlank 終端)までの 4 dot: STAT bit2 は強制 0
    /// (実機。lcdon_timing-GS STAT_LYC0/LYC1 pass2 s3 がともに 0x80 で確定)
    BOOL _coincBlanked;
    /// OAM/VRAM 読み出し禁止窓の anchor: 直近の LY 増分 dot からの dots。
    /// 窓: OAM = 通常 [0,256)/line0 [80,252)・VRAM = [80,252)
    uint32_t _dotsSinceInc;
    /// line0(死相)窓が有効(lcdon_timing-GS OAM: line0 の窓は mode3 開始から)
    BOOL _bootWindow;
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
        _mode = MBPPUModeHBlank; // 電源投入死相中のモード読出し 0 と一致
        _dotsInMode = 0;
        _mode3Length = MBPPUMode3BaseLength;
        _completedFrameCount = 0;
        _frameSignaled = NO;
        // 電源投入直後 = 実機同様 LCD ON 死相から開始(off→on 遷移と同一状態)
        _lcdBootDots = 80;
        _dotsSinceInc = 0;
        _bootWindow = YES;
        _hblankIncremented = NO;
        _coincBlanked = NO;
        _statIrqLine = NO;
        _coincidenceLatch = NO;
    }
    return self;
}

#pragma mark - VRAM / OAM

- (uint8_t)readVRAM:(uint16_t)address {
    address &= 0x1FFF;
    // VRAM 読み出し禁止窓(dsi = LY 増分 anchor からの dots): [80, 252)。
    // line0(死相 mode3 [80,252))と通常 line(mode3 を −4 dot ロール [inc+80, inc+252))
    // が同一則で書ける(実機。lcdon_timing-GS VRAM 群全サンプル実測)
    // VRAM 読み出し禁止窓(dsi): [anchor+80, anchor+256) — mode3 開始の 4 dot 前
    // (−4 ロールは START のみ)から mode0 開始 dot まで。line0(死相)/通常同一則。
    if (self.lcdc & 0x80 && _mode != MBPPUModeVBlank) {
        uint32_t s = _dotsSinceInc;
        // line0(死相): [anchor+80, anchor+252) / 通常: [anchor+80, anchor+256)
        // (mode3 の可視開始 dot から −4 ロールは START のみ、終端は mode0 開始)
        BOOL denied = _bootWindow ? (s >= 80 && s < 252) : (s >= 80 && s < 256);
        if (denied) return 0xFF;
    }
    return ((const uint8_t *)_vram.bytes)[address];
}

- (void)writeVRAM:(uint8_t)value address:(uint16_t)address {
    address &= 0x1FFF;
    // VRAM 書込み禁止窓(dsi = LY 増分 anchor からの dots)。実機。lcdon_write_timing-GS
    // VRAM 群 19 サンプル実測: 読出し([anchor+80, anchor+256))より START 側 4 dot 緩い。
    //   line0(死相): [anchor+80, anchor+252)(読出しと同一)
    //   通常 line:   [anchor+84, anchor+256)(= 可視 mode3。mode2 窓は書込み可)
    if (self.lcdc & 0x80 && _mode != MBPPUModeVBlank) {
        uint32_t s = _dotsSinceInc;
        BOOL denied = _bootWindow ? (s >= 80 && s < 252) : (_mode == MBPPUModeDraw);
        if (denied) return;
    }
    ((uint8_t *)_vram.mutableBytes)[address] = value;
}

- (uint8_t)readOAM:(uint16_t)address {
    address &= 0xFF;
    // OAM 読み出し禁止窓(dsi = 直近の LY 増分 anchor からの dots):
    //   通常 line = [0, 256)  /  line0(LCD ON 直後の死相) = [80, 252)
    // (実機。lcdon_timing-GS OAM 群全サンプル: LY 増分 dot から早期ロック開始、
    //  mode0 開始(HBlank)で解放、line0 は死相 mode3 開始から)。intr_2_oam_ok_timing
    // (mode0 開始で解放)とも整合。
    if (self.lcdc & 0x80 && _mode != MBPPUModeVBlank) {
        uint32_t s = _dotsSinceInc;
        // line0(死相): 窓 = 可視 mode3 そのまま [anchor+80, anchor+252)。
        // 通常 line: OAM = [anchor, anchor+256)(mode2 の 4 dot 前〜mode0 開始)
        BOOL denied = _bootWindow ? (s >= 80 && s < 252) : (s < 256);
        if (denied) return 0xFF;
    }
    return ((const uint8_t *)_oam.bytes)[address];
}

- (void)writeOAM:(uint8_t)value address:(uint16_t)address {
    address &= 0xFF;
    // OAM 書込み禁止窓(dsi)。実機。lcdon_write_timing-GS OAM 群 19 サンプル実測:
    //   line0(死相): [anchor+80, anchor+252)(読出しと同一)
    //   通常 line:   [anchor+4, anchor+80)(mode2 前 76 dot)+ [anchor+84, anchor+256)
    //   (= 可視 mode3)。mode2 最後の 4 dot([anchor+80, anchor+84))は書込み可。
    // VBlank(mode1)中は無条件に書込み可。
    if (self.lcdc & 0x80 && _mode != MBPPUModeVBlank) {
        uint32_t s = _dotsSinceInc;
        BOOL denied;
        if (_bootWindow) {
            denied = (s >= 80 && s < 252);
        } else {
            denied = (_mode == MBPPUModeDraw)
                  || (_mode == MBPPUModeOAMScan && s < 80);
        }
        if (denied) return;
    }
    ((uint8_t *)_oam.mutableBytes)[address] = value;
}

- (void)setLcdc:(uint8_t)value {
    // LCD OFF→ON 遷移で「死相」を設定(実機 80 dots = mode2 と同長: LY=0 固定・
    // モード読出し 0・OAM/VRAM ともアクセス可 → lcdon_timing-GS 実測からの定数)。
    // line0 = 死相 80 + mode3 172 + mode0 204 = 通常 456-dot ラインと同長。
    // dsi 窓 anchor(LY 増分相当)を LCD ON dot に置く(line0 用)
    if ((value & 0x80) && !(_lcdc & 0x80)) {
        _lcdBootDots = 80;
        _dotsSinceInc = 0;
        _bootWindow = YES;
    }
    _lcdc = value;
}

- (void)writeSTAT:(uint8_t)value {
    // 下位 3bit(モード/coincidence)は読み取り専用。bit6..3(割り込みソース)は書込み可
    _stat = (uint8_t)(value & 0x78);
}

- (uint8_t)statValue {
    uint8_t result = (uint8_t)(0x80 | (_stat & 0x78)); // bit7 は常時 1(実機仕様)
    if (self.lcdc & 0x80) {
        result |= (uint8_t)(_mode & 0x03);
        if (!_coincBlanked && _ly == self.lyc) result |= 0x04;
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
        _coincBlanked = NO;
        _dotsSinceInc = 0;
        _bootWindow = NO;
        _dotsInMode = 0;
        if (_frameSignaled) {
            _frameSignaled = NO;
            return YES;
        }
        return NO;
    }

    BOOL frameCompleted = NO;
    for (uint32_t i = 0; i < dots; i++) {
        // LCD ON 直後の死相: LY=0 固定・モード読出し 0(HBlank 相当 = OAM/VRAM アクセス可)。
        // 長さ = 80 = mode2 と同長。終端で mode3(Draw)へ遷移し、line0 = 死相 80 +
        // mode3 172 + mode0 204 = 通常 456-dot ラインと同構造(mode2 が死相に置換)。
        if (_lcdBootDots > 0) {
            _lcdBootDots--;
            if (_lcdBootDots == 0) {
                // 死相終端: mode3 開始(_bootHBlankDots 廃止: line0 の mode0 も 204)
                _mode = MBPPUModeDraw;
                _dotsInMode = 0;
            } else {
                _mode = MBPPUModeHBlank;
                _ly = 0;
                _dotsInMode = 0;
            }
            _dotsSinceInc++; // dsi anchor = LCD ON dot(line0 窓用)
            [self fireSTATIfRequest:ifRequest];
            continue;
        }
        _dotsInMode++;
        _dotsSinceInc++;
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
                    _hblankIncremented = NO;
                    [self renderCurrentScanline];
                }
                break;
            case MBPPUModeHBlank: {
                uint32_t threshold = MBPPULineDots - 80 - _mode3Length;
                // LY 増分は HBlank 終端の 4 dot 前(実機。lcdon_timing-GS LY pass1-3 の
                // 4-dot 窓 + hblank_ly_scx_timing-GS の 51/50/49 M データから確定:
                // LY 増分 = 次 line mode2 開始の 4 dot 前 = mode0 開始 + mode0長 - 4)。
                // VBlank 遷移(143→144)は終端同時(現行 vblank_stat_intr-GS PASS 維持)。
                if (_dotsInMode == threshold - 4 && _ly <= 142) {
                    // 増分直後 4 dot: STAT bit2 強制 0(実機)
                    _coincBlanked = YES;
                    _ly++;
                    _hblankIncremented = YES;
                    // dsi anchor 更新: OAM/VRAM 禁止窓はこの dot から張り直し
                    _dotsSinceInc = 0;
                    _bootWindow = NO;
                }
                if (_dotsInMode >= threshold) {
                    _dotsInMode = 0;
                    _coincBlanked = NO;
                    if (_hblankIncremented) {
                        _mode = MBPPUModeOAMScan;
                        _hblankIncremented = NO;
                    } else {
                        // LY 増分なし = line 143 の HBlank → VBlank 開始
                        _ly = 144;
                        _mode = MBPPUModeVBlank;
                        if (ifRequest) *ifRequest |= 0x01; // VBlank 割り込み要求
                    }
                }
                break;
            }
            case MBPPUModeVBlank:
                if (_dotsInMode >= 456) {
                    _dotsInMode = 0;
                    // VBlank 各 line 境界でも dsi anchor 更新(VBlank 中の読み出し窓)
                    _dotsSinceInc = 0;
                    _bootWindow = NO;
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
        BOOL coincidence = (!_coincBlanked && _ly == self.lyc);
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
