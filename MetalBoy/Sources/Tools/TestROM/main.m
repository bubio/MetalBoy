#import <Foundation/Foundation.h>
#import "MBLaunchOptions.h"
#import "MBEmulatorSession.h"
#import "MBErrors.h"
#import "MBTestROMReport.h"
#import <stdio.h>

// metalboy-testrom(headless 検証ツール・research R-9)
//
// 用法: metalboy-testrom <rom> [--frames N] [--json]
//
// 指定 ROM をヘッドレス(GUI なし)で指定フレーム数だけ駆動し、
// シリアル出力($FF01/$FF02 経由)を blargg 形式($0x81 開始)として収集して報告する。
// 既定は人間可読(シリアル出力を stdout・ログイベントを stderr)、--json は
// 結果・シリアル出力・ログイベントを 1 つの JSON として stdout に出す(憲法 V)。
// 終了コード: 0=正常終了, 1=起動・セーブ・実行エラー, 2=引数エラー

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: metalboy-testrom <rom-path> [--frames N] [--json]\n");
            return 2;
        }
        NSString *romPath = [NSString stringWithUTF8String:argv[1]];
        NSUInteger frames = 1800; // 30 秒相当(59.727fps)
        BOOL json = NO;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) {
                frames = (NSUInteger)MAX(1, atoi(argv[i + 1]));
                i++;
            } else if (strcmp(argv[i], "--json") == 0) {
                json = YES;
            }
        }

        NSError *error = nil;
        MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:romPath scale:3 volumePercent:0];
        MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
        if (session == nil) {
            fprintf(stderr, "%s\n", MBUserFacingMessageForError(error).UTF8String);
            return (int)MBExitCodeForError(error);
        }

        MBTestROMReport *report = [[MBTestROMReport alloc] initWithROMPath:romPath frames:frames];
        MBStderrLogPort *stderrLog = [[MBStderrLogPort alloc] init];
        session.logPort = json ? report : stderrLog;
        __block BOOL sawFirstByte = NO;
        session.serialOutputHandler = ^(uint8_t byte) {
            if (byte == 0x81 && !sawFirstByte) {
                sawFirstByte = YES;
                return; // blargg 先頭マーカー($81)はテキスト化の対象外
            }
            sawFirstByte = YES;
            [report appendSerialByte:byte];
        };

        [session runFrames:frames];

        // 終了時の .sav 書出し(通常アプリと同経路の検証)。save 失敗はエラーレポートのみ
        NSError *stopError = nil;
        if (![session stopAndReturnError:&stopError]) {
            fprintf(stderr, "%s\n", MBUserFacingMessageForError(stopError).UTF8String);
        }

        if (json) {
            NSData *data = [report JSONData];
            fwrite(data.bytes, 1, data.length, stdout);
            printf("\n");
        } else if (report.serialText.length == 0) {
            printf("シリアル出力なし(%lu フレーム駆動)\n", (unsigned long)frames);
        } else {
            printf("%s", report.serialText.UTF8String);
        }
        return 0;
    }
}
