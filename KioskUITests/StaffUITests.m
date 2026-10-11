#import <XCTest/XCTest.h>

// Runs against a live booth: STAFF_BOOTH_URL and STAFF_TOKEN come from the environment
// (TEST_RUNNER_STAFF_BOOTH_URL / TEST_RUNNER_STAFF_TOKEN on the xcodebuild command line).
// STAFF_SCREENSHOTS, if set, is a directory to write screenshots to.
@interface StaffUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation StaffUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *host = env[@"STAFF_BOOTH_URL"], *token = env[@"STAFF_TOKEN"];
    if (host.length == 0 || token.length == 0) {
        XCTSkip(@"Set TEST_RUNNER_STAFF_BOOTH_URL and TEST_RUNNER_STAFF_TOKEN to run against a booth");
    }
    self.app = [[XCUIApplication alloc] init];
    self.app.launchArguments = @[@"-kioskRole", @"staff", @"-boothURL", host, @"-boothStaffToken", token];
    [self.app launch];
    XCTAssertTrue([[self text:@"Live"] waitForExistenceWithTimeout:30], @"the staff screen should connect");
    [self pause:2];
}

- (void)pause:(double)seconds {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (XCUIElement *)text:(NSString *)label {
    return [self.app.staticTexts elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]];
}

- (XCUIElement *)button:(NSString *)label {
    return [self.app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]];
}

- (void)snapshot:(NSString *)name {
    NSString *directory = NSProcessInfo.processInfo.environment[@"STAFF_SCREENSHOTS"];
    if (directory.length == 0) return;
    NSData *png = XCUIScreen.mainScreen.screenshot.PNGRepresentation;
    [png writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}

- (void)testSoldOutToggleRoundTrips {
    XCUIElement *available = [self button:@"Vanilla, available"];
    XCUIElement *soldOut = [self button:@"Vanilla, sold out"];
    XCTAssertTrue([available waitForExistenceWithTimeout:10], @"vanilla should start available");
    [available tap];
    XCTAssertTrue([soldOut waitForExistenceWithTimeout:2], @"the toggle should flip at once");
    [self pause:7];
    XCTAssertTrue(soldOut.exists, @"the hub should keep vanilla sold out");
    [self snapshot:@"staff-sold-out"];
    [soldOut tap];
    XCTAssertTrue([available waitForExistenceWithTimeout:2]);
    [self pause:7];
    XCTAssertTrue(available.exists, @"the hub should make vanilla available again");
}

- (void)testAcknowledgeClosesAlert {
    [self snapshot:@"staff-live"];
    XCUIElement *gotIt = [self.app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Got it'"]].firstMatch;
    if (![gotIt waitForExistenceWithTimeout:5]) {
        XCTSkip(@"No open alert to acknowledge");
    }
    XCUIElement *title = [[self.app descendantsMatchingType:XCUIElementTypeAny] matchingIdentifier:@"alerts-title"].firstMatch;
    NSInteger before = [self openCount:title.label];
    XCTAssertGreaterThan(before, 0);
    [gotIt tap];
    [self pause:4];
    [self snapshot:@"staff-after-ack"];
    XCTAssertEqual([self openCount:title.label], before - 1, @"the hub should close the acknowledged alert");
}

- (NSInteger)openCount:(NSString *)label {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+) open" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:label options:0 range:NSMakeRange(0, label.length)];
    return match ? [[label substringWithRange:[match rangeAtIndex:1]] integerValue] : 0;
}

@end
