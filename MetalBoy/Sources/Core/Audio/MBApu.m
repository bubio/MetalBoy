#import "MBApu.h"

// Game Boy DMG APU(4 チャンネル)。セーブ形状・UI は持たない(原則 II)。
//
// 精密化(2026-10-19): 従来の「レジスタ値の静的反映」から、Pan Docs 仕様の
// フレームシーケンサ駆動(length/stweep/エンベロープ)へ引き上げた。
// 参照実装は ~/dev/_Emu/BubiBoyLite/src/core/apu.odin(length step 0,2,4,6 /
// sweep step 2,6 / envelope step 7、trigger 時 length リロード + extra decrement)。
// 「音長が短い」の原因: 旧実装は (a) length counter を全く減らさず、(b) エンベロープを
// envStep 無視で 128Hz で減衰、(c) ch1 sweep / wave trigger / noise 分周比スケールが無し
// → 音程こそ鳴るが減衰が速く楽節が縮む。出力は DAC 的±加算(無音=0)へ修正し、
// 旧実装の (sum-24)*1000 による int16 ラップの音割れも解消した。

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    // エンベロープ(NRx2)
    uint8_t initialVolume;   // NRx2 bit7-4
    uint8_t envPeriod;       // NRx2 bit2-0
    BOOL envIncrease;        // NRx2 bit3
    int32_t envTimer;
    uint8_t volume;          // 現在の音量 0-15
} MBEnvelope;

typedef struct {
    BOOL enabled;
    BOOL dacEnabled;
    uint8_t duty;            // NRx1 bit7-6
    uint16_t lengthCounter;  // 64
    BOOL lengthEnabled;      // NRx4 bit6
    uint16_t freqRaw;        // 11bit
    int32_t timer;           // duty ステップ進行タイマー(T-cycle)
    int32_t phase;           // duty ステップ 0-7
    MBEnvelope envelope;
} MBSquareChannel;

typedef struct {
    uint8_t period;   // NR10 bit6-4
    BOOL negate;      // NR10 bit3
    uint8_t shift;    // NR10 bit2-0
    int32_t timer;
    uint16_t shadowFreq;
    BOOL enabled;
    BOOL negateCalculatedSinceTrigger;
} MBSweep;

typedef struct {
    BOOL enabled;
    BOOL dacEnabled;         // NR30 bit7
    uint16_t lengthCounter;  // 256
    BOOL lengthEnabled;      // NR34 bit6
    uint8_t volumeCode;      // NR32 bit6-5(0/1/2/3 = ミュート/100/50/25%)
    uint16_t freqRaw;
    int32_t timer;           // ステップ進行タイマー(T-cycle)
    int32_t phase;           // 波形ステップ 0-31
} MBWaveChannel;

typedef struct {
    BOOL enabled;
    BOOL dacEnabled;
    uint16_t lengthCounter;  // 64
    BOOL lengthEnabled;      // NR44 bit6
    uint8_t shift;           // NR43 bit7-4
    uint8_t widthMode;       // NR43 bit3
    uint8_t dividerCode;     // NR43 bit2-0
    int32_t timer;
    uint16_t lfsr;
    MBEnvelope envelope;
} MBNoiseChannel;

// ch1 スイープ(ch2/ch4/ch3 には無い)
typedef struct {
    MBSquareChannel square2[2]; // 0 = ch1(スイープあり), 1 = ch2
    MBSweep sweep;
    MBWaveChannel wave;
    MBNoiseChannel noise;
    uint8_t waveRAM[16];
    uint8_t nr50;
    uint8_t nr51;
    BOOL apuEnabled;
    int32_t frameTimer;              // 0..8192
    int32_t frameStep;               // 0..7(次に実行される step)
    double dotsToNextSample;         // 出力レートへの間引き残り dots
    NSMutableData *pendingSamples;
} MBApuState;

// duty パターン(CGB BIOS 相当)
static const uint8_t kDutyPatterns[4][8] = {
    {0,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,1},
    {1,0,0,0,0,1,1,1},
    {0,1,1,1,1,1,1,0},
};

