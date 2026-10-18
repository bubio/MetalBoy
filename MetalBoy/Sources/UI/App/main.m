#import <Cocoa/Cocoa.h>
#import "MBAppDelegate.h"

/// エントリポイント。引数解析・終了コードは MBAppDelegate が担う。
int main(int argc, const char *argv[]) {
    static MBAppDelegate *keepAppDelegate = nil;
    @autoreleasepool {
        keepAppDelegate = [[MBAppDelegate alloc] init];
        return [keepAppDelegate applicationMain];
    }
}
