#import "MBCartridge.h"
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

NSErrorDomain const MBCartridgeErrorDomain = @"MBCartridgeErrorDomain";

NS_ASSUME_NONNULL_BEGIN

// カートリッジ(ROM + MBC + SRAM + RTC 簡易)。
// 対応マッパー: MBC0/1/2/3(+RTC 簡易)/5(research R-6)。MBC7/MMM01 等は非対応エラー。

@interface MBCartridge ()
@property (nonatomic, readwrite) MBCartridgeType cartridgeType;
@property (nonatomic, readwrite) NSUInteger romSize;
@property (nonatomic, readwrite) NSUInteger ramSize;
@property (nonatomic, readwrite) BOOL hasBattery;
@property (nonatomic, readwrite) BOOL isCgbOnly;
@property (nonatomic, readwrite, copy) NSString *title;
@property (nonatomic, readwrite, nullable, copy) NSData *currentRAM;
@property (nonatomic, strong) NSMutableData *ram;   // SRAM 実体
@property (nonatomic) BOOL ramEnabled;
@property (nonatomic) NSUInteger romBankLow;
@property (nonatomic) NSUInteger romBankHigh;
@property (nonatomic) NSUInteger selectedROMBank;
@property (nonatomic) NSUInteger ramBank;
@property (nonatomic) BOOL mbc1RAMBankingMode;
@property (nonatomic) BOOL rtcSelected;
@property (nonatomic) BOOL rtcHalt;
@property (nonatomic) int64_t rtcLastTick;
@end

@implementation MBCartridge
{
    // RTC レジスタ(S/M/H/DL/DH)。配列はプロパティにできないため ivar 直保持
    uint8_t rtcRegisters[5];
}

#pragma mark - helpers

static NSUInteger BankCount(NSUInteger romSize) {
    return MAX(1, (NSUInteger)(romSize / 0x4000));
}

static BOOL IsSupportedCartridgeType(uint8_t t) {
    switch (t) {
        case 0x00: case 0x01: case 0x02: case 0x03:
        case 0x05: case 0x06:
        case 0x0F: case 0x10: case 0x11: case 0x12: case 0x13:
        case 0x19: case 0x1A: case 0x1B: case 0x1C: case 0x1D: case 0x1E:
            return YES;
        default:
            return NO;
    }
}

static NSUInteger RamSizeForHeaderByte(uint8_t b) {
    switch (b) {
        case 0: return 0;
        case 1: return 0x800;   // 2KiB
        case 2: return 0x2000;  // 8KiB
        case 3: return 0x8000;  // 32KiB
        case 4: return 0x20000; // 128KiB(MBC5 系)
        case 5: return 0x10000; // 64KiB(MBC5 系)
        default: return 0;
    }
}

static BOOL BatteryForHeaderByte(uint8_t t) {
    switch (t) {
        case 0x03: case 0x06: case 0x0F: case 0x10: case 0x13: case 0x1B: case 0x1E:
            return YES;
        default:
            return NO;
    }
}

static int64_t MonotonicNow(void) {
    return (int64_t)mach_absolute_time();
}

- (void)syncRTC {
    // 簡易実装: 経過時間の追跡のみ行い、時刻の厳密換算はしない(research R-6)
    self.rtcLastTick = MonotonicNow();
}

- (void)updateSelectedROMBank {
    NSUInteger banks = BankCount(self.romSize);
    NSUInteger selected = 1;
    switch (self.cartridgeType) {
        case MBCartridgeTypeROMOnly:
            selected = 1;
            break;
        case MBCartridgeTypeMBC1: {
            selected = self.romBankLow & 0x1F;
            if (selected == 0) selected = 1;
            if (self.mbc1RAMBankingMode) {
                selected |= (self.romBankHigh & 0x3) << 5;
            }
            break;
        }
        case MBCartridgeTypeMBC2: {
            selected = self.romBankLow & 0x0F;
            if (selected == 0) selected = 1;
            break;
        }
        case MBCartridgeTypeMBC3: {
            selected = self.romBankLow & 0x7F;
            if (selected == 0) selected = 1;
            break;
        }
        case MBCartridgeTypeMBC5: {
            selected = (NSUInteger)self.romBankLow | ((NSUInteger)self.romBankHigh << 8);
            break;
        }
    }
    self.selectedROMBank = selected % banks;
}

#pragma mark - init

