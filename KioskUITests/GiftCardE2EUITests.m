#import <XCTest/XCTest.h>

@interface GiftCardE2EUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@property (nonatomic, copy) NSString *shots;
@property (nonatomic, copy) NSString *tag;
@end

@implementation GiftCardE2EUITests

- (NSDictionary *)env { return NSProcessInfo.processInfo.environment; }

- (void)setUp {
    self.continueAfterFailure = NO;
    self.shots = self.env[@"GC_E2E_SHOTS"] ?: @"/tmp/giftcard-e2e/shots";
    [NSFileManager.defaultManager createDirectoryAtPath:self.shots withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)snapshot:(NSString *)name {
    [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:[NSString stringWithFormat:@"%@/%@.png", self.shots, name] atomically:YES];
}

- (void)dump:(NSString *)name {
    [self.app.debugDescription writeToFile:[NSString stringWithFormat:@"%@/%@.txt", self.shots, name] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (XCUIElement *)text:(NSString *)prefix {
    return [[self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (XCUIElement *)button:(NSString *)prefix {
    return [[self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (void)waitFor:(XCUIElement *)element timeout:(NSTimeInterval)timeout {
    if (![element waitForExistenceWithTimeout:timeout]) [self dump:@"failure"];
    XCTAssertTrue(element.exists, @"%@", element);
}

- (BOOL)configured {
    return [self.env[@"GC_E2E_URL"] length] && [self.env[@"GC_E2E_TOKEN"] length];
}

- (void)launchWithName:(NSString *)name {
    self.app = [[XCUIApplication alloc] init];
    self.app.launchArguments = @[@"-kioskRole", @"kiosk", @"-boothURL", self.env[@"GC_E2E_URL"], @"-boothToken", self.env[@"GC_E2E_TOKEN"],
                                 @"-kioskName", name, @"-kioskScreen", @"summary", @"-kioskItems", @"cup:vanilla",
                                 @"-kioskCustomerName", @"Alex", @"-kioskSimulatePayment", @"NO", @"-kioskHideDebugBar", @"NO"];
    [self.app launch];
    [self waitFor:self.app.buttons[@"Mock Reader"] timeout:90];
    [NSThread sleepForTimeInterval:8];
    [self snapshot:@"launch"];
    [self dump:@"launch"];
    [self.app.buttons[@"Mock Reader"] tap];
    [self waitFor:self.app.buttons[@"mockReaderView"] timeout:20];
    [self.app.buttons[@"mockReaderView"] tap];
    XCUIElement *add = self.app.cells[@"addContactlessAndChipReaderButton"];
    [self waitFor:add timeout:20];
    [add tap];
    [NSThread sleepForTimeInterval:5];
    XCUIElement *dismiss = self.app.buttons[@"mockReaderDismissButton"];
    if (dismiss.exists) [dismiss tap];
    [NSThread sleepForTimeInterval:1];
}

- (void)enterNumber:(NSString *)number {
    [self waitFor:self.app.buttons[@"Pay with gift card"] timeout:30];
    [self snapshot:[NSString stringWithFormat:@"%@-1-summary", self.tag]];
    [self.app.buttons[@"Pay with gift card"] tap];
    XCUIElement *proceed = [self button:@"Continue to Payment"];
    if ([proceed waitForExistenceWithTimeout:5]) [proceed tap];
    [self waitFor:[self text:@"Scan your gift card"] timeout:60];
    [[self button:@"Enter number instead"] tap];
    [self waitFor:[self text:@"Enter your gift card number"] timeout:10];
    for (NSUInteger i = 0; i < number.length; i++) [self.app.buttons[[number substringWithRange:NSMakeRange(i, 1)]] tap];
    [[self button:@"Check Balance"] tap];
}

- (XCUIElement *)awaitSquareReader {
    XCUIElement *prompt = [self text:@"Tap or insert in card reader to pay"];
    if (![prompt waitForExistenceWithTimeout:60]) [self dump:@"no-square-reader"];
    XCTAssertTrue(prompt.exists);
    [self snapshot:[NSString stringWithFormat:@"%@-4-square-reader", self.tag]];
    return prompt;
}

- (void)tapCard {
    [self awaitSquareReader];
    [self.app.buttons[@"mockReaderView"] tap];
    XCUIElement *tap = [[[self.app descendantsMatchingType:XCUIElementTypeAny] matchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Tap Card' OR identifier CONTAINS 'Tap Card'"]] firstMatch];
    if (![tap waitForExistenceWithTimeout:10]) [self dump:@"no-tap-card"];
    XCTAssertTrue(tap.exists);
    [tap tap];
}

- (void)testFullCoverage {
    XCTSkipUnless(self.configured, @"set GC_E2E_URL and GC_E2E_TOKEN");
    self.tag = @"full";
    [self launchWithName:@"GC E2E full"];
    [self enterNumber:self.env[@"GC_E2E_GAN_FULL"]];
    [self waitFor:[self text:@"Pay $"] timeout:30];
    [self snapshot:@"full-2-confirm"];
    [[self button:@"Pay $"] tap];
    [self waitFor:[self text:@"Thank you, Alex."] timeout:60];
    [NSThread sleepForTimeInterval:2];
    [self snapshot:@"full-3-confirmation"];
    [self dump:@"full-done"];
}

- (void)testSplit {
    XCTSkipUnless(self.configured, @"set GC_E2E_URL and GC_E2E_TOKEN");
    self.tag = @"split";
    [self launchWithName:@"GC E2E split"];
    [self enterNumber:self.env[@"GC_E2E_GAN_SPLIT"]];
    [self waitFor:[self button:@"Split Payment"] timeout:30];
    [self snapshot:@"split-2-confirm"];
    [[self button:@"Split Payment"] tap];
    [self tapCard];
    [self waitFor:[self text:@"Thank you, Alex."] timeout:90];
    [NSThread sleepForTimeInterval:2];
    [self snapshot:@"split-5-confirmation"];
    [self dump:@"split-done"];
}

- (void)testSplitThenCancelAtTheReader {
    XCTSkipUnless(self.configured, @"set GC_E2E_URL and GC_E2E_TOKEN");
    self.tag = @"cancel";
    [self launchWithName:@"GC E2E cancel"];
    [self enterNumber:self.env[@"GC_E2E_GAN_CANCEL"]];
    [self waitFor:[self button:@"Split Payment"] timeout:30];
    [[self button:@"Split Payment"] tap];
    [self awaitSquareReader];
    XCUIElement *cancel = self.app.buttons[@"Close"];
    XCTAssertTrue(cancel.exists);
    [cancel tap];
    XCUIElement *alert = self.app.alerts[@"Your gift card wasn't charged"];
    [self waitFor:alert timeout:60];
    [self snapshot:@"cancel-5-not-charged"];
    [alert.buttons[@"OK"] tap];
    [self waitFor:[self button:@"Pay with gift card"] timeout:30];
    [self snapshot:@"cancel-6-summary"];
}

@end
