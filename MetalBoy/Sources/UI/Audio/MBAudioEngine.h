#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 音声出力( AVAudioEngine + AVAudioSourceNode )。コアから供給された
/// ステレオ int16 の PCM をキューから消費し、出力フォーマット(float32)へ変換します。
/// 音量は mainMixerNode.outputVolume に 0〜100% を写像して適用(research R-3)。
@interface MBAudioEngine : NSObject

- (instancetype)initWithVolumePercent:(NSUInteger)volumePercent;

/// 消費キューに PCM(int16 ×2ch)を追加(エミュレーションスレッドから呼ばれる)
- (void)pushSamples:(NSData *)samples;

/// 音量の動的変更 (0-100)
- (void)setVolumePercent:(NSUInteger)volumePercent;

- (BOOL)start;

@end

NS_ASSUME_NONNULL_END
