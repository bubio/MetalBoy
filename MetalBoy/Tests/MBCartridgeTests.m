#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import "MBCartridge.h"

NS_ASSUME_NONNULL_BEGIN

static void WriteHeaderByte(uint8_t *rom, uint16_t address, uint8_t value) {
    rom[address] = value;
}

/// 最小 ROM の作成(0x8000・MBC0)
static NSData *MakeROM0(void) {
    uint8_t rom[0x8000];
    for (NSUInteger i = 0; i < sizeof(rom); i++) {
        rom[i] = (uint8_t)(i & 0xFF);
    }
    WriteHeaderByte(rom, 0x0147, 0x00); // ROM only
    WriteHeaderByte(rom, 0x0149, 0x00); // RAM size 0
    return [NSData dataWithBytes:rom length:sizeof(rom)];
}

/// MBC1 + 8KB RAM
static NSData *MakeROM1(void) {
    uint8_t rom[0x8000];
    for (NSUInteger i = 0; i < sizeof(rom); i++) {
        rom[i] = (uint8_t)((i / 0x4000) * 0x10 + (i & 0xFF));
    }
    WriteHeaderByte(rom, 0x0147, 0x01); // MBC1
    WriteHeaderByte(rom, 0x0149, 0x02); // RAM 8KB
    return [NSData dataWithBytes:rom length:sizeof(rom)];
}

@interface MBCartridgeTests : XCTestCase
@end

@implementation MBCartridgeTests

- (void)testValidROM0 {
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:MakeROM0() error:&error];
    XCTAssertNotNil(cart);
    XCTAssertEqual(cart.cartridgeType, MBCartridgeTypeROMOnly);
    XCTAssertEqual(cart.ramSize, 0);
    XCTAssertFalse(cart.hasBattery);
}

- (void)testROMTooShort {
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:[NSMutableData dataWithLength:0x50] error:&error];
    XCTAssertNil(cart);
    XCTAssertNotNil(error);
}

- (void)testCgbOnlyRejected {
    uint8_t rom[0x8000];
    memset(rom, 0, sizeof(rom));
    rom[0x0147] = 0x00;
    rom[0x0143] = 0xC0;
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:[NSData dataWithBytes:rom length:sizeof(rom)] error:&error];
    XCTAssertNil(cart);
    XCTAssertEqual(error.code, MBCartridgeErrorCodeCgbOnlyROM);
}

- (void)testMBC1BankSwitch {
    // ラベル的なバンク内容が違うことを、バンク1 に切り換えて確認
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:MakeROM1() error:&error];
    XCTAssertNotNil(cart);
    XCTAssertEqual(cart.cartridgeType, MBCartridgeTypeMBC1);
    XCTAssertEqual(cart.ramSize, 0x2000);
    // 初期バンク 1
    XCTAssertEqual([cart romByteAtAddress:0x4000], (uint8_t)((1 * 0x10 + 0) & 0xFF));
    // バンク 1 が 32KB ROM に収まるため、2 以上は折り返し
    [cart writeControlByte:0x02 atAddress:0x2000];
    XCTAssertEqual([cart romByteAtAddress:0x4000], (uint8_t)0x00); // bank 2 % 2 = 0 → bank 0
}

- (void)testSRAMAccess {
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:MakeROM1() error:&error];
    XCTAssertNotNil(cart);
    // 無効状態では既定 0xFF
    XCTAssertEqual([cart sramByteAtAddress:0xA000], 0xFF);
    // RAM 有効化 → 書込み
    [cart writeControlByte:0x0A atAddress:0x0000];
    [cart writeSRAMByte:0x42 atAddress:0xA001];
    XCTAssertEqual([cart sramByteAtAddress:0xA001], 0x42);
    // 有効化解除 → 0xFF(無効状態では読めない)
    [cart writeControlByte:0x00 atAddress:0x0000];
    XCTAssertEqual([cart sramByteAtAddress:0xA001], 0xFF);
}

- (void)testSaveAndRestoreRAM {
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:MakeROM1() error:&error];
    XCTAssertNotNil(cart);
    [cart writeControlByte:0x0A atAddress:0x0000];
    [cart writeSRAMByte:0xAB atAddress:0xA000];
    NSData *ram = cart.currentRAM;
    XCTAssertEqual(ram.length, 0x2000);
    XCTAssertEqual(((const uint8_t *)ram.bytes)[0], 0xAB, "SRAM の書込みが currentRAM に反映される");

    NSError *restoreError = nil;
    MBCartridge *cart2 = [[MBCartridge alloc] initWithROMData:MakeROM1() error:&restoreError];
    XCTAssertNotNil(cart2);
    XCTAssertTrue([cart2 restoreRAM:ram error:&restoreError]);
    XCTAssertEqual([cart2 sramByteAtAddress:0xA000], 0xFF, "RAM 無効中は 0xFF(初期化後は ramEnabled=NO)");
    // サイズ不一致は失敗
    NSError *mismatch = nil;
    NSData *shortData = [NSMutableData dataWithLength:16];
    XCTAssertFalse([cart2 restoreRAM:shortData error:&mismatch]);
    XCTAssertEqual(mismatch.code, MBCartridgeErrorCodeRAMSizeMismatch);
}

@end

NS_ASSUME_NONNULL_END