// ノイズ除数表(0→8, 1→16, ... 7→112)
static const int kNoiseDivisors[8] = {8, 16, 32, 48, 64, 80, 96, 112};

// 1 サンプル出力あたりの T-cycle 数: 4194304(dot/s) ÷ 48000(sample/s)
static const double kDotsPerOutputSample = 4194304.0 / 48000.0;

// DAC レンジ: 4ch 合計 ±60 → int16 ±30000(500 倍)。無音(全ch無効)=0
static const int kSampleScale = 500;

static const uint8_t kDefaultNR50 = 0x77;
static const uint8_t kDefaultNR51 = 0xF3;

#pragma mark - 内部ヘルパー

static inline int32_t PulsePeriod(uint16_t freqRaw) {
    return (int32_t)(2048 - freqRaw) * 4; // T-cycle
}

static inline int32_t WavePeriod(uint16_t freqRaw) {
    return (int32_t)(2048 - freqRaw) * 2; // T-cycle
}

static inline int32_t NoisePeriod(const MBNoiseChannel *ch) {
    return kNoiseDivisors[ch->dividerCode] << ch->shift; // T-cycle
}

static inline void ResetEnvelope(MBEnvelope *env) {
    env->volume = env->initialVolume;
    env->envTimer = env->envPeriod;
}

/// NRx4 書込時の length/trigger obscure 挙動(Pan Docs / BubiBoyLite準拠)
static inline void ApplyLengthAndTrigger(uint16_t *lengthCounter,
                                         BOOL *lengthEnabled,
                                         BOOL *channelEnabled,
                                         int32_t frameStep,
                                         BOOL newLengthEnabled,
                                         BOOL trigger,
                                         uint16_t maxLength) {
    BOOL nextStepClocksLength = (frameStep % 2 == 0);
    BOOL wasEnabled = *lengthEnabled;
    if (!nextStepClocksLength && !wasEnabled && newLengthEnabled && *lengthCounter > 0) {
        (*lengthCounter)--;
        if (*lengthCounter == 0 && !trigger) *channelEnabled = NO;
    }
    *lengthEnabled = newLengthEnabled;
    if (trigger && *lengthCounter == 0) {
        *lengthCounter = maxLength;
        if (!nextStepClocksLength && newLengthEnabled) (*lengthCounter)--;
    }
}

static inline void DisableIfDacOff(MBEnvelope *env, BOOL *channelEnabled, BOOL *dacOn) {
    if (!*dacOn) {
        *channelEnabled = NO;
    }
    (void)env;
}

#pragma mark - MBApu

@interface MBApu () {
@public
    MBApuState _s;
}
@end

@implementation MBApu

- (instancetype)initWithDefaults {
    self = [super init];
    if (self) {
        _s.pendingSamples = [NSMutableData data];
        _s.apuEnabled = YES;
        _s.nr50 = kDefaultNR50;
        _s.nr51 = kDefaultNR51;
        for (NSInteger i = 0; i < 2; i++) {
            _s.square2[i].enabled = NO;
            _s.square2[i].dacEnabled = YES;
            _s.square2[i].duty = 2;
            _s.square2[i].lengthCounter = 0;
            _s.square2[i].freqRaw = 0;
            _s.square2[i].timer = 0;
            _s.square2[i].phase = 0;
        }
        _s.sweep.timer = 0;
        _s.wave.enabled = NO;
        _s.wave.dacEnabled = NO;
        _s.wave.lengthCounter = 0;
        _s.wave.timer = 0;
        _s.wave.phase = 0;
        _s.noise.enabled = NO;
        _s.noise.dacEnabled = NO;
        _s.noise.lengthCounter = 0;
        _s.noise.timer = 0;
        _s.noise.lfsr = 0x7FFF;
        memset(_s.waveRAM, 0, sizeof(_s.waveRAM));
        _s.frameTimer = 0;
        _s.frameStep = 0;
        _s.dotsToNextSample = kDotsPerOutputSample;
    }
    return self;
}

