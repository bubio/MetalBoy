#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// セーブファイルの読み書き(FR-013/FR-014 / research R-7)。
/// パスは `<ROM ベース名>.sav`(ROM と同じディレクトリ)。内容は SRAM の生ダンプ。
/// 破損・サイズ不一致・読取不能は黙って上書きせずエラーで失敗する。
extern NSErrorDomain const MBSaveFileErrorDomain;

typedef NS_ERROR_ENUM(MBSaveFileErrorDomain, MBSaveFileErrorCode) {
    MBSaveFileErrorCodeSizeMismatch = 1,
    MBSaveFileErrorCodeReadFailed   = 2,
    MBSaveFileErrorCodeWriteFailed  = 3,
};

@interface MBSaveFile : NSObject

/// ROM パスから対応する .sav パスを導出
+ (NSString *)saveFilePathForROMPath:(NSString *)romPath;

/// 指定パスで .sav を扱う
- (instancetype)initWithPath:(NSString *)path;

/// セーブデータを読み込む。ファイルが存在しない場合 nil + nil エラー(起動は続行)
- (nullable NSData *)loadWithError:(NSError **)error;

/// セーブデータを書き出す。失敗は NSError(FR-013 の書出し経路)
- (BOOL)saveData:(NSData *)data error:(NSError **)error;

@property (nonatomic, readonly, copy) NSString *path;

@end

NS_ASSUME_NONNULL_END
