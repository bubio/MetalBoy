#import <Foundation/Foundation.h>
#import "MBPorts.h"

NS_ASSUME_NONNULL_BEGIN

/// テスト ROM 実行結果(シリアル出力 + ログイベント)。人間可読テキストと機械可読 JSON の
/// 両方で報告する(憲法 V)。MBLogPort として MBEmulatorSession に接続できる。
@interface MBTestROMReport : NSObject <MBLogPort>

- (instancetype)initWithROMPath:(NSString *)romPath frames:(NSUInteger)frames;
- (instancetype)init NS_UNAVAILABLE;

- (void)appendSerialByte:(uint8_t)byte;

/// シリアル出力(Latin-1 としてテキスト化)
@property (nonatomic, readonly, copy) NSString *serialText;
/// blargg 形式の合格判定(シリアル出力に "Passed" を含む)
@property (nonatomic, readonly) BOOL passed;

/// {"rom", "frames", "passed", "serial", "events": [{"type", "message"}]}
- (NSData *)JSONData;

@end

/// ログイベントを stderr へ 1 行ずつ出力する LogPort(人間可読)
@interface MBStderrLogPort : NSObject <MBLogPort>
@end

NS_ASSUME_NONNULL_END
