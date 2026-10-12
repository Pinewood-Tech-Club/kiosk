#import <XCTest/XCTest.h>

// Simulated payments run the gift card flow against the app's stand-in server, where the card number's last four
// digits pick the outcome (SimulatedGiftCards.Ending): 1111 covers part of the order, 0000 is empty, anything else
// covers it all.
@interface GiftCardUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation GiftCardUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    [NSFileManager.defaultManager createDirectoryAtPath:@"/tmp/giftcard-screens" withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)launchOn:(NSString *)screen extra:(NSArray<NSString *> *)extra {
    self.app = [[XCUIApplication alloc] init];
    NSMutableArray *arguments = [@[@"-kioskScreen", screen, @"-kioskItems", @"cup:vanilla;cone:chocolate,cookies",
                                   @"-kioskCustomerName", @"Alex", @"-kioskNoSquare", @"YES", @"-kioskHideDebugBar", @"YES",
                                   @"-kioskSimulatePayment", @"YES"] mutableCopy];
    [arguments addObjectsFromArray:extra];
    self.app.launchArguments = arguments;
    [self.app launch];
}

- (void)snapshot:(NSString *)name {
    NSString *path = [NSString stringWithFormat:@"/tmp/giftcard-screens/%@.png", name];
    [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:path atomically:YES];
}

- (XCUIElement *)text:(NSString *)prefix {
    return [[self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (XCUIElement *)button:(NSString *)prefix {
    return [[self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (void)waitFor:(XCUIElement *)element {
    XCTAssertTrue([element waitForExistenceWithTimeout:20], @"%@", element);
}

- (void)typeNumber:(NSString *)number {
    for (NSUInteger i = 0; i < number.length; i++) {
        [self.app.buttons[[number substringWithRange:NSMakeRange(i, 1)]] tap];
    }
}

- (void)enterNumber:(NSString *)number {
    [self waitFor:[self text:@"Scan your gift card"]];
    [[self button:@"Enter number instead"] tap];
    [self waitFor:[self text:@"Enter your gift card number"]];
    [self typeNumber:number];
    [[self button:@"Check Balance"] tap];
}

- (void)testSummaryLeadsToScanAndManualEntry {
    [self launchOn:@"summary" extra:@[]];
    XCUIElement *gift = [self button:@"Pay with gift card"];
    [self waitFor:gift];
    XCTAssertTrue([self button:@"Pay with card"].exists);
    [NSThread sleepForTimeInterval:1.5];
    [self snapshot:@"1-summary"];
    [gift tap];

    XCUIElement *proceed = [self button:@"Continue to Payment"];
    [self waitFor:proceed];
    [proceed tap];

    [self waitFor:[self text:@"Scan your gift card"]];
    XCTAssertTrue([self text:@"Hold your gift card's QR code or barcode"].exists);
    XCTAssertTrue(self.app.otherElements[@"Gift card camera"].exists);
    [NSThread sleepForTimeInterval:0.8];
    [self snapshot:@"2-scan"];

    [[self button:@"Enter number instead"] tap];
    [self waitFor:[self text:@"Enter your gift card number"]];
    XCUIElement *check = [self button:@"Check Balance"];
    XCTAssertFalse(check.enabled);
    [self typeNumber:@"77833200123456789"];
    XCUIElement *field = [self.app.otherElements elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == 'Gift card number'"]];
    XCTAssertEqualObjects(field.value, @"7783 3200 1234 5678");
    XCTAssertTrue(check.enabled);
    [NSThread sleepForTimeInterval:0.5];
    [self snapshot:@"3-manual-entry"];
    [self.app.buttons[@"Delete"] tap];
    XCTAssertEqualObjects(field.value, @"7783 3200 1234 567");
    XCTAssertFalse(check.enabled);

    [[self button:@"Back"] tap];
    [self waitFor:[self text:@"Scan your gift card"]];
    [[self button:@"Pay with card instead"] tap];
    [self waitFor:[self text:@"Thank you, Alex."]];
}

- (void)testGiftCardPaysTheWholeOrder {
    [self launchOn:@"giftcard" extra:@[]];
    [self enterNumber:@"7783320012345678"];
    [self waitFor:[self text:@"Pay $"]];
    XCTAssertTrue([[self text:@"Pay $"].label hasSuffix:@"with gift card ending 5678?"]);
    XCTAssertTrue([self text:@"Balance after"].exists);
    [NSThread sleepForTimeInterval:0.6];
    [self snapshot:@"4-confirm-full"];
    [[self button:@"Pay $"] tap];
    [self waitFor:[self text:@"Thank you, Alex."]];
    [self waitFor:[self text:@"Gift card •••• 5678"]];
    [NSThread sleepForTimeInterval:1.6];
    [self snapshot:@"5-confirmation-gift-only"];
}

- (void)testGiftCardSplitsWithTheReader {
    [self launchOn:@"giftcard" extra:@[]];
    [self enterNumber:@"7783320012341111"];
    [self waitFor:[self text:@"Your gift card has $2.00."]];
    XCTAssertTrue([self text:@"Use it and pay the remaining"].exists);
    [NSThread sleepForTimeInterval:0.6];
    [self snapshot:@"6-confirm-split"];
    [[self button:@"Split Payment"] tap];
    [self waitFor:[self text:@"Gift card applied"]];
    [NSThread sleepForTimeInterval:0.5];
    [self snapshot:@"7-applied"];
    [self waitFor:[self text:@"Thank you, Alex."]];
    [self waitFor:[self text:@"Visa •••• 1111 + Gift card •••• 1111"]];
    XCTAssertTrue([self text:@"Gift card •••• 1111"].exists);
    [NSThread sleepForTimeInterval:1.6];
    [self snapshot:@"8-confirmation-split"];
}

- (void)testCanceledReaderReturnsToTheOrder {
    [self launchOn:@"giftcard" extra:@[@"-kioskForceError", @"canceled"]];
    [self enterNumber:@"7783320012341111"];
    [self waitFor:[self button:@"Split Payment"]];
    [[self button:@"Split Payment"] tap];
    XCUIElement *alert = self.app.alerts[@"Your gift card wasn't charged"];
    [self waitFor:alert];
    [NSThread sleepForTimeInterval:1.0];
    [self snapshot:@"9-reader-canceled"];
    [alert.buttons[@"OK"] tap];
    [self waitFor:[self button:@"Pay with gift card"]];
}

- (void)testEmptyCardOffersAnother {
    [self launchOn:@"giftcard" extra:@[]];
    [self enterNumber:@"7783320012340000"];
    [self waitFor:[self text:@"This gift card has no balance"]];
    [self snapshot:@"10-empty"];
    [[self button:@"Try Another Card"] tap];
    [self waitFor:[self text:@"Scan your gift card"]];
}

@end
