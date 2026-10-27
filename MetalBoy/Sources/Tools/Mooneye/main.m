#import <Foundation/Foundation.h>
#import "MBGameBoy.h"
#import "MBCartridge.h"
#import <stdio.h>
#import <string.h>

// metalboy-mooneye(Mooneye テストスイート判定ツール)
//
// 用法: metalboy-mooneye <rom> [--bios <path>] [--seconds N]
//
// シリアル quit プロトコルで判定する: 03 05 08 0D 15 22 = PASS / 42 x6 = FAIL。
// --bios 指定時は実 BIOS を供給して起動する(boot_* 系の検証用)。
// 終了コード: 0=PASS, 1=FAIL, 2=TIMEOUT・引数・ロードエラー

static void PrintBytes(const char *label, const uint8_t *bytes, int length) {
    printf("%s:", label);
    for (int i = 0; i < length; i++) {
        printf(" %02X", bytes[i]);
    }
    printf("\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: metalboy-mooneye <rom> [--bios <path>] [--seconds N]\n");
            return 2;
        }
        const char *romPath = argv[1];
        const char *biosPath = NULL;
        double maxSeconds = 15.0;
        for (int i = 2; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--bios") == 0) {
                biosPath = argv[++i];
            } else if (strcmp(argv[i], "--seconds") == 0) {
                maxSeconds = atof(argv[++i]);
            }
        }

        NSData *rom = [NSData dataWithContentsOfFile:@(romPath)];
        if (rom == nil) {
            fprintf(stderr, "ROM を読み込めません: %s\n", romPath);
            return 2;
        }
        MBCartridge *cart = [[MBCartridge alloc] initWithROMData:rom error:nil];
        MBGameBoy *gb = cart ? [[MBGameBoy alloc] initWithCartridge:cart error:nil] : nil;
        if (gb == nil) {
            fprintf(stderr, "カートリッジを初期化できません: %s\n", romPath);
            return 2;
        }
        if (biosPath != NULL) {
            NSData *bios = [NSData dataWithContentsOfFile:@(biosPath)];
            if (bios == nil) {
                fprintf(stderr, "BIOS を読み込めません: %s\n", biosPath);
                return 2;
            }
            gb.bootROMData = bios;
        }

        static uint8_t serial[256];
        static int serialLength = 0;
        gb.serialOutputHandler = ^(uint8_t byte) {
            if (serialLength < (int)sizeof(serial)) {
                serial[serialLength++] = byte;
            }
        };

        static const uint8_t passBytes[6] = {0x03, 0x05, 0x08, 0x0D, 0x15, 0x22};
        static const uint8_t failBytes[6] = {0x42, 0x42, 0x42, 0x42, 0x42, 0x42};
        NSDate *start = [NSDate date];
        while ([[NSDate date] timeIntervalSinceDate:start] < maxSeconds) {
            [gb runFrame];
            if (serialLength < 6) {
                continue;
            }
            // 結果は末尾 6 バイトで判定する(テスト自身がシリアル転送する ROM は
            // 先頭に別のバイトが入る。serial/boot_sclk_align)
            const uint8_t *tail = serial + serialLength - 6;
            if (memcmp(tail, passBytes, 6) == 0) {
                printf("PASS %s\n", romPath);
                return 0;
            }
            if (memcmp(tail, failBytes, 6) == 0) {
                printf("FAIL %s\n", romPath);
                PrintBytes("serial", serial, serialLength);
                return 1;
            }
        }

        printf("TIMEOUT %s\n", romPath);
        PrintBytes("serial", serial, serialLength);
        MBCPU *cpu = gb.cpu;
        printf("regs A=%02X F=%02X B=%02X C=%02X D=%02X E=%02X H=%02X L=%02X SP=%04X PC=%04X\n",
               cpu.registerA, cpu.registerF, cpu.registerB, cpu.registerC, cpu.registerD,
               cpu.registerE, cpu.registerH, cpu.registerL, cpu.sp, cpu.pc);
        printf("io DIV=%02X TIMA=%02X TMA=%02X TAC=%02X IF=%02X BOOT=%02X\n",
               [gb.memory read8:0xFF04], [gb.memory read8:0xFF05], [gb.memory read8:0xFF06],
               [gb.memory read8:0xFF07], [gb.memory read8:0xFF0F], [gb.memory read8:0xFF50]);
        printf("ppu LCDC=%02X STAT=%02X LY=%d BGP=%02X\n",
               gb.ppu.lcdc, gb.ppu.stat, gb.ppu.ly, gb.ppu.bgp);
        return 2;
    }
}
