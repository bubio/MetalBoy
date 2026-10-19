#import "MBJoypad.h"

NS_ASSUME_NONNULL_BEGIN

// $FF00 P1: bit5/4 は「最後に書込んだ値」を読み戻す(物理セレクトライン: bit=0 が駆動)。
// bit4=0 → 方向キー行結線 / bit5=0 → ボタン行結線。両ビット 0 なら両行の OR。
// bit3-0 は結線行の押下状態(押下=0)。bit7/6 は読み出し常時 1。
// pressedMask: bit0=Right bit1=Left bit2=Up bit3=Down bit4=A bit5=B bit6=Select bit7=Start(1=押下)

@implementation MBJoypad

- (instancetype)init {
    self = [super init];
    if (self) {
        _pressedMask = 0;    // 何も押されていない
        _registerLatch = 0x00; // 電源投入既定(DMG: bit5/4=0 両行駆動 → $FF00 読みは $CF)
    }
    return self;
}

- (uint8_t)buttonStateMask {
    // 押下ビットはHardware どおり「押下=0」として写像する。両行選択時は OR 結線相当
    uint8_t direction = (uint8_t)(self.pressedMask & 0x0F);
    uint8_t buttons   = (uint8_t)((self.pressedMask >> 4) & 0x0F);
    uint8_t state = 0x0F;
    if (!(self.registerLatch & 0x10)) state &= (uint8_t)~direction; // bit4=0 で方向行駆動
    if (!(self.registerLatch & 0x20)) state &= (uint8_t)~buttons;   // bit5=0 でボタン行駆動
    return state;
}

- (uint8_t)registerValue {
    // bit7/6 常時 1。bit5/4 は最後の $FF00 書込み値を読み戻す(物理セレクトライン相当)。
    // bit3-0 は選択行の押下状態(押下=0)。
    uint8_t result = (uint8_t)(0xC0 | (self.registerLatch & 0x30));
    result |= [self buttonStateMask]; // bit3-0 にボタン状態(押下=0)
    return result;
}

@end

NS_ASSUME_NONNULL_END
