#import "MBErrors.h"

NSErrorDomain const MBErrorDomain = @"MBErrorDomain";

NS_ASSUME_NONNULL_BEGIN

NSUInteger MBExitCodeForError(NSError *error) {
    if (error == nil) return 1;
    switch (error.code) {
        case MBErrorCodeUsageError:
        case MBErrorCodeOptionOutOfRange:
        case MBErrorCodeROMNotSpecified:
            return 2;
        default:
            return 1;
    }
}

NSString *MBUserFacingMessageForError(NSError *error) {
    if (error == nil) {
        return @"内部エラー(原因不明)";
    }
    // ユーザー向け 1 行は NSLocalizedFailureReasonErrorKey のみ。
    // localizedDescription は Foundation が英語の 既定文を自動生成するため使わない
    NSString *localized = error.localizedFailureReason;
    if (![error.domain isEqualToString:MBErrorDomain]) {
        // Core 層など別ドメインのエラーは分類を持たない → その層の理由を 1 行で出す
        return localized ?: @"起動中にエラーが発生しました";
    }
    switch (error.code) {
        case MBErrorCodeUsageError:
        case MBErrorCodeROMNotSpecified:
            return @"ROM ファイルを引数に指定してください(用法: MetalBoy [--scale 1-8] [--volume 0-100] <rom>)";
        case MBErrorCodeOptionOutOfRange:
            return localized ?: @"オプションの値が範囲外です";
        case MBErrorCodeROMNotFound:
            return localized ?: @"指定された ROM ファイルが存在しません";
        case MBErrorCodeInvalidROM:
            return localized ?: @"指定されたファイルは有効な Game Boy ROM ではありません";
        case MBErrorCodeUnsupportedMapper:
            return localized ?: @"対応していないカートリッジマッパーです(MBC0/1/2/3/5 のみ対応)";
        case MBErrorCodeCgbOnly:
            return localized ?: @"この ROM は Game Boy Color 専用のため、DMG 対応の本アプリでは非対応です";
        case MBErrorCodeSaveLoadFailed:
            return localized ?: @"セーブデータの読み込みに失敗しました";
        case MBErrorCodeSaveWriteFailed:
            return localized ?: @"セーブデータの保存に失敗しました";
        case MBErrorCodeWindowUnavailable:
            return localized ?: @"画面表示が利用できないため起動できません";
        case MBErrorCodeEmulationStartFailed:
            return localized ?: @"エミュレーション初期化に失敗しました";
        default:
            return localized ?: @"起動中にエラーが発生しました";
    }
}

NS_ASSUME_NONNULL_END
