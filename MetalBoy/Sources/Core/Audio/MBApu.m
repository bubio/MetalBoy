#import "MBApu.h"

// Game Boy DMG APU(4 チャンネル)。セーブ形状・UI は持たない(原則 II)。
//
// 精密化(2026-10-19): 「レジスタ値の静的反映」から Pan Docs 仕様のフレームシーケンサ
// 駆動(length/sweep/エンベロープ)へ引き上げた。
//
// 精密化(2026-11): ミキサー/サンプリングを参照実装 ~/dev/_Emu/BubiBoyLite/src/core/apu.odin
// に合わせて作り直した。旧実装は「全チャンネルの瞬時値をモノラルで単純加算」しており、
// (a) NR51 パンニングと NR50 マスター音量を無視、(b) wave/noise を点サンプルしていたため
// ノイズが実機とかなり違って聞こえた。現在は
//   - 4ch を -1..+1 に正規化し、NR51 で L/R へ振り分け、NR50 で音量を掛ける(ステレオ)
//   - wave/noise は前回サンプルから今回までの全 T-cycle の出力を平均(ボックスフィルタ)
//   - wave がナイキストを超える場合は 1 周期平均へフォールバック
//   - pulse は参照実装と同じく瞬時値
// としている。サンプル採取は 48000/4194304 の整数アキュムレータで行い、正確に 48kHz。

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
    int64_t sampleArea;      // 区間平均用: 出力単位の累積
    int32_t sampleCycles;    // 区間平均用: 累積した T-cycle 数
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
    int64_t sampleArea;      // 区間平均用
    int32_t sampleCycles;
} MBNoiseChannel;

typedef struct {
    MBSquareChannel square2[2]; // 0 = ch1(スイープあり), 1 = ch2
    MBSweep sweep;
    MBWaveChannel wave;
    MBNoiseChannel noise;
    uint8_t waveRAM[16];
    uint8_t nr50;
    uint8_t nr51;
    BOOL apuEnabled;
    int32_t frameTimer;              // 0..8191(512Hz フレームシーケンサ)
    int32_t frameStep;               // 0..7(次に実行される step)
    int32_t sampleCounter;           // 48kHz 採取用(CPU_HZ 単位の固定小数点)
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
static const int32_t kNoiseDivisors[8] = {8, 16, 32, 48, 64, 80, 96, 112};

static const int32_t kCpuHz = 4194304;           // dot/s
static const int32_t kSampleRate = 48000;        // 出力サンプルレート
static const int32_t kFrameSequencerPeriod = 8192;

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

// 以下 3 つは tickDots: の 4.19MHz ホットループから呼ぶため static inline C 関数にする
// (インスタンスメソッドだと T-cycle 毎に 4 回の ObjC msgSend が発生する)。

/// 矩形波 ch の周期タイマーを 1 T-cycle 進める。
static inline void TickSquareChannel(MBSquareChannel *ch) {
    if (!ch->enabled) return;
    ch->timer--;
    if (ch->timer <= 0) {
        ch->timer += PulsePeriod(ch->freqRaw);
        ch->phase = (ch->phase + 1) & 7;
    }
}

/// ch3 の周期タイマーを 1 T-cycle 進める。
static inline void TickWaveChannel(MBWaveChannel *ch) {
    if (!ch->enabled) return;
    ch->timer--;
    if (ch->timer <= 0) {
        ch->timer += WavePeriod(ch->freqRaw);
        ch->phase = (ch->phase + 1) & 31;
    }
}

/// ch4 の周期タイマーを 1 T-cycle 進め、LFSR を更新する。
static inline void TickNoiseChannel(MBNoiseChannel *ch) {
    if (!ch->enabled) return;
    ch->timer--;
    if (ch->timer <= 0) {
        ch->timer += NoisePeriod(ch);
        // clock shift 14/15 では LFSR にクロックが入らない(Pan Docs)
        if (ch->shift >= 14) return;
        uint16_t feedback = (uint16_t)((ch->lfsr & 1) ^ ((ch->lfsr >> 1) & 1));
        ch->lfsr = (uint16_t)((ch->lfsr >> 1) | (feedback << 14));
        if (ch->widthMode) {
            ch->lfsr = (uint16_t)((ch->lfsr & ~0x0040) | (feedback << 6));
        }
    }
}

static inline void ResetEnvelope(MBEnvelope *env) {
    env->volume = env->initialVolume;
    env->envTimer = env->envPeriod;
}

/// wave RAM の position(0-31)位置の出力を -15..+15 の生の単位で返す。
/// NR32 の音量は「4bit サンプルを右シフト」する実機挙動(参照実装と同じ)。
static int32_t WaveOutputUnits(const MBWaveChannel *ch, const uint8_t *waveRAM, int32_t position) {
    if (!ch->enabled || !ch->dacEnabled || ch->volumeCode == 0) return 0;
    uint8_t byteValue = waveRAM[(position / 2) & 0x0F];
    int32_t nibble = (position % 2 == 0) ? (byteValue >> 4) : (byteValue & 0x0F);
    int32_t shifted;
    switch (ch->volumeCode) {
        case 1: shifted = nibble; break;         // 100%
        case 2: shifted = nibble >> 1; break;    // 50%
        default: shifted = nibble >> 2; break;   // 25%
    }
    return 2 * shifted - 15;
}

/// ch3 の波形 1 周期(32 サンプル)が 48kHz のサンプル区間より短いか。
/// その場合は区間平均ではなく 1 周期平均へフォールバックする(参照実装と同じ)。
static BOOL WaveAboveNyquist(uint16_t freqRaw) {
    int64_t periodCycles = (int64_t)WavePeriod(freqRaw) * 32;
    return (2LL * (int64_t)kCpuHz) >= ((int64_t)kSampleRate * periodCycles);
}

/// ノイズの現在出力を -15..+15 の生の単位で返す。LFSR bit0=0 で正、1 で負。
static int32_t NoiseOutputUnits(const MBNoiseChannel *ch) {
    if (!ch->enabled || !ch->dacEnabled) return 0;
    return (ch->lfsr & 0x01) == 0 ? ch->envelope.volume : -(int32_t)ch->envelope.volume;
}

/// 矩形波 ch の現在出力を -1..+1 に正規化して返す(瞬時値)。
static float PulseOutput(const MBSquareChannel *ch) {
    if (!ch->enabled || !ch->dacEnabled) return 0.0f;
    int32_t bit = kDutyPatterns[ch->duty][ch->phase];
    float vol = (float)ch->envelope.volume / 15.0f;
    return bit == 0 ? -vol : vol;
}

static int16_t ScaleToInt16(float value) {
    float scaled = value * 32767.0f;
    if (scaled > 32767.0f) scaled = 32767.0f;
    if (scaled < -32768.0f) scaled = -32768.0f;
    return (int16_t)scaled;
}

/// NRx4 書込時の length/trigger obscure 挙動(Pan Docs / BubiBoyLite 準拠)
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
        }
        _s.sweep.timer = 0;
        _s.noise.lfsr = 0x7FFF;
        memset(_s.waveRAM, 0, sizeof(_s.waveRAM));
        _s.frameTimer = 0;
        _s.frameStep = 0;
        _s.sampleCounter = 0;
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

