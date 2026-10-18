#import "MBOptionParser.h"
#import "MBLaunchOptions.h"
#import "MBErrors.h"

NS_ASSUME_NONNULL_BEGIN

// 値の解析: 非負整数として解釈可能でなければ -1 を返す
static NSInteger ParseUnsignedInteger(NSString *text) {
    if (text.length == 0) return -1;
    // 数字以外の文字を 1 つでも含むなら非整数
    if ([text rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) {
        return -1;
    }
    return [text integerValue];
}

@implementation MBOptionParser

- (nullable MBLaunchOptions *)parseArguments:(NSArray<NSString *> *)arguments
                                       error:(NSError **)error {
    __block NSString *romPath = nil;
    __block NSUInteger scale = 0;
    __block NSUInteger volume = 0;
    __block BOOL scaleSet = NO;
    __block BOOL volumeSet = NO;
    __block NSError *failError = nil;
    __block BOOL failed = NO;

    void (^fail)(NSError *) = ^void(NSError *err) {
        failed = YES;
        failError = err;
    };

    NSUInteger argumentCount = arguments.count;
    NSUInteger index = 0;
    while (index < argumentCount) {
        NSString *arg = arguments[index];
        if ([arg isEqualToString:@"--scale"]) {
            index++;
            if (index >= argumentCount) {
                fail([NSError errorWithDomain:MBErrorDomain
                                         code:MBErrorCodeUsageError
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                         @"--scale には値(1〜8)が必要です"}]);
                break;
            }
            NSInteger value = ParseUnsignedInteger(arguments[index]);
            if (value < 1 || value > 8) {
                fail([NSError errorWithDomain:MBErrorDomain
                                         code:MBErrorCodeOptionOutOfRange
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             [NSString stringWithFormat:@"画面スケールは 1〜8 で指定してください(指定値: %@)", arguments[index]]}]);
                break;
            }
            scale = (NSUInteger)value;
            scaleSet = YES;
            index++;
            continue;
        }
        if ([arg isEqualToString:@"--volume"]) {
            index++;
            if (index >= argumentCount) {
                fail([NSError errorWithDomain:MBErrorDomain
                                         code:MBErrorCodeUsageError
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                         @"--volume には値(0〜100)が必要です"}]);
                break;
            }
            NSInteger value = ParseUnsignedInteger(arguments[index]);
            if (value < 0 || value > 100) {
                fail([NSError errorWithDomain:MBErrorDomain
                                         code:MBErrorCodeOptionOutOfRange
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             [NSString stringWithFormat:@"音量は 0〜100 で指定してください(指定値: %@)", arguments[index]]}]);
                break;
            }
            volume = (NSUInteger)value;
            volumeSet = YES;
            index++;
            continue;
        }
        if ([arg hasPrefix:@"--"]) {
            fail([NSError errorWithDomain:MBErrorDomain
                                     code:MBErrorCodeUsageError
                                 userInfo:@{NSLocalizedFailureReasonErrorKey:
                                         [NSString stringWithFormat:@"未知のオプションです: %@", arg]}]);
            break;
        }
        if (romPath != nil) {
            fail([NSError errorWithDomain:MBErrorDomain
                                     code:MBErrorCodeUsageError
                                 userInfo:@{NSLocalizedFailureReasonErrorKey:
                                         @"ROM ファイルは 1 つだけ指定できます"}]);
            break;
        }
        romPath = arg;
        index++;
    }

    if (failed) {
        if (error) *error = failError;
        return nil;
    }

    if (romPath == nil) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:MBErrorCodeROMNotSpecified
                                            userInfo:@{NSLocalizedFailureReasonErrorKey: @"ROM ファイルが指定されていません"}];
        return nil;
    }

    return [[MBLaunchOptions alloc] initWithROMPath:romPath
                                              scale:(scaleSet ? scale : 3)
                                      volumePercent:(volumeSet ? volume : 50)];
}

- (NSString *)usageText {
    return @"用法: MetalBoy [--scale 1-8] [--volume 0-100] <rom-path>\n"
           @"  <rom-path>   Game Boy ROM ファイルのパス(必須)\n"
           @"  --scale N    画面スケール 1〜8(既定 3)\n"
           @"  --volume P   音量 0〜100(既定 50)";
}

@end

NS_ASSUME_NONNULL_END
