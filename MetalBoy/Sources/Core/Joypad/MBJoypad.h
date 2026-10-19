#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Game Boy ボタン(data-model.md MBKeyMapping 対応・FR-008)
typedef NS_OPTIONS(NSUInteger, MBJoypadButtonMask) {
    MBJoypadButtonRight  = 1 << 0,
    MBJoypadButtonLeft   = 1 << 1,
    MBJoypadButtonUp     = 1 << 2,
    MBJoypadButtonDown   = 1 << 3,
    MBJoypadButtonA      = 1 << 4,
    MBJoypadButtonB      = 1 << 5,
    MBJoypadButtonSelect = 1 << 6,
    MBJoypadButtonStart  = 1 << 7,
};

/// Game Boy Joypad($FF00 P1)。コア層・UI 非依存
@interface MBJoypad : NSObject

/// 現在押されているボタンの集合(押下=bit 0)
/// bit0=Right bit1=Left bit2=Up bit3=Down bit4=A bit5=B bit6=Select bit7=Start
/// 矢印/AB/Start/Select はこの定義に対応(上: bit0..3 は GC 的方向、bit4..7 は ボタン)
@property (nonatomic) uint8_t pressedMask;

/// $FF00 最終書込み値の bit5/4 ラッチ(読み戻し bit5/4 はこの値そのもの)。
/// bit5/4=0 はセレクトライン駆動低(該当行が結線)を意味する。
@property (nonatomic) uint8_t registerLatch;

/// $FF00 読み取り値(押下 bit は反転される: 未押下=1)
- (uint8_t)registerValue;
/// 押されている方向キー/ボタン列を 8bit マスクへ写像
- (uint8_t)buttonStateMask;

@end

NS_ASSUME_NONNULL_END
