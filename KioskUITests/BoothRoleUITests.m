#import <XCTest/XCTest.h>

@interface BoothRoleUITests : XCTestCase
@property (nonatomic, copy) NSString *boothURL;
@property (nonatomic, copy) NSString *staffToken;
@property (nonatomic, copy) NSString *kioskToken;
@end

@implementation BoothRoleUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    self.boothURL = env[@"BOOTH_TEST_URL"];
    self.staffToken = env[@"BOOTH_TEST_STAFF_TOKEN"];
    self.kioskToken = env[@"BOOTH_TEST_KIOSK_TOKEN"];
}

- (BOOL)hasBooth {
    return self.boothURL.length && self.staffToken.length && self.kioskToken.length;
}

- (NSDictionary *)request:(NSString *)path body:(NSDictionary *)body {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.boothURL stringByAppendingString:path]]];
    [request setValue:[@"Bearer " stringByAppendingString:self.staffToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"ui-test-staff" forHTTPHeaderField:@"X-Booth-Device"];
    if (body) {
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    __block NSDictionary *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return result;
}

- (NSDictionary *)kioskNamed:(NSString *)name {
    for (NSDictionary *kiosk in [self request:@"/v1/state" body:nil][@"kiosks"]) {
        if ([kiosk[@"reportedName"] isEqual:name]) return kiosk;
    }
    return nil;
}

- (NSDictionary *)waitForKioskNamed:(NSString *)name matching:(BOOL (^)(NSDictionary *))match {
    for (int i = 0; i < 60; i++) {
        NSDictionary *kiosk = [self kioskNamed:name];
        if (kiosk && match(kiosk)) return kiosk;
        [NSThread sleepForTimeInterval:1];
    }
    return nil;
}

- (void)act:(NSDictionary *)action {
    NSMutableDictionary *full = [action mutableCopy];
    full[@"id"] = NSUUID.UUID.UUIDString;
    full[@"by"] = @"UI test";
    NSDictionary *response = [self request:@"/v1/actions" body:@{@"actions": @[full]}];
    XCTAssertEqualObjects(response[@"results"][0][@"status"], @"ok", @"%@", response);
}

- (void)testExitStaffModeStartsTheKioskWithoutRelaunch {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    NSString *name = [@"UI exit " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"staff", @"-staffPage", @"scooper", @"-boothURL", self.boothURL,
                            @"-boothStaffToken", self.staffToken, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name];
    [app launch];

    XCUIElement *exit = app.buttons[@"Exit staff mode"];
    XCTAssertTrue([exit waitForExistenceWithTimeout:60]);
    XCTAssertNil([self kioskNamed:name]);
    [exit tap];
    XCUIElement *confirm = app.buttons[@"Exit"];
    XCTAssertTrue([confirm waitForExistenceWithTimeout:10]);
    [confirm tap];

    XCTAssertTrue([app.staticTexts[@"Set up this iPad"] waitForExistenceWithTimeout:15]);
    [self keepScreenshot:@"role-picker-after-exit"];
    [app.buttons[@"Start Kiosk"] tap];
    NSDictionary *kiosk = [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"online"] boolValue]; }];
    XCTAssertNotNil(kiosk, @"the kiosk never reached the booth after leaving staff mode");
    if (![kiosk[@"open"] boolValue]) [self act:@{@"type": @"setKioskOpen", @"kiosk": kiosk[@"id"], @"open": @YES}];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:60]);
    [self keepScreenshot:@"kiosk-after-exit"];
    [self act:@{@"type": @"removeKiosk", @"kiosk": kiosk[@"id"]}];
}

- (void)testStaffSwitchesReachTheKioskLive {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    NSString *name = [@"UI kiosk " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name];
    [app launch];

    NSDictionary *kiosk = [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"online"] boolValue]; }];
    XCTAssertNotNil(kiosk);
    NSString *kioskID = kiosk[@"id"];
    if (![kiosk[@"open"] boolValue]) [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @YES}];
    if ([kiosk[@"debug"] boolValue]) [self act:@{@"type": @"setKioskDebug", @"kiosk": kioskID, @"debug": @NO}];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:90]);
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:20], @"the debug bar must be off unless staff turn it on");

    [self act:@{@"type": @"setKioskDebug", @"kiosk": kioskID, @"debug": @YES}];
    XCTAssertTrue([app.buttons[@"Log"] waitForExistenceWithTimeout:20]);
    [self keepScreenshot:@"debug-on"];
    [self act:@{@"type": @"setKioskDebug", @"kiosk": kioskID, @"debug": @NO}];
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:20]);

    [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @NO}];
    XCTAssertTrue([app.buttons[@"Closed"] waitForExistenceWithTimeout:20]);
    [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @YES}];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:20]);

    [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @NO}];
    [self act:@{@"type": @"setKioskDebug", @"kiosk": kioskID, @"debug": @YES}];
    XCTAssertTrue([app.buttons[@"Closed"] waitForExistenceWithTimeout:20]);
    XCTAssertTrue([app.buttons[@"Log"] waitForExistenceWithTimeout:20]);
    [app terminate];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", @"https://unreachable.invalid", @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name];
    [app launch];
    XCTAssertTrue([app.buttons[@"Closed"] waitForExistenceWithTimeout:90], @"closed must be remembered while the booth is unreachable");
    XCTAssertTrue(app.buttons[@"Log"].exists, @"debug tools must be remembered while the booth is unreachable");
    [self keepScreenshot:@"closed-and-debug-remembered-offline"];

    [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @YES}];
    [self act:@{@"type": @"setKioskDebug", @"kiosk": kioskID, @"debug": @NO}];
    [app terminate];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name];
    [app launch];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:90]);
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:20]);
    [self act:@{@"type": @"removeKiosk", @"kiosk": kioskID}];
}

