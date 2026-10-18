#import "MBWindowController.h"

NS_ASSUME_NONNULL_BEGIN

// ニアレストサンプリングのフラグメントシェーダ(MSL ソースをランタイムコンパイル)
static NSString * const kShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 texCoord;\n"
"};\n"
"\n"
"vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {\n"
"    const float2 positions[4] = {\n"
"        float2(-1.0, -1.0), float2(1.0, -1.0),\n"
"        float2(-1.0,  1.0), float2(1.0,  1.0),\n"
"    };\n"
"    const float2 coords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };\n"
"    VertexOut out;\n"
"    out.position = float4(positions[vid], 0.0, 1.0);\n"
"    out.texCoord = coords[vid];\n"
"    return out;\n"
"}\n"
"\n"
"fragment float4 fullscreenFragment(VertexOut in [[stage_in]],\n"
"                                   texture2d<float> tex [[texture(0)]]) {\n"
"    constexpr sampler s(address::clamp_to_edge, filter::nearest);\n"
"    return tex.sample(s, in.texCoord);\n"
"}\n";

@interface MBWindowController () <MTKViewDelegate>
@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, strong) NSMutableData *pixelBuffer; // 最新フレーム
@end

@implementation MBWindowController

- (instancetype)initWithCGSize:(CGSize)contentSize {
    NSRect frame = NSMakeRect(0, 0, contentSize.width, contentSize.height);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window center];
    window.title = @"MetalBoy";
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (self) {
        _device = MTLCreateSystemDefaultDevice();
        if (_device == nil) {
            // Metal 非対応環境は呼び出し側で presentation 失敗として扱う
            return self;
        }
        _commandQueue = [_device newCommandQueue];

        // Metal ビュー
        MTKView *view = [[MTKView alloc] initWithFrame:frame device:_device];
        view.delegate = self;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.drawableSize = CGSizeMake(contentSize.width, contentSize.height);
        window.contentView = view;
        _mtkView = view;

        // フレームテクスチャ(160x144 RGBA8)
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                             width:160
                                                                                            height:144
                                                                                         mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        _texture = [_device newTextureWithDescriptor:descriptor];
        _pixelBuffer = [NSMutableData dataWithLength:160 * 144 * 4];

        // シェーダからパイプライン生成
        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithSource:kShaderSource options:nil error:&error];
        if (library == nil) {
            NSLog(@"Metal shader compile failed: %@", error.localizedDescription);
        } else {
            MTLRenderPipelineDescriptor *pipeline = [[MTLRenderPipelineDescriptor alloc] init];
            pipeline.vertexFunction = [library newFunctionWithName:@"fullscreenVertex"];
            pipeline.fragmentFunction = [library newFunctionWithName:@"fullscreenFragment"];
            pipeline.colorAttachments[0].pixelFormat = view.colorPixelFormat;
            _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipeline error:&error];
        }
    }
    return self;
}

#pragma mark - MBRenderPort(エミュレーションスレッドから呼ばれる)

- (void)presentFramebuffer:(const uint32_t *)pixels {
    if (pixels == nil) return;
    @synchronized (self.pixelBuffer) {
        memcpy(self.pixelBuffer.mutableBytes, pixels, 160 * 144 * 4);
    }
    // 表示は MTKViewDelegate(drawInMTKView:)に任せる
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view {
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (drawable == nil || self.pipelineState == nil || self.texture == nil) return;

    @synchronized (self.pixelBuffer) {
        [self.texture replaceRegion:MTLRegionMake2D(0, 0, 160, 144)
                        mipmapLevel:0
                          withBytes:self.pixelBuffer.bytes
                        bytesPerRow:160 * 4];
    }

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (pass == nil) return;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setFragmentTexture:self.texture atIndex:0];
        // フル画面クアッド描画
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // ピクセルは常に処理サイズ(160x144)で供給し、ビューはスケールして表示。
    view.drawableSize = CGSizeMake(MAX(160, size.width), MAX(144, size.height));
}

@end

NS_ASSUME_NONNULL_END
