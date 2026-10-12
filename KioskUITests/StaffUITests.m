#import <XCTest/XCTest.h>

@interface StaffUITests : XCTestCase
@end

@implementation StaffUITests

- (void)testUnreachableBoothShowsFallback {
    self.continueAfterFailure = NO;
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"staff", @"-boothURL", @"https://unreachable.invalid"];
    [app launch];
    XCTAssertTrue([app.staticTexts[@"Can't reach the booth"] waitForExistenceWithTimeout:30]);
    XCTAssertTrue(app.buttons[@"Retry now"].exists);
}

@end