- (void)setSupply:(NSString *)kind item:(NSString *)item soldOut:(BOOL)soldOut {
    [self act:@{@"type": @"setSupply", @"kind": kind, @"item": item, @"soldOut": @(soldOut)}];
}

- (XCUIElement *)card:(XCUIApplication *)app titled:(NSString *)title {
    return [app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", title]];
}

- (void)testSoldOutCupsAndConesOnTheKiosk {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    NSString *name = [@"UI supplies " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    for (NSString *vessel in @[@"cup", @"cone"]) [self setSupply:@"vessel" item:vessel soldOut:NO];
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name, @"-kioskItems", @"cone:vanilla", @"-kioskStep", @"vessel"];
    [app launch];
    NSDictionary *kiosk = [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"online"] boolValue]; }];
    XCTAssertNotNil(kiosk);
    NSString *kioskID = kiosk[@"id"];
    if (![kiosk[@"open"] boolValue]) [self act:@{@"type": @"setKioskOpen", @"kiosk": kioskID, @"open": @YES}];

    XCUIElement *cone = [self card:app titled:@"Waffle Cone"];
    XCUIElement *cup = [self card:app titled:@"Cup"];
    XCTAssertTrue([cone waitForExistenceWithTimeout:60]);
    XCTAssertTrue(cone.isEnabled);
    [self setSupply:@"vessel" item:@"cone" soldOut:YES];
    XCTAssertTrue([app.staticTexts[@"Sold out"] waitForExistenceWithTimeout:20]);
    XCTAssertFalse(cone.isEnabled, @"a sold-out cone can't be chosen");
    XCTAssertTrue(cup.isEnabled);
    XCUIElement *total = [app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS '$5.50'"]];
    XCTAssertTrue(total.exists, @"the cone already in the cart stays and is still charged");
    [self keepScreenshot:@"cone-sold-out-in-builder"];

    [self setSupply:@"vessel" item:@"cup" soldOut:YES];
    XCTAssertTrue([self waitForPredicate:@"enabled == NO" on:cup timeout:20]);
    [app.buttons[@"Start over"] tap];
    XCUIElement *confirm = app.alerts.buttons[@"Start Over"];
    XCTAssertTrue([confirm waitForExistenceWithTimeout:10]);
    [confirm tap];
    XCTAssertTrue([app.buttons[@"Closed"] waitForExistenceWithTimeout:20]);
    XCTAssertTrue(app.staticTexts[@"We're out of cups and cones for now. Please see a staff member."].exists);
    [self keepScreenshot:@"no-cups-or-cones-closed"];

    [self setSupply:@"vessel" item:@"cone" soldOut:NO];
    XCUIElement *begin = app.buttons[@"Begin Order"];
    XCTAssertTrue([begin waitForExistenceWithTimeout:20]);
    [begin tap];
    XCTAssertTrue([cone waitForExistenceWithTimeout:20]);
    XCTAssertTrue([self waitForPredicate:@"selected == YES" on:cone timeout:10], @"with cups out a new item starts as a cone");
    XCTAssertFalse(cup.isEnabled);
    [self keepScreenshot:@"cups-sold-out-new-item-is-a-cone"];

    [self setSupply:@"vessel" item:@"cup" soldOut:NO];
    XCTAssertTrue([self waitForPredicate:@"enabled == YES" on:cup timeout:20]);
    [app terminate];
    [self act:@{@"type": @"removeKiosk", @"kiosk": kioskID}];
}

- (BOOL)waitForPredicate:(NSString *)format on:(XCUIElement *)element timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation *match = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithFormat:format] object:element];
    return [XCTWaiter waitForExpectations:@[match] timeout:timeout] == XCTWaiterResultCompleted;
}

- (void)keepScreenshot:(NSString *)name {
    XCTAttachment *attachment = [XCTAttachment attachmentWithScreenshot:XCUIScreen.mainScreen.screenshot];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

- (BOOL)waitForAbsence:(XCUIElement *)element timeout:(NSTimeInterval)timeout {
    XCTNSPredicateExpectation *gone = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithFormat:@"exists == NO"] object:element];
    return [XCTWaiter waitForExpectations:@[gone] timeout:timeout] == XCTWaiterResultCompleted;
}

@end
