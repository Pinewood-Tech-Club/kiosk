#import <XCTest/XCTest.h>

static const CGFloat kCardsY = 966;
static const CGFloat kMargin = 24;
static const CGFloat kCardWidth = 296;
static const CGFloat kPitch = 312;
static const CGFloat kScreenWidth = 1032;

@interface ToppingsCarouselUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation ToppingsCarouselUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] init];
    self.app.launchArguments = @[@"-kioskStep", @"toppings", @"-kioskCurrent", @"cup:vanilla,chocolate",
                                 @"-kioskNoSquare", @"YES", @"-kioskHideDebugBar", @"YES"];
    [self.app launch];
    XCTAssertTrue([[self card:@"whip"] waitForExistenceWithTimeout:30], @"the toppings step should show its cards");
    [self pause:2.0];
}

- (void)pause:(double)seconds {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (XCUIElement *)card:(NSString *)topping {
    return self.app.buttons[[@"topping-" stringByAppendingString:topping]];
}

- (XCUICoordinate *)at:(CGFloat)x {
    return [[self.app coordinateWithNormalizedOffset:CGVectorMake(0, 0)] coordinateWithOffset:CGVectorMake(x, kCardsY)];
}

- (void)attachScreenshot:(NSString *)name {
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:[XCUIScreen.mainScreen screenshot]];
    shot.name = name;
    shot.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:shot];
}

- (void)assertSnapped:(NSString *)context {
    CGFloat whip = CGRectGetMinX([self card:@"whip"].frame);
    CGFloat last = CGRectGetMaxX([self card:@"sprinkles"].frame);
    CGFloat steps = (kMargin - whip) / kPitch;
    BOOL onCard = fabs(steps - round(steps)) * kPitch < 1.5;
    BOOL atEnd = fabs(last - (kScreenWidth - kMargin)) < 1.5;
    XCTAssertTrue(onCard || atEnd, @"%@: carousel came to rest between cards (whip at %.1f, last ends at %.1f)",
                  context, whip, last);
}

- (void)testStartsAtTheFirstCardWithTheNextOnePeeking {
    XCTAssertEqualWithAccuracy(CGRectGetMinX([self card:@"whip"].frame), kMargin, 1);
    CGFloat peek = CGRectGetMinX([self card:@"mms"].frame);
    XCTAssertEqualWithAccuracy(peek, kMargin + 3 * kPitch, 1);
    XCTAssertLessThan(peek, kScreenWidth, @"the fourth card should peek in from the right edge");
    XCTAssertEqualWithAccuracy(CGRectGetWidth([self card:@"whip"].frame), kCardWidth, 1);
    [self attachScreenshot:@"start"];
}

- (void)testFlingReachesTheEndSnapsAndTogglesAScrolledCard {
    [[self at:900] pressForDuration:0.02 thenDragToCoordinate:[self at:250] withVelocity:2400 thenHoldForDuration:0];
    for (int i = 0; i < 4; i++) [self attachScreenshot:[NSString stringWithFormat:@"mid-fling %d", i]];
    [self pause:2.5];
    [self assertSnapped:@"after fling"];
    XCUIElement *sprinkles = [self card:@"sprinkles"];
    XCTAssertLessThanOrEqual(CGRectGetMaxX(sprinkles.frame), kScreenWidth - kMargin + 1, @"a fling should reach the last card");
    [self attachScreenshot:@"end"];

    [sprinkles tap];
    [self pause:0.25];
    [self attachScreenshot:@"toss from scrolled card"];
    [self pause:2.0];
    XCTAssertEqualObjects(sprinkles.value, @"Added");
    [self attachScreenshot:@"sprinkles added"];
    [sprinkles tap];
    [self pause:1.5];
    XCTAssertEqualObjects(sprinkles.value, @"+$0.50");

    [[self at:150] pressForDuration:0.02 thenDragToCoordinate:[self at:900] withVelocity:2400 thenHoldForDuration:0];
    [self pause:2.5];
    XCTAssertEqualWithAccuracy(CGRectGetMinX([self card:@"whip"].frame), kMargin, 1.5, @"a fling back should return to the start");
}

- (void)testSlowDragSnapsToTheNearestCard {
    [[self at:700] pressForDuration:0.1 thenDragToCoordinate:[self at:600] withVelocity:200 thenHoldForDuration:0.4];
    [self pause:1.5];
    [self assertSnapped:@"short drag"];
    XCTAssertEqualWithAccuracy(CGRectGetMinX([self card:@"whip"].frame), kMargin, 1.5, @"a short drag should spring back");

    [[self at:700] pressForDuration:0.1 thenDragToCoordinate:[self at:460] withVelocity:200 thenHoldForDuration:0.4];
    [self attachScreenshot:@"held between cards"];
    [self pause:1.5];
    [self assertSnapped:@"long drag"];
    XCTAssertEqualWithAccuracy(CGRectGetMinX([self card:@"whip"].frame), kMargin - kPitch, 1.5,
                               @"a drag past half a card should move one card on");
}

- (void)testScrollingDoesNotToggleACard {
    XCUIElement *chocolate = [self card:@"chocolate"];
    [[self at:520] pressForDuration:0.05 thenDragToCoordinate:[self at:240] withVelocity:900 thenHoldForDuration:0];
    [self pause:2.0];
    XCTAssertEqualObjects(chocolate.value, @"+$0.50", @"a drag that starts on a card must not add it");
}

@end
