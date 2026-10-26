#import "MBCPU.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Flags

#define FLAG_Z (1 << 7)
#define FLAG_N (1 << 6)
#define FLAG_H (1 << 5)
#define FLAG_C (1 << 4)

#pragma mark - BIOS なし DMG 電源投入相当レジスタ初期値(research R-5 / Pan Docs)

static const uint8_t  kPowerOnA = 0x01;
static const uint8_t  kPowerOnF = 0xB0;   // Z=1 H=1 C=1 N=0
static const uint8_t  kPowerOnB = 0x00;
static const uint8_t  kPowerOnC = 0x13;
static const uint8_t  kPowerOnD = 0x00;
static const uint8_t  kPowerOnE = 0xD8;
static const uint8_t  kPowerOnH = 0x01;
static const uint8_t  kPowerOnL = 0x4D;
static const uint16_t kPowerOnSP = 0xFFFE;

#pragma mark - 割り込みベクタ

static const uint8_t  kIFBits[5]    = {0x01, 0x02, 0x04, 0x08, 0x10};
static const uint16_t kIFVectors[5] = {0x0040, 0x0048, 0x0050, 0x0058, 0x0060};

#pragma mark - 算術ヘルパ(純関数)

static inline uint8_t AddBytes(uint8_t a, uint8_t b, uint8_t carryIn, uint8_t *outFlags) {
    uint32_t result = (uint32_t)a + (uint32_t)b + carryIn;
    uint8_t flags = 0;
    if ((uint8_t)result == 0) flags |= FLAG_Z;
    if (((a & 0x0F) + (b & 0x0F) + carryIn) > 0x0F) flags |= FLAG_H;
    if (result > 0xFF) flags |= FLAG_C;
    *outFlags = flags;
    return (uint8_t)result;
}

static inline uint8_t SubBytes(uint8_t a, uint8_t b, uint8_t borrowIn, uint8_t *outFlags) {
    int32_t result = (int32_t)a - (int32_t)b - borrowIn;
    uint8_t flags = FLAG_N;
    if ((result & 0xFF) == 0) flags |= FLAG_Z;
    if (((a & 0x0F) - (b & 0x0F) - borrowIn) < 0) flags |= FLAG_H;
    if (result < 0) flags |= FLAG_C;
    *outFlags = flags;
    return (uint8_t)result;
}

static inline uint16_t Add16NoZero(uint16_t a, uint16_t b, uint8_t *outFlags) {
    uint32_t result = (uint32_t)a + (uint32_t)b;
    uint8_t flags = 0;
    if (((a & 0x0FFF) + (b & 0x0FFF)) > 0x0FFF) flags |= FLAG_H;
    if (result > 0xFFFF) flags |= FLAG_C;
    *outFlags = flags;
    return (uint16_t)result;
}

#pragma mark - class

@interface MBCPU ()
@property (nonatomic) uint8_t regA, regF, regB, regC, regD, regE, regH, regL;
@property (nonatomic) uint16_t sp;
@property (nonatomic) uint16_t pc;
@property (nonatomic) BOOL ime;
@property (nonatomic) BOOL imeDelayed;
@property (nonatomic) BOOL imeApplyAfterInstruction; // EI 遅延: 翌命令完了後に適用する待機分
@property (nonatomic) BOOL halted;
@property (nonatomic) NSUInteger ticksDone; // 直近命令で既に吐き出した M-cycle 数
@end

@implementation MBCPU {
    uint64_t _reportedOpcodes[4]; // 通知済み未定義オペコード(256 bit)
}

- (instancetype)init {
    return [self initWithPowerOnStates];
}

- (instancetype)initWithPowerOnStates {
    self = [super init];
    if (self) {
        _regA = kPowerOnA;
        _regF = kPowerOnF;
        _regB = kPowerOnB;
        _regC = kPowerOnC;
        _regD = kPowerOnD;
        _regE = kPowerOnE;
        _regH = kPowerOnH;
        _regL = kPowerOnL;
        _sp   = kPowerOnSP;
        _pc   = 0x0100;      // BIOS 不在 → $0100 から直接開始(FR-007)
        _ime  = NO;
        _imeDelayed = NO;
        _halted = NO;
    }
    return self;
}

- (void)setPC:(uint16_t)pc {
    _pc = pc;
}

@dynamic registerD, registerE, registerH, registerL;

- (uint8_t)registerA { return _regA; }
- (uint8_t)registerF { return _regF; }
- (uint8_t)registerB { return _regB; }
- (uint8_t)registerC { return _regC; }
- (uint8_t)registerD { return _regD; }
- (uint8_t)registerE { return _regE; }
- (uint8_t)registerH { return _regH; }
- (uint8_t)registerL { return _regL; }

#pragma mark - fetch helpers