- (nullable instancetype)initWithROMData:(NSData *)romData error:(NSError *_Nullable *_Nullable)error {
    self = [super init];
    if (!self) return nil;

    void (^fail)(NSInteger, NSString *) = ^(NSInteger code, NSString *message) {
        if (error) {
            *error = [NSError errorWithDomain:MBCartridgeErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedFailureReasonErrorKey: message ?: @""}];
        }
    };

    if (romData.length < 0x0150) {
        fail(MBCartridgeErrorCodeROMTooShort, @"ROM が小さすぎます(ヘッダ読取不可)");
        return nil;
    }
    const uint8_t *b = (const uint8_t *)romData.bytes;
    uint8_t typeByte = b[0x0147];

    if (!IsSupportedCartridgeType(typeByte)) {
        fail(MBCartridgeErrorCodeUnsupportedType,
             [NSString stringWithFormat:@"対応していないカートリッジタイプ: 0x%02X(MBC0/1/2/3/5 のみ)", typeByte]);
        return nil;
    }
    if (b[0x0143] == 0xC0) {
        fail(MBCartridgeErrorCodeCgbOnlyROM,
             @"Game Boy Color 専用 ROM は非対応です(対応ハード: DMG のみ)");
        return nil;
    }

    _romData = [romData copy];
    _romSize = romData.length;
    _ramSize = RamSizeForHeaderByte(b[0x0149]);
    _isCgbOnly = NO;
    _hasBattery = BatteryForHeaderByte(typeByte);

    switch (typeByte) {
        case 0x00: _cartridgeType = MBCartridgeTypeROMOnly; break;
        case 0x01: case 0x02: case 0x03: _cartridgeType = MBCartridgeTypeMBC1; break;
        case 0x05: case 0x06: _cartridgeType = MBCartridgeTypeMBC2; break;
        case 0x0F: case 0x10: case 0x11: case 0x12: case 0x13: _cartridgeType = MBCartridgeTypeMBC3; break;
        default: _cartridgeType = MBCartridgeTypeMBC5; break;
    }

    NSMutableString *title = [NSMutableString string];
    for (NSInteger i = 0x0134; i <= 0x0143 && i < (NSInteger)romData.length; i++) {
        unichar c = b[i];
        if (c == 0 || c < 0x20 || c > 0x7E) break;
        [title appendFormat:@"%C", c];
    }
    _title = [title copy];

    if (_ramSize > 0) {
        _ram = [NSMutableData dataWithLength:_ramSize];
        memset(_ram.mutableBytes, 0xFF, _ramSize);
    }
    _ramEnabled = NO;
    _rtcHalt = YES;
    _rtcLastTick = MonotonicNow();
    memset(rtcRegisters, 0, sizeof(rtcRegisters));
    [self updateSelectedROMBank];
    return self;
}

#pragma mark - ROM/SRAM access

- (uint8_t)romByteAtAddress:(uint16_t)address {
    if (address < 0x4000) {
        return [self byteAtRomAddress:address];
    }
    NSUInteger offset = (NSUInteger)(address - 0x4000) & 0x3FFF;
    return [self byteAtRomAddress:self.selectedROMBank * 0x4000 + offset];
}

- (uint8_t)byteAtRomAddress:(NSUInteger)addr {
    if (addr >= self.romSize) return 0xFF;
    const uint8_t *b = (const uint8_t *)self.romData.bytes;
    return b[addr];
}

- (uint8_t)sramByteAtAddress:(uint16_t)address {
    if (!self.ramEnabled) return 0xFF;
    if (self.cartridgeType == MBCartridgeTypeMBC3 && self.rtcSelected) {
        return [self rtcRegisterByte:(uint8_t)self.ramBank];
    }
    if (self.ramSize == 0) return 0xFF;
    NSUInteger idx = (address - 0xA000) & 0x1FFF;
    if (self.cartridgeType == MBCartridgeTypeMBC1 && self.mbc1RAMBankingMode) {
        idx += self.ramBank * 0x2000;
    }
    if (idx >= self.ramSize) return 0xFF;
    if (self.cartridgeType == MBCartridgeTypeMBC2) {
        return (uint8_t)(((const uint8_t *)self.ram.bytes)[idx] | 0xF0);
    }
    return ((const uint8_t *)self.ram.bytes)[idx];
}