#pragma mark - 電源(NR52)

/// DMG の電源 off: NR10-NR51 とチャンネル状態をクリアする。wave RAM と length カウンタの値は
/// 保持し、length enable は 0 に戻す(Pan Docs / dmg_sound 01-registers test 5, 08-len ctr during power)。
- (void)powerOff {
    _s.apuEnabled = NO;

    uint16_t len[4] = { _s.square2[0].lengthCounter, _s.square2[1].lengthCounter,
                        _s.wave.lengthCounter, _s.noise.lengthCounter };

    memset(&_s.square2[0], 0, sizeof(_s.square2[0]));
    memset(&_s.square2[1], 0, sizeof(_s.square2[1]));
    memset(&_s.wave, 0, sizeof(_s.wave));
    memset(&_s.noise, 0, sizeof(_s.noise));
    _s.sweep = (MBSweep){0};

    // DMG は電源 off/on で length カウンタの値を保持する(長さ有効ビットは 0 に戻る)。
    // 参照: dmg_sound 08-len ctr during power / 11-regs after power / 01-registers test 5。
    _s.square2[0].lengthCounter = len[0];
    _s.square2[1].lengthCounter = len[1];
    _s.wave.lengthCounter = len[2];
    _s.noise.lengthCounter = len[3];

    _s.nr50 = 0;
    _s.nr51 = 0;
    _s.frameTimer = 0;
    _s.frameStep = 0;
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
    if (address == 0xFF26) { // NR52 だけは電源 off 中も受け付ける
        BOOL newPower = (value & 0x80) != 0;
        if (_s.apuEnabled && !newPower) {
            [self powerOff];
        } else if (!_s.apuEnabled && newPower) {
            _s.apuEnabled = YES;
            _s.frameTimer = 0;
            _s.frameStep = 0;
        }
        return;
    }
    if (address >= 0xFF30 && address <= 0xFF3F) {
        _s.waveRAM[address - 0xFF30] = value; // 電源 off 中も読み書き可
        return;
    }
    // 電源 off 中の書込みは NR41(noise length)だけが有効(DMG の例外)。
    // dmg_sound 01-registers test 6 / 11-regs after power test 4 が検査する。
    BOOL isLengthRegister = (address == 0xFF20);
    if (!_s.apuEnabled && !isLengthRegister) return;

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
        default:
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
    // length: step 0,2,4,6(256Hz)。チャンネルが無効でも length_enabled なら減算する
    // (dmg_sound 02-len ctr test 11/12)。
    if (step == 0 || step == 2 || step == 4 || step == 6) {
        MBSquareChannel sq[2] = { _s.square2[0], _s.square2[1] };
        for (NSInteger i = 0; i < 2; i++) {
            if (sq[i].lengthEnabled && sq[i].lengthCounter > 0) {
                sq[i].lengthCounter--;
                if (sq[i].lengthCounter == 0) sq[i].enabled = NO;
            }
        }
        _s.square2[0] = sq[0];
        _s.square2[1] = sq[1];
        if (_s.wave.lengthEnabled && _s.wave.lengthCounter > 0) {
            _s.wave.lengthCounter--;
            if (_s.wave.lengthCounter == 0) _s.wave.enabled = NO;
        }
        if (_s.noise.lengthEnabled && _s.noise.lengthCounter > 0) {
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

    // period==0/shift==0 でもオーバーフロー判定自体は行う(参照実装と同じ)
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

#pragma mark - DIV 書込み副作用

/// DIV($FF04)書込み: 内部カウンタの bit12 が 1→0 ならフレームシーケンサが 1 回余分に進む。
/// 参照実装 apu_notify_div_write と同じ(呼び出し時点の旧カウンタ値を受け取る)。
- (void)notifyDivWriteWithOldValue:(uint16_t)oldDivCounter {
    if (!_s.apuEnabled) return;
    if (oldDivCounter & 0x1000) {
        [self clockFrameSequencer];
    }
    _s.frameTimer = 0;
}

#pragma mark - チャンネル進行・サンプル生成

/// ch3 の 1 周期(32 サンプル)平均を -1..+1 で返す(ナイキスト超えフォールバック)。
- (float)waveCycleAverage {
    int32_t units = 0;
    for (int32_t position = 0; position < 32; position++) {
        units += WaveOutputUnits(&_s.wave, _s.waveRAM, position);
    }
    return (float)units / (32.0f * 15.0f);
}

- (void)emitSampleWithWave:(float)waveSample noise:(float)noiseSample {
    int16_t left = 0;
    int16_t right = 0;
    if (_s.apuEnabled) {
        float ch1 = PulseOutput(&_s.square2[0]);
        float ch2 = PulseOutput(&_s.square2[1]);
        float ch3 = waveSample;
        float ch4 = noiseSample;

        float leftVolume = (float)(((_s.nr50 >> 4) & 0x07) + 1) / 8.0f;
        float rightVolume = (float)((_s.nr50 & 0x07) + 1) / 8.0f;

        float leftMix = 0.0f;
        if (_s.nr51 & 0x10) leftMix += ch1;
        if (_s.nr51 & 0x20) leftMix += ch2;
        if (_s.nr51 & 0x40) leftMix += ch3;
        if (_s.nr51 & 0x80) leftMix += ch4;
        leftMix *= 0.25f * leftVolume;

        float rightMix = 0.0f;
        if (_s.nr51 & 0x01) rightMix += ch1;
        if (_s.nr51 & 0x02) rightMix += ch2;
        if (_s.nr51 & 0x04) rightMix += ch3;
        if (_s.nr51 & 0x08) rightMix += ch4;
        rightMix *= 0.25f * rightVolume;

        left = ScaleToInt16(leftMix);
        right = ScaleToInt16(rightMix);
    }
    int16_t pair[2] = { left, right };
    [_s.pendingSamples appendBytes:pair length:sizeof(pair)];
}

- (void)tickDots:(uint32_t)dots {
    for (uint32_t i = 0; i < dots; i++) {
        if (_s.apuEnabled) {
            _s.frameTimer++;
            if (_s.frameTimer >= kFrameSequencerPeriod) {
                _s.frameTimer -= kFrameSequencerPeriod;
                [self clockFrameSequencer];
            }

            TickSquareChannel(&_s.square2[0]);
            TickSquareChannel(&_s.square2[1]);

            // wave/noise は 1 T-cycle ごとの出力を蓄積し、サンプル採取時に平均する
            // (点サンプルによるエイリアシング対策、参照実装 T20-2)。
            _s.wave.sampleArea += WaveOutputUnits(&_s.wave, _s.waveRAM, _s.wave.phase);
            _s.wave.sampleCycles++;
            TickWaveChannel(&_s.wave);

            _s.noise.sampleArea += NoiseOutputUnits(&_s.noise);
            _s.noise.sampleCycles++;
            TickNoiseChannel(&_s.noise);
        }

        // APU 電源 off 中も一定レートで無音サンプルを出す(再生側のペーシングを崩さない)。
        _s.sampleCounter += kSampleRate;
        if (_s.sampleCounter >= kCpuHz) {
            _s.sampleCounter -= kCpuHz;

            float waveSample = 0.0f;
            if (_s.wave.sampleCycles > 0) {
                if (WaveAboveNyquist(_s.wave.freqRaw)) {
                    waveSample = [self waveCycleAverage];
                } else {
                    waveSample = (float)_s.wave.sampleArea
                                  / (float)_s.wave.sampleCycles / 15.0f;
                }
            }
            _s.wave.sampleArea = 0;
            _s.wave.sampleCycles = 0;

            float noiseSample = 0.0f;
            if (_s.noise.sampleCycles > 0) {
                noiseSample = (float)_s.noise.sampleArea
                              / (float)_s.noise.sampleCycles / 15.0f;
            }
            _s.noise.sampleArea = 0;
            _s.noise.sampleCycles = 0;

            [self emitSampleWithWave:waveSample noise:noiseSample];
        }
    }
}

@end

NS_ASSUME_NONNULL_END
