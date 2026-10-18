#import <Foundation/Foundation.h>
#import "MBCartridge.h"
#import "MBJoypad.h"
#import "MBPPU.h"
#import "MBApu.h"
#import "MBCPU.h"
#import "MBMemoryMap.h"

NS_ASSUME_NONNULL_BEGIN

/// コアのエミュレーションマシン: CPU・メモリ・PPU・APU・Joypad・カートリッジを
/// 接続し、フレーム単位で駆動する(MBEmulatorState 相当)。UI・OS 非依存(原則 VI)。
@interface MBGameBoy : NSObject

@property (nonatomic, readonly, strong) MBCPU *cpu;
@property (nonatomic, readonly, strong) MBMemoryMap *memory;
@property (nonatomic, readonly, strong) MBPPU *ppu;
@property (nonatomic, readonly, strong) MBApu *apu;
@property (nonatomic, readonly, strong) MBJoypad *joypad;
@property (nonatomic, readonly, strong) MBCartridge *cartridge;

/// 接続済みのマシンを作る(research R-5: BIOS なしの DMG 電源投入相当で初期化)
- (nullable instancetype)initWithCartridge:(MBCartridge *)cartridge error:(NSError *_Nullable *_Nullable)error;

/// 1 フレーム分駆動(70224 dots 相当)。返り値: フレームが完成したら YES
- (BOOL)runFrame;

/// Serial 出力(テスト ROM 判定・診断の収集)
@property (nonatomic, nullable, copy) void (^serialOutputHandler)(uint8_t byte);

/// 実 BIOS の optional 読み込み(デバッグ/検証用。nil なら BIOS なし $0100 開始)
@property (nonatomic, nullable, strong) NSData *bootROMData;
@end

NS_ASSUME_NONNULL_END
