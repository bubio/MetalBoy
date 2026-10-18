#import <Foundation/Foundation.h>
#import "MBJoypad.h"

NS_ASSUME_NONNULL_BEGIN

/// M-cycle 単位の CPU 周辺ハードへの接点(コア内部用)
@protocol MBCPUBus <NSObject>
- (uint8_t)cpuReadAddress:(uint16_t)address;
- (void)cpuWrite:(uint8_t)value address:(uint16_t)address;
/// 1 M-cycle 経過(4 T-cycle)。割り込み要求は戻り値として IF の OR を返す
- (uint8_t)cpuTickCycle;
/// IF レジスタ値の読み取り(割り込み処理判定用)
- (uint8_t)ifRegister;
/// IE レジスタ値の読み取り(HALT 唤醒判定用: IF & IE != 0 なら IME 無関係で解除)
- (uint8_t)ieRegister;
/// IF への書き込み(unimplemented 等の把握用は MBLogPort で)
- (void)setIfRegister:(uint8_t)value;
@end

/// Game Boy DMG CPU(SM83)。BIOS なし DMG 電源投入相当の初期値を持つ(research R-5)。
/// 命令は SM83 命令一式 + CB。タイマ・割り込みは bus 経由の IF に反映。
@interface MBCPU : NSObject

- (instancetype)init;   // DMG 起動時のレジスタ初期値(AF=01B0 BC=0013 DE=00D8 HL=014D SP=FFFE)
- (instancetype)initWithPowerOnStates; // 明示的初期化

/// 1 命令実行。返り値: 消費した M-cycle 数。halt 中は 1 を返す
- (NSUInteger)stepWithBus:(id<MBCPUBus>)bus;

/// ハードウェアレジスタへの簡易アクセス(テスト用)
@property (nonatomic, readonly) uint8_t registerA;
@property (nonatomic, readonly) uint8_t registerF;
@property (nonatomic, readonly) uint8_t registerB;
@property (nonatomic, readonly) uint8_t registerC;
@property (nonatomic, readonly) uint8_t registerD;
@property (nonatomic, readonly) uint8_t registerE;
@property (nonatomic, readonly) uint8_t registerH;
@property (nonatomic, readonly) uint8_t registerL;
@property (nonatomic, readonly) uint16_t sp;
@property (nonatomic, readonly) uint16_t pc;
/// 実 BIOS 駆動用(デバッグ/検証): pc を直接設定する。通常は BIOS なしで $0100 のまま
- (void)setPC:(uint16_t)pc;
/// 割り込みIME
@property (nonatomic, readonly) BOOL ime;

@end

NS_ASSUME_NONNULL_END
