#import "MBApu.h"

NS_ASSUME_NONNULL_BEGIN

// 実装メモ(research R-3):
//   コアは PCM サンプル生成のみ。音量適用・再生は UI 層の MBAudioOutPort 実装が担う。
//   サンプル出力= 4 T-cycle(1 M-cycle)毎に 1 サンプル → 約 1.048MHz で生成し、
//   セッションがフレーム境界で取り出す(1 フレーム ≒ 7488 M-cycle / 2 チャンネル int16)。
//   簡易化: 各チャンネルの動作は最低限(方形波 duty・ノイズ LFSR), エンベロープは
//   レジスタ値の静的反映。

typedef struct {
    BOOL enabled;
    uint8_t duty;
    uint16_t freqRaw;
    int32_t divider;
    int32_t phase;
    uint8_t volume;
    uint8_t envStep;
    int8_t envDir;
    uint16_t lengthCounter;
} MBSquareChannel;

typedef struct {
    BOOL enabled;
    uint16_t freqRaw;
    int32_t divider;
    int32_t phase;
    uint8_t volumeShift;   // NR1C: 0=25%? → 実装は 0=ミュート 1,2,3 でシフト量
    uint16_t lengthCounter;
} MBWaveChannel;

typedef struct {
    BOOL enabled;
    uint8_t volume;
    uint8_t envStep;
    int8_t envDir;
    uint16_t lfsr;
    uint16_t divider;
    uint8_t shift;         // NR43 bit4-7
    uint8_t widthMode;     // NR43 bit3
    uint16_t lengthCounter;
} MBNoiseChannel;

#pragma mark - Duty パターン

static const uint8_t kDutyPatterns[4][8] = {
    {0,0,0,0,0,0,0,1},
    {1,0,0,0,0,0,0,1},
    {1,0,0,0,0,1,1,1},
    {0,1,1,1,1,1,1,0},
};

#pragma mark - DMG 電源投入相当初期値

static const uint8_t kDefaultNR50 = 0x77;
static const uint8_t kDefaultNR51 = 0xF3;

// 1 サンプル出力あたりの T-cycle 数: 4194304 (dot/s) ÷ 48000 (sample/s) ≒ 87.38(research R-3)
static const double kDotsPerOutputSample = 4194304.0 / 48000.0;

@interface MBApu ()
{
@public
    MBSquareChannel _square[2];
    MBWaveChannel _wave;
    MBNoiseChannel _noise;
    uint8_t _waveRAM[16];
    uint8_t _nr50;
    uint8_t _nr51;
    BOOL _apuEnabled;
    int32_t _frameTimer;
    int32_t _frameStep;
    double _dotsToNextSample; // 出力レートへの間引き用残り dots(87.38 ≒ 4194304/48000)
    NSMutableData *_pendingSamples;
}
@end

@implementation MBApu

- (instancetype)initWithDefaults {
    self = [super init];
    if (self) {
        _pendingSamples = [NSMutableData data];
        _apuEnabled = YES;
        _nr50 = kDefaultNR50;
        _nr51 = kDefaultNR51;
        for (NSInteger i = 0; i < 2; i++) {
            _square[i].enabled = NO;
            _square[i].duty = 2;
            _square[i].divider = 0;
            _square[i].freqRaw = 0;
            _square[i].volume = 8;
            _square[i].envStep = 0;
            _square[i].lengthCounter = 64;
        }
        _wave.enabled = NO;
        _wave.volumeShift = 2;
        _wave.lengthCounter = 256;
        memset(_waveRAM, 0, sizeof(_waveRAM));
        _noise.enabled = NO;
        _noise.volume = 8;
        _noise.envStep = 0;
        _noise.shift = 4;
        _noise.widthMode = 0;
        _noise.lengthCounter = 64;
        _noise.lfsr = 0x7FFF;
        _frameTimer = 0;
        _frameStep = 0;
        _dotsToNextSample = kDotsPerOutputSample;
    }
    return self;
}

- (instancetype)init {
    return [self initWithDefaults];
}

- (NSMutableData *)pendingSamples {
    return _pendingSamples;
}

- (NSUInteger)pendingSampleCount {
    return _pendingSamples.length / sizeof(int16_t);
}

- (NSMutableData *)takePendingSamples {
    NSMutableData *result = _pendingSamples;
    _pendingSamples = [NSMutableData data];
    return result;
}

#pragma mark - レジスタ

