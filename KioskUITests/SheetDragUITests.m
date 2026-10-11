#import <XCTest/XCTest.h>

// XCUITest's public drags are a single straight segment. These XCUIAutomation classes (the ones
// WebDriverAgent uses) replay an arbitrary touch path, so a finger can go down, hold, reverse and
// lift anywhere, and a second finger can join.
@protocol KioskPointerEventPath <NSObject>
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end

@protocol KioskSynthesizedEventRecord <NSObject>
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

typedef struct {
    double t;
    CGFloat y;
} Waypoint;

static const CGFloat kGrabX = 760;
static const CGFloat kGrabY = 170;
static const CGFloat kBottomY = 1370;

@interface SheetDragUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@end

@implementation SheetDragUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.app = [[XCUIApplication alloc] init];
    self.app.launchArguments = @[@"-kioskScreen", @"summary", @"-kioskItems", @"cup:vanilla;cone:chocolate,cookies",
                                 @"-kioskNoSquare", @"YES", @"-kioskHideDebugBar", @"YES"];
    [self.app launch];
    XCTAssertTrue([[self keepOrdering] waitForExistenceWithTimeout:30], @"the order sheet should start open");
    [self pause:1.5];
}

- (void)pause:(double)seconds {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

- (XCUIElement *)keepOrdering {
    return [self.app.buttons elementMatchingPredicate:[NSPredicate predicateWithFormat:@"label CONTAINS 'Keep ordering'"]];
}

- (id<KioskPointerEventPath>)pathAt:(CGFloat)x waypoints:(const Waypoint *)points count:(NSUInteger)count
                             liftAt:(double)lift {
    id<KioskPointerEventPath> path = [[NSClassFromString(@"XCPointerEventPath") alloc]
                                      initForTouchAtPoint:CGPointMake(x, points[0].y) offset:points[0].t];
    for (NSUInteger i = 1; i < count; i++) {
        // Dense samples, so the synthesizer can't straighten the path between distant points.
        double t0 = points[i - 1].t, t1 = points[i].t;
        NSUInteger steps = MAX(1, (NSUInteger)((t1 - t0) / 0.016));
        for (NSUInteger s = 1; s <= steps; s++) {
            double u = (double)s / steps;
            CGFloat y = points[i - 1].y + (points[i].y - points[i - 1].y) * u;
            [path moveToPoint:CGPointMake(x, y) atOffset:t0 + (t1 - t0) * u];
        }
    }
    [path liftUpAtOffset:lift];
    return path;
}

- (void)perform:(NSString *)name paths:(NSArray *)paths {
    id<KioskSynthesizedEventRecord> record = [[NSClassFromString(@"XCSynthesizedEventRecord") alloc]
                                              initWithName:name interfaceOrientation:UIInterfaceOrientationPortrait];
    for (id path in paths) [record addPointerEventPath:path];
    NSError *error = nil;
    XCTAssertTrue([record synthesizeWithError:&error], @"%@: %@", name, error);
}

- (void)drag:(NSString *)name waypoints:(const Waypoint *)points count:(NSUInteger)count holdAtEnd:(double)hold {
    double lift = points[count - 1].t + hold;
    [self perform:name paths:@[[self pathAt:kGrabX waypoints:points count:count liftAt:lift]]];
}

/// After any release the sheet must come to rest open or closed, and the app must still answer touches:
/// closing and reopening the order proves nothing is left holding the sheet.
- (void)assertSettled:(NSString *)name {
    [self pause:2.0];
    XCUIElement *keep = [self keepOrdering];
    XCTAttachment *shot = [XCTAttachment attachmentWithScreenshot:self.app.screenshot];
    shot.name = [name stringByAppendingString:@" after release"];
    shot.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:shot];
    if (keep.exists) {
        XCTAssertEqualWithAccuracy(CGRectGetMidY(keep.frame), 112, 4, @"%@: sheet came to rest part-way", name);
        [keep tap];
        [self pause:1.6];
        XCTAssertFalse([self keepOrdering].exists, @"%@: Keep ordering didn't close the sheet", name);
    }
    [[[self.app coordinateWithNormalizedOffset:CGVectorMake(0, 0)] coordinateWithOffset:CGVectorMake(783, 1285)] tap];
    [self pause:2.0];
    XCTAssertTrue([self keepOrdering].exists, @"%@: View Order didn't reopen the sheet (app stuck)", name);
    XCTAssertEqualWithAccuracy(CGRectGetMidY([self keepOrdering].frame), 112, 4, @"%@: reopened sheet not at rest", name);
}

