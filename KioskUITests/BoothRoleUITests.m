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

- (void)testSoldOutToppingsOnTheKiosk {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    NSString *name = [@"UI toppings " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    for (NSString *topping in @[@"whip", @"mms"]) [self setSupply:@"topping" item:topping soldOut:NO];
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name, @"-kioskCurrent", @"cup:vanilla+whip",
                            @"-kioskStep", @"toppings", @"-kioskHideDebugBar", @"YES"];
    [app launch];
    NSDictionary *kiosk = [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"online"] boolValue]; }];
    XCTAssertNotNil(kiosk);
    NSString *kioskID = kiosk[@"id"];

    XCUIElement *whip = app.buttons[@"Whipped Cream"];
    XCUIElement *mms = app.buttons[@"M&M's"];
    XCTAssertTrue([mms waitForExistenceWithTimeout:60]);
    XCTAssertTrue(mms.isEnabled);
    [self setSupply:@"topping" item:@"mms" soldOut:YES];
    [self setSupply:@"topping" item:@"whip" soldOut:YES];
    XCTAssertTrue([self waitForPredicate:@"enabled == NO" on:mms timeout:20], @"a sold-out topping can't be added");
    XCTAssertEqualObjects(mms.value, @"Sold out");
    XCTAssertTrue(whip.isEnabled, @"a sold-out topping already on the item can still be taken off");
    XCTAssertEqualObjects(whip.value, @"Added");
    [self keepScreenshot:@"toppings-sold-out-in-builder"];

    [whip tap];
    XCTAssertTrue([self waitForPredicate:@"enabled == NO" on:whip timeout:10], @"once taken off, a sold-out topping can't go back on");
    XCTAssertEqualObjects(whip.value, @"Sold out");

    [self setSupply:@"topping" item:@"mms" soldOut:NO];
    [self setSupply:@"topping" item:@"whip" soldOut:NO];
    XCTAssertTrue([self waitForPredicate:@"enabled == YES" on:mms timeout:20]);
    XCTAssertTrue([self waitForPredicate:@"enabled == YES" on:whip timeout:20]);
    [app terminate];
    [self act:@{@"type": @"removeKiosk", @"kiosk": kioskID}];
}

- (void)testStaffPinUnlocksTheDebugBarWithoutTheBooth {
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", @"https://unreachable.invalid", @"-boothToken", @"offline",
                            @"-kioskNoSquare", @"YES", @"-kioskStaffPin", @"2468", @"-boothKioskDebug", @"NO",
                            @"-boothKioskOpen", @"YES", @"-boothSoldOutState", @""];
    [app launch];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:90]);
    XCTAssertFalse(app.buttons[@"Log"].exists, @"the debug bar starts hidden");

    XCUICoordinate *corner = [app coordinateWithNormalizedOffset:CGVectorMake(0.03, 0.03)];
    [corner pressForDuration:3.5];
    XCUIElement *alert = app.alerts[@"Staff tools"];
    XCTAssertTrue([alert waitForExistenceWithTimeout:10]);
    XCUIElement *field = alert.secureTextFields.firstMatch;
    [field tap];
    [field typeText:@"1111"];
    [alert.buttons[@"Unlock"] tap];
    XCTAssertTrue([app.alerts.staticTexts[@"That PIN didn't match. Try again."] waitForExistenceWithTimeout:10]);
    XCTAssertFalse(app.buttons[@"Log"].exists);
    field = app.alerts[@"Staff tools"].secureTextFields.firstMatch;
    [field tap];
    [field typeText:@"2468"];
    [app.alerts[@"Staff tools"].buttons[@"Unlock"] tap];
    XCTAssertTrue([app.buttons[@"Log"] waitForExistenceWithTimeout:10]);
    XCTAssertTrue(app.buttons[@"Readers"].exists);
    [self keepScreenshot:@"debug-bar-unlocked-offline"];

    [app.buttons[@"Debug"] tap];
    XCUIElement *hide = app.buttons[@"Hide debug bar"];
    XCTAssertTrue([hide waitForExistenceWithTimeout:5]);
    [hide tap];
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:10]);
}

- (void)unlockWithPin:(NSString *)pin in:(XCUIApplication *)app {
    XCUICoordinate *corner = [app coordinateWithNormalizedOffset:CGVectorMake(0.03, 0.03)];
    [corner pressForDuration:3.5];
    XCUIElement *alert = app.alerts[@"Staff tools"];
    XCTAssertTrue([alert waitForExistenceWithTimeout:10]);
    XCUIElement *field = alert.secureTextFields.firstMatch;
    [field tap];
    [field typeText:pin];
    [alert.buttons[@"Unlock"] tap];
}

