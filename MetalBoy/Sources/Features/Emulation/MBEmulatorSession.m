#import "MBEmulatorSession.h"
#import "MBLaunchOptions.h"
#import "MBSaveFile.h"
#import "MBErrors.h"
#import "MBGameBoy.h"
#import "MBCartridge.h"
#import "MBPPU.h"
#import "MBApu.h"
#import "MBJoypad.h"
#import <mach/mach_time.h>
#import <mach/mach_time.h> // mach_wait_until

NS_ASSUME_NONNULL_BEGIN

/// 実時間ペース: NTSC Game Boy 59.7275 fps(research R-2/R-3)
static const double kFramesPerSecond = 59.7275;

@interface MBEmulatorSession ()
@property (nonatomic, readwrite, strong) MBGameBoy *machine;
@property (nonatomic, readwrite, strong) MBLaunchOptions *options;
@property (nonatomic, readwrite, strong) MBSaveFile *saveFile;
@property (nonatomic, readwrite) BOOL stopped;
@property (nonatomic, readwrite) NSUInteger frameCount;
@property (nonatomic) dispatch_queue_t runQueue;
@property (nonatomic) dispatch_semaphore_t doneSemaphore;
@property (nonatomic) BOOL stopRequested;
@property (nonatomic) BOOL runStarted;
@end

/// MBButton → MBJoypad のビットマスク写像(範囲外は 0)
static uint32_t MBJoypadButtonMaskFromButton(MBButton button) {
    switch (button) {
        case MBButtonUp:     return MBJoypadButtonUp;
        case MBButtonDown:   return MBJoypadButtonDown;
        case MBButtonLeft:   return MBJoypadButtonLeft;
        case MBButtonRight:  return MBJoypadButtonRight;
        case MBButtonA:      return MBJoypadButtonA;
        case MBButtonB:      return MBJoypadButtonB;
        case MBButtonStart:  return MBJoypadButtonStart;
        case MBButtonSelect: return MBJoypadButtonSelect;
        default:             return 0;
    }
}

@implementation MBEmulatorSession

- (nullable instancetype)initWithOptions:(MBLaunchOptions *)options
                                   error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (options == nil || options.romPath.length == 0) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:MBErrorCodeROMNotSpecified
                                            userInfo:nil];
        return nil;
    }
    _options = options;

    // ROM 存在確認(FR-014)
    if (![[NSFileManager defaultManager] fileExistsAtPath:options.romPath]) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:MBErrorCodeROMNotFound
                                            userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                    [NSString stringWithFormat:@"ROM ファイルが見つかりません: %@", options.romPath]}];
        return nil;
    }

    // ROM 読み込み
    NSError *readError = nil;
    NSData *romData = [NSData dataWithContentsOfFile:options.romPath options:NSDataReadingMappedIfSafe error:&readError];
    if (romData == nil) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:MBErrorCodeInvalidROM
                                            userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                    [NSString stringWithFormat:@"ROM ファイルを読み込めませんでした: %@", options.romPath]}];
        return nil;
    }

    // カートリッジ解析(MBC0/1/2/3/5 のみ対応・FR-016/FR-012)
    NSError *cartError = nil;
    MBCartridge *cartridge = [[MBCartridge alloc] initWithROMData:romData error:&cartError];
    if (cartridge == nil) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:[MBEmulatorSession cartridgeErrorCodeFor:cartError.code]
                                            userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                    MBUserFacingMessageForError(cartError)}];
        return nil;
    }

    // セーブファイル復元(FR-013: ROM と同じディレクトリの <ROM名>.sav)
    _saveFile = [[MBSaveFile alloc] initWithPath:[MBSaveFile saveFilePathForROMPath:options.romPath]];
    if (cartridge.hasBattery && cartridge.ramSize > 0) {
        NSError *saveError = nil;
        NSData *savedRAM = [_saveFile loadWithError:&saveError];
        if (savedRAM != nil) {
            NSError *restoreError = nil;
            if (![cartridge restoreRAM:savedRAM error:&restoreError]) {
                // サイズ不一致・破損は黙って上書きせず起動失敗(research R-7)
                if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                        code:MBErrorCodeSaveLoadFailed
                                                    userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                            MBUserFacingMessageForError(restoreError)}];
                return nil;
            }
        } else if (saveError != nil) {
            if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                    code:MBErrorCodeSaveLoadFailed
                                                userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                        MBUserFacingMessageForError(saveError)}];
            return nil;
        }
    }

    // マシン構築(初期化)
    NSError *machineError = nil;
    _machine = [[MBGameBoy alloc] initWithCartridge:cartridge error:&machineError];
    if (_machine == nil) {
        if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                code:MBErrorCodeEmulationStartFailed
                                            userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                    @"エミュレーション初期化に失敗しました"}];
        return nil;
    }
    // 未実装・未定義挙動は logPort へ記録する(憲法 V)
    __weak MBEmulatorSession *weakSelf = self;
    _machine.cpu.unimplementedBehaviorHandler = ^(NSString *message) {
        [weakSelf.logPort logEvent:MBLogEventUnimplementedBehavior message:message];
    };
    _runQueue = dispatch_queue_create("com.metalboy.emulation", DISPATCH_QUEUE_SERIAL);
    _doneSemaphore = dispatch_semaphore_create(0);
    _stopped = NO;
    return self;
}

