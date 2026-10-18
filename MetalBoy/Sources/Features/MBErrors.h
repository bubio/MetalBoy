#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// エラー基盤(FR-011 / contracts/cli.md)。すべての起動失敗原因を分類し、
/// CLI 終了コード(1=ランタイム, 2=引数)への写像を提供する。日本語メッセージ。
extern NSErrorDomain const MBErrorDomain;

typedef NS_ERROR_ENUM(MBErrorDomain, MBErrorCode) {
    MBErrorCodeUsageError            = 1, // 引数エラー(exit 2)
    MBErrorCodeOptionOutOfRange      = 2, // 範囲外オプション(exit 2)
    MBErrorCodeROMNotSpecified       = 3, // ROM 未指定(exit 2)
    MBErrorCodeROMNotFound           = 4, // ROM 不在(exit 1)
    MBErrorCodeInvalidROM            = 5, // 無効 ROM(exit 1)
    MBErrorCodeUnsupportedMapper     = 6, // 非対応マッパー(exit 1)
    MBErrorCodeCgbOnly               = 7, // CGB 専用(exit 1)
    MBErrorCodeSaveLoadFailed        = 8, // セーブ読込失敗(exit 1)
    MBErrorCodeSaveWriteFailed       = 9, // セーブ書込み失敗(exit 1)
    MBErrorCodeWindowUnavailable     = 10,// GUI 利用不可(exit 1)
    MBErrorCodeEmulationStartFailed  = 11,// 起動処理の失敗(exit 1)
};

/// エラーから CLI 終了コードを写像(contracts/cli.md: 1=ランタイム, 2=引数)
NSUInteger MBExitCodeForError(NSError *error);

/// ユーザー向け 1 行メッセージ(日本語・FR-011)
NSString *MBUserFacingMessageForError(NSError *error);

NS_ASSUME_NONNULL_END