- (instancetype)init {
    return [self initWithDefaults];
}

- (void)applyPostBootState {
    // DMG BIOS のチャイム後: ch1 は有効のまま音量 0 まで減衰済み(NR52=$F1, NR11=$80, NR12=$F3)
    _s.square2[0].duty = 2;
    _s.square2[0].envelope.initialVolume = 0x0F;
    _s.square2[0].envelope.envIncrease = NO;
    _s.square2[0].envelope.envPeriod = 3;
    _s.square2[0].envelope.volume = 0;
    _s.square2[0].dacEnabled = YES;
    _s.square2[0].enabled = YES;
    // ch2 は BIOS 未使用 → 電源投入値(NR21=$3F)
    _s.square2[1].duty = 0;
}

- (NSMutableData *)pendingSamples {
    return _s.pendingSamples;
}

- (NSUInteger)pendingSampleCount {
    return _s.pendingSamples ? _s.pendingSamples.length / sizeof(int16_t) : 0;
}

- (NSMutableData *)takePendingSamples {
    NSMutableData *result = _s.pendingSamples;
    if (result == nil) result = [NSMutableData data];
    _s.pendingSamples = [NSMutableData data];
    return result;
}

#pragma mark - レジスタ書込み

- (void)writeNR10:(uint8_t)value {
    // negate → 正の方向へ切り替えた後 negate 計算が走っていたら即 ch1 停止
    if (_s.sweep.negate && !(value & 0x08) && _s.sweep.negateCalculatedSinceTrigger) {
        _s.square2[0].enabled = NO;
    }
    _s.sweep.period = (value >> 4) & 0x07;
    _s.sweep.shift = value & 0x07;
    _s.sweep.negate = (value & 0x08) != 0;
}

- (void)triggerEnvelopeWrite:(uint8_t)value envelope:(MBEnvelope *)env dac:(BOOL *)dacEnabled {
    *dacEnabled = (value & 0xF8) != 0; // DAC: 上位3bit(N/A/V構成)が全 0 なら DAC off
    env->initialVolume = (value >> 4) & 0x0F;
    env->envPeriod = value & 0x07;
    env->envIncrease = (value & 0x08) != 0;
}

