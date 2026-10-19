#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Game Boy DMG PPU。160x144 RGBA8 フレームバッファの生成だけを行う(UI 描画はしない・
/// 原則 II)。research R-2: 描画・スケール・フィルタは UI 層の MBRenderPort 実装に属する。
/// 機能範囲: BG / ウィンドウ / スプライト / 背景パレット / LY/STAT/ VBlank 割り込み。
@interface MBPPU : NSObject

/// 出力フレームバッファ: 160*144 RGBA8(1 ピクセル = 4 バイト)
@property (nonatomic, readonly, strong) NSMutableData *framebuffer;
/// 1 フレーム完了毎にインクリメント
@property (nonatomic, readonly) NSUInteger completedFrameCount;

/// $FF40 LCDC
/// $FF40 LCDC
@property (nonatomic) uint8_t lcdc;
/// $FF42 SCY / $FF43 SCX / $FF45 LYC
@property (nonatomic) uint8_t scy, scx, lyc;
/// $FF47/48/49 背景パレット
@property (nonatomic) uint8_t bgp, obp0, obp1;
/// $FF4A WY / $FF4B WX
@property (nonatomic) uint8_t wy, wx;
/// $FF44 LY(現在走査行)
@property (nonatomic, readonly) uint8_t ly;
/// $FF41 STAT(LY coincidence 割り込み設定含む)
@property (nonatomic, readonly) uint8_t stat;

/// $FF41 読み取り値(モード・coincidence を合成した値)
- (uint8_t)statValue;

/// VRAM($8000-$9FFF)・OAM($FE00-$FE9F)は PPU が所有する
- (uint8_t)readVRAM:(uint16_t)address;      // 0x0000-0x1FFF 相対アクセス用
- (void)writeVRAM:(uint8_t)value address:(uint16_t)address;
- (uint8_t)readOAM:(uint16_t)address;
- (void)writeOAM:(uint8_t)value address:(uint16_t)address;
- (void)writeSTAT:(uint8_t)value;

/// 1 dot 進行。割り込みビットは外部へ(第5bit VBlank, 第1bit STAT 割り込み)
/// 割り込み要求は ifFlags に OR される callback パス。
/// 返り値: YES = 1 フレーム完了(呼び出し側はフレーム提示 möglich)
- (BOOL)tickDots:(uint32_t)dots ifRequest:(uint8_t *)ifRequest;

/// VBlank 期間判定(バンクからの DMA などで使用)
- (BOOL)inVBlank;
/// DMA($FF46)用の手動 OAM 転送などは外部から API 経由なしで writeOAM を使う

@end

NS_ASSUME_NONNULL_END
