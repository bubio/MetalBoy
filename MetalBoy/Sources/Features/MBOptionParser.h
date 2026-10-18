#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class MBLaunchOptions;

/// CLI 引数契約(contracts/cli.md)の解析。範囲外は既定値への
/// フォールバックを行わず必ずエラーで失敗する(FR-005)。
/// 許容形式: `[--scale N] [--volume P] <rom-path>`。オプション/位置引数の
/// 順序は不問。同一オプションの重複は最後の値を採用(テスト容易性の既定動作)。
@interface MBOptionParser : NSObject

typedef NS_ENUM(NSUInteger, MBParserFailure) {
    MBParserFailureUsage                 = 1, // 使い方
    MBParserFailureOptionOutOfRange      = 2,
    MBParserFailureROMNotSpecified       = 3,
    MBParserFailureTooManyPositional     = 4,
    MBParserFailureUnknownOption         = 5,
    MBParserFailureMissingOptionValue    = 6,
};

- (nullable MBLaunchOptions *)parseArguments:(NSArray<NSString *> *)arguments
                                       error:(NSError *_Nullable *_Nullable)error;

/// 使用法の 1 行説明(stdout は使わず stderr 用)
- (NSString *)usageText;

@end

NS_ASSUME_NONNULL_END
