#import <Foundation/Foundation.h>
#import "MBJoypad.h"
#import "MBCartridge.h"

NS_ASSUME_NONNULL_BEGIN

/// 機能層で UI 固有依存を排除したポート群(憲法原則 VI / contracts/layer-ports.md)。
/// プロトコルのみをここに配置し、OS 固有実装は UI 層が提供する。

#pragma mark - Input

/// Game Boy ボタン(UI → 機能層の入力写像用)
typedef NS_ENUM(NSUInteger, MBButton) {
    MBButtonUp,
    MBButtonDown,
    MBButtonLeft,
    MBButtonRight,
    MBButtonA,
    MBButtonB,
    MBButtonStart,
    MBButtonSelect,
};

@protocol MBInputPort <NSObject>
- (void)setButton:(MBButton)button pressed:(BOOL)pressed;
@end

#pragma mark - Rendering

@protocol MBRenderPort <NSObject>
/// コアが生成した 160x144 RGBA8 ピクセル列(4 バイト/ピクセル)の供給受付。
/// 実装側で拡大表示等を行う(research R-2)。pixels は NULL 終端ではなく固定 160*144 長。
- (void)presentFramebuffer:(const uint32_t *)pixels;
@end

#pragma mark - Audio

@protocol MBAudioOutPort <NSObject>
/// コアが生成した PCM サンプルの供給受付(ステレオ int16、2 サンプル単位/フレーム)。
/// 音量の適用とキュー管理は UI 側の責務(research R-3)
- (void)enqueueSamples:(const int16_t *)samples count:(NSUInteger)count;
@end

#pragma mark - Log

typedef NS_ENUM(NSUInteger, MBLogEvent) {
    MBLogEventInfo,
    MBLogEventUnimplementedBehavior, // 未実装・未確定挙動の記録(憲法 V)
    MBLogEventEmulationError,
};

@protocol MBLogPort <NSObject>
- (void)logEvent:(MBLogEvent)event message:(NSString *)message;
@end

NS_ASSUME_NONNULL_END