- (void)testStaffPinUnlocksTheDebugBarWithTheBooth {
    NSString *boothPin = NSProcessInfo.processInfo.environment[@"BOOTH_TEST_STAFF_PIN"];
    XCTSkipUnless([self hasBooth] && boothPin.length, @"Also set TEST_RUNNER_BOOTH_TEST_STAFF_PIN to the booth's staff PIN");
    NSString *name = [@"UI pin " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    NSString *localPin = [boothPin isEqualToString:@"2468"] ? @"1357" : @"2468";
    XCUIApplication *app = [[XCUIApplication alloc] init];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name, @"-kioskStaffPin", localPin,
                            @"-kioskStaffPinHash", @"", @"-boothKioskDebug", @"NO", @"-boothKioskOpen", @"YES"];
    [app launch];
    XCTAssertTrue([app.buttons[@"Begin Order"] waitForExistenceWithTimeout:90]);
    NSDictionary *kiosk = [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"connected"] boolValue]; }];
    XCTAssertNotNil(kiosk);
    NSString *kioskID = kiosk[@"id"];
    XCTAssertFalse([kiosk[@"debug"] boolValue]);
    XCTAssertFalse(app.buttons[@"Log"].exists);

    [self unlockWithPin:boothPin in:app];
    XCTAssertTrue([app.buttons[@"Log"] waitForExistenceWithTimeout:20], @"the booth's staff PIN unlocks while the booth is reachable");
    [self keepScreenshot:@"debug-bar-unlocked-online"];
    [app.buttons[@"Hide"] tap];
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:10]);

    [self unlockWithPin:localPin in:app];
    XCTAssertTrue([app.buttons[@"Log"] waitForExistenceWithTimeout:10], @"the kiosk's own PIN works with the booth reachable too");
    [app.buttons[@"Hide"] tap];
    XCTAssertTrue([self waitForAbsence:app.buttons[@"Log"] timeout:10]);
    XCTAssertFalse([[self kioskNamed:name][@"debug"] boolValue], @"unlocking on the kiosk doesn't change the staff switch");

    [app terminate];
    [self act:@{@"type": @"removeKiosk", @"kiosk": kioskID}];
}

- (NSURLSessionWebSocketTask *)openStaffSocket {
    NSString *url = [[self.boothURL stringByReplacingOccurrencesOfString:@"http" withString:@"ws" options:NSAnchoredSearch range:NSMakeRange(0, self.boothURL.length)]
                     stringByAppendingString:@"/v1/ws"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setValue:[@"Bearer " stringByAppendingString:self.staffToken] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"ui-test-assist" forHTTPHeaderField:@"X-Booth-Device"];
    NSURLSessionWebSocketTask *socket = [NSURLSession.sharedSession webSocketTaskWithRequest:request];
    [socket resume];
    return socket;
}

- (void)send:(NSDictionary *)command toKiosk:(NSString *)kioskID on:(NSURLSessionWebSocketTask *)socket {
    NSMutableDictionary *full = [command mutableCopy];
    full[@"kiosk"] = kioskID;
    full[@"by"] = @"UI test";
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"type": @"command", @"command": full} options:0 error:nil];
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    __block NSError *failure = nil;
    dispatch_semaphore_t sent = dispatch_semaphore_create(0);
    [socket sendMessage:message completionHandler:^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(sent);
    }];
    dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    XCTAssertNil(failure);
}

- (NSDictionary *)waitForSessionOf:(NSString *)kioskID matching:(BOOL (^)(NSDictionary *))match {
    for (int i = 0; i < 60; i++) {
        for (NSDictionary *session in [self request:@"/v1/state" body:nil][@"sessions"]) {
            if ([session[@"kiosk"] isEqual:kioskID] && match(session)) return session;
        }
        [NSThread sleepForTimeInterval:0.5];
    }
    return nil;
}

- (NSDictionary *)launchAssistedKiosk:(XCUIApplication *)app items:(NSString *)items {
    NSString *name = [@"UI assist " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
    app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.boothURL, @"-boothToken", self.kioskToken,
                            @"-kioskNoSquare", @"YES", @"-kioskName", name, @"-kioskItems", items, @"-kioskStep", @"vessel",
                            @"-kioskHideDebugBar", @"YES"];
    [app launch];
    return [self waitForKioskNamed:name matching:^BOOL(NSDictionary *k) { return [k[@"online"] boolValue]; }];
}

