#import "MBTestBus.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBTestBus ()
@property (nonatomic, readwrite) uint8_t lastTickCycle;
@end

@implementation MBTestBus

- (instancetype)init {
    self = [super init];
    if (self) {
        _memory = [NSMutableData dataWithLength:0x10000];
        _lastTickCycle = 0;
    }
    return self;
}

- (void)loadProgram:(NSArray<NSNumber *> *)bytes atAddress:(uint16_t)address {
    NSUInteger i = 0;
    for (NSNumber *value in bytes) {
        [self writeByte:(uint8_t)value.intValue at:(uint16_t)(address + i)];
        i++;
    }
}

- (void)writeByte:(uint8_t)value at:(uint16_t)address {
    ((uint8_t *)self.memory.mutableBytes)[address] = value;
}

- (uint8_t)byteAt:(uint16_t)address {
    return ((const uint8_t *)self.memory.bytes)[address];
}

#pragma mark - MBCPUBus

- (uint8_t)cpuReadAddress:(uint16_t)address {
    return [self byteAt:address];
}

- (void)cpuWrite:(uint8_t)value address:(uint16_t)address {
    [self writeByte:value at:address];
}

- (uint8_t)cpuTickCycle {
    self.lastTickCycle++;
    return 0;
}

- (uint8_t)ifRegister { return self.busIfRegister; }

- (void)setIfRegister:(uint8_t)value {
    self.busIfRegister = value;
}

- (uint8_t)ieRegister { return self.ieRegisterValue; }

@end

NS_ASSUME_NONNULL_END
