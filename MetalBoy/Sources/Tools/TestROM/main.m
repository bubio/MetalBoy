#import <Foundation/Foundation.h>
#import "MBOptionParser.h"
#import "MBLaunchOptions.h"
#import "MBEmulatorSession.h"
#import "MBErrors.h"
#import "MBSaveFile.h"
#import <stdio.h>

// metalboy-testrom(headless 検証ツール・research R-9)
//
// 用法: metalboy-testrom <rom> [--frames N]
//
// 指定 ROM をヘッドレス(GUI なし)で指定フレーム数だけ駆動し、
// シリアル出力($FF01/$FF02 経由)を blargg 形式($0x81 開始)として収集して報告する。
// 終了コード: 0=正常終了("Passed" 出力に到達), 1=起動・セーブ・実行エラー, 2=引数エラー

static void AppendSerialByte(NSMutableData *data, uint8_t byte) {
    [data appendBytes:&byte length:1];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: metalboy-testrom <rom-path> [--frames N]\n");
            return 2;
        }
        NSString *romPath = [NSString stringWithUTF8String:argv[1]];
        NSUInteger frames = 1800; // 30 秒相当(59.727fps)
        for (int i = 2; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--frames") == 0) {
                frames = (NSUInteger)MAX(1, atoi(argv[i + 1]));
                i++;
            }
        }

        MBOptionParser *parser = [[MBOptionParser alloc] init];
        NSError *error = nil;
        MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:romPath scale:3 volumePercent:0];
        (void)parser;

        MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
        if (session == nil) {
            fprintf(stderr, "%s\n", MBUserFacingMessageForError(error).UTF8String);
            return (int)MBExitCodeForError(error);
        }

        NSMutableData *serialOutput = [NSMutableData data];
        session.serialOutputHandler = ^(uint8_t byte) {
            if (byte == 0x81 && serialOutput.length == 0) {
                return; // blargg 先頭マーカー($81)はテキスト化の対象外
            }
            AppendSerialByte(serialOutput, byte);
        };

        [session runFrames:frames];

        // 終了時の .sav 書出し(通常アプリと同経路の検証)。save 失敗はエラーレポートのみ
        NSError *stopError = nil;
        if (![session stopAndReturnError:&stopError]) {
            fprintf(stderr, "%s\n", MBUserFacingMessageForError(stopError).UTF8String);
        }

        NSString *outputText = [[NSString alloc] initWithData:serialOutput
                                                     encoding:NSISOLatin1StringEncoding];
        if (outputText.length == 0) {
            printf("シリアル出力なし(%lu フレーム駆動)\n", (unsigned long)frames);
            return 0;
        }
        printf("%s", outputText.UTF8String);
        return 0;
    }
}