- (void)writeRegister:(uint8_t)value address:(uint16_t)address {
    // NR52 bit7 がクリアの間は、NR52 を除くレジスタへの書込みを無視する
    if (!_apuEnabled && address != 0xFF26) return;
    switch (address) {
        case 0xFF11: _square[0].duty = (value >> 6) & 0x03; break;
        case 0xFF12:
            _square[0].volume = (value >> 4) & 0x0F;
            _square[0].envStep = value & 0x07;
            _square[0].envDir = (value & 0x08) ? 1 : -1;
            if (value == 0) { _square[0].enabled = NO; }
            break;
        case 0xFF13: _square[0].freqRaw = (uint16_t)((_square[0].freqRaw & 0x0700) | value); break;
        case 0xFF14:
            _square[0].freqRaw = (uint16_t)((_square[0].freqRaw & 0x00FF) | ((value & 0x07) << 8));
            if (value & 0x80) { // trigger
                _square[0].enabled = YES;
                _square[0].phase = 0;
                _square[0].divider = 0;
                _square[0].lengthCounter = (_square[0].lengthCounter == 0) ? 64 : _square[0].lengthCounter;
            }
            break;
        case 0xFF16: _square[1].duty = (value >> 6) & 0x03; break;
        case 0xFF17:
            _square[1].volume = (value >> 4) & 0x0F;
            _square[1].envStep = value & 0x07;
            _square[1].envDir = (value & 0x08) ? 1 : -1;
            if (value == 0) { _square[1].enabled = NO; }
            break;
        case 0xFF18: _square[1].freqRaw = (uint16_t)((_square[1].freqRaw & 0x0700) | value); break;
        case 0xFF19:
            _square[1].freqRaw = (uint16_t)((_square[1].freqRaw & 0x00FF) | ((value & 0x07) << 8));
            if (value & 0x80) {
                _square[1].enabled = YES;
                _square[1].phase = 0;
                _square[1].divider = 0;
            }
            break;
        case 0xFF1A:
            _wave.enabled = (value & 0x80) != 0;
            break;
        case 0xFF1C:
            _wave.volumeShift = (uint8_t)((value >> 5) & 0x03);
            break;
        case 0xFF1E:
            _wave.freqRaw = (uint16_t)((_wave.freqRaw & 0x00FF) | ((value & 0x07) << 8));
            _wave.divider = 0;
            break;
        case 0xFF21:
            _noise.volume = (value >> 4) & 0x0F;
            _noise.envStep = value & 0x07;
            _noise.envDir = (value & 0x08) ? 1 : -1;
            if (value == 0) { _noise.enabled = NO; }
            break;
        case 0xFF22:
            _noise.shift = (value >> 4) & 0x0F;
            _noise.widthMode = (value >> 3) & 0x01;
            _noise.divider = value & 0x07;
            break;
        case 0xFF23:
            if (value & 0x80) {
                _noise.enabled = YES;
                _noise.lfsr = 0x7FFF;
            }
            break;
        case 0xFF24: _nr50 = value; break;
        case 0xFF25: _nr51 = value; break;
        case 0xFF26:
            _apuEnabled = (value & 0x80) != 0;
            if (!_apuEnabled) {
                _square[0].enabled = NO;
                _square[1].enabled = NO;
                _wave.enabled = NO;
                _noise.enabled = NO;
            }
            break;
        default:
            if (address >= 0xFF30 && address <= 0xFF3F) {
                _waveRAM[address - 0xFF30] = value;
            }
            break;
    }
}

- (uint8_t)readRegister:(uint16_t)address {
    switch (address) {
        case 0xFF11: return (uint8_t)((_square[0].duty << 6) | 0x3F);
        case 0xFF12: return (uint8_t)((_square[0].volume << 4) | _square[0].envStep | (_square[0].envDir > 0 ? 0x08 : 0));
        case 0xFF14: return (uint8_t)0x80 | (uint8_t)((_square[0].freqRaw >> 8) & 0x07);
        case 0xFF16: return (uint8_t)((_square[1].duty << 6) | 0x3F);
        case 0xFF17: return (uint8_t)((_square[1].volume << 4) | _square[1].envStep | (_square[1].envDir > 0 ? 0x08 : 0));
        case 0xFF18: return (uint8_t)0x00;
        case 0xFF19: return (uint8_t)0x80 | (uint8_t)((_square[1].freqRaw >> 8) & 0x07);
        case 0xFF1A: return (uint8_t)(_wave.enabled ? 0x80 : 0x7F);
        case 0xFF1C: return (uint8_t)((_wave.volumeShift << 5) | 0x9F);
        case 0xFF21: return (uint8_t)((_noise.volume << 4) | _noise.envStep | (_noise.envDir > 0 ? 0x08 : 0));
        case 0xFF22: return (uint8_t)((_noise.shift << 4) | (_noise.widthMode << 3) | _noise.divider);
        case 0xFF23: return (uint8_t)0x80;
        case 0xFF24: return _nr50;
        case 0xFF25: return _nr51;
        case 0xFF26: return (uint8_t)((_apuEnabled ? 0x80 : 0x00) | 0x70); // DMG: bit7=電源、bit4-6=1、bit0-3=0
        default:
            if (address >= 0xFF30 && address <= 0xFF3F) {
                return _waveRAM[address - 0xFF30];
            }
            return 0xFF;
    }
}