- (void)testAssistResendWhileApplyingAddsOnce {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    XCUIApplication *app = [[XCUIApplication alloc] init];
    NSString *kioskID = [self launchAssistedKiosk:app items:@"cup:vanilla;cup:chocolate"][@"id"];
    XCTAssertNotNil(kioskID);
    NSDictionary *session = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) {
        return [s[@"screen"] isEqual:@"builder"] && [[s[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"inOrder == YES"]] count] == 2;
    }];
    XCTAssertNotNil(session);
    NSString *itemID = session[@"items"][0][@"id"];
    NSURLSessionWebSocketTask *socket = [self openStaffSocket];
    NSString *commandID = NSUUID.UUID.UUIDString;
    NSDictionary *command = @{@"id": commandID, @"op": @"addScoop", @"item": itemID, @"flavor": @"cookies"};
    [self send:command toKiosk:kioskID on:socket];
    [NSThread sleepForTimeInterval:0.3];
    [self send:command toKiosk:kioskID on:socket];
    [NSThread sleepForTimeInterval:0.4];
    [self send:command toKiosk:kioskID on:socket];
    NSDictionary *done = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) {
        return [[s[@"results"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", commandID]] count] > 0;
    }];
    XCTAssertNotNil(done);
    [NSThread sleepForTimeInterval:4];
    NSDictionary *settled = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) { return YES; }];
    NSDictionary *item = [[settled[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", itemID]] firstObject];
    XCTAssertEqualObjects(item[@"flavors"], (@[@"vanilla", @"cookies"]), @"a resend while the kiosk is still applying the command must not add a second scoop");
    NSArray *applied = [settled[@"results"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@ AND status == 'applied'", commandID]];
    XCTAssertEqual(applied.count, 1u);
    [socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [app terminate];
    [self act:@{@"type": @"removeKiosk", @"kiosk": kioskID}];
}

- (void)testStaffScoopKeepsAnItemTheCustomerWasAboutToRemove {
    XCTSkipUnless([self hasBooth], @"Set TEST_RUNNER_BOOTH_TEST_URL, _STAFF_TOKEN and _KIOSK_TOKEN to run against a booth");
    XCUIApplication *app = [[XCUIApplication alloc] init];
    NSString *kioskID = [self launchAssistedKiosk:app items:@"cup:vanilla"][@"id"];
    XCTAssertNotNil(kioskID);
    NSDictionary *session = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) {
        return [s[@"screen"] isEqual:@"builder"] && [[s[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"inOrder == YES"]] count] == 1;
    }];
    XCTAssertNotNil(session);
    NSString *itemID = session[@"items"][0][@"id"];
    NSURLSessionWebSocketTask *socket = [self openStaffSocket];
    [self send:@{@"id": NSUUID.UUID.UUIDString, @"op": @"removeScoop", @"item": itemID, @"flavor": @"vanilla"} toKiosk:kioskID on:socket];
    NSDictionary *emptied = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) {
        return [s[@"editing"] boolValue] && [[s[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@ AND flavors.@count == 0", itemID]] count] == 1;
    }];
    XCTAssertNotNil(emptied);

    XCUIElement *viewOrder = [app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH 'View Order'"]];
    XCTAssertTrue([viewOrder waitForExistenceWithTimeout:10]);
    [viewOrder tap];
    XCUIElement *remove = app.alerts.buttons[@"Remove"];
    XCTAssertTrue([remove waitForExistenceWithTimeout:10]);
    [self send:@{@"id": NSUUID.UUID.UUIDString, @"op": @"addScoop", @"item": itemID, @"flavor": @"chocolate"} toKiosk:kioskID on:socket];
    NSDictionary *rescooped = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) {
        return [[s[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@ AND flavors.@count == 1", itemID]] count] == 1;
    }];
    XCTAssertNotNil(rescooped);
    [self keepScreenshot:@"remove-dialog-after-staff-scoop"];
    [remove tap];

    NSDictionary *after = [self waitForSessionOf:kioskID matching:^BOOL(NSDictionary *s) { return [s[@"screen"] isEqual:@"summary"]; }];
    XCTAssertNotNil(after, @"the order opens with the item kept");
    XCTAssertEqualObjects([after[@"items"] valueForKey:@"flavors"], (@[@[@"chocolate"]]));
    XCTAssertEqualObjects(after[@"totalCents"], @400);
    [self keepScreenshot:@"item-kept-after-staff-scoop"];
    [socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
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
