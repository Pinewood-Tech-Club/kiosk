#import <XCTest/XCTest.h>

// The order is a $4.00 cup and a $9.00 waffle cone ($13.00). Gift card ending 1675 holds $16.75, 1111 holds $2.00.
@interface DonationUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation DonationUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    [NSFileManager.defaultManager createDirectoryAtPath:@"/tmp/donation-shots" withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)launchOn:(NSString *)screen extra:(NSArray<NSString *> *)extra {
    self.app = [[XCUIApplication alloc] init];
    NSMutableArray *arguments = [@[@"-kioskRole", @"kiosk", @"-kioskScreen", screen,
                                   @"-kioskItems", @"cup:vanilla;cone:chocolate,cookies+whip",
                                   @"-kioskCustomerName", @"Alex", @"-kioskNoSquare", @"YES", @"-kioskHideDebugBar", @"YES",
                                   @"-kioskSimulatePayment", @"YES"] mutableCopy];
    [arguments addObjectsFromArray:extra];
    self.app.launchArguments = arguments;
    [self.app launch];
}

- (void)snapshot:(NSString *)name {
    NSString *path = [NSString stringWithFormat:@"/tmp/donation-shots/%@.png", name];
    [XCUIScreen.mainScreen.screenshot.PNGRepresentation writeToFile:path atomically:YES];
}

