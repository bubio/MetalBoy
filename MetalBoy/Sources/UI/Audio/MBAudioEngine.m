#import "MBAudioEngine.h"
#import "MBPorts.h"

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger kOutputSampleRate = 48000;

@interface MBAudioEngine ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioSourceNode *sourceNode;
@property (nonatomic, strong) AVAudioFormat *format;
@property (nonatomic, strong) NSMutableData *sampleBuffer;
@property (nonatomic) NSLock *bufferLock;
@property (nonatomic, readwrite) NSUInteger volumePercent;
@end

@implementation MBAudioEngine

- (instancetype)initWithVolumePercent:(NSUInteger)volumePercent {
    self = [super init];
    if (self) {
        _volumePercent = MIN(MAX(volumePercent, 0), 100);
        _sampleBuffer = [NSMutableData data];
        _bufferLock = [[NSLock alloc] init];
        _engine = [[AVAudioEngine alloc] init];
        _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:(double)kOutputSampleRate
                                                                channels:2];
        __weak MBAudioEngine *weakSelf = self;
        _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:_format renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount, AudioBufferList *outputData) {
            return [weakSelf renderIntoBufferList:outputData frameCount:frameCount isSilence:isSilence];
        }];
        [_engine attachNode:_sourceNode];
        [_engine connect:_sourceNode to:_engine.mainMixerNode format:_format];
        [_engine connect:_engine.mainMixerNode to:_engine.outputNode format:_format];
        _engine.mainMixerNode.outputVolume = (float)((float)volumePercent / 100.0f);
    }
    return self;
}

- (instancetype)init {
    return [self initWithVolumePercent:50];
}

- (void)dealloc {
    if (self.engine != nil && self.engine.isRunning) {
        [self.engine stop];
    }
}

- (void)setVolumePercent:(NSUInteger)volumePercent {
    volumePercent = MIN(MAX(volumePercent, 0), 100);
    _volumePercent = volumePercent;
    self.engine.mainMixerNode.outputVolume = (float)(volumePercent / 100.0);
}

#pragma mark - MBAudioOutPort

- (void)enqueueSamples:(const int16_t *)samples count:(NSUInteger)count {
    if (samples == nil || count == 0) return;
    NSData *data = [NSData dataWithBytes:samples length:count * sizeof(int16_t)];
    // キューが積みすぎる場合は捨てさ(research R-3: 一定のレイテンシを保つ)
    [self pushSamples:data];
}

- (void)pushSamples:(NSData *)samples {
    if (samples.length == 0) return;
    [self.bufferLock lock];
    // 上限: 100 ms 分を超えたから切る
    NSUInteger maxBytes = (NSUInteger)(kOutputSampleRate * 0.2) * 2 * sizeof(int16_t);
    if (self.sampleBuffer.length > maxBytes) {
        NSUInteger excess = self.sampleBuffer.length - maxBytes;
        [self.sampleBuffer replaceBytesInRange:NSMakeRange(0, excess) withBytes:NULL length:0];
    }
    [self.sampleBuffer appendData:samples];
    [self.bufferLock unlock];
}

/// bool 判定ではなく内部データから自動で詰める(research R-3)
- (OSStatus)renderIntoBufferList:(AudioBufferList *)bufferList
                      frameCount:(AVAudioFrameCount)frameCount
                       isSilence:(BOOL *)isSilence {
    if (isSilence) { *isSilence = NO; }
    NSUInteger neededInt16 = (NSUInteger)frameCount * 2; // ステレオ(2ch × frames)
    NSUInteger needBytes = neededInt16 * sizeof(int16_t);

    [self.bufferLock lock];
    NSUInteger bytesToTake = MIN(self.sampleBuffer.length, needBytes);
    NSData *chunk = [NSData dataWithBytes:self.sampleBuffer.bytes length:bytesToTake];
    if (bytesToTake > 0) {
        [self.sampleBuffer replaceBytesInRange:NSMakeRange(0, bytesToTake) withBytes:NULL length:0];
    }
    [self.bufferLock unlock];

    const int16_t *source = (const int16_t *)chunk.bytes;
    for (NSUInteger channel = 0; channel < bufferList->mNumberBuffers; channel++) {
        AudioBuffer *buffer = &bufferList->mBuffers[channel];
        float *output = (float *)buffer->mData;
        buffer->mNumberChannels = 1;
        for (NSUInteger frame = 0; frame < frameCount; frame++) {
            NSUInteger idx = frame * 2 + channel;
            if (idx < chunk.length / sizeof(int16_t)) {
                output[frame] = (float)(source[idx] / 32768.0);
            } else {
                output[frame] = 0.0f; // データ不足 → 無音
            }
        }
        buffer->mDataByteSize = (UInt32)(frameCount * sizeof(float));
    }
    return noErr;
}

- (BOOL)start {
    NSError *error = nil;
    if (![self.engine startAndReturnError:&error]) {
        NSLog(@"AVAudioEngine start failed: %@", error);
        return NO;
    }
    return YES;
}

@end

NS_ASSUME_NONNULL_END
