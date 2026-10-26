#import "MBAppDelegate.h"
#import "MBWindowController.h"
#import "MBAudioEngine.h"
#import "MBOptionParser.h"
#import "MBLaunchOptions.h"
#import "MBEmulatorSession.h"
#import "MBErrors.h"
#import "MBPorts.h"
#import "MBTestROMReport.h"
#import <signal.h>
#import <stdio.h>

NS_ASSUME_NONNULL_BEGIN

@interface MBAppDelegate () <NSWindowDelegate>
@property (nonatomic, strong) MBEmulatorSession *session;
@property (nonatomic, strong) MBWindowController *windowController;
@property (nonatomic, strong) MBAudioEngine *audioEngine;
@property (nonatomic, strong) MBLaunchOptions *options;
@property (nonatomic, strong) id localKeyEventMonitor;
@property (nonatomic) dispatch_source_t sigintSource;
@end

@implementation MBAppDelegate

/// CLI 起動本体。返り値 = プロセス終了コード(0=正常, 1=ランタイム, 2=引数)
- (int)applicationMain {
    NSApplication *app = [NSApplication sharedApplication];
    app.delegate = self;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // CLI 起動での SIGINT: dispatch_source で main queue へ転送し、クリーン停止
    // (セーブ書出し → 正常終了コード 0)。シグナル登録は UI 層のみで行う。
    signal(SIGINT, SIG_IGN);
    dispatch_source_t sigint = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigint, ^{
        NSError *error = nil;
        if (![self.session stopAndReturnError:&error]) {
            fprintf(stderr, "%s\n", MBUserFacingMessageForError(error).UTF8String);
        }
        [NSApp terminate:self];
    });
    dispatch_resume(sigint);
    self.sigintSource = sigint;

    int exitCode = [self runAppWithOptions:[NSProcessInfo processInfo].arguments];

    if (exitCode != 0) {
        // セッション生成失敗 → アプリ起動させず即返る(exitCode 1 or 2)
        return exitCode;
    }

    // GUI は一回だけ。通常は [NSApp run] が terminate まで戻らない
    return exitCode;
}

- (int)runAppWithOptions:(NSArray<NSString *> *)arguments {
    // 引数には実行ファイルのパス(argv[0])が含まれる → 削除
    if (arguments.count > 0) {
        arguments = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    }

    NSError *error = nil;
    MBOptionParser *parser = [[MBOptionParser alloc] init];
    MBLaunchOptions *options = [parser parseArguments:arguments error:&error];
    if (options == nil) {
        // FR-011: 診断メッセージは stderr・終了コードは 0/1/2(FR-005)
        fprintf(stderr, "%s\n", MBUserFacingMessageForError(error).UTF8String);
        fprintf(stderr, "%s\n", parser.usageText.UTF8String);
        return (int)MBExitCodeForError(error);
    }
    self.options = options;

    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    if (session == nil) {
        //カートリッジ・セーブ復元・エミュ起動エラー → 1 (FR-011)
        fprintf(stderr, "%s\n", MBUserFacingMessageForError(error).UTF8String);
        return (int)MBExitCodeForError(error);
    }

    // キー入力割当(FR-a8): 矢印=十字キー / Z=B / X=A / Enter=Start / スペース=Select
    MBWindowController *window = [[MBWindowController alloc] initWithCGSize:CGSizeMake(160 * options.scale, 144 * options.scale)];
    MBAudioEngine *audio = [[MBAudioEngine alloc] initWithVolumePercent:options.volumePercent];

    session.renderPort = window;
    session.audioOutPort = audio;
    session.logPort = [[MBStderrLogPort alloc] init]; // 未実装挙動の記録(憲法 V)
    self.session = session;
    self.windowController = window;
    self.audioEngine = audio;

    // 音声出力を開始(0% の場合もノードは起動し、ゲイン 0 で完全無音)
    [audio start];

    // キーイベントのモニタリング(ゲームキーはここで消費し AppKit へ渡さない。
    // 未処理キーとして responder chain まで届くと NSBeep が鳴るため)
    __weak MBAppDelegate *weakSelf = self;
    self.localKeyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *event) {
        BOOL consumed = [weakSelf dispatchKeyEvent:event];
        return consumed ? nil : event;
    }];

    // ウィンドウを閉じたらアプリを終了する(windowWillClose: → terminate)
    window.window.delegate = self;
    // FR-002: メニューを持たない。未設定だと AppKit が既定のアプリメニューを生成するため空にする
    NSApp.mainMenu = [[NSMenu alloc] init];
    [window showWindow:self];
    [NSApp activateIgnoringOtherApps:YES];

    // エミュレーション開始(内部スレッド)
    [session run];

    // terminate まで戻らない(セーブは NSApplicationWillTerminateNotification で)
    [NSApp run];
    return 0;
}

#pragma mark - key events

/// ゲームキーをエミュ入力へ写像したら YES を返す(モニタで消費 → AppKit 未処理ビープ防止)。
/// Cmd+Q 以外で Cmd/Ctrl/Option が押されている場合は消費しない。
- (BOOL)dispatchKeyEvent:(NSEvent *)event {
    BOOL pressed = (event.type == NSEventTypeKeyDown);
    // Cmd+Q は終了操作(FR-002 によりメニューを持たないため、キーモニタで直接処理する)
    if (pressed && (event.modifierFlags & NSEventModifierFlagCommand)
        && [event.charactersIgnoringModifiers caseInsensitiveCompare:@"q"] == NSOrderedSame) {
        [NSApp terminate:self];
        return YES;
    }
    if (pressed && (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))) {
        return NO;
    }
    NSString *chars = event.charactersIgnoringModifiers;
    MBButton button;
    if (chars.length == 0) return NO;
    unichar c = [chars characterAtIndex:0];
    switch (c) {
        case NSUpArrowFunctionKey:    button = MBButtonUp; break;
        case NSDownArrowFunctionKey:  button = MBButtonDown; break;
        case NSLeftArrowFunctionKey:  button = MBButtonLeft; break;
        case NSRightArrowFunctionKey: button = MBButtonRight; break;
        case 'z': case 'Z':           button = MBButtonB; break;
        case 'x': case 'X':           button = MBButtonA; break;
        case '\r':                    button = MBButtonStart; break;
        case ' ':                     button = MBButtonSelect; break;
        default: return NO;
    }
    [self.session setButton:button pressed:pressed];
    return YES;
}

#pragma mark - clean stop(ウィンドウ閉鎖・terminate・SIGINT 共通)

- (void)dealloc {
    if (self.localKeyEventMonitor != nil) {
        [NSEvent removeMonitor:self.localKeyEventMonitor];
    }
}

- (void)stopSessionIfRunning {
    if (self.session != nil && !self.session.stopped) {
        [self.session stopAndReturnError:nil];
    }
}

- (void)cleanupSession {
    [self stopSessionIfRunning];
}

#pragma mark - NSApplicationDelegate / NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    [self cleanupSession];
    [NSApp terminate:self];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self cleanupSession];
}

@end

NS_ASSUME_NONNULL_END
