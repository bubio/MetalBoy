#import "MBSaveFile.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const MBSaveFileErrorDomain = @"MBSaveFileErrorDomain";

@implementation MBSaveFile

+ (NSString *)saveFilePathForROMPath:(NSString *)romPath {
    NSString *directory = [romPath stringByDeletingLastPathComponent];
    if (directory.length == 0) directory = @".";
    NSString *baseName = [[romPath lastPathComponent] stringByDeletingPathExtension];
    return [directory stringByAppendingPathComponent:[baseName stringByAppendingString:@".sav"]];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
    }
    return self;
}

- (nullable NSData *)loadWithError:(NSError **)error {
    NSString *path = self.path;
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:path]) {
        return nil; // 無ければ nil(エラーにもしない・FR-013/FR-014)
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
    if (data == nil) {
        if (error) {
            *error = [NSError errorWithDomain:MBSaveFileErrorDomain
                                         code:MBSaveFileErrorCodeReadFailed
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             [NSString stringWithFormat:@"セーブデータ '%@' を読み込めませんでした", path]}];
        }
        return nil;
    }
    return data;
}

- (BOOL)saveData:(NSData *)data error:(NSError **)error {
    NSString *path = self.path;
    NSError *writeError = nil;
    BOOL wrote = [data writeToFile:path options:NSDataWritingAtomic error:&writeError];
    if (!wrote) {
        // 統一ドメインのエラーに変換して返す(失敗理由は 1 行の日本語メッセージに集約)
        if (error) {
            NSString *reason = writeError.localizedFailureReason
                ?: writeError.localizedDescription
                ?: @"書き込み先にアクセスできません";
            *error = [NSError errorWithDomain:MBSaveFileErrorDomain
                                         code:MBSaveFileErrorCodeWriteFailed
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             [NSString stringWithFormat:@"セーブデータ '%@' を保存できませんでした(%@)", path, reason]}];
        }
        return NO;
    }
    return YES;
}

@end

NS_ASSUME_NONNULL_END