- (void)writeRegister:(uint8_t)value address:(uint16_t)address {
    if (!_s.apuEnabled && address != 0xFF26) return;
    switch (address) {
        case 0xFF10: [self writeNR10:value]; break;

        case 0xFF11: { // NR11: duty + length(ch1)
            _s.square2[0].duty = (value >> 6) & 0x03;
            _s.square2[0].lengthCounter = 64 - (value & 0x3F);
            break;
        }
        case 0xFF12: { // NR12: envelope(ch1)
            [self triggerEnvelopeWrite:value envelope:&_s.square2[0].envelope dac:&_s.square2[0].dacEnabled];
            if (!_s.square2[0].dacEnabled) _s.square2[0].enabled = NO;
            break;
        }
        case 0xFF13: // NR13: freq low(ch1)
            _s.square2[0].freqRaw = (uint16_t)((_s.square2[0].freqRaw & 0x0700) | value);
            break;
        case 0xFF14: { // NR14: freq high + length enable + trigger(ch1)
            _s.square2[0].freqRaw = (uint16_t)((_s.square2[0].freqRaw & 0x00FF) | ((value & 0x07) << 8));
            BOOL trigger = (value & 0x80) != 0;
            ApplyLengthAndTrigger(&_s.square2[0].lengthCounter,
                                  &_s.square2[0].lengthEnabled,
                                  &_s.square2[0].enabled,
                                  _s.frameStep, (value & 0x40) != 0, trigger, 64);
            if (trigger) [self triggerSquare:&_s.square2[0] hasSweep:YES];
            break;
        }

        case 0xFF16: { // NR21: duty + length(ch2)
            _s.square2[1].duty = (value >> 6) & 0x03;
            _s.square2[1].lengthCounter = 64 - (value & 0x3F);
            break;
        }
        case 0xFF17: { // NR22: envelope(ch2)
            [self triggerEnvelopeWrite:value envelope:&_s.square2[1].envelope dac:&_s.square2[1].dacEnabled];
            if (!_s.square2[1].dacEnabled) _s.square2[1].enabled = NO;
            break;
        }
        case 0xFF18: // NR23: freq low(ch2)
            _s.square2[1].freqRaw = (uint16_t)((_s.square2[1].freqRaw & 0x0700) | value);
            break;
        case 0xFF19: { // NR24: freq high(ch2)
            _s.square2[1].freqRaw = (uint16_t)((_s.square2[1].freqRaw & 0x00FF) | ((value & 0x07) << 8));
            BOOL trigger = (value & 0x80) != 0;
            ApplyLengthAndTrigger(&_s.square2[1].lengthCounter,
                                  &_s.square2[1].lengthEnabled,
                                  &_s.square2[1].enabled,
                                  _s.frameStep, (value & 0x40) != 0, trigger, 64);
            if (trigger) [self triggerSquare:&_s.square2[1] hasSweep:NO];
            break;
        }

        case 0xFF1A: { // NR30: wave DAC
            _s.wave.dacEnabled = (value & 0x80) != 0;
            if (!_s.wave.dacEnabled) _s.wave.enabled = NO;
            break;
        }
        case 0xFF1B: // NR31: wave length
            _s.wave.lengthCounter = 256 - value;
            break;
        case 0xFF1C: // NR32: wave volume code
            _s.wave.volumeCode = (value >> 5) & 0x03;
            break;
        case 0xFF1D: // NR33: wave freq low
            _s.wave.freqRaw = (uint16_t)((_s.wave.freqRaw & 0x0700) | value);
            break;
        case 0xFF1E: { // NR34: wave freq high + trigger
            _s.wave.freqRaw = (uint16_t)((_s.wave.freqRaw & 0x00FF) | ((value & 0x07) << 8));
            BOOL trigger = (value & 0x80) != 0;
            ApplyLengthAndTrigger(&_s.wave.lengthCounter,
                                  &_s.wave.lengthEnabled,
                                  &_s.wave.enabled,
                                  _s.frameStep, (value & 0x40) != 0, trigger, 256);
            if (trigger) {
                _s.wave.timer = WavePeriod(_s.wave.freqRaw);
                _s.wave.phase = 0;
                _s.wave.enabled = _s.wave.dacEnabled;
            }
            break;
        }

        case 0xFF20: // NR41: noise length
            _s.noise.lengthCounter = 64 - (value & 0x3F);
            break;
        case 0xFF21: { // NR42: noise envelope
            [self triggerEnvelopeWrite:value envelope:&_s.noise.envelope dac:&_s.noise.dacEnabled];
            if (!_s.noise.dacEnabled) _s.noise.enabled = NO;
            break;
        }
        case 0xFF22: { // NR43: noise タイミング
            _s.noise.shift = (value >> 4) & 0x0F;
            _s.noise.widthMode = (value >> 3) & 0x01;
            _s.noise.dividerCode = value & 0x07;
            break;
        }
        case 0xFF23: { // NR44: noise trigger
            BOOL trigger = (value & 0x80) != 0;
            ApplyLengthAndTrigger(&_s.noise.lengthCounter,
                                  &_s.noise.lengthEnabled,
                                  &_s.noise.enabled,
                                  _s.frameStep, (value & 0x40) != 0, trigger, 64);
            if (trigger) {
                _s.noise.timer = NoisePeriod(&_s.noise);
                _s.noise.lfsr = 0x7FFF;
                ResetEnvelope(&_s.noise.envelope);
                _s.noise.enabled = _s.noise.dacEnabled;
            }
            break;
        }

        case 0xFF24: _s.nr50 = value; break;
        case 0xFF25: _s.nr51 = value; break;
        case 0xFF26: { // NR52: 電源
            BOOL newPower = (value & 0x80) != 0;
            if (_s.apuEnabled && !newPower) {
                _s.square2[0].enabled = NO;
                _s.square2[1].enabled = NO;
                _s.wave.enabled = NO;
                _s.noise.enabled = NO;
                _s.frameTimer = 0;
                _s.frameStep = 0;
            }
            _s.apuEnabled = newPower;
            break;
        }
        default:
            if (address >= 0xFF30 && address <= 0xFF3F) {
                _s.waveRAM[address - 0xFF30] = value;
            }
            break;
    }
}

