#import "MBMemoryMap.h"
#import "MBPPU.h"
#import "MBApu.h"
#import "MBJoypad.h"
#import "MBCartridge.h"

NS_ASSUME_NONNULL_BEGIN

// 扱う領域:
//   $0000-$7FFF  カートリッジ ROM(バンク切替は cartridge 側)
//   $8000-$9FFF  VRAM(PPU)
//   $A000-$BFFF  SRAM(cartridge 側)
//   $C000-$DFFF  WRAM / $E000-$FDFF echo(WRAM ミラー)
//   $FE00-$FE9F  OAM(PPU)
//   $FEA0-$FEFF  未使用(NOP)
//   $FF00-$FF7F  IO(候上: HP/serial/timer/ppu regs/apu regs)
//   $FF80-$FFFE  HRAM
//   $FFFF        IE
// タイマ: DIV($FF04) 256 T-cycle毎、TIMA($FF05) TAC 設定に応じて。IF bit=2

@interface MBMemoryMap ()
@property (nonatomic, strong) NSMutableData *wram;
@property (nonatomic, strong) NSMutableData *hram;
@property (nonatomic) uint16_t divCounter;     // $FF04 内部カウンタ(dot 単位 +4/M。上位 8bit が DIV)
@property (nonatomic) uint8_t tima;
@property (nonatomic) uint8_t tma;
@property (nonatomic) uint8_t tac;
@property (nonatomic) BOOL timaReloadPending;  // TIMA$FF オーバーフロー:M 中(立下り tick〜リロード tick)
@property (nonatomic) BOOL timaReloadGuard;    // リロード M 中: TIMA 書込み廃棄・TMA 書込みは TIMA へ即反映
@property (nonatomic) uint8_t serialData;      // $FF01 SB
@property (nonatomic) uint8_t serialWrittenData; // CPU が最後に SB へ書いた値(外部出力用)
@property (nonatomic) BOOL serialTransferStart; // $FF02 bit7
@property (nonatomic) int32_t serialTransferCounter;
@property (nonatomic) uint8_t latchedSCBits;   // $FF02 bit1(clock source)簡易
// OAM DMA($FF46)。逐次転送(1バイト/M-cycle、開始に 2 M-cycle 遅延)。
// 参照実装: BubiBoyLite bus.odin dma_tick_one_mcycle / Mooneye oam_dma_start.s
@property (nonatomic) BOOL dmaActive;
@property (nonatomic) uint16_t dmaPendingSource; // dmaStartDelay 消化後に dmaSource へ反映
@property (nonatomic) uint16_t dmaSource;
@property (nonatomic) NSUInteger dmaIndex;       // 転送済みバイト数(0..159)
@property (nonatomic) int32_t dmaStartDelay;     // 開始までの残り M-cycle(0=保留なし)
@property (nonatomic) uint8_t dmaLastWrite;      // $FF46 読み戻し(最後に書き込んだ値)
@end

@implementation MBMemoryMap

- (instancetype)init {
    self = [super init];
    if (self) {
        _wram = [NSMutableData dataWithLength:0x2000];
        _hram = [NSMutableData dataWithLength:0x7F];
        _ifRegister = 0;
        _ieRegister = 0;
        _tac = 0;
        _serialData = 0;
    }
    return self;
}

#pragma mark - Timer

// TAC&3 → dot 単位内部カウンタの立下り検出ビット
// (4096Hz=1024dot→bit9 / 262kHz=16dot→bit3 / 65536Hz=64dot→bit5 / 16384Hz=256dot→bit7)
//
- (uint16_t)tacDotsMask {
    static const uint16_t masks[4] = {0x0200, 0x0008, 0x0020, 0x0080};
    return masks[_tac & 0x03];
}

// クロックライン = TAC enable かつ 選択ビットが 1。1→0 遷移が TIMA tick
- (BOOL)timerClockHigh {
    return ((_tac & 0x04) != 0) && ((_divCounter & [self tacDotsMask]) != 0);
}

// 立下りエッジでの TIMA 更新。$FF で 0 停止(1 M-cycle)→ 翌 tick で TMA+IF
- (void)timerFallingEdge {
    if (_tima == 0xFF) {
        _tima = 0;
        _timaReloadPending = YES;
    } else {
        _tima++;
    }
}


