#import "MBTestROMReport.h"
#import <stdio.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *MBLogEventName(MBLogEvent event) {
    switch (event) {
        case MBLogEventInfo: return @"info";
        case MBLogEventUnimplementedBehavior: return @"unimplemented";
        case MBLogEventEmulationError: return @"error";
    }
    return @"unknown";
}

@implementation MBTestROMReport {
    NSString *_romPath;
    NSUInteger _frames;
    NSMutableData *_serial;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_events;
}

- (instancetype)initWithROMPath:(NSString *)romPath frames:(NSUInteger)frames {
    self = [super init];
    if (self) {
        _romPath = [romPath copy];
        _frames = frames;
        _serial = [NSMutableData data];
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)appendSerialByte:(uint8_t)byte {
    [_serial appendBytes:&byte length:1];
}

- (NSString *)serialText {
    return [[NSString alloc] initWithData:_serial encoding:NSISOLatin1StringEncoding] ?: @"";
}

- (BOOL)passed {
    return [self.serialText containsString:@"Passed"];
}

- (void)logEvent:(MBLogEvent)event message:(NSString *)message {
    @synchronized (self) {
        [_events addObject:@{@"type": MBLogEventName(event), @"message": message}];
    }
}

- (NSData *)JSONData {
    NSDictionary *object;
    @synchronized (self) {
        object = @{
            @"rom": _romPath,
            @"frames": @(_frames),
            @"passed": @(self.passed),
            @"serial": self.serialText,
            @"events": [_events copy],
        };
    }
    return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
}

@end

@implementation MBStderrLogPort

- (void)logEvent:(MBLogEvent)event message:(NSString *)message {
    fprintf(stderr, "[%s] %s\n", MBLogEventName(event).UTF8String, message.UTF8String);
}

@end

NS_ASSUME_NONNULL_END
