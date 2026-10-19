#import "MBGameBoy.h"
#import "MBCPU.h"

NS_ASSUME_NONNULL_BEGIN

static const uint32_t kDotsPerFrame = 70224;

@interface MBGameBoy () <MBCPUBus>
@property (nonatomic, readwrite, strong) MBCPU *cpu;
@property (nonatomic, readwrite, strong) MBMemoryMap *memory;
@property (nonatomic, readwrite, strong) MBPPU *ppu;
@property (nonatomic, readwrite, strong) MBApu *apu;
@property (nonatomic, readwrite, strong) MBJoypad *joypad;
@property (nonatomic, readwrite, strong) MBCartridge *cartridge;
/// 実 BIOS の可視状態($FF50 書込みで非表示)。nil なら BIOS なしで $0100 開始
@property (nonatomic) BOOL bootROMVisible;
@end

@implementation MBGameBoy

- (nullable instancetype)initWithCartridge:(MBCartridge *)cartridge error:(NSError *_Nullable *_Nullable)error {
    self = [super init];
    if (!self) return nil;
    if (cartridge == nil) {
        if (error) *error = [NSError errorWithDomain:MBCartridgeErrorDomain
                                                code:MBCartridgeErrorCodeInvalidROM
                                            userInfo:nil];
        return nil;
    }
    _cartridge = cartridge;
    _cpu = [[MBCPU alloc] init];
    _ppu = [[MBPPU alloc] init];
    _apu = [[MBApu alloc] initWithDefaults];
    _joypad = [[MBJoypad alloc] init];
    _memory = [[MBMemoryMap alloc] init];
    _memory.ppuTarget = _ppu;
    _memory.apuTarget = _apu;
    _memory.joypadTarget = _joypad;
    _memory.cartridgeTarget = cartridge;
    _memory.serialOutputHandler = self.serialOutputHandler;
    return self;
}

#pragma mark - 実 BIOS パス(デバッグ/検証用。仕様上アプリ側は BIOS 不要のまま)

/// 実 BIOS を設定(256 バイト or CGB 512 バイト)。指定すると電源投入は $0000 BIOS から開始
- (void)setBootROMData:(NSData * _Nullable)bootROMData {
    _bootROMData = bootROMData;
    self.bootROMVisible = (bootROMData.length > 0);
    if (bootROMData.length > 0) {
        [self.cpu setPC:0x0000];
    }
}

/// $0000-$00FF は BIOS の可視中のみ BIOS を返す(DMG ブート ROM は 256 バイトのみ。
/// $0200-$08FF の分割配置は CGB ブート ROM のルールなので DMG 専用の本機では使わない)
- (BOOL)cpuReadFromBootROM:(uint16_t)address {
    if (!self.bootROMData || !self.bootROMVisible) return NO;
    return address < 0x0100;
}

- (void)setBootROMVisible:(BOOL)bootROMVisible {
    _bootROMVisible = bootROMVisible;
}

- (void)setSerialOutputHandler:(void (^ _Nullable)(uint8_t))serialOutputHandler {
    _serialOutputHandler = serialOutputHandler;
    self.memory.serialOutputHandler = serialOutputHandler;
}

#pragma mark - frame drive

- (BOOL)runFrame {
    // 1 フレーム = 70224 dots = 17556 M-cycle。cpu step の返り値は M-cycle なので
    // M-cycle 単位で配分する(過去は dots 残量に対して M-cycle を直接減算しており、
    // 1 フレーム分の CPU 駆動が実機の 4 倍回ってゲーム内部時間が 4 倍速になっていた)
    uint32_t cyclesRemaining = kDotsPerFrame / 4;
    uint32_t safetyGuard = kDotsPerFrame; // STEP 無限ループ防止(STOP 等の簡易フレーム完了)
    while (cyclesRemaining > 0) {
        NSUInteger cycles = [self.cpu stepWithBus:self];
        cyclesRemaining = (cyclesRemaining >= cycles) ? cyclesRemaining - (uint32_t)cycles : 0;
        if (safetyGuard-- == 0) {
            return YES;
        }
    }
    // フレーム数の管理はセッション側(1 runFrame 呼び出し = 実機 1 フレーム分の時間)
    return YES;
}

#pragma mark - MBCPUBus

/// VC: cpuReadAddress / cpuWrite は memory ヘ interp 南見太。適用:
/// PPU/Apu/timer は memory 内で完結。

- (uint8_t)cpuReadAddress:(uint16_t)address {
    // 実 BIOS 可視中は $0000-$00FF(DMG ブート ROM 全域)を BIOS から返す
    if ([self cpuReadFromBootROM:address]) {
        NSData *bios = self.bootROMData;
        NSRange range = NSMakeRange(address, 1);
        if (range.location < bios.length) {
            uint8_t b = 0xFF;
            [bios getBytes:&b range:range];
            return b;
        }
    }
    return [self.memory read8:address];
}

- (void)cpuWrite:(uint8_t)value address:(uint16_t)address {
    // $FF50 書込みは BIOS の非表示(実機のアンバンクのみ相当)
    if (address == 0xFF50) {
        self.bootROMVisible = NO;
        return;
    }
    [self.memory write8:value address:address];
}

- (uint8_t)cpuTickCycle {
    // 4 dots 分 PPU/APU を進める(timer は memory の tickCycle 内部)
    [self.memory tickCycle];
    uint8_t ifRequest = 0x00;
    [self.ppu tickDots:4 ifRequest:&ifRequest];
    [self.apu tickDots:4];
    if (ifRequest) {
        self.memory.ifRegister |= ifRequest;
    }
    return self.memory.ifRegister;
}

- (uint8_t)ifRegister {
    return self.memory.ifRegister;
}

- (uint8_t)ieRegister {
    return self.memory.ieRegister;
}

- (void)setIfRegister:(uint8_t)value {
    self.memory.ifRegister = value;
}

@end

NS_ASSUME_NONNULL_END
