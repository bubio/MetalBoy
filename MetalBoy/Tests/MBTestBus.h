#import <Foundation/Foundation.h>
#import "MBCPU.h"

NS_ASSUME_NONNULL_BEGIN

/// CPU 単体テスト用の簡易バス: 64KB の RAM そのままで MBCPUBus を実装
@interface MBTestBus : NSObject <MBCPUBus>

/// $0000-$FFFF
@property (nonatomic, strong) NSMutableData *memory;
/// IE 値(HALT 唤醒テスト用に変更可能)
@property (nonatomic, readwrite) uint8_t ieRegisterValue;
/// IF 値(割り込み処理テスト用。get/set とも実値を保持)
@property (nonatomic, readwrite) uint8_t busIfRegister;

- (void)loadProgram:(NSArray<NSNumber *> *)bytes atAddress:(uint16_t)address;
- (uint8_t)byteAt:(uint16_t)address;
@property (nonatomic, readonly) uint8_t lastTickCycle;

@end

NS_ASSUME_NONNULL_END