- (uint8_t)nr52Value {
    uint8_t result = _apuEnabled ? 0x80 : 0x00;
    if (_apuEnabled) {
        if (_square[0].enabled) result |= 0x01;
        if (_square[1].enabled) result |= 0x02;
        if (_wave.enabled)      result |= 0x04;
        if (_noise.enabled)     result |= 0x08;
    }
    return result;
}

#pragma mark - Ticking

- (void)tickDots:(uint32_t)dots {
    if (!_apuEnabled) return;
    for (uint32_t i = 0; i < dots; i++) {
        // フレームシーケンサ(8192 T-cycle = 512Hz)
        _frameTimer++;
        if (_frameTimer >= 8192) {
            _frameTimer = 0;
            _frameStep = (_frameStep + 1) & 7;
            if ((_frameStep & 3) == 3) {
                _square[0].volume = (uint8_t)MIN(15, MAX(0, (int)_square[0].volume + (int)_square[0].envDir));
                _square[1].volume = (uint8_t)MIN(15, MAX(0, (int)_square[1].volume + (int)_square[1].envDir));
                _noise.volume = (uint8_t)MIN(15, MAX(0, (int)_noise.volume + (int)_noise.envDir));
            }
        }
        [self tickChannels];
        _dotsToNextSample -= 1.0;
        if (_dotsToNextSample <= 0.0) {
            _dotsToNextSample += kDotsPerOutputSample;
            [self emitSample];
        }
    }
}

- (void)tickChannels {
    for (NSInteger i = 0; i < 2; i++) {
        MBSquareChannel *ch = &_square[i];
        if (!ch->enabled) continue;
        ch->divider++;
        int32_t period = (int32_t)(2048 - ch->freqRaw) * 4; // 概算(4 T-cycle 単位の分周)
        if (period <= 0) period = 1;
        if (ch->divider >= period) {
            ch->divider = 0;
            ch->phase = (ch->phase + 1) & 7;
        }
    }
    if (_wave.enabled) {
        _wave.divider++;
        int32_t period = MAX(1, (2048 - _wave.freqRaw) * 2);
        if (_wave.divider >= period) {
            _wave.divider = 0;
            _wave.phase = (_wave.phase + 1) & 31;
        }
    }
    if (_noise.enabled) {
        uint32_t per = (uint32_t)MAX(1, ((_noise.divider + 1) * (1 << _noise.shift)));
        _noise.divider++;
        if (_noise.divider >= (int32_t)per) {
            uint16_t xorBit = (_noise.lfsr ^ (_noise.lfsr >> 1)) & 0x01;
            _noise.lfsr = (uint16_t)((_noise.lfsr >> 1) | (xorBit << 14));
            if (_noise.widthMode) {
                _noise.lfsr = (uint16_t)((_noise.lfsr & ~0x40) | (xorBit << 6));
            }
            _noise.divider = 0;
        }
    }
}

- (void)emitSample {
    int32_t sample = 0;
    if (_square[0].enabled) {
        if (kDutyPatterns[_square[0].duty][_square[0].phase]) sample += _square[0].volume;
    }
    if (_square[1].enabled) {
        if (kDutyPatterns[_square[1].duty][_square[1].phase]) sample += _square[1].volume;
    }
    if (_wave.enabled && _wave.volumeShift > 0) {
        uint8_t n = _waveRAM[_wave.phase / 2];
        uint8_t nibble = (_wave.phase & 1) ? (n & 0x0F) : (n >> 4);
        sample += (int32_t)nibble >> (_wave.volumeShift == 1 ? 3 : _wave.volumeShift == 2 ? 1 : 0);
    }
    if (_noise.enabled) {
        if ((_noise.lfsr & 0x01) == 0) sample += _noise.volume;
    }

    // 4 チャンネル合算(0-60 程度)を int16 に写像し、L/R 同一値で 2ch 書き出す
    int16_t value = (int16_t)((sample - 24) * 1000);
    int16_t pair[2] = { value, value };
    [_pendingSamples appendBytes:pair length:sizeof(pair)];
}

@end

NS_ASSUME_NONNULL_END
