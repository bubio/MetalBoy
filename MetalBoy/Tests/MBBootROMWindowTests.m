#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import "MBGameBoy.h"
#import "MBCPU.h"
#import "MBCartridge.h"

NS_ASSUME_NONNULL_BEGIN

/// 実 BIOS optional 実装の回帰テスト。
/// CGB ブート ROM は $0000-$00FF+$0200-$08FF の分割配置だが、DMG ブート ROM は
/// 256 バイト($0000-$00FF)のみ。本機は DMG 専用なので $0100 以降は常にカートリッジから
/// 読むこと(実 Tetris で割込み内 $0200+ のオペコードが BIOS 側から読まれ暴走した回帰)。
@interface MBBootROMWindowTests : XCTestCase
@end

@implementation MBBootROMWindowTests

/// カートリッジ各位置に判別可能な値を置いた MBC0 を作る
- (NSData *)makeCartridgeData {
    uint8_t rom[0x8000];
    for (NSUInteger i = 0; i < sizeof(rom); i++) {
        rom[i] = 0x00;
    }
    rom[0x0100] = 0x11;              // 実行領域の目印(エントリポイント)
    rom[0x0147] = 0x00;              // MBC0
    rom[0x0149] = 0x00;
    rom[0x0200] = 0x22;              // BIOS ウィンドウ誤設定で読まれないはずの位置
    rom[0x0800] = 0x33;
    return [NSData dataWithBytes:rom length:sizeof(rom)];
}

- (void)testBootROMWindowIsDMGOnly {
    NSError *error = nil;
    MBCartridge *cart = [[MBCartridge alloc] initWithROMData:[self makeCartridgeData] error:&error];
    XCTAssertNotNil(cart, "テスト用カートリッジの構築に成功する %@", error);
    if (!cart) return;

    MBGameBoy *gb = [[MBGameBoy alloc] initWithCartridge:cart error:&error];
    XCTAssertNotNil(gb, "マシン構築に成功する %@", error);
    if (!gb) return;

    uint8_t bios[0x100];
    memset(bios, 0x00, sizeof(bios));
    bios[0x0000] = 0xEE;             // BIOS 側の目印($0000)
    gb.bootROMData = [NSData dataWithBytes:bios length:sizeof(bios)];
    // bootROMData 設定で可視化される(実 BIOS 駆動相当)

    // $0000-$00FF は BIOS から読む
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0000], 0xEE, "BIOS 可視中は $0000 を BIOS から返す");

    // $0100 と $0200-$08FF は常にカートリッジ(DMG の BIOS は 256 バイトのみ)
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0100], 0x11, "$0100 はカートリッジから返す");
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0200], 0x22, "$0200 はカートリッジから返す(CGB ルールを払拭)");
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0800], 0x33, "$0800 はカートリッジから返す");

    // アンバンク($FF50 書込み相当)後は $0000-$00FF もカートリッジから返す
    [(id<MBCPUBus>)gb cpuWrite:0x01 address:0xFF50];
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0000], 0x00, "アンバンク後は $0000 もカートリッジから返す");
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0100], 0x11, "アンバンク後も $0100 はカートリッジ");
    XCTAssertEqual([(id<MBCPUBus>)gb cpuReadAddress:0x0200], 0x22, "アンバンク後も $0200 はカートリッジ");
}

@end

NS_ASSUME_NONNULL_END
