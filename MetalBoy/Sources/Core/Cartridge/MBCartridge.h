#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// カートリッジのバンクコントローラ種別(FR-016: MBC0/1/2/3/5 のみ対応)
typedef NS_ENUM(NSUInteger, MBCartridgeType) {
    MBCartridgeTypeROMOnly   = 0,  // MBC0(マッパーなし)
    MBCartridgeTypeMBC1      = 1,
    MBCartridgeTypeMBC2      = 5,
    MBCartridgeTypeMBC3      = 3,
    MBCartridgeTypeMBC5      = 0x19, // 0x19〜0x1E を広義に MBC5 扱い
};

/// ROM 解析エラー・RAM 復元失敗などのカートリッジ層エラー
extern NSErrorDomain const MBCartridgeErrorDomain;

typedef NS_ERROR_ENUM(MBCartridgeErrorDomain, MBCartridgeErrorCode) {
    MBCartridgeErrorCodeROMTooShort      = 1, // 無効 ROM(ヘッダ未満)
    MBCartridgeErrorCodeInvalidROM       = 2, // 無効 ROM(サイズ奇形等)
    MBCartridgeErrorCodeUnsupportedType  = 3, // 対応範囲外カートリッジ(R-6)
    MBCartridgeErrorCodeCgbOnlyROM       = 4, // CGB 専用 ROM(FR-012)
    MBCartridgeErrorCodeRAMSizeMismatch  = 5, // セーブ復元のサイズ不一致
};

/// Game Boy カートリッジ(ROM + MBC + SRAM)。コア層・UI 非依存(憲法原則 II/VIII 相当)
/// - data-model.md の MBCartridgeROM / MBCartridgeRAM を 1 クラスに統合
@interface MBCartridge : NSObject

/// 解析済み ROM 生データ(読み取り専用)
@property (nonatomic, readonly, copy) NSData *romData;
/// カートリッジ種別(マッパー分類)
@property (nonatomic, readonly) MBCartridgeType cartridgeType;
/// ROM サイズ(バイト)
@property (nonatomic, readonly) NSUInteger romSize;
/// SRAM サイズ(バイト。非対応タイプは 0)
@property (nonatomic, readonly) NSUInteger ramSize;
/// バッテリーバックアップ RAM を持つか(セーブファイル対象判定・FR-013/FR-014)
@property (nonatomic, readonly) BOOL hasBattery;
/// CGB 専用 ROM か(ヘッダ $0143 の専用フラグ。DMG では非対応・FR-012)
@property (nonatomic, readonly) BOOL isCgbOnly;
/// カートリッジタイトル(ヘッダ $0134..0143 の ASCII 部分。診断用)
@property (nonatomic, readonly, copy) NSString *title;

/// 現在の SRAM 内容(終了時のセーブファイル書出し元・FR-013)。未使用は nil
@property (nonatomic, readonly, nullable) NSData *currentRAM;

/// ROM 生データから生成。解析不能・対応範囲外は error に設定し nil を返す
- (nullable instancetype)initWithROMData:(NSData *)romData
                                   error:(NSError *_Nullable *_Nullable)error;

/// セーブファイル復元(preconditions: hasBattery == YES)。サイズ不一致は
/// MBCartridgeErrorCodeRAMSizeMismatch で失敗(research R-7: 黙って上書きしない)
- (BOOL)restoreRAM:(NSData *)ram error:(NSError *_Nullable *_Nullable)error;

/// アドレス($0000-$7FFF)からのバンク切替後 ROM バイト読み取り
- (uint8_t)romByteAtAddress:(uint16_t)address;
/// アドレス($A000-$BFFF)からの SRAM バイト読み取り(SRAM 無しは 0xFF)
- (uint8_t)sramByteAtAddress:(uint16_t)address;
/// SRAM への書き込み(SRAM 無しは破棄)
- (void)writeSRAMByte:(uint8_t)value atAddress:(uint16_t)address;
/// MBC 制御レジスタ領域($0000-$7FFF)への書き込み
- (void)writeControlByte:(uint8_t)value atAddress:(uint16_t)address;
/// MBC3 RTC レジスタ読み取り(簡易対応・research R-6)。非 MBC3 は 0
- (uint8_t)rtcRegisterByte:(uint8_t)index;
/// MBC3 RTC レジスタ書き込み(簡易)
- (void)writeRTCRegisterByte:(uint8_t)value index:(uint8_t)index;

@end

NS_ASSUME_NONNULL_END
