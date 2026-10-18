#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "MBPorts.h"

NS_ASSUME_NONNULL_BEGIN

/// Game Boy 画面のウィンドウ(MTLView)。MBRenderPort を実装し、
/// コアが供給した 160x144 RGBA8 をスケール倍でニアレストサンプリング表示する。
@interface MBWindowController : NSWindowController <MBRenderPort>

- (instancetype)initWithCGSize:(CGSize)contentSize;

@end

NS_ASSUME_NONNULL_END