- (void)applyPostBootStateWithDivCounter:(uint16_t)divCounter {
    _ifRegister = 0x01; // BIOS 中の VBlank 要求が残る(IF=$E1)
    _divCounter = divCounter;
}

#pragma mark - read/write

- (uint8_t)read8:(uint16_t)address {
    // OAM DMA 中の OAM 読み出し衝突(実機: 0xFF を返す。BubiBoyLite bus_read 同)
    if (_dmaActive && address >= 0xFE00 && address <= 0xFE9F) {
        return 0xFF;
    }
    if (address < 0x8000) {
        return [(id)self.cartridgeTarget romByteAtAddress:address];
    }
    if (address < 0xA000) {
        return [self.ppuTarget readVRAM:(uint16_t)(address - 0x8000)];
    }
    if (address < 0xC000) {
        return [(id)self.cartridgeTarget sramByteAtAddress:address];
    }
    if (address < 0xFE00) {
        uint16_t mirrored = address & 0x1FFF;
        uint8_t *b = (uint8_t *)self.wram.bytes;
        return b[mirrored];
    }
    if (address < 0xFF80) {
        return [self ioRead:address];
    }
    if (address < 0xFFFF) {
        uint8_t *b = (uint8_t *)self.hram.bytes;
        return b[address - 0xFF80];
    }
    // IE
    return self.ieRegister;
}

- (void)write8:(uint8_t)value address:(uint16_t)address {
    // OAM DMA 中の OAM 書き込み衝突(実機: 捨てられる)。
    // 抑止ウィンドウは読出し側(dmaActive=M_{w+2}..M_{w+161})と同一
    // (Mooneye push_timing.s: 2 ラウンドの push/pop から規定)。
    if (_dmaActive && address >= 0xFE00 && address <= 0xFE9F) {
        return;
    }
    if (address < 0x8000) {
        [(id)self.cartridgeTarget writeControlByte:value atAddress:address];
        return;
    }
    if (address < 0xA000) {
        [self.ppuTarget writeVRAM:value address:(uint16_t)(address - 0x8000)];
        return;
    }
    if (address < 0xC000) {
        [(id)self.cartridgeTarget writeSRAMByte:value atAddress:address];
        return;
    }
    if (address < 0xFE00) {
        uint16_t mirrored = address & 0x1FFF;
        uint8_t *b = (uint8_t *)self.wram.mutableBytes;
        b[mirrored] = value;
        return;
    }
    if (address < 0xFF80) {
        [self ioWrite:value address:address];
        return;
    }
    if (address < 0xFFFF) {
        uint8_t *b = (uint8_t *)self.hram.mutableBytes;
        b[address - 0xFF80] = value;
        return;
    }
    self.ieRegister = value;
}

- (uint8_t)ioRead:(uint16_t)address {
    MBPPU *ppu = self.ppuTarget;
    MBApu *apu = self.apuTarget;
    MBJoypad *joypad = self.joypadTarget;
    if (address <= 0xFE9F) {
        return [ppu readOAM:(uint16_t)(address - 0xFE00)];
    }
    if (address <= 0xFEFF) {
        return 0xFF; // $FEA0-$FEFF 未使用
    }
    switch (address) {
        case 0xFF00: return (joypad ? [joypad registerValue] : 0xFF);
        case 0xFF01: return _serialData;
        case 0xFF02: return (uint8_t)(0x7E | (_serialTransferStart ? 0x80 : 0x00) | (_latchedSCBits & 0x03));
        case 0xFF04: return (uint8_t)(_divCounter >> 8);
        case 0xFF05: return _tima;
        case 0xFF06: return _tma;
        case 0xFF07: return (uint8_t)(0xF8 | _tac);
        case 0xFF0F: return (uint8_t)(0xE0 | _ifRegister);
        case 0xFF40: return ppu ? ppu.lcdc : 0xFF;
        case 0xFF41: return ppu ? [ppu statValue] : 0xFF;
        case 0xFF42: return ppu ? ppu.scy : 0xFF;
        case 0xFF43: return ppu ? ppu.scx : 0xFF;
        case 0xFF44: return ppu ? ppu.ly : 0xFF;
        case 0xFF45: return ppu ? ppu.lyc : 0xFF;
        case 0xFF46: return _dmaLastWrite; // 読み戻しは最後に書き込んだ値(Mooneye oam_dma/reg_read)
        case 0xFF47: return ppu ? ppu.bgp : 0xFF;
        case 0xFF48: return ppu ? ppu.obp0 : 0xFF;
        case 0xFF49: return ppu ? ppu.obp1 : 0xFF;
        case 0xFF4A: return ppu ? ppu.wy : 0xFF;
        case 0xFF4B: return ppu ? ppu.wx : 0xFF;
        case 0xFFFF: return self.ieRegister;
        default:
            if (address >= 0xFF10 && address <= 0xFF3F) {
                return apu ? [apu readRegister:address] : 0xFF;
            }
            return 0xFF;
    }
}

