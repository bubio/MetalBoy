#import "MBLaunchOptions.h"

NS_ASSUME_NONNULL_BEGIN

@implementation MBLaunchOptions

- (instancetype)initWithROMPath:(NSString *)romPath scale:(NSUInteger)scale volumePercent:(NSUInteger)volumePercent {
    self = [super init];
    if (self) {
        _romPath = [romPath copy];
        _scale = scale;
        _volumePercent = volumePercent;
    }
    return self;
}

@end

NS_ASSUME_NONNULL_END
