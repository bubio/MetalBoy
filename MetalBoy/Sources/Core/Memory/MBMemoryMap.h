#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ゲーム状態を束ねる最小のバス。MBGameBoy が組み立てに使う。
/// BUS アドレス($0000-$FFFF)の read/write 責務。
@interface MBMemoryMap : NSObject

- (instancetype)init;

/// WRAM($C000-$DFFF + エコー)/ HRAM($FF80-$FFFE)/ IE($FFFF)/ IF($FF0F)/
/// IO($FF00-$FF7F)/ Serial($FF01-$FF02)/ Timer($FF04-$FF07)/ IO($FF46 DMA)
- (uint8_t)read8:(uint16_t)address;
- (void)write8:(uint8_t)value address:(uint16_t)address;

/// DIV/TIMA も 4 T-cycle(1 M-cycle)毎に tick
- (void)tickCycle;

/// IF レジスタ(割り込み要求ビット)。IO から設定もなされる
/// BIOS なし起動用: DMG BIOS 終了時($0100)の IF と DIV 内部カウンタにする
- (void)applyPostBootStateWithDivCounter:(uint16_t)divCounter;
@property (nonatomic, readwrite) uint8_t ifRegister;
@property (nonatomic, readwrite) uint8_t ieRegister;

/// DMA 転送($FF46)で OAM への書込みをここに通知(PPU へのブリッジ。
/// 転送は dmaWriteOAM:address: を使用・CPU 書込み抑制とは別経路)
@property (nonatomic, nullable, strong) id oamTarget; // MBPPU(writeOAM:address:)レスポンダ
/// Serial 出力の収集先(NSTextBlock 階層に縛らず block で)
@property (nonatomic, nullable, copy) void (^serialOutputHandler)(uint8_t byte);
/// Joypad(DMG: $FF00)操作オブジェクト
@property (nonatomic, nullable, strong) id joypadTarget;
/// PPU
@property (nonatomic, nullable, strong) id ppuTarget;
/// APU
@property (nonatomic, nullable, strong) id apuTarget;
/// カートリッジ
@property (nonatomic, nullable, strong) id cartridgeTarget;

@end

NS_ASSUME_NONNULL_END