// M-cycle 単位のティック割出し(実機位置合わせ):
// すべてのバス操作(命令フェッチ込み)の直後に 1 M-cycle 分 cpuTickCycle を起こす。
// 合計 M-cycle は stepWithBus 冒頭で _ticksDone=0 にし、最後に tickBusTimes(count: -)で
// 内部遅延分のみ追加吐き出しする。
static inline uint8_t CPUFetch8(MBCPU *self, id<MBCPUBus> bus) {
    uint8_t value = [bus cpuReadAddress:self->_pc];
    self->_pc++;
    [self tickM:bus];
    return value;
}

static inline uint16_t CPUFetch16(MBCPU *self, id<MBCPUBus> bus) {
    uint16_t low = CPUFetch8(self, bus);
    uint16_t high = CPUFetch8(self, bus);
    return (uint16_t)(low | (uint16_t)(high << 8));
}

static inline void CPUPush16(MBCPU *self, id<MBCPUBus> bus, uint16_t value) {
    [bus cpuWrite:(uint8_t)(value >> 8)  address:(uint16_t)(self->_sp - 1)];
    [self tickM:bus];
    [bus cpuWrite:(uint8_t)(value & 0xFF) address:(uint16_t)(self->_sp - 2)];
    [self tickM:bus];
    self->_sp -= 2;
}

static inline uint16_t CPUPop16(MBCPU *self, id<MBCPUBus> bus) {
    uint16_t low = [bus cpuReadAddress:self->_sp];
    [self tickM:bus];
    uint16_t high = [bus cpuReadAddress:(uint16_t)(self->_sp + 1)];
    [self tickM:bus];
    self->_sp += 2;
    return (uint16_t)(low | (uint16_t)(high << 8));
}

#pragma mark - register pair helpers

static inline uint16_t Bc(MBCPU *self)  { return (uint16_t)(self->_regB << 8 | self->_regC); }
static inline uint16_t De(MBCPU *self)  { return (uint16_t)(self->_regD << 8 | self->_regE); }
static inline uint16_t Hl(MBCPU *self)  { return (uint16_t)(self->_regH << 8 | self->_regL); }

static inline uint8_t Get8R(MBCPU *self, NSUInteger idx, id<MBCPUBus> bus) {
    switch (idx) {
        case 0: return self->_regB;
        case 1: return self->_regC;
        case 2: return self->_regD;
        case 3: return self->_regE;
        case 4: return self->_regH;
        case 5: return self->_regL;
        case 6: {
            uint8_t value = [bus cpuReadAddress:Hl(self)];
            [self tickM:bus];
            return value;
        }
        default: return self->_regA;
    }
}

static inline void Set8R(MBCPU *self, NSUInteger idx, uint8_t value, id<MBCPUBus> bus) {
    switch (idx) {
        case 0: self->_regB = value; break;
        case 1: self->_regC = value; break;
        case 2: self->_regD = value; break;
        case 3: self->_regE = value; break;
        case 4: self->_regH = value; break;
        case 5: self->_regL = value; break;
        case 6:
            [bus cpuWrite:value address:Hl(self)];
            [self tickM:bus];
            break;
        default: self->_regA = value; break;
    }
}

static inline void IncR(MBCPU *self, NSUInteger idx, id<MBCPUBus> bus) {
    uint8_t v = Get8R(self, idx, bus);
    uint8_t result = (uint8_t)(v + 1);
    uint8_t flags = (uint8_t)((result == 0 ? FLAG_Z : 0)
                              | (((v & 0x0F) == 0x0F) ? FLAG_H : 0)
                              | (self->_regF & FLAG_C));
    Set8R(self, idx, result, bus);
    self->_regF = flags;
}

static inline void DecR(MBCPU *self, NSUInteger idx, id<MBCPUBus> bus) {
    uint8_t v = Get8R(self, idx, bus);
    uint8_t result = (uint8_t)(v - 1);
    uint8_t flags = (uint8_t)(FLAG_N
                              | (result == 0 ? FLAG_Z : 0)
                              | (((v & 0x0F) == 0) ? FLAG_H : 0)
                              | (self->_regF & FLAG_C));
    Set8R(self, idx, result, bus);
    self->_regF = flags;
}

static inline BOOL CondPass(MBCPU *self, NSUInteger cond) {
    switch (cond) {
        case 0: return (self->_regF & FLAG_Z) == 0;  // NZ
        case 1: return (self->_regF & FLAG_Z) != 0;  // Z
        case 2: return (self->_regF & FLAG_C) == 0;  // NC
        default: return (self->_regF & FLAG_C) != 0; // C
    }
}

#pragma mark - step

