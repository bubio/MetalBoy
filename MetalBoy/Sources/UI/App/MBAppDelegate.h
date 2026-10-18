#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// アプリ本体(MetalBoy アプリターゲット)。CLI から起動され、
/// 引数解析 → セッション生成 → ウィンドウ・音声起動。GUI はこのファイル群だけ(UI 層)。
@interface MBAppDelegate : NSObject <NSApplicationDelegate>

/// CLI 起動の本体。返り値はプロセス終了コード(0/1/2)。GUI 起動後に再帰しない。
- (int)applicationMain;

@end

NS_ASSUME_NONNULL_END
