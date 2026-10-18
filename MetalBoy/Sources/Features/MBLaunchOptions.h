#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 起動オプション(data-model.md MBLaunchOptions)。永続化なし・プロセス寿命のみ有効(FR-006)
@interface MBLaunchOptions : NSObject

/// ROM ファイルパス(必須)
@property (nonatomic, readonly, copy) NSString *romPath;
/// 画面スケール x1〜x8(既定 x3・FR-003)
@property (nonatomic, readonly) NSUInteger scale;
/// 音量 0〜100%(既定 50・FR-004)
@property (nonatomic, readonly) NSUInteger volumePercent;

- (instancetype)initWithROMPath:(NSString *)romPath scale:(NSUInteger)scale volumePercent:(NSUInteger)volumePercent;

@end

NS_ASSUME_NONNULL_END
