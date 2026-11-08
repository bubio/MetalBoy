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
    /// ウィンドウ内部ラインカウンタ(dmg-acid2 の落とし穴: LY 代用禁止)。
    /// LY>=WY かつ WX により ≥1 画素描画したライン数だけ進める(参照 BubiBoyLite ppu.odin)。
    /// リセット点: 初期化 / LCD OFF→ON(LCDC bit7 立ち上げ) / LY フレームラップ。
    uint16_t _windowLine;
    /// 現ラインの BG/ウィンドウ パレット適用前カラーナンバー(0-3)。
    /// DMG の OBJ 優先判定(attr bit7)は BGP 適用後の「色」ではなくこの生値と比較する。
    uint8_t _bgColorIndex[160];
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
        _windowLine = 0;
    }
    return self;
}

- (void)applyPostBootStateAdvancingDots:(uint32_t)dots {
    _bgp = 0xFC;
    uint8_t ignored = 0;
    while (dots >= 4) {
        [self tickDots:4 ifRequest:&ignored];
        dots -= 4;
    }
    _completedFrameCount = 0;
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
        _windowLine = 0; // LCD ON 時はライン先頭から再開(ウィンドウ内部カウンタも 0 に)
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
                    _mode3Length = MBPPUMode3BaseLength + (n == 0 ? 0 : (4 * ((n + 3) / 4)))
                        + 4 * ([self spritePenaltyDots] / 4);
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
                        _windowLine = 0; // フレームラップで内部カウンタも 0 に
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

/// 現ラインの OBJ による mode 3 伸長 dots(Pan Docs OBJ penalty)。
/// OAM 順で line に掛かる最大 10 体のうち X<168 を対象に、BG タイル単位で
/// 最初の 1 体は 11 - min(5, (X+SCX)&7)、同一タイル内の 2 体目以降は 6 dots。
/// 呼び出し側で M-cycle 単位に切り捨てる(Mooneye intr_2_mode0_timing_sprites)。
- (uint32_t)spritePenaltyDots {
    if (!(self.lcdc & 0x02)) return 0;
    const uint8_t *oam = (const uint8_t *)_oam.bytes;
    int32_t height = (self.lcdc & 0x04) ? 16 : 8;
    BOOL tileSeen[32] = {NO};
    uint32_t penalty = 0;
    for (NSInteger found = 0, si = 0; si < 40 && found < 10; si++) {
        int32_t screenY = (int32_t)oam[si * 4] - 16;
        if ((int32_t)self.ly < screenY || (int32_t)self.ly >= screenY + height) continue;
        found++;
        uint8_t x = oam[si * 4 + 1];
        if (x >= 168) continue;
        uint32_t pos = (uint32_t)x + (self.scx & 0x07);
        if (tileSeen[pos >> 3]) {
            penalty += 6;
        } else {
            tileSeen[pos >> 3] = YES;
            penalty += 11 - MIN(5u, pos & 0x07);
        }
    }
    return penalty;
}

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

    // ウィンドウはこのラインで ≥1 画素描画するか(LY>=WY かつ WX が画面内に届く)。
    // 実際に描画したラインだけ window_line を進める(dmg-acid2 の落とし穴)。
    BOOL winVisibleThisLine = winOn && y >= self.wy && ((int)self.wx - 7) < 160;

    uint8_t paletteColors[4];
    for (NSInteger i = 0; i < 4; i++) {
        paletteColors[i] = (uint8_t)((self.bgp >> (i * 2)) & 0x03);
    }

    // BG / Window
    for (uint8_t x = 0; x < 160; x++) {
        if (!bgOn) {
            row[x] = kColorRGBA[0];                    // DMG: BG OFF 時は白固定
            _bgColorIndex[x] = 0;                      // BG 不透明扱いしない(BG OFF で OBJ 常時表)
            continue;
        }
        BOOL useWindow = winVisibleThisLine && (x + 7) >= self.wx;
        uint16_t mapBase = useWindow ? (winMap9C00 ? 0x1C00 : 0x1800) : (bgMap9C00 ? 0x1C00 : 0x1800);
        uint8_t xx = useWindow ? (uint8_t)(x - (self.wx - 7)) : (uint8_t)(x + self.scx);
        // ウィンドウの行は内部カウンタ _windowLine で数える(LY からは算出しない)
        uint8_t yy = useWindow ? (uint8_t)(_windowLine & 0xFF) : (uint8_t)(y + self.scy);
        uint16_t mapIndex = mapBase + (uint16_t)((yy / 8) * 32 + (xx / 8));
        uint8_t tileIndex = vram[mapIndex];
        uint8_t colorIndex = [self tileColorIndex:vram tileIndex:tileIndex fx:(uint8_t)(xx & 7) fy:(uint8_t)(yy & 7) tileData8000:tileData8000];
        _bgColorIndex[x] = colorIndex;                 // パレット適用前の値を保存(window 画素も BG 扱い)
        row[x] = kColorRGBA[paletteColors[colorIndex]];
    }

    if (winVisibleThisLine) {
        _windowLine++;
    }

    // スプライト: ライン上のスプライト(OAM 順・最大 10 体)を DMG 優先度に並べ替えて描画
    // (実機/Pan Docs "OBJ priority" + 参照 BubiBoyLite ppu.odin):
    //   スプライト間優先 = X 座標が小さいほど優先・同 X は OAM 順。
    //   一度描いた(=非透明と確定した)画素は低優先度スプライトで上書きされない。
    //   attr bit7(BG 優先)= BGP 適用「前」の BG 生カラーナンバー != 0 を条件に隠れる。
    if (self.lcdc & 0x02) {
        BOOL tall = (self.lcdc & 0x04) != 0;
        uint8_t height = tall ? 16 : 8;

        // ライン上スプライトの収集(OAM 順・最大 10 体)
        uint8_t sortedX[10], sortedIdx[10];
        NSInteger count = 0;
        for (NSInteger si = 0; si < 40 && count < 10; si++) {
            uint8_t sy = oam[si * 4];
            int32_t screenY = (int32_t)sy - 16;
            if ((int32_t)y < screenY || (int32_t)y >= screenY + height) continue;
            sortedX[count] = oam[si * 4 + 1];
            sortedIdx[count] = (uint8_t)si;
            count++;
        }
        // 挿入ソート: (X,OAM インデックス) 昇順 = DMG 描画優先度順(最大 10 体なので十分)
        for (NSInteger i = 1; i < count; i++) {
            uint8_t cx = sortedX[i], ci = sortedIdx[i];
            NSInteger j = i - 1;
            while (j >= 0 && (sortedX[j] > cx || (sortedX[j] == cx && sortedIdx[j] > ci))) {
                sortedX[j + 1] = sortedX[j];
                sortedIdx[j + 1] = sortedIdx[j];
                j--;
            }
            sortedX[j + 1] = cx;
            sortedIdx[j + 1] = ci;
        }

        BOOL pixelOwned[160] = { NO };
        for (NSInteger i = 0; i < count; i++) {
            NSInteger si = sortedIdx[i];
            uint8_t attr = oam[si * 4 + 3];
            int32_t screenY = (int32_t)oam[si * 4] - 16;
            int32_t screenX = (int32_t)sortedX[i] - 8;
            for (int32_t px = MAX(0, screenX); px < MIN(160, screenX + 8); px++) {
                uint8_t fx = (uint8_t)(px - screenX);
                uint8_t fy = (uint8_t)(y - screenY);
                if (attr & 0x40) fy = (uint8_t)(height - 1 - fy); // 縦フリップ
                if (attr & 0x20) fx = (uint8_t)(7 - fx);          // 横フリップ
                uint16_t tileAddr = oam[si * 4 + 2];
                if (tall) tileAddr = (uint16_t)(tileAddr & 0xFE);
                uint8_t raw = [self tileColorIndex:vram tileIndex:(uint8_t)tileAddr fx:fx fy:fy tileData8000:YES];
                if (raw == 0) continue;                           // 透過: 画素の所有権も取らない
                if (pixelOwned[px]) continue;                     // 高優先度スプライトが確定済み
                pixelOwned[px] = YES;                             // スプライト間優先度を確定(BG 優先判定とは独立)
                if (attr & 0x80 && _bgColorIndex[px] != 0) continue; // BG 生インデックス 1-3 の上には描かない
                uint8_t palette = (attr & 0x10) ? self.obp1 : self.obp0;
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