+ (MBErrorCode)cartridgeErrorCodeFor:(NSInteger)cartCode {
    switch (cartCode) {
        case MBCartridgeErrorCodeUnsupportedType: return MBErrorCodeUnsupportedMapper;
        case MBCartridgeErrorCodeCgbOnlyROM:      return MBErrorCodeCgbOnly;
        default:                                  return MBErrorCodeInvalidROM;
    }
}

#pragma mark - Ports

- (void)setSerialOutputHandler:(void (^ _Nullable)(uint8_t))serialOutputHandler {
    _serialOutputHandler = serialOutputHandler;
    self.machine.serialOutputHandler = serialOutputHandler;
}

#pragma mark - drive(1 フレーム分の処理・ポート配信)

- (void)driveFrame {
    [self.machine runFrame];
    self.frameCount++;

    // 描画(research R-2: UI 側 port へピクセル供給)
    if (self.renderPort != nil) {
        const uint32_t *pixels = (const uint32_t *)self.machine.ppu.framebuffer.bytes;
        [self.renderPort presentFramebuffer:pixels];
    }

    // 音声(research R-3: コア内はモノラル複製 int16 ×2)
    if (self.audioOutPort != nil) {
        NSMutableData *samples = [self.machine.apu takePendingSamples];
        if (samples.length >= 4) {
            [self.audioOutPort enqueueSamples:(const int16_t *)samples.bytes count:samples.length / 2];
        }
    }
}

#pragma mark - run(実時間)

- (void)run {
    if (self.runStarted) return;
    self.runStarted = YES;
    self.stopRequested = NO;

    uint64_t start = mach_absolute_time();
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    static const uint64_t kNanosPerSecond = NSEC_PER_SEC;
    uint64_t frameNanos = (uint64_t)(kNanosPerSecond / kFramesPerSecond);

    dispatch_async(self.runQueue, ^{
        uint64_t frameIndex = 0;
        while (!self.stopRequested) {
            @autoreleasepool {
                uint64_t target = start + ((frameIndex * frameNanos) / timebase.numer * timebase.denom);
                uint64_t now = mach_absolute_time();
                if (target > now) {
                    mach_wait_until(target);
                }
                [self driveFrame];
            }
            frameIndex++;
        }
        dispatch_semaphore_signal(self.doneSemaphore);
    });
}

- (void)runFrames:(NSUInteger)frames {
    for (NSUInteger i = 0; i < frames; i++) {
        @autoreleasepool {
            [self driveFrame];
        }
    }
}

#pragma mark - stop

- (BOOL)stopAndReturnError:(NSError **)error {
    if (self.stopped) return YES;
    self.stopRequested = YES;
    if (self.runStarted) {
        dispatch_semaphore_wait(self.doneSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    self.stopped = YES;

    // セーブ書出し(FR-013: 終了時に SRAM の内容を .sav へ生ダンプ)
    MBCartridge *cartridge = self.machine.cartridge;
    if (cartridge.hasBattery && cartridge.ramSize > 0) {
        NSData *ram = cartridge.currentRAM;
        if (ram != nil) {
            NSError *saveError = nil;
            if (![self.saveFile saveData:ram error:&saveError]) {
                if (error) *error = [NSError errorWithDomain:MBErrorDomain
                                                        code:MBErrorCodeSaveWriteFailed
                                                    userInfo:@{NSLocalizedFailureReasonErrorKey:
                                                            MBUserFacingMessageForError(saveError)}];
                return NO;
            }
        }
    }
    return YES;
}

#pragma mark - MBInputPort実装(ボタン → Joypad 写像)

- (void)setButton:(MBButton)button pressed:(BOOL)pressed {
    uint32_t mask = MBJoypadButtonMaskFromButton(button);
    if (mask == 0) return;
    uint32_t current = self.machine.joypad.pressedMask;
    if (pressed) {
        self.machine.joypad.pressedMask = (uint8_t)(current | mask);
    } else {
        self.machine.joypad.pressedMask = (uint8_t)(current & ~mask);
    }
}

@end

NS_ASSUME_NONNULL_END