- (void)triggerSquare:(MBSquareChannel *)ch hasSweep:(BOOL)hasSweep {
    ResetEnvelope(&ch->envelope);
    ch->phase = 0;
    ch->timer = PulsePeriod(ch->freqRaw);
    if (hasSweep) {
        _s.sweep.shadowFreq = ch->freqRaw;
        _s.sweep.timer = (_s.sweep.period == 0) ? 8 : _s.sweep.period;
        _s.sweep.enabled = (_s.sweep.period != 0 || _s.sweep.shift != 0);
        _s.sweep.negateCalculatedSinceTrigger = NO;
        if (_s.sweep.shift != 0) {
            uint16_t newFreq = 0;
            BOOL overflow = NO;
            [self sweepCalculate:&newFreq overflow:&overflow];
            if (overflow) {
                ch->enabled = NO;
                return; // オーバーフロー時は dac で上書き復活させない(実機仕様)
            }
        }
    }
    ch->enabled = ch->dacEnabled;
}

- (void)sweepCalculate:(uint16_t *)newFreq overflow:(BOOL *)overflow {
    int32_t delta = (int32_t)_s.sweep.shadowFreq >> _s.sweep.shift;
    if (_s.sweep.negate) delta = -delta;
    int32_t result = (int32_t)_s.sweep.shadowFreq + delta;
    *overflow = (result > 0x7FF);
    *newFreq = (uint16_t)(result & 0x7FF);
    if (_s.sweep.negate) _s.sweep.negateCalculatedSinceTrigger = YES;
}

#pragma mark - レジスタ読み込み

- (uint8_t)readRegister:(uint16_t)address {
    switch (address) {
        case 0xFF10:
            return (uint8_t)(0x80 | (_s.sweep.period << 4) | (_s.sweep.negate ? 0x08 : 0) | _s.sweep.shift);
        case 0xFF11: return (uint8_t)((_s.square2[0].duty << 6) | 0x3F);
        case 0xFF12:
            return (uint8_t)((_s.square2[0].envelope.initialVolume << 4)
                             | (_s.square2[0].envelope.envIncrease ? 0x08 : 0)
                             | _s.square2[0].envelope.envPeriod);
        // NRx4: 周波数・トリガは書込み専用。読めるのは length enable(bit6)のみ(Pan Docs)
        case 0xFF14: return (uint8_t)(0xBF | (_s.square2[0].lengthEnabled ? 0x40 : 0));
        case 0xFF16: return (uint8_t)((_s.square2[1].duty << 6) | 0x3F);
        case 0xFF17:
            return (uint8_t)((_s.square2[1].envelope.initialVolume << 4)
                             | (_s.square2[1].envelope.envIncrease ? 0x08 : 0)
                             | _s.square2[1].envelope.envPeriod);
        case 0xFF18: return 0xFF; // NR23 は書込み専用(実機: 読み 0xFF)
        case 0xFF19: return (uint8_t)(0xBF | (_s.square2[1].lengthEnabled ? 0x40 : 0));
        case 0xFF1A: return (uint8_t)(_s.wave.dacEnabled ? 0xFF : 0x7F);
        case 0xFF1C: return (uint8_t)((_s.wave.volumeCode << 5) | 0x9F);
        case 0xFF1E: return (uint8_t)(0xBF | (_s.wave.lengthEnabled ? 0x40 : 0));
        case 0xFF21:
            return (uint8_t)((_s.noise.envelope.initialVolume << 4)
                             | (_s.noise.envelope.envIncrease ? 0x08 : 0)
                             | _s.noise.envelope.envPeriod);
        case 0xFF22:
            return (uint8_t)((_s.noise.shift << 4) | (_s.noise.widthMode << 3) | _s.noise.dividerCode);
        case 0xFF23:
            return (uint8_t)(0x3F | (_s.noise.lengthEnabled ? 0x40 : 0x00) | 0x80); // 未使用 bit0-5=1
        case 0xFF24: return _s.nr50;
        case 0xFF25: return _s.nr51;
        case 0xFF26:
            return [self nr52Value]; // ビット4-6=1・bit7=電源・bit0-3=チャンネル状態
        default:
            if (address >= 0xFF30 && address <= 0xFF3F) {
                return _s.waveRAM[address - 0xFF30];
            }
            return 0xFF;
    }
}

