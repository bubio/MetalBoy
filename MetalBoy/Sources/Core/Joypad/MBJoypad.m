#import "MBJoypad.h"

NS_ASSUME_NONNULL_BEGIN

// $FF00 P1: bit4=0 → 方向キー行選択 / bit5=0 → ボタン行選択。
// 下位 4bit は「押されているボタンを 0」として返る(ハードウェア仕様に準拠)。
// pressedMask: bit0=Right bit1=Left bit2=Up bit3=Down bit4=A bit5=B bit6=Select bit7=Start(1=押下)

@implementation MBJoypad

- (instancetype)init {
    self = [super init];
    if (self) {
        _pressedMask = 0;    // 何も押されていない
        _selectDirectionKeys = NO;
        _selectButtonKeys = NO;
    }
    return self;
}

- (uint8_t)buttonStateMask {
    // 押下ビットはHardware どおり「押下=0」として写像する。両行選択時は OR 結線相当
    uint8_t direction = (uint8_t)(self.pressedMask & 0x0F);
    uint8_t buttons   = (uint8_t)((self.pressedMask >> 4) & 0x0F);
    uint8_t state = 0x0F;
    if (self.selectDirectionKeys) state &= (uint8_t)(~direction & 0x0F);
    if (self.selectButtonKeys)    state &= (uint8_t)(~buttons & 0x0F);
    return state;
}

- (uint8_t)registerValue {
    uint8_t result = 0xF0; // bit6/7 常時 1(DMG 未使用)・bit4/5=選択解除既定
    if (self.selectDirectionKeys) result &= (uint8_t)~0x10;
    if (self.selectButtonKeys)    result &= (uint8_t)~0x20;
    result |= [self buttonStateMask]; // bit3-0 にボタン状態(押下=0)
    return result;
}

@end

NS_ASSUME_NONNULL_END