- (void)ioWrite:(uint8_t)value address:(uint16_t)address {
    MBPPU *ppu = self.ppuTarget;
    MBApu *apu = self.apuTarget;
    MBJoypad *joypad = self.joypadTarget;
    if (address <= 0xFE9F) {
        if (ppu) [ppu writeOAM:value address:(uint16_t)(address - 0xFE00)];
        return;
    }
    switch (address) {
        case 0xFF00:
            if (joypad) {
                joypad.registerLatch = (value & 0x30); // bit5/4 は書込み値を読み戻す
            }
            break;
        case 0xFF01:
            _serialData = value;
            _serialWrittenData = value;
            break;
        case 0xFF02: {
            _latchedSCBits = (uint8_t)(value & 0x03);
            _serialTransferStart = (value & 0x80) != 0;
            if (_serialTransferStart) {
                // 送出バイトは開始時点で外部(テスト ROM 判定)へ渡す。転送完了を待たずに
                // 次の SB を書く ROM(Mooneye quit)でもシフト途中の値ではなく書込み値を出す。
                // 内部クロック時のみ 8 bit 後に完了する(外部クロックは相手がいないので完了しない)
                _serialTransferCounter = 8;
                if (self.serialOutputHandler) self.serialOutputHandler(_serialWrittenData);
            }
            break;
        }
        case 0xFF04: {
            // 書込みは内部カウンタの 0 化。選択ビットが立っていた場合は
            // 1→0 遷移(=立下りエッジ)が書込み時点で発生する(Mooneye *_div_trigger)。
            // オーバーフロー待ちがある場合は DIV リセットでキャンセルされる。
            if ([self timerClockHigh]) [self timerFallingEdge];
            _divCounter = 0;
            _timaReloadPending = NO;
            break;
        }
        case 0xFF05:
            // オーバーフロー M 中: 書込みがオーバーフローをキャンセル(リロードも IF もなし)。
            // リロード M 中: TIMA 書込みは廃棄、TMA 書込みはリロードドットへの到着とみなし TIMA へ反映。
            if (_timaReloadPending) {
                _tima = value;
                _timaReloadPending = NO;
            } else if (!_timaReloadGuard) {
                _tima = value;
            }
            break;
        case 0xFF06: {
            _tma = value;
            if (_timaReloadPending) {
                // リロードが次 tick で新しい TMA を拾う
                _timaReloadPending = YES;
            } else if (_timaReloadGuard) {
                // リロード M 中の TMA 書込みは TIMA へも反映される
                _tima = value;
            }
            break;
        }
        case 0xFF07: {
            // TAC 書込みでも clock line(enabled && 選択ビット)の 1→0 で tick
            // (disable 時や mask 変更で旧ラインが 1 のまま落とされる場合を含む)
            BOOL oldHigh = [self timerClockHigh];
            _tac = (uint8_t)(value & 0x07);
            if (oldHigh && ![self timerClockHigh]) [self timerFallingEdge];
            break;
        }
        case 0xFF40: if (ppu) ppu.lcdc = value; break;
        case 0xFF41: if (ppu) [ppu writeSTAT:value]; break;
        case 0xFF42: if (ppu) ppu.scy = value; break;
        case 0xFF43: if (ppu) ppu.scx = value; break;
        case 0xFF45: if (ppu) ppu.lyc = value; break;
        case 0xFF46: {
            // OAM DMA: 開始は 2 M-cycle 後(実行中の転送はそのまま継続し、
            // 遅延消化後に新規転送が打ち切り開始される=BubiBoyLite dma_tick_one_mcycle)
            _dmaLastWrite = value;
            _dmaPendingSource = (uint16_t)(value << 8);
            _dmaStartDelay = 2;
            break;
        }
        case 0xFF47: if (ppu) ppu.bgp = value; break;
        case 0xFF48: if (ppu) ppu.obp0 = value; break;
        case 0xFF49: if (ppu) ppu.obp1 = value; break;
        case 0xFF4A: if (ppu) ppu.wy = value; break;
        case 0xFF4B: if (ppu) ppu.wx = value; break;
        case 0xFF0F: _ifRegister = (uint8_t)(value & 0x1F); break;
        case 0xFFFF: self.ieRegister = value; break;
        default:
            if (address >= 0xFF10 && address <= 0xFF3F) {
                [apu writeRegister:value address:address];
            }
            break;
    }
}

