import XCTest
@testable import Kiosk

final class PricingTests: XCTestCase {
    private func item(_ vessel: Vessel, _ flavors: [Flavor], _ toppings: [Topping] = []) -> IceCreamItem {
        IceCreamItem(vessel: vessel, flavors: flavors, toppings: toppings)
    }

    func testSingleItemScoopPrices() {
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla])]).totalCents, 400)
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla, .chocolate])]).totalCents, 700)
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla, .chocolate, .cookies])]).totalCents, 900)
    }

    func testNoDiscountAcrossItems() {
        let three: [Flavor] = [.vanilla, .chocolate, .cookies]
        let quote = Pricing.quote([item(.cup, three), item(.cup, three)])
        XCTAssertEqual(quote.lines.map(\.scoopShareCents), [900, 900])
        XCTAssertEqual(quote.scoopsTotalCents, 1800)
        XCTAssertEqual(quote.scoopCount, 6)
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla]), item(.cone, [.vanilla])]).totalCents, 950)
    }

    func testMixedCupAndConeWithToppings() {
        let quote = Pricing.quote([
            item(.cone, [.vanilla, .chocolate], [.whip]),
            item(.cup, [.cookies, .cookies, .vanilla], [.gummies, .mms]),
        ])
        XCTAssertEqual(quote.lines.map(\.scoopShareCents), [700, 900])
        XCTAssertEqual(quote.lines.map(\.totalCents), [900, 1000])
        XCTAssertEqual(quote.totalCents, 1900)
    }

    func testReceiptAndCatalogLinesRestartPerItem() {
        let quote = Pricing.quote([item(.cup, [.vanilla, .chocolate]), item(.cup, [.vanilla, .chocolate, .cookies])])
        XCTAssertEqual(Receipt.chargedLines(for: quote).map(\.title),
                       ["Ice Cream (First Scoop)", "Ice Cream (Second Scoop)", "Ice Cream (First Scoop)", "Ice Cream (Second Scoop)", "Ice Cream (Third Scoop)"])
        XCTAssertEqual(Receipt.chargedLines(for: quote).map(\.cents), [400, 300, 400, 300, 200])
    }
}