- (void)testDragToBottomHoldAndRelease {
    Waypoint points[] = {{0, kGrabY}, {2.5, kBottomY}};
    [self drag:@"bottom-hold-release" waypoints:points count:2 holdAtEnd:2.0];
    [self assertSettled:@"bottom-hold-release"];
}

- (void)testDragToBottomHoldThenBackUp {
    Waypoint points[] = {{0, kGrabY}, {2.0, kBottomY}, {4.5, kBottomY}, {6.5, kGrabY + 20}};
    [self drag:@"bottom-hold-up" waypoints:points count:4 holdAtEnd:0.6];
    [self assertSettled:@"bottom-hold-up"];
}

- (void)testSlowOscillationThroughTheWholeTravel {
    Waypoint points[] = {
        {0, kGrabY}, {1.5, 600}, {2.5, 300}, {4.0, 1100}, {5.0, 700}, {6.5, kBottomY}, {7.5, kBottomY},
        {9.0, 400}, {9.6, 60}, {10.4, 60}, {12.0, 1250}, {13.0, 900}, {14.5, kBottomY}, {15.5, 500},
        {16.5, 1300}, {18.0, 200},
    };
    [self drag:@"oscillation" waypoints:points count:sizeof(points) / sizeof(points[0]) holdAtEnd:0.3];
    [self assertSettled:@"oscillation"];
}

- (void)testReleaseAtTheBottomAfterOscillating {
    Waypoint points[] = {{0, kGrabY}, {2.0, 900}, {3.0, 400}, {4.5, kBottomY}, {5.5, 700}, {7.0, kBottomY}};
    [self drag:@"oscillate-release-bottom" waypoints:points count:6 holdAtEnd:1.0];
    [self assertSettled:@"oscillate-release-bottom"];
}

- (void)testFlingsAndShortPulls {
    Waypoint flingDown[] = {{0, kGrabY}, {0.12, kGrabY + 220}};
    [self drag:@"fling-down" waypoints:flingDown count:2 holdAtEnd:0];
    [self assertSettled:@"fling-down"];
    Waypoint shortPull[] = {{0, kGrabY}, {0.6, kGrabY + 120}, {1.0, kGrabY + 90}};
    [self drag:@"short-pull" waypoints:shortPull count:3 holdAtEnd:0.2];
    [self assertSettled:@"short-pull"];
    Waypoint flingUp[] = {{0, kGrabY}, {1.5, 1000}, {1.62, 780}};
    [self drag:@"fling-up-from-low" waypoints:flingUp count:3 holdAtEnd:0];
    [self assertSettled:@"fling-up-from-low"];
    Waypoint above[] = {{0, kGrabY + 100}, {1.0, 20}, {2.0, 5}};
    [self drag:@"above-open" waypoints:above count:3 holdAtEnd:0.5];
    [self assertSettled:@"above-open"];
}

- (void)testSecondFingerJoinsAndLiftsFirst {
    Waypoint first[] = {{0, kGrabY}, {2.0, 1000}, {3.0, kBottomY}};
    Waypoint second[] = {{1.0, 400}, {2.5, 900}, {4.0, 300}};
    [self perform:@"two-fingers" paths:@[
        [self pathAt:kGrabX waypoints:first count:3 liftAt:3.4],
        [self pathAt:300 waypoints:second count:3 liftAt:4.6],
    ]];
    [self assertSettled:@"two-fingers"];
}

@end