#pragma mark - OAM DMA

/// 1 M-cycle ぶん OAM DMA を進める。
/// M0(書込み, delay=2 セット)→ M1(何もしない)→ M2(転送開始: active 化のみ、
/// byte0 は M3 の終端 tick から書込む=byte k は M_{w+2+k} の終端で OAM に載る。
/// これで Mooneye oam_dma_start「M2 で OAM 読み出しは FF」と oam_dma_restart の
/// 終端境界(最終 byte の M そのものに CPU 読み出しが重なると FF、
/// その 1 M-cycle 後は OAM に載った値が読める)の両方を満たす)
- (void)dmaTickOneMCycle {
    if (_dmaStartDelay > 0) {
        _dmaStartDelay -= 1;
        if (_dmaStartDelay == 0) {
            _dmaActive = YES;
            _dmaSource = _dmaPendingSource;
            _dmaIndex = 0;
            return; // 開始 tick では転送しない(隔離 M)
        }
    }
    if (_dmaActive) {
        uint16_t src = (uint16_t)(_dmaSource + _dmaIndex);
        uint8_t value = [self dmaRawRead:src];
        [self.ppuTarget writeOAM:value address:(uint16_t)_dmaIndex];
        _dmaIndex += 1;
        if (_dmaIndex >= 0xA0) {
            _dmaActive = NO;
        }
    }
}

/// DMA 自身のソース読み出しは OAM 衝突ゲートを通らない(bus_read_raw 相当)。
/// DMG では $E000-$FFFF は WRAM のミラー($FE00→$DE00。Mooneye oam_dma/sources-GS)
- (uint8_t)dmaRawRead:(uint16_t)address {
    if (address >= 0xE000) {
        return ((uint8_t *)self.wram.bytes)[address & 0x1FFF];
    }
    BOOL saved = _dmaActive;
    _dmaActive = NO;
    uint8_t value = [self read8:address];
    _dmaActive = saved;
    return value;
}

#pragma mark - tick

- (void)tickCycle {
    // 1 M-cycle = 4 T-cycle(dots)。
    // 実機タイマ: 内部 dot カウンタの +4 毎に TAC 選択ビットの立下りを見る。
    // TIMA リロード待ちを先に消化(reload 前の廃棄ガードも 1 tick で解く)。
    _timaReloadGuard = NO;
    if (_timaReloadPending) {
        _timaReloadPending = NO;
        _tima = _tma;
        _ifRegister |= 0x04;
        _timaReloadGuard = YES; // リロード M 中の TIMA 書込みだけ廃棄される
    }
    uint16_t prev = _divCounter;
    _divCounter = (uint16_t)(_divCounter + 4);
    if ((_tac & 0x04) && ((prev & [self tacDotsMask]) != 0) && ((_divCounter & [self tacDotsMask]) == 0)) {
        [self timerFallingEdge];
    }
    // 内部クロックのシリアル: DIV 内部カウンタ bit8 の立下り(512 dots)毎に 1 bit シフト。
    // 接続相手なしなので 1 が入り、8 bit 後に SB=$FF・IF bit3(serial/boot_sclk_align)
    if (_serialTransferStart && (_latchedSCBits & 0x01)
        && (prev & 0x100) != 0 && (_divCounter & 0x100) == 0) {
        _serialData = (uint8_t)((_serialData << 1) | 0x01);
        _serialTransferCounter -= 1;
        if (_serialTransferCounter <= 0) {
            _serialTransferStart = NO;
            _ifRegister |= 0x08;
        }
    }
    [self dmaTickOneMCycle];
}

#pragma mark - property 再生成(read/write 单纯)

- (void)setIfRegister:(uint8_t)value {
    _ifRegister = (uint8_t)(value & 0x1F);
}

@end

NS_ASSUME_NONNULL_END