- (uint8_t)nr52Value {
    uint8_t result = 0x70; // 未使用 bit4-6 は常に 1(Mooneye unused_hwio)
    if (_s.apuEnabled) {
        result |= 0x80;
        if (_s.square2[0].enabled) result |= 0x01;
        if (_s.square2[1].enabled) result |= 0x02;
        if (_s.wave.enabled)       result |= 0x04;
        if (_s.noise.enabled)      result |= 0x08;
    }
    return result;
}

#pragma mark - フレームシーケンサ(512Hz)

- (void)clockFrameSequencer {
    int32_t step = _s.frameStep;
    // length: step 0,2,4,6(256Hz)
    if (step == 0 || step == 2 || step == 4 || step == 6) {
        MBSquareChannel sq[2] = { _s.square2[0], _s.square2[1] };
        for (NSInteger i = 0; i < 2; i++) {
            if (sq[i].enabled && sq[i].lengthEnabled && sq[i].lengthCounter > 0) {
                sq[i].lengthCounter--;
                if (sq[i].lengthCounter == 0) sq[i].enabled = NO;
            }
        }
        _s.square2[0] = sq[0];
        _s.square2[1] = sq[1];
        if (_s.wave.enabled && _s.wave.lengthEnabled && _s.wave.lengthCounter > 0) {
            _s.wave.lengthCounter--;
            if (_s.wave.lengthCounter == 0) _s.wave.enabled = NO;
        }
        if (_s.noise.enabled && _s.noise.lengthEnabled && _s.noise.lengthCounter > 0) {
            _s.noise.lengthCounter--;
            if (_s.noise.lengthCounter == 0) _s.noise.enabled = NO;
        }
    }
    // sweep: step 2,6(128Hz・ch1 のみ)
    if (step == 2 || step == 6) {
        [self clockSweep];
    }
    // envelope: step 7 のみ(64Hz。参照実装 BubiBoyLite と同一)
    if (step == 7) {
        [self clockEnvelope:&_s.square2[0].envelope];
        [self clockEnvelope:&_s.square2[1].envelope];
        [self clockEnvelope:&_s.noise.envelope];
    }
    _s.frameStep = (step + 1) & 7;
}

- (void)clockSweep {
    if (!_s.square2[0].enabled || !_s.sweep.enabled) return;
    _s.sweep.timer--;
    if (_s.sweep.timer > 0) return;
    _s.sweep.timer = (_s.sweep.period == 0) ? 8 : _s.sweep.period;

    uint16_t newFreq = 0;
    BOOL overflow = NO;
    [self sweepCalculate:&newFreq overflow:&overflow];
    if (overflow) {
        _s.square2[0].enabled = NO;
        return;
    }
    if (_s.sweep.shift != 0) {
        _s.sweep.shadowFreq = newFreq;
        _s.square2[0].freqRaw = newFreq;
        _s.square2[0].timer = PulsePeriod(newFreq);
        // 次回反映用の事前オーバーフロー判定(実機仕様)
        uint16_t dummy = 0;
        BOOL overflow2 = NO;
        [self sweepCalculate:&dummy overflow:&overflow2];
        if (overflow2) _s.square2[0].enabled = NO;
    }
}