- (NSUInteger)stepWithBus:(id<MBCPUBus>)bus {
    // EI 遅延: 前命令(EI)で待機したフラグは「この命令の完了後」に IME へ反映する。
    // 実態は finishTicks(命令末尾)で適用するのでここで積み替える。
    // ここで消費しておかないと case 0xFB 自身が立てるフラグと混ざる。
    _imeApplyAfterInstruction = _imeDelayed;
    _imeDelayed = NO;
    _ticksDone = 0;

    // 割り込みサービス(実機仕様: IME=1 かつ (IF & IE) != 0 のときだけ発生)
    uint8_t ifReg = [bus ifRegister];
    uint8_t serviceable = ifReg & ([bus ieRegister] & 0x1F);
    if (_ime && serviceable != 0) {
        for (NSInteger i = 0; i < 5; i++) {
            if (serviceable & kIFBits[i]) {
                _ime = NO;
                _halted = NO;
                uint16_t returnPC = _pc;
                // 実機: 2 internal + PC push(W,W=push 内で tick)+ 1 internal の 5 M-cycle
                [self tickBusTimes:bus count:2];
                // 上位 byte push(SP-1)。ここが $FFFF=IE の場合、ディスパッチ最中の
                // IE 書換が起きる(Mooneye ie_push.s の観測)
                _sp = (uint16_t)(_sp - 1);
                [bus cpuWrite:(uint8_t)(returnPC >> 8) address:_sp];
                [self tickM:bus];
                // 実機: 上位 push 直後に (IF & IE) を再評価し、64 再優先決定する。
                // 0 ならディスパッチ取り消し: 下位 push なし・IF クリアなし・
                // PC=$0000(ie_push round1 の観測)、IME は 0 のまま(round2)。
                uint8_t rePending = [bus ifRegister] & ([bus ieRegister] & 0x1F);
                if (rePending == 0) {
                    _pc = 0x0000;
                    _imeApplyAfterInstruction = NO;
                    [self tickBusTimes:bus count:1];
                    return 5;
                }
                NSInteger j = i;
                for (NSInteger k = 0; k < 5; k++) {
                    if (rePending & kIFBits[k]) { j = k; break; }
                }
                // 下位 byte push(SP-2)。round3 の観測: ここでの IE 書換は
                // 再評価済みのためディスパッチは取り消されない
                _sp = (uint16_t)(_sp - 1);
                [bus cpuWrite:(uint8_t)(returnPC & 0xFF) address:_sp];
                [self tickM:bus];
                _pc = kIFVectors[j];
                [bus setIfRegister:(uint8_t)([bus ifRegister] & ~kIFBits[j])];
                _imeApplyAfterInstruction = NO;
                [self tickBusTimes:bus count:1];
                return 5;
            }
        }
    }

    if (_halted) {
        // Pan Docs: (IF & IE) != 0 なら IME 無関係に HALT を解除(IME=0 でも直後の
        // 命令から実行を再開し、割り込み処理自体は IME=1 のときだけ行う)
        uint8_t pending = (uint8_t)(ifReg & [bus ieRegister] & 0x1F);
        if (pending == 0) {
            [bus cpuTickCycle];
            return 1;
        }
        _halted = NO;
    }

    uint8_t opcode = CPUFetch8(self, bus);
    NSUInteger cycleCount = 0;

    if (opcode == 0xCB) {
        uint8_t cbOpcode = CPUFetch8(self, bus);
        cycleCount = 2;
        NSUInteger src = cbOpcode & 0x07;
        uint8_t x = (uint8_t)(cbOpcode >> 6);
        uint8_t y = (uint8_t)((cbOpcode >> 3) & 7);
        uint8_t value = Get8R(self, (NSUInteger)src, bus);
        uint8_t result = value;
        uint8_t flags = 0;
        switch (x) {
            case 0: { // RLC/RRC/RL/RR/SLA/SRA/SWAP/SRL(y=0-7)
                switch (y) {
                    case 0: { // RLC
                        uint8_t carryOut = (uint8_t)(value >> 7);
                        result = (uint8_t)((value << 1) | carryOut);
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 1: { // RRC
                        uint8_t carryOut = (uint8_t)(value & 0x01);
                        result = (uint8_t)((value >> 1) | (carryOut << 7));
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 2: { // RL
                        uint8_t carryOut = (uint8_t)(value >> 7);
                        result = (uint8_t)((value << 1) | ((self->_regF & FLAG_C) ? 1 : 0));
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 3: { // RR
                        uint8_t carryOut = (uint8_t)(value & 0x01);
                        result = (uint8_t)((value >> 1) | ((self->_regF & FLAG_C) ? 0x80 : 0));
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 4: { // SLA
                        uint8_t carryOut = (uint8_t)(value >> 7);
                        result = (uint8_t)(value << 1);
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 5: { // SRA
                        uint8_t carryOut = (uint8_t)(value & 0x01);
                        result = (uint8_t)((value >> 1) | (value & 0x80));
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                    case 6: { // SWAP
                        result = (uint8_t)((value >> 4) | (value << 4));
                        flags = 0;
                    } break;
                    default: { // SRL
                        uint8_t carryOut = (uint8_t)(value & 0x01);
                        result = (uint8_t)(value >> 1);
                        flags = (uint8_t)(carryOut ? FLAG_C : 0);
                    } break;
                }
                if (result == 0) flags |= FLAG_Z;
                self->_regF = flags;
                Set8R(self, src, result, bus);
            } break;
            case 1: { // BIT y,r(0x40-0x7F: Z=bit が 0 時、H=1、N/C 不変)
                BOOL bitSet = (value & (1 << y)) != 0;
                self->_regF = (uint8_t)(FLAG_H | (bitSet ? 0 : FLAG_Z) | (self->_regF & FLAG_C));
            } break;
            case 2: { // RES y,r(0x80-0xBF: フラグ不変)
                result &= (uint8_t)~(1 << y);
                Set8R(self, src, result, bus);
            } break;
            default: { // SET
                result |= (uint8_t)(1 << y);
                Set8R(self, src, result, bus);
            } break;
        }
        // M-cycle: reg 対象は rotate/shift・RES/SET=2・BIT=2、(HL) 対象は BIT=3・それ以外=4
        if (x == 1) {
            cycleCount = (src == 6) ? 3 : 2;
        } else {
            cycleCount = (src == 6) ? 4 : 2;
        }
        [self finishTicks:cycleCount bus:bus];
        return cycleCount;
    }

    // LD r,r'($40-$7F、HALT/STOP 除く)
    if (opcode >= 0x40 && opcode <= 0x7F && opcode != 0x76) {
        NSUInteger dst = (opcode >> 3) & 0x07;
        NSUInteger src = opcode & 0x07;
        uint8_t value = Get8R(self, src, bus);
        Set8R(self, dst, value, bus);
        NSUInteger count = (src == 6 || dst == 6) ? 2 : 1;
        [self finishTicks:count bus:bus];
        return count;
    }

    // ALU 即値群($C6/$CE/$D6/$DE/$E6/$EE/$F6/$FE)
    if (opcode == 0xC6 || opcode == 0xCE || opcode == 0xD6 || opcode == 0xDE ||
        opcode == 0xE6 || opcode == 0xEE || opcode == 0xF6 || opcode == 0xFE) {
        uint8_t value = CPUFetch8(self, bus);
        uint8_t flags = 0;
        switch (opcode) {
            case 0xC6: _regA = AddBytes(_regA, value, 0, &flags); _regF = flags; break;
            case 0xCE: _regA = AddBytes(_regA, value, (uint8_t)((_regF & FLAG_C) ? 1 : 0), &flags); _regF = flags; break;
            case 0xD6: _regA = SubBytes(_regA, value, 0, &flags); _regF = flags; break;
            case 0xDE: _regA = SubBytes(_regA, value, (uint8_t)((_regF & FLAG_C) ? 1 : 0), &flags); _regF = flags; break;
            case 0xE6: _regA &= value; _regF = (uint8_t)((_regA == 0 ? FLAG_Z : 0) | FLAG_H); break;
            case 0xEE: _regA ^= value; _regF = (uint8_t)(_regA == 0 ? FLAG_Z : 0); break;
            case 0xF6: _regA |= value; _regF = (uint8_t)(_regA == 0 ? FLAG_Z : 0); break;
            case 0xFE: SubBytes(_regA, value, 0, &flags); _regF = flags; break;
        }
        cycleCount = 2;
        [self finishTicks:cycleCount bus:bus];
        return cycleCount;
    }

    // ALU 群 $80-$BF(ADD/ADC/SUB/SBC/AND/XOR/OR/CP)
    if (opcode >= 0x80 && opcode <= 0xBF) {
        NSUInteger src = opcode & 0x07;
        uint8_t value = Get8R(self, src, bus);
        uint8_t flags = 0;
        if (opcode < 0x88) { _regA = AddBytes(_regA, value, 0, &flags); _regF = flags; }
        else if (opcode < 0x90) { _regA = AddBytes(_regA, value, (uint8_t)((_regF & FLAG_C) ? 1 : 0), &flags); _regF = flags; }
        else if (opcode < 0x98) { _regA = SubBytes(_regA, value, 0, &flags); _regF = flags; }
        else if (opcode < 0xA0) { _regA = SubBytes(_regA, value, (uint8_t)((_regF & FLAG_C) ? 1 : 0), &flags); _regF = flags; }
        else if (opcode < 0xA8) { _regA &= value; _regF = (uint8_t)((_regA == 0 ? FLAG_Z : 0) | FLAG_H); }
        else if (opcode < 0xB0) { _regA ^= value; _regF = (uint8_t)(_regA == 0 ? FLAG_Z : 0); }
        else if (opcode < 0xB8) { _regA |= value; _regF = (uint8_t)(_regA == 0 ? FLAG_Z : 0); }
        else { SubBytes(_regA, value, 0, &flags); _regF = flags; }
        cycleCount = (src == 6) ? 2 : 1; // reg→reg は 1、(HL) 参照は 2
        [self finishTicks:cycleCount bus:bus];
        return cycleCount;
    }

    switch (opcode) {
        case 0x00: /* NOP */ cycleCount = 1; break;

        // LD BC/DE/HL/SP,nn16
        case 0x01: { uint16_t v = CPUFetch16(self, bus); _regB = (uint8_t)(v >> 8); _regC = (uint8_t)v; cycleCount = 3; } break;
        case 0x11: { uint16_t v = CPUFetch16(self, bus); _regD = (uint8_t)(v >> 8); _regE = (uint8_t)v; cycleCount = 3; } break;
        case 0x21: { uint16_t v = CPUFetch16(self, bus); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 3; } break;
        case 0x31: { _sp = CPUFetch16(self, bus); cycleCount = 3; } break;

        // store A through register pairs
        case 0x02: [bus cpuWrite:_regA address:Bc(self)]; [self tickM:bus]; cycleCount = 2; break;
        case 0x12: [bus cpuWrite:_regA address:De(self)]; [self tickM:bus]; cycleCount = 2; break;

        // INC/DEC r
        case 0x04: IncR(self, 0, bus); cycleCount = 1; break;
        case 0x0C: IncR(self, 1, bus); cycleCount = 1; break;
        case 0x14: IncR(self, 2, bus); cycleCount = 1; break;
        case 0x1C: IncR(self, 3, bus); cycleCount = 1; break;
        case 0x24: IncR(self, 4, bus); cycleCount = 1; break;
        case 0x2C: IncR(self, 5, bus); cycleCount = 1; break;
        case 0x3C: IncR(self, 7, bus); cycleCount = 1; break;
        case 0x34: IncR(self, 6, bus); cycleCount = 3; break; // INC (HL)(blargg 11-op a,(hl) 回帰)
        case 0x05: DecR(self, 0, bus); cycleCount = 1; break;
        case 0x0D: DecR(self, 1, bus); cycleCount = 1; break;
        case 0x15: DecR(self, 2, bus); cycleCount = 1; break;
        case 0x1D: DecR(self, 3, bus); cycleCount = 1; break;
        case 0x25: DecR(self, 4, bus); cycleCount = 1; break;
        case 0x2D: DecR(self, 5, bus); cycleCount = 1; break;
        case 0x3D: DecR(self, 7, bus); cycleCount = 1; break;
        case 0x35: DecR(self, 6, bus); cycleCount = 3; break; // DEC (HL)(blargg 11-op a,(hl) 回帰)

        // LD r, n8
        case 0x06: _regB = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x0E: _regC = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x16: _regD = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x1E: _regE = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x26: _regH = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x2E: _regL = CPUFetch8(self, bus); cycleCount = 2; break;
        case 0x3E: _regA = CPUFetch8(self, bus); cycleCount = 2; break;

        // LD (nn), A
        case 0xEA: { uint16_t addr = CPUFetch16(self, bus); [bus cpuWrite:_regA address:addr]; [self tickM:bus]; cycleCount = 4; } break;
        case 0xFA: { uint16_t addr = CPUFetch16(self, bus); _regA = [bus cpuReadAddress:addr]; [self tickM:bus]; cycleCount = 4; } break;

        // LDH (a8), A / A, (a8)
        case 0xE0: { uint8_t lo = CPUFetch8(self, bus); [bus cpuWrite:_regA address:(uint16_t)(0xFF00 | lo)]; [self tickM:bus]; cycleCount = 3; } break;
        case 0xF0: { uint8_t lo = CPUFetch8(self, bus); _regA = [bus cpuReadAddress:(uint16_t)(0xFF00 | lo)]; [self tickM:bus]; cycleCount = 3; } break;

        // LDH (C), A / LDH A, (C)
        case 0xE2: [bus cpuWrite:_regA address:(uint16_t)(0xFF00 | _regC)]; [self tickM:bus]; cycleCount = 2; break;
        case 0xF2: _regA = [bus cpuReadAddress:(uint16_t)(0xFF00 | _regC)]; [self tickM:bus]; cycleCount = 2; break;

        // LD (BC)/(DE), A
        case 0x0A: _regA = [bus cpuReadAddress:Bc(self)]; [self tickM:bus]; cycleCount = 2; break;
        case 0x1A: _regA = [bus cpuReadAddress:De(self)]; [self tickM:bus]; cycleCount = 2; break;

        // INC / DEC rp
        case 0x03: { uint16_t v = (uint16_t)(Bc(self) + 1); _regB = (uint8_t)(v >> 8); _regC = (uint8_t)v; cycleCount = 2; } break;
        case 0x13: { uint16_t v = (uint16_t)(De(self) + 1); _regD = (uint8_t)(v >> 8); _regE = (uint8_t)v; cycleCount = 2; } break;
        case 0x23: { uint16_t v = (uint16_t)(Hl(self) + 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;
        case 0x33: _sp = (uint16_t)(_sp + 1); cycleCount = 2; break;
        case 0x0B: { uint16_t v = (uint16_t)(Bc(self) - 1); _regB = (uint8_t)(v >> 8); _regC = (uint8_t)v; cycleCount = 2; } break;
        case 0x1B: { uint16_t v = (uint16_t)(De(self) - 1); _regD = (uint8_t)(v >> 8); _regE = (uint8_t)v; cycleCount = 2; } break;
        case 0x2B: { uint16_t v = (uint16_t)(Hl(self) - 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;
        case 0x3B: _sp = (uint16_t)(_sp - 1); cycleCount = 2; break;

        // rotates & cpl & daa & scf & ccf
        case 0x07: { // RLCA
            uint8_t carryOut = (uint8_t)(_regA >> 7);
            _regA = (uint8_t)((_regA << 1) | carryOut);
            _regF = (uint8_t)(carryOut ? FLAG_C : 0);
            cycleCount = 1;
        } break;
        case 0x0F: { // RRCA
            uint8_t carryOut = (uint8_t)(_regA & 0x01);
            _regA = (uint8_t)((_regA >> 1) | (carryOut << 7));
            _regF = (uint8_t)(carryOut ? FLAG_C : 0);
            cycleCount = 1;
        } break;
        case 0x17: { // RLA
            uint8_t carryIn = (uint8_t)((_regF & FLAG_C) ? 1 : 0);
            uint8_t carryOut = (uint8_t)(_regA >> 7);
            _regA = (uint8_t)((_regA << 1) | carryIn);
            _regF = (uint8_t)(carryOut ? FLAG_C : 0);
            cycleCount = 1;
        } break;
        case 0x1F: { // RRA
            uint8_t carryIn = (uint8_t)((_regF & FLAG_C) ? 0x80 : 0);
            uint8_t carryOut = (uint8_t)(_regA & 0x01);
            _regA = (uint8_t)((_regA >> 1) | carryIn);
            _regF = (uint8_t)(carryOut ? FLAG_C : 0);
            cycleCount = 1;
        } break;
        case 0x2F: { _regA = (uint8_t)(~_regA); _regF = (uint8_t)(_regF | FLAG_N | FLAG_H); cycleCount = 1; } break;
        case 0x27: { // DAA(SM83 仕様: N=1 の減算後補正では C を変化させない。blargg 01-special #6 回帰)
            BOOL subtract = (_regF & FLAG_N) != 0;
            BOOL halfCarry = (_regF & FLAG_H) != 0;
            BOOL carry = (_regF & FLAG_C) != 0;
            uint8_t adjustment = 0;
            BOOL setC = carry;
            if (halfCarry || (!subtract && (_regA & 0x0F) > 0x09)) adjustment |= 0x06;
            if (carry || (!subtract && _regA > 0x99)) adjustment |= 0x60;
            _regA = subtract ? (uint8_t)(_regA - adjustment) : (uint8_t)(_regA + adjustment);
            if (adjustment & 0x60) setC = YES;
            _regF = (uint8_t)((_regA == 0 ? FLAG_Z : 0)
                              | (subtract ? FLAG_N : 0)
                              | (setC ? FLAG_C : 0));
            cycleCount = 1;
        } break;
        case 0x37: { _regF = (uint8_t)((_regF & FLAG_Z) | FLAG_C); cycleCount = 1; } break;
        case 0x3F: { _regF = (uint8_t)((_regF & FLAG_Z) | ((_regF & FLAG_C) ? 0 : FLAG_C)); cycleCount = 1; } break;

        // ADD HL,rp / LD HL,SP+e8 / ADD SP,e8
        case 0x09: { uint8_t f; uint16_t r = Add16NoZero(Hl(self), Bc(self), &f); _regH = (uint8_t)(r >> 8); _regL = (uint8_t)r; _regF = (uint8_t)(f | (_regF & FLAG_Z)); cycleCount = 2; } break;
        case 0x19: { uint8_t f; uint16_t r = Add16NoZero(Hl(self), De(self), &f); _regH = (uint8_t)(r >> 8); _regL = (uint8_t)r; _regF = (uint8_t)(f | (_regF & FLAG_Z)); cycleCount = 2; } break;
        case 0x29: { uint8_t f; uint16_t r = Add16NoZero(Hl(self), Hl(self), &f); _regH = (uint8_t)(r >> 8); _regL = (uint8_t)r; _regF = (uint8_t)(f | (_regF & FLAG_Z)); cycleCount = 2; } break;
        case 0x39: { uint8_t f; uint16_t r = Add16NoZero(Hl(self), _sp, &f); _regH = (uint8_t)(r >> 8); _regL = (uint8_t)r; _regF = (uint8_t)(f | (_regF & FLAG_Z)); cycleCount = 2; } break;
        case 0xF8: { // LD HL, SP+e8
            int8_t offset = (int8_t)CPUFetch8(self, bus);
            uint16_t result = (uint16_t)(_sp + offset);
            uint8_t flags = 0;
            if (((_sp & 0x0F) + (offset & 0x0F)) > 0x0F) flags |= FLAG_H;
            if (((_sp & 0xFF) + (offset & 0xFF)) > 0xFF) flags |= FLAG_C;
            _regH = (uint8_t)(result >> 8); _regL = (uint8_t)result;
            _regF = flags;
            cycleCount = 3;
        } break;
        case 0xE8: { // ADD SP,e8(Z=0, N=0)
            int8_t offset = (int8_t)CPUFetch8(self, bus);
            uint16_t result = (uint16_t)(_sp + offset);
            uint8_t flags = 0;
            if (((_sp & 0x0F) + (offset & 0x0F)) > 0x0F) flags |= FLAG_H;
            if (((_sp & 0xFF) + (offset & 0xFF)) > 0xFF) flags |= FLAG_C;
            _sp = result;
            _regF = flags;
            cycleCount = 4;
        } break;
        case 0xF9: { _sp = Hl(self); cycleCount = 2; } break;

        // HALT / STOP
        case 0x76: _halted = YES; cycleCount = 1; break;
        case 0x10: _halted = YES; cycleCount = 1; break; // STOP → halt 相当(簡略)

        // LD r,r'($40-$7F・0x76 は上で処理済みのため削除)
        // (0x40-0x7F は switch 直前の if ブロックで処理する)

        // LD (HL),n8
        case 0x36: { uint8_t value = CPUFetch8(self, bus); [bus cpuWrite:value address:Hl(self)]; [self tickM:bus]; cycleCount = 3; } break;

        // LD A,(HLD)/(HLI)
        case 0x2A: { _regA = [bus cpuReadAddress:Hl(self)]; [self tickM:bus]; uint16_t v = (uint16_t)(Hl(self) + 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;
        case 0x3A: { _regA = [bus cpuReadAddress:Hl(self)]; [self tickM:bus]; uint16_t v = (uint16_t)(Hl(self) - 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;
        case 0x22: { [bus cpuWrite:_regA address:Hl(self)]; [self tickM:bus]; uint16_t v = (uint16_t)(Hl(self) + 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;
        case 0x32: { [bus cpuWrite:_regA address:Hl(self)]; [self tickM:bus]; uint16_t v = (uint16_t)(Hl(self) - 1); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 2; } break;

        // PUSH / POP
        case 0xC5: [self tickM:bus]; CPUPush16(self, bus, Bc(self)); cycleCount = 4; break;
        case 0xD5: [self tickM:bus]; CPUPush16(self, bus, De(self)); cycleCount = 4; break;
        case 0xE5: [self tickM:bus]; CPUPush16(self, bus, Hl(self)); cycleCount = 4; break;
        case 0xF5: [self tickM:bus]; CPUPush16(self, bus, (uint16_t)((_regA << 8) | _regF)); cycleCount = 4; break;
        case 0xC1: { uint16_t v = CPUPop16(self, bus); _regB = (uint8_t)(v >> 8); _regC = (uint8_t)v; cycleCount = 3; } break;
        case 0xD1: { uint16_t v = CPUPop16(self, bus); _regD = (uint8_t)(v >> 8); _regE = (uint8_t)v; cycleCount = 3; } break;
        case 0xE1: { uint16_t v = CPUPop16(self, bus); _regH = (uint8_t)(v >> 8); _regL = (uint8_t)v; cycleCount = 3; } break;
        case 0xF1: { uint16_t v = CPUPop16(self, bus); _regA = (uint8_t)(v >> 8); _regF = (uint8_t)(v & 0xF0); cycleCount = 3; } break;

        // JP nn / JP cc /
        case 0xC3: { _pc = CPUFetch16(self, bus); cycleCount = 4; } break;
        case 0xE9: { _pc = Hl(self); cycleCount = 1; } break;
        case 0xC2: case 0xCA: case 0xD2: case 0xDA: {
            NSUInteger cond = (opcode >> 3) & 3;
            uint16_t target = CPUFetch16(self, bus);
            if (CondPass(self, cond)) { _pc = target; cycleCount = 4; } else { cycleCount = 3; }
        } break;

        // JR e8 / JR cc
        case 0x18: { int8_t offset = (int8_t)CPUFetch8(self, bus); _pc = (uint16_t)(_pc + offset); cycleCount = 3; } break;
        case 0x20: case 0x28: case 0x30: case 0x38: {
            NSUInteger cond = (opcode >> 3) & 3;
            int8_t offset = (int8_t)CPUFetch8(self, bus);
            if (CondPass(self, cond)) { _pc = (uint16_t)(_pc + offset); cycleCount = 3; } else { cycleCount = 2; }
        } break;

        // CALL / CALL cc /
        case 0xCD: { uint16_t target = CPUFetch16(self, bus); [self tickM:bus]; CPUPush16(self, bus, _pc); _pc = target; cycleCount = 6; } break;
        case 0xC4: case 0xCC: case 0xD4: case 0xDC: {
            NSUInteger cond = (opcode >> 3) & 3;
            uint16_t target = CPUFetch16(self, bus);
            if (CondPass(self, cond)) { [self tickM:bus]; CPUPush16(self, bus, _pc); _pc = target; cycleCount = 6; } else { cycleCount = 3; }
        } break;

        // RET 関連
        case 0xC9: { _pc = CPUPop16(self, bus); cycleCount = 4; } break;
        case 0xC0: case 0xC8: case 0xD0: case 0xD8: {
            NSUInteger cond = (opcode >> 3) & 3;
            if (CondPass(self, cond)) { [self tickM:bus]; _pc = CPUPop16(self, bus); cycleCount = 5; } else { cycleCount = 2; }
        } break;
        case 0xD9: { _pc = CPUPop16(self, bus); _ime = YES; cycleCount = 4; } break;

        // RST
        case 0xC7: case 0xCF: case 0xD7: case 0xDF: case 0xE7: case 0xEF: case 0xF7: case 0xFF: {
            uint16_t vector = (uint16_t)(0x0000 + ((uint16_t)(opcode - 0xC7) & 0x38));
            [self tickM:bus]; // 内部 M(実機: M1=internal)
            CPUPush16(self, bus, _pc);
            _pc = vector;
            cycleCount = 4;
        } break;

        // DI / EI
        case 0xF3: _ime = NO; cycleCount = 1; break;
        case 0xFB: _imeDelayed = YES; cycleCount = 1; break;

        // LD (a16),SP / LD A,(a16)
        case 0x08: { uint16_t addr = CPUFetch16(self, bus); [bus cpuWrite:(uint8_t)(_sp & 0xFF) address:addr]; [self tickM:bus]; [bus cpuWrite:(uint8_t)(_sp >> 8) address:(uint16_t)(addr + 1)]; [self tickM:bus]; cycleCount = 5; } break;

        default:
            cycleCount = 1; // 未定義オペコードは NOP として扱う(実機はロックアップ)
            if (_unimplementedBehaviorHandler && !(_reportedOpcodes[opcode >> 6] & (1ULL << (opcode & 63)))) {
                _reportedOpcodes[opcode >> 6] |= 1ULL << (opcode & 63);
                _unimplementedBehaviorHandler([NSString stringWithFormat:
                    @"未定義オペコード $%02X を NOP として実行(PC=$%04X)", opcode, (uint16_t)(_pc - 1)]);
            }
            break;
    }

    [self finishTicks:cycleCount bus:bus];
    return cycleCount;
}

// _ticksDone を数えながら 1 M-cycle 吐き出す(直近命令の M-cycle 進行トラッキング)
- (void)tickM:(id<MBCPUBus>)bus {
    _ticksDone += 1;
    [bus cpuTickCycle];
}

// 残りの M-cycle(内部遅延などバス操作を持たない分)を吐き出して打ち切る。
// すべての命令パス(CB/LD/ALU 即値群の早期 return 経由含む)がここを必ず 1 回
// 通るので、EI 遅延の IME 適用もここで行う。
- (void)finishTicks:(NSUInteger)total bus:(id<MBCPUBus>)bus {
    NSUInteger done = _ticksDone;
    if (done < total) {
        [self tickBusTimes:bus count:(total - done)];
    }
    if (_imeApplyAfterInstruction) {
        _ime = YES;
        _imeApplyAfterInstruction = NO;
    }
}

- (void)tickBusTimes:(id<MBCPUBus>)bus count:(NSUInteger)count {
    for (NSUInteger i = 0; i < count; i++) {
        [bus cpuTickCycle];
    }
}

- (NSUInteger)stepCBWithBus:(id<MBCPUBus>)bus baseCycles:(NSUInteger)base {
    // stepWithBus 内で CB は実装済み。呼ばれない(HALTE 対応のため残す)
    (void)base;
    uint8_t op = CPUFetch8(self, bus);
    [bus cpuTickCycle];
    return (NSUInteger)op;
}

@end

NS_ASSUME_NONNULL_END
