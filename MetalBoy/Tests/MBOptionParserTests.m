#import <XCTest/XCTest.h>
#import "MBOptionParser.h"
#import "MBLaunchOptions.h"
#import "MBErrors.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBOptionParserTests : XCTestCase
@end

@implementation MBOptionParserTests

- (MBOptionParser *)parser {
    return [[MBOptionParser alloc] init];
}

- (void)testDefaults {
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"/tmp/game.gb"] error:nil];
    XCTAssertNotNil(options);
    XCTAssertEqualObjects(options.romPath, @"/tmp/game.gb");
    XCTAssertEqual(options.scale, 3);
    XCTAssertEqual(options.volumePercent, 50);
}

- (void)testOptionsInAnyOrder {
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--volume", @"25", @"/tmp/game.gb", @"--scale", @"2"] error:nil];
    XCTAssertNotNil(options);
    XCTAssertEqual(options.scale, 2);
    XCTAssertEqual(options.volumePercent, 25);
    XCTAssertEqualObjects(options.romPath, @"/tmp/game.gb");
}

- (void)testOverridingLastWins {
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--scale", @"1", @"--scale", @"5", @"/tmp/game.gb"] error:nil];
    XCTAssertNotNil(options);
    XCTAssertEqual(options.scale, 5);
}

- (void)testScaleOutOfRange {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--scale", @"9", @"/tmp/game.gb"] error:&error];
    XCTAssertNil(options);
    XCTAssertNotNil(error);
    XCTAssertEqual(MBExitCodeForError(error), 2);
}

- (void)testScaleZeroOutOfRange {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--scale", @"0", @"/tmp/game.gb"] error:&error];
    XCTAssertNil(options);
    XCTAssertEqual(error.code, MBErrorCodeOptionOutOfRange);
}

- (void)testVolumeOutOfRange {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--volume", @"101", @"/tmp/game.gb"] error:&error];
    XCTAssertNil(options);
    XCTAssertEqual(MBExitCodeForError(error), 2);
}

- (void)testMissingValue {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"/tmp/game.gb", @"--scale"] error:&error];
    XCTAssertNil(options);
    XCTAssertEqual(error.code, MBErrorCodeUsageError);
}

- (void)testMissingROM {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[] error:&error];
    XCTAssertNil(options);
    XCTAssertEqual(error.code, MBErrorCodeROMNotSpecified);
    XCTAssertEqual(MBExitCodeForError(error), 2);
}

- (void)testUnknownOption {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--debug", @"/tmp/game.gb"] error:&error];
    XCTAssertNil(options);
    XCTAssertNotNil(error);
}

- (void)testTextValueIsInvalid {
    NSError *error = nil;
    MBLaunchOptions *options = [[self parser] parseArguments:@[@"--scale", @"abc", @"/tmp/game.gb"] error:&error];
    XCTAssertNil(options);
    XCTAssertNotNil(error);
}

@end

NS_ASSUME_NONNULL_END
