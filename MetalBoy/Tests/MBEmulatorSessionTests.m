#import <XCTest/XCTest.h>
#import "MBEmulatorSession.h"
#import "MBLaunchOptions.h"
#import "MBPorts.h"
#import "MBPPU.h"
#import "MBSaveFile.h"
#import "MBErrors.h"
#import <mach/mach_time.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// テスト用 ROM: $100 から LD A,$81 → LD ($FF01),A → LDH ($FF02),A(シリアル転送)
// → 無限ループ(jr -2)。シリアル出力 1 バイトがセッションのハンドラに届く。
static NSData *MakeSerialOutputROM(void) {
    uint8_t rom[0x8000];
    memset(rom, 0x00, sizeof(rom));
    const uint8_t program[] = {
        0x3E, 0x81,        // LD A, $81
        0xE0, 0x01,        // LDH ($FF01), A
        0xE0, 0x02,        // LDH ($FF02), A  → 転送開始(転送 1 byte)
        0x18, 0xFE,        // JR -2(無限ループ)
    };
    memcpy(rom + 0x100, program, sizeof(program));
    rom[0x0147] = 0x00;
    rom[0x0149] = 0x00;
    return [NSData dataWithBytes:rom length:sizeof(rom)];
}

// フレームバッファを記録するテスト用 RenderPort
@interface MBRecordingRenderPort : NSObject <MBRenderPort>
@property (nonatomic) NSUInteger presentCount;
@property (nonatomic, strong) NSMutableData *lastFrame;
@end

@implementation MBRecordingRenderPort
- (void)presentFramebuffer:(const uint32_t *)pixels {
    self.presentCount++;
    if (self.lastFrame == nil) {
        self.lastFrame = [NSMutableData dataWithLength:160 * 144 * 4];
    }
    memcpy(self.lastFrame.mutableBytes, pixels, 160 * 144 * 4);
}
@end

@interface MBEmulatorSessionTests : XCTestCase
@property (nonatomic, strong) NSString *tempDir;
@end

@implementation MBEmulatorSessionTests

- (void)setUp {
    [super setUp];
    self.tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

- (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:self.tempDir error:nil];
    [super tearDown];
}

- (NSString *)writeROM:(NSData *)rom name:(NSString *)name {
    NSString *path = [self.tempDir stringByAppendingPathComponent:name];
    [rom writeToFile:path atomically:YES];
    return path;
}

- (void)testInitFailsForMissingROM {
    MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:@"/nonexistent/rom.gb" scale:3 volumePercent:50];
    NSError *error = nil;
    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    XCTAssertNil(session);
    XCTAssertNotNil(error);
}

- (void)testInitFailsForInvalidROM {
    NSString *path = [self writeROM:[NSMutableData dataWithLength:0x30] name:@"bad.gb"];
    MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:path scale:3 volumePercent:50];
    NSError *error = nil;
    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    XCTAssertNil(session);
    XCTAssertNotNil(error);
}

// T038: セーブファイル破損(サイズ不一致)は黙って上書きせず起動失敗(research R-7)
- (void)testInitFailsForCorruptSaveFile {
    uint8_t rom[0x8000];
    memset(rom, 0x00, sizeof(rom));
    rom[0x0147] = 0x03; // MBC1+RAM+BATTERY
    rom[0x0149] = 0x02; // 8KB RAM
    NSString *path = [self writeROM:[NSData dataWithBytes:rom length:sizeof(rom)] name:@"corrupt.gb"];

    // 不一致サイズの .sav を事前に置く
    NSString *savePath = [MBSaveFile saveFilePathForROMPath:path];
    [[NSMutableData dataWithLength:16] writeToFile:savePath atomically:YES];

    MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:path scale:3 volumePercent:50];
    NSError *error = nil;
    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    XCTAssertNil(session, "サイズ不一致の .sav は起動失敗(フォールバック禁止)");
    XCTAssertNotNil(error);
    XCTAssertEqual(error.code, MBErrorCodeSaveLoadFailed);
}

- (void)testHeadlessRunFramesPresentsFrame {
    NSString *path = [self writeROM:MakeSerialOutputROM() name:@"serial.gb"];
    MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:path scale:3 volumePercent:50];
    NSError *error = nil;
    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    XCTAssertNotNil(session);

    MBRecordingRenderPort *renderPort = [[MBRecordingRenderPort alloc] init];
    session.renderPort = renderPort;
    session.audioOutPort = nil;

    __block NSMutableArray<NSNumber *> *output = [NSMutableArray array];
    session.serialOutputHandler = ^(uint8_t byte) {
        [output addObject:@(byte)];
    };

    [session runFrames:2];
    XCTAssertEqual(renderPort.presentCount, 2, "1 フレームごとに present が呼ばれる");
    XCTAssertEqual(output.count, 1, "シリアル出力 1 バイト");
    XCTAssertEqual(output.firstObject.intValue, 0x81);
    XCTAssertFalse(session.stopped);
}

- (void)testStopWritesSaveFileForBatteryROM {
    // MBC1 + 8KB RAM(バッテリーバックアップ付き 0x03)。RAM 有効化→$2000 書込→$A001 に 0x42
    uint8_t rom[0x8000];
    memset(rom, 0xFF, sizeof(rom));
    const uint8_t program[] = {
        0x3E, 0x0A,        // LD A, $0A
        0xEA, 0x00, 0x00,  // LD ($0000), A  → MBC1 RAMG による SRAM 有効化
        0x3E, 0x42,        // LD A, $42
        0xEA, 0x01, 0xA0,  // LD ($A001), A
        0x18, 0xFE,        // JR -2(無限ループ)
    };
    memcpy(rom + 0x100, program, sizeof(program));
    rom[0x0147] = 0x03; // MBC1+RAM+BATTERY
    rom[0x0149] = 0x02; // 8KB RAM
    NSString *path = [self writeROM:[NSData dataWithBytes:rom length:sizeof(rom)] name:@"battery.gb"];

    MBLaunchOptions *options = [[MBLaunchOptions alloc] initWithROMPath:path scale:3 volumePercent:50];
    NSError *error = nil;
    MBEmulatorSession *session = [[MBEmulatorSession alloc] initWithOptions:options error:&error];
    XCTAssertNotNil(session);

    session.renderPort = nil;
    session.audioOutPort = nil;
    [session runFrames:1];

    NSError *stopError = nil;
    XCTAssertTrue([session stopAndReturnError:&stopError]);
    XCTAssertTrue(session.stopped);

    NSString *savePath = [MBSaveFile saveFilePathForROMPath:path];
    NSData *saved = [NSData dataWithContentsOfFile:savePath];
    XCTAssertNotNil(saved, "stop 時に .sav が書かれる");
    XCTAssertEqual(saved.length, (NSUInteger)0x2000);
    XCTAssertEqual(((const uint8_t *)saved.bytes)[1], 0x42, "$A001 に書込んだ値が保存される");
}

@end

NS_ASSUME_NONNULL_END