- (void)clockEnvelope:(MBEnvelope *)env {
    if (env->envPeriod == 0) return;
    env->envTimer--;
    if (env->envTimer > 0) return;
    env->envTimer = env->envPeriod;
    int32_t next = env->volume + (env->envIncrease ? 1 : -1);
    if (next >= 0 && next <= 15) env->volume = (uint8_t)next;
}

#pragma mark - チャンネル進行・サンプル生成

- (void)tickDots:(uint32_t)dots {
    if (!_s.apuEnabled) return;
    for (uint32_t i = 0; i < dots; i++) {
        _s.frameTimer++;
        if (_s.frameTimer >= 8192) {
            _s.frameTimer -= 8192;
            [self clockFrameSequencer];
        }

        for (NSInteger c = 0; c < 2; c++) {
            MBSquareChannel *ch = &_s.square2[c];
            if (!ch->enabled) continue;
            ch->timer--;
            if (ch->timer <= 0) {
                ch->timer += PulsePeriod(ch->freqRaw);
                ch->phase = (ch->phase + 1) & 7;
            }
        }

        if (_s.wave.enabled) {
            _s.wave.timer--;
            if (_s.wave.timer <= 0) {
                _s.wave.timer += WavePeriod(_s.wave.freqRaw);
                _s.wave.phase = (_s.wave.phase + 1) & 31;
            }
        }

        if (_s.noise.enabled) {
            _s.noise.timer--;
            if (_s.noise.timer <= 0) {
                _s.noise.timer += NoisePeriod(&_s.noise);
                uint16_t feedback = (uint16_t)((_s.noise.lfsr & 1) ^ ((_s.noise.lfsr >> 1) & 1));
                _s.noise.lfsr = (uint16_t)((_s.noise.lfsr >> 1) | (feedback << 14));
                if (_s.noise.widthMode) {
                    _s.noise.lfsr = (uint16_t)((_s.noise.lfsr & ~0x0040) | (feedback << 6));
                }
            }
        }

        _s.dotsToNextSample -= 1.0;
        if (_s.dotsToNextSample <= 0.0) {
            _s.dotsToNextSample += kDotsPerOutputSample;
            [self emitSample];
        }
    }
}

- (void)emitSample {
    int32_t sample = 0; // DAC 加算・無音 = 0(中心)

    for (NSInteger c = 0; c < 2; c++) {
        MBSquareChannel *ch = &_s.square2[c];
        if (ch->enabled && ch->dacEnabled) {
            sample += kDutyPatterns[ch->duty][ch->phase] ? ch->envelope.volume
                                                         : -(int32_t)ch->envelope.volume;
        }
    }
    if (_s.wave.enabled && _s.wave.dacEnabled) {
        uint8_t n = _s.waveRAM[_s.wave.phase / 2];
        int32_t nibble = (_s.wave.phase & 1) ? (n & 0x0F) : (n >> 4);
        int32_t code = _s.wave.volumeCode; // 0=無音 1=100% 2=50% 3=25%
        int32_t waveVolume = (code == 1) ? 15 : (code == 2) ? 7 : (code == 3) ? 3 : 0;
        sample += (nibble * 2 - 15) * waveVolume / 15; // ±15 レンジ
    }
    if (_s.noise.enabled && _s.noise.dacEnabled) {
        sample += ((_s.noise.lfsr & 0x01) == 0) ? _s.noise.envelope.volume
                                                : -(int32_t)_s.noise.envelope.volume;
    }

    int16_t value = (int16_t)(sample * kSampleScale);
    int16_t pair[2] = { value, value };
    [_s.pendingSamples appendBytes:pair length:sizeof(pair)];
}

@end

NS_ASSUME_NONNULL_END
