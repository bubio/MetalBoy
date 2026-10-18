#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import "MBSaveFile.h"
#import "MBErrors.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBSaveFileTests : XCTestCase
@property (nonatomic, strong) NSString *tempDir;
@end

@implementation MBSaveFileTests

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

- (void)testDerivedPath {
    NSString *path = [MBSaveFile saveFilePathForROMPath:@"/games/roms/Pokemon.gb"];
    XCTAssertEqualObjects(path, @"/games/roms/Pokemon.sav", "ROM と同じディレクトリの <ROM名>.sav");
}

- (void)testLoadNonexistentReturnsNilWithoutError {
    MBSaveFile *file = [[MBSaveFile alloc] initWithPath:[self.tempDir stringByAppendingPathComponent:@"X.sav"]];
    NSError *error = nil;
    NSData *data = [file loadWithError:&error];
    XCTAssertNil(data, "不在ファイルは nil・エラーでもない");
    XCTAssertNil(error);
}

- (void)testSaveAndLoadRoundTrip {
    NSString *path = [self.tempDir stringByAppendingPathComponent:@"Y.sav"];
    MBSaveFile *file = [[MBSaveFile alloc] initWithPath:path];
    NSData *data = [NSData dataWithBytes:"\x01\x02\x03" length:3];
    NSError *error = nil;
    XCTAssertTrue([file saveData:data error:&error]);
    XCTAssertNil(error);

    NSError *loadError = nil;
    NSData *loaded = [file loadWithError:&loadError];
    XCTAssertNotNil(loaded);
    XCTAssertEqualObjects(loaded, data);
}

- (void)testSaveToInvalidPathFails {
    MBSaveFile *file = [[MBSaveFile alloc] initWithPath:@"/definitely/not/a/real/directory/z.sav"];
    NSError *error = nil;
    NSData *data = [NSMutableData dataWithLength:8];
    BOOL wrote = [file saveData:data error:&error];
    XCTAssertFalse(wrote);
    XCTAssertNotNil(error);
    XCTAssertEqual(error.code, MBSaveFileErrorCodeWriteFailed);
}

@end

NS_ASSUME_NONNULL_END