- (void)writeSRAMByte:(uint8_t)value atAddress:(uint16_t)address {
    if (!self.ramEnabled) return;
    if (self.cartridgeType == MBCartridgeTypeMBC3 && self.rtcSelected) {
        [self writeRTCRegisterByte:value index:(uint8_t)self.ramBank];
        return;
    }
    if (self.ramSize == 0) return;
    NSUInteger idx = (address - 0xA000) & 0x1FFF;
    if (self.cartridgeType == MBCartridgeTypeMBC1 && self.mbc1RAMBankingMode) {
        idx += self.ramBank * 0x2000;
    }
    if (idx >= self.ramSize) return;
    uint8_t *bytes = (uint8_t *)self.ram.mutableBytes;
    if (self.cartridgeType == MBCartridgeTypeMBC2) {
        bytes[idx] = (uint8_t)(value & 0x0F);
    } else {
        bytes[idx] = value;
    }
    self.currentRAM = [self.ram copy];
}

#pragma mark - MBC control

- (void)writeControlByte:(uint8_t)value atAddress:(uint16_t)address {
    switch (self.cartridgeType) {
        case MBCartridgeTypeROMOnly:
            break;
        case MBCartridgeTypeMBC1: {
            if (address < 0x2000) {
                self.ramEnabled = ((value & 0x0F) == 0x0A);
            } else if (address < 0x4000) {
                self.romBankLow = value;
            } else if (address < 0x6000) {
                self.romBankHigh = value & 0x03;
            } else {
                self.mbc1RAMBankingMode = (value & 0x01) != 0;
            }
            break;
        }
        case MBCartridgeTypeMBC2: {
            if (address < 0x4000) {
                if ((address & 0x0100) == 0) {
                    self.ramEnabled = ((value & 0x0F) == 0x0A);
                } else {
                    self.romBankLow = value & 0x0F;
                }
            }
            break;
        }
        case MBCartridgeTypeMBC3: {
            if (address < 0x2000) {
                self.ramEnabled = ((value & 0x0F) == 0x0A);
            } else if (address < 0x4000) {
                self.romBankLow = value & 0x7F;
            } else if (address < 0x6000) {
                if (value >= 0x08 && value <= 0x0C) {
                    self.rtcSelected = YES;
                    self.ramBank = value & 0x0F;
                } else {
                    self.rtcSelected = NO;
                    self.ramBank = value & 0x07;
                }
            } else {
                [self syncRTC]; // RTC latch(簡易)
            }
            break;
        }
        case MBCartridgeTypeMBC5: {
            if (address < 0x2000) {
                self.ramEnabled = ((value & 0x0F) == 0x0A);
            } else if (address < 0x3000) {
                self.romBankLow = value;
            } else if (address < 0x4000) {
                self.romBankHigh = value & 0x01;
            } else if (address < 0x6000) {
                if (value < 0x10) {
                    self.ramBank = value & 0x0F;
                    self.rtcSelected = NO;
                }
            }
            break;
        }
    }
    [self updateSelectedROMBank];
}

#pragma mark - RTC(簡易)

- (uint8_t)rtcRegisterByte:(uint8_t)index {
    if (self.cartridgeType != MBCartridgeTypeMBC3) return 0;
    [self syncRTC];
    if (index < 5) return rtcRegisters[index];
    return 0xFF;
}

- (void)writeRTCRegisterByte:(uint8_t)value index:(uint8_t)index {
    if (self.cartridgeType != MBCartridgeTypeMBC3) return;
    if (index < 5) rtcRegisters[index] = value;
    if (index == 4) {
        self.rtcHalt = (value & 0x40) != 0;
    }
}

#pragma mark - Save / Restore

- (nullable NSData *)currentRAM {
    if (self.ramSize == 0) return nil;
    return [self.ram copy];
}

- (BOOL)restoreRAM:(NSData *)ram error:(NSError *_Nullable *_Nullable)error {
    if (self.ramSize == 0) {
        if (error) {
            *error = [NSError errorWithDomain:MBCartridgeErrorDomain
                                         code:MBCartridgeErrorCodeRAMSizeMismatch
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             @"このカートリッジにはセーブ用 RAM がありません"}];
        }
        return NO;
    }
    if (ram.length != self.ramSize) {
        if (error) {
            *error = [NSError errorWithDomain:MBCartridgeErrorDomain
                                         code:MBCartridgeErrorCodeRAMSizeMismatch
                                     userInfo:@{NSLocalizedFailureReasonErrorKey:
                                             [NSString stringWithFormat:@"セーブファイルのサイズが不一致です(期待: %lu バイト, 実際: %lu バイト)",
                                              (unsigned long)self.ramSize, (unsigned long)ram.length]}];
        }
        return NO;
    }
    self.ram = [ram mutableCopy];
    self.currentRAM = [ram copy];
    return YES;
}

@end

NS_ASSUME_NONNULL_END
