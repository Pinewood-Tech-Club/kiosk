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

- (void)testRefusedTokenAsksForPinAndSignsIn {
    NSString *pin = NSProcessInfo.processInfo.environment[@"STAFF_PIN"];
    if (pin.length == 0) {
        XCTSkip(@"Set TEST_RUNNER_STAFF_PIN to test PIN sign-in");
    }
    [self.app terminate];
    self.app.launchArguments = @[@"-kioskRole", @"staff", @"-boothURL", NSProcessInfo.processInfo.environment[@"STAFF_BOOTH_URL"],
                                 @"-boothStaffToken", @"not-a-staff-token"];
    [self.app launch];
    XCTAssertTrue([[self text:@"Sign in again"] waitForExistenceWithTimeout:30], @"a refused token should ask for the PIN");
    [self snapshot:@"staff-sign-in"];
    XCUIElement *field = self.app.secureTextFields.firstMatch;
    [field tap];
    [field typeText:pin];
    [[self.app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH 'Sign in'"]] tap];
    XCTAssertTrue([[self text:@"Live"] waitForExistenceWithTimeout:30], @"the PIN session should connect");
}

// Needs a reverse proxy to the booth at STAFF_PROXY_URL that goes down while the file STAFF_PROXY_DOWN_FLAG exists.
- (void)testChangeMadeOfflineSurvivesRelaunchAndReachesTheHub {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    NSString *proxy = env[@"STAFF_PROXY_URL"], *flag = env[@"STAFF_PROXY_DOWN_FLAG"];
    if (proxy.length == 0 || flag.length == 0) {
        XCTSkip(@"Set TEST_RUNNER_STAFF_PROXY_URL and TEST_RUNNER_STAFF_PROXY_DOWN_FLAG to test going offline");
    }
    NSArray *arguments = @[@"-kioskRole", @"staff", @"-boothURL", proxy, @"-boothStaffToken", env[@"STAFF_TOKEN"]];
    [self.app terminate];
    self.app.launchArguments = arguments;
    [self.app launch];
    XCUIElement *available = [self button:@"Chocolate, available"];
    XCUIElement *soldOut = [self button:@"Chocolate, sold out"];
    XCTAssertTrue([available waitForExistenceWithTimeout:30], @"chocolate should start available");

    [[NSFileManager defaultManager] createFileAtPath:flag contents:nil attributes:nil];
    XCTAssertTrue([[self text:@"Offline, reconnecting"] waitForExistenceWithTimeout:40], @"losing the booth should show offline");
    [available tap];
    XCTAssertTrue([soldOut waitForExistenceWithTimeout:2], @"the toggle should flip while offline");
    XCTAssertTrue([self text:@"Queued, sends when online"].exists);
    XCTAssertTrue([self text:@"Your changes send when it's back"].exists);
    [self snapshot:@"staff-offline-queued"];

    [self.app terminate];
    [[NSFileManager defaultManager] removeItemAtPath:flag error:nil];
    [self pause:3];
    [self.app launch];
    XCTAssertTrue([[self text:@"Live"] waitForExistenceWithTimeout:30]);
    [self pause:8];
    XCTAssertFalse([self text:@"Sending"].exists, @"the queued change should have been answered");
    XCTAssertFalse([self text:@"Queued, sends when online"].exists);
    XCTAssertTrue(soldOut.exists, @"the queued change should reach the hub after a relaunch");
    [self snapshot:@"staff-after-reconnect"];

    [soldOut tap];
    XCTAssertTrue([available waitForExistenceWithTimeout:2]);
    [self pause:7];
    XCTAssertTrue(available.exists);
}

- (NSInteger)openCount:(NSString *)label {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"(\\d+) open" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:label options:0 range:NSMakeRange(0, label.length)];
    return match ? [[label substringWithRange:[match rangeAtIndex:1]] integerValue] : 0;
}

@end
