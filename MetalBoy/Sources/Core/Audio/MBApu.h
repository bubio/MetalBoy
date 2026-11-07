#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Game Boy DMG APU。PCM サンプル生成だけを行う(再生・音量はしない・原則 II)。
/// UI 側の MBAudioOutPort 実装が最終的なゲインを適用する(research R-3)。
/// 機能範囲: 4 チャンネル(2 方形波 / 1 波形メモリ / 1 ノイズ)、frame sequencer、
/// NR50/NR51 によるステレオミックス。
@interface MBApu : NSObject

/// 最新のサンプルをここへ出力。ステレオ int16 L/R をインターリーブで格納する。
/// L/R は NR51 パンニングを反映する(NR50 はマスター音量)。
@property (nonatomic, readonly, strong) NSMutableData *pendingSamples;

/// $FF10-$FF3F の APU レジスタ書き込み
- (void)writeRegister:(uint8_t)value address:(uint16_t)address; // address: $FF10-$FF3F
/// $FF10-$FF3F の APU レジスタ読み込み
- (uint8_t)readRegister:(uint16_t)address;
/// $FF26 NR52 読み取り
- (uint8_t)nr52Value;

/// 1 dot 進行。サンプルは 4194304/48000 dot ごとに 1 サンプルずつ生成
- (void)tickDots:(uint32_t)dots;

/// DIV($FF04)書込み時の副作用。旧内部カウンタ値の bit12 が 1 ならフレームシーケンサを
/// 1 step 余分に進める(実機の DIV-APU カウンタ仕様)。
- (void)notifyDivWriteWithOldValue:(uint16_t)oldDivCounter;

/// pendingSamples を取り出し(呼び出し側でクリア)
- (NSMutableData *)takePendingSamples;
/// 送信待ちサンプル数(int16 単位)
@property (nonatomic, readonly) NSUInteger pendingSampleCount;

/// 電源投入の初期化(NR52=0xF1, NR51=0xF3)
- (instancetype)initWithDefaults;
/// BIOS なし起動用: DMG BIOS 終了時($0100)の APU 状態にする(Mooneye boot_hwio-dmgABCmgb)
- (void)applyPostBootState;

@end

NS_ASSUME_NONNULL_END
