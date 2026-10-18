#import <Foundation/Foundation.h>
#import "MBPorts.h"

NS_ASSUME_NONNULL_BEGIN

/// エミュレーションセッション(contracts/layer-ports.md)。UI 層は
/// renderPort / audioOutPort / inputPort の実装をセットする。
/// セッションがスレッドでフレーム駆動する(research R-2, 59.727fps 実時間)。
/// ヘッドレス使用時は、リポートに nil ポートを許容する(テスト ROM ランナー)。

@class MBLaunchOptions;

@interface MBEmulatorSession : NSObject <MBInputPort>

/// 生成は ROM 解析 → BIOS なし初期化 → セーブ復元(FR-013)。解析/検証エラーは
/// error に 1:1 分類の NSError(FR-011) を設定して nil を返す
- (nullable instancetype)initWithOptions:(MBLaunchOptions *)options
                                   error:(NSError *_Nullable *_Nullable)error;

/// ポート(UI が実装を投入。NULL 許可=ヘッドレス)
@property (nonatomic, nullable, strong) id<MBRenderPort> renderPort;
@property (nonatomic, nullable, strong) id<MBAudioOutPort> audioOutPort;
@property (nonatomic, nullable, strong) id<MBInputPort> inputPort;
@property (nonatomic, nullable, strong) id<MBLogPort> logPort;

/// 実時間でエミュレーションを開始する(別スレッド)。stop を呼ぶまで戻らない
- (void)run;

/// クリーン停止: セーブ書出し → リソース解放(FR-010)。書込み失敗は error を返す
- (BOOL)stopAndReturnError:(NSError **)error;

/// 停止済みか
@property (nonatomic, readonly) BOOL stopped;

/// ヘッドレス駆動用: 指定フレーム数を可能な限り短時間で走らせる(research R-9)
- (void)runFrames:(NSUInteger)frames;

/// Serial 出力収集(テスト ROM 判定・診断用)。nil でクリア
@property (nonatomic, nullable, copy) void (^serialOutputHandler)(uint8_t byte);

/// 実行中のフレーム数(デバッグ・テスト用)
@property (nonatomic, readonly) NSUInteger frameCount;

@end

NS_ASSUME_NONNULL_END
