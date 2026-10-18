#import <XCTest/XCTest.h>
#import "MBErrors.h"

NS_ASSUME_NONNULL_BEGIN

@interface MBErrorPresentationTests : XCTestCase
@end

@implementation MBErrorPresentationTests

- (void)testArgumentErrorsMapToExitCode2 {
    NSError *error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeUsageError userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 2);
    error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeOptionOutOfRange userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 2);
    error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeROMNotSpecified userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 2);
}

- (void)testRuntimeErrorsMapToExitCode1 {
    NSError *error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeROMNotFound userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 1);
    error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeCgbOnly userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 1);
    error = [NSError errorWithDomain:MBErrorDomain code:MBErrorCodeSaveWriteFailed userInfo:nil];
    XCTAssertEqual(MBExitCodeForError(error), 1);
}

- (void)testJapaneseMessageAvailable {
    NSError *error = [NSError errorWithDomain:MBErrorDomain
                                         code:MBErrorCodeROMNotFound
                                     userInfo:nil];
    NSString *message = MBUserFacingMessageForError(error);
    XCTAssertGreaterThan(message.length, 0, "日本語のユーザー向けメッセージが 1 行で返る");
}

@end

NS_ASSUME_NONNULL_END