- (XCUIElement *)text:(NSString *)prefix {
    return [[self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (XCUIElement *)exactText:(NSString *)label {
    return [[self.app.staticTexts matchingPredicate:[NSPredicate predicateWithFormat:@"label == %@", label]] firstMatch];
}

- (XCUIElement *)button:(NSString *)prefix {
    return [[self.app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"label BEGINSWITH %@", prefix]] firstMatch];
}

- (void)waitFor:(XCUIElement *)element {
    XCTAssertTrue([element waitForExistenceWithTimeout:20], @"%@", element);
}

- (void)waitForGone:(XCUIElement *)element {
    NSPredicate *gone = [NSPredicate predicateWithFormat:@"exists == NO"];
    [self waitForExpectations:@[[self expectationForPredicate:gone evaluatedWithObject:element handler:nil]] timeout:10];
}

- (void)typeNumber:(NSString *)number {
    for (NSUInteger i = 0; i < number.length; i++) {
        [self.app.buttons[[number substringWithRange:NSMakeRange(i, 1)]] tap];
    }
}

- (void)enterGiftCard:(NSString *)number {
    [self waitFor:[self text:@"Scan your gift card"]];
    [[self button:@"Enter number instead"] tap];
    [self waitFor:[self text:@"Enter your gift card number"]];
    [self typeNumber:number];
    [[self button:@"Check Balance"] tap];
}

- (void)testPresetsToggleAndCustomUsesTheKeypad {
    [self launchOn:@"summary" extra:@[]];
    XCUIElement *five = self.app.buttons[@"Donate $5"];
    [self waitFor:five];
    XCTAssertTrue(self.app.buttons[@"Donate $2"].exists);
    XCTAssertTrue(self.app.buttons[@"Donate $10"].exists);
    XCTAssertTrue([self exactText:@"$13.00"].exists);
    XCTAssertFalse([self exactText:@"Donation"].exists);
    [NSThread sleepForTimeInterval:1.0];
    [self snapshot:@"2-picker-none"];

    [five tap];
    [self waitFor:[self exactText:@"$18.00"]];
    XCTAssertTrue([self exactText:@"Donation"].exists);
    XCTAssertTrue(five.selected);
    [NSThread sleepForTimeInterval:0.6];
    [self snapshot:@"3-picker-five"];

    [five tap];
    [self waitFor:[self exactText:@"$13.00"]];
    XCTAssertFalse(five.selected);

    [self.app.buttons[@"Donate $10"] tap];
    [self waitFor:[self exactText:@"$23.00"]];

    [self.app.buttons[@"Custom donation"] tap];
    [self waitFor:[self text:@"Any whole dollar amount"]];
    XCUIElement *add = [self button:@"Add"];
    XCTAssertFalse(add.enabled);
    [self typeNumber:@"0"];
    XCTAssertFalse(add.enabled);
    [self typeNumber:@"2"];
    [self typeNumber:@"5"];
    XCUIElement *amount = [self.app.otherElements elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label == 'Donation amount'"]];
    XCTAssertEqualObjects(amount.value, @"$25");
    XCTAssertTrue([self button:@"Add $25 Donation"].enabled);
    [NSThread sleepForTimeInterval:0.6];
    [self snapshot:@"4-custom-keypad"];
    [self.app.buttons[@"Delete"] tap];
    [self.app.buttons[@"Delete"] tap];
    [self typeNumber:@"1009"];
    XCTAssertEqualObjects(amount.value, @"$100");
    [self.app.buttons[@"Delete"] tap];
    [self.app.buttons[@"Delete"] tap];
    [self typeNumber:@"5"];
    XCTAssertEqualObjects(amount.value, @"$15");
    [[self button:@"Add $15 Donation"] tap];

    [self waitFor:self.app.buttons[@"Custom donation, $15"]];
    [self waitFor:[self exactText:@"$28.00"]];
    XCTAssertFalse(self.app.buttons[@"Donate $10"].selected);
    [NSThread sleepForTimeInterval:0.8];
    [self snapshot:@"5-picker-custom"];

    [[self button:@"Pay with card"] tap];
    XCUIElement *proceed = [self button:@"Continue to Payment"];
    [self waitFor:proceed];
    [proceed tap];
    [self waitFor:[self text:@"Thank you, Alex."]];
    [self waitFor:[self exactText:@"Donation"]];
    XCTAssertTrue([self exactText:@"$28.00"].exists);
    [NSThread sleepForTimeInterval:1.6];
    [self snapshot:@"6-confirmation-card"];
}

- (void)testCustomCancelLeavesTheDonationAlone {
    [self launchOn:@"summary" extra:@[@"-kioskDonation", @"200"]];
    [self waitFor:[self exactText:@"$15.00"]];
    XCTAssertTrue(self.app.buttons[@"Donate $2"].selected);
    [self.app.buttons[@"Custom donation"] tap];
    [self waitFor:[self text:@"Any whole dollar amount"]];
    [self typeNumber:@"7"];
    [[self button:@"Cancel"] tap];
    [self waitForGone:[self text:@"Any whole dollar amount"]];
    XCTAssertTrue([self exactText:@"$15.00"].exists);
    XCTAssertTrue(self.app.buttons[@"Donate $2"].selected);
}

- (void)testGiftCardLeftoverCanBeDonated {
    [self launchOn:@"giftcard" extra:@[@"-kioskDonation", @"200"]];
    [self enterGiftCard:@"7783320012341675"];
    XCUIElement *pay = [self button:@"Pay $15.00"];
    [self waitFor:pay];
    [pay tap];
    XCUIElement *alert = self.app.alerts[@"You'll have $1.75 left on your gift card"];
    [self waitFor:alert];
    XCTAssertTrue(alert.buttons[@"Donate $1.75"].exists);
    XCTAssertTrue(alert.buttons[@"No thanks"].exists);
    [NSThread sleepForTimeInterval:0.8];
    [self snapshot:@"7-leftover-offer"];
    [alert.buttons[@"Donate $1.75"] tap];

    [self waitFor:[self text:@"Thank you, Alex."]];
    [self waitFor:[self text:@"Gift card •••• 1675"]];
    XCTAssertTrue([self exactText:@"$16.75"].exists);
    XCTAssertTrue([self exactText:@"$3.75"].exists);
    [NSThread sleepForTimeInterval:1.6];
    [self snapshot:@"8-confirmation-leftover-donated"];
}

- (void)testGiftCardLeftoverCanBeDeclined {
    [self launchOn:@"giftcard" extra:@[@"-kioskDonation", @"200"]];
    [self enterGiftCard:@"7783320012341675"];
    XCUIElement *pay = [self button:@"Pay $15.00"];
    [self waitFor:pay];
    [pay tap];
    XCUIElement *alert = self.app.alerts[@"You'll have $1.75 left on your gift card"];
    [self waitFor:alert];
    [alert.buttons[@"No thanks"] tap];
    [self waitFor:[self text:@"Thank you, Alex."]];
    XCTAssertTrue([self exactText:@"$15.00"].exists);
    XCTAssertTrue([self exactText:@"$2.00"].exists);
}

- (void)testNoLeftoverOfferWhenTheCardCoversTenDollarsOrMore {
    [self launchOn:@"giftcard" extra:@[]];
    [self enterGiftCard:@"7783320012345678"];
    XCUIElement *pay = [self button:@"Pay $13.00"];
    [self waitFor:pay];
    [pay tap];
    [self waitFor:[self text:@"Thank you, Alex."]];
    XCTAssertEqual(self.app.alerts.count, 0);
}

- (void)testSplitPaymentCarriesTheDonationWithoutAnOffer {
    [self launchOn:@"giftcard" extra:@[@"-kioskDonation", @"500"]];
    [self enterGiftCard:@"7783320012341111"];
    [self waitFor:[self text:@"Your gift card has $2.00."]];
    XCTAssertTrue([self text:@"Use it and pay the remaining $16.00"].exists);
    [[self button:@"Split Payment"] tap];
    XCTAssertEqual(self.app.alerts.count, 0);
    [self waitFor:[self text:@"Thank you, Alex."]];
    [self waitFor:[self exactText:@"Donation"]];
    XCTAssertTrue([self exactText:@"$18.00"].exists);
    XCTAssertTrue([self exactText:@"$16.00"].exists);
    [NSThread sleepForTimeInterval:1.6];
    [self snapshot:@"9-confirmation-split-donation"];
}

@end
