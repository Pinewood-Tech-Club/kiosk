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

    func testHotFudgeIsPricedLikeEveryTopping() {
        XCTAssertEqual(Topping.fudge.priceCents, 50)
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla], [.fudge, .chocolate])]).totalCents, 500)
    }

    func testHotFudgeStacksUnderEverythingElse() {
        XCTAssertEqual(Topping.stacked([.sprinkles, .whip, .chocolate, .fudge]), [.fudge, .whip, .chocolate, .sprinkles])
    }

    func testDonationIsAddedToTheTotalOnlyWithItems() {
        let quote = Pricing.quote([item(.cup, [.vanilla])], donationCents: 500)
        XCTAssertEqual(quote.itemsTotalCents, 400)
        XCTAssertEqual(quote.totalCents, 900)
        XCTAssertEqual(quote.adding(donationCents: 125).totalCents, 1025)
        XCTAssertEqual(Pricing.quote([], donationCents: 500).totalCents, 0)
        XCTAssertEqual(Pricing.quote([item(.cup, [.vanilla])], donationCents: -100).totalCents, 400)
    }

    func testDonationIsItsOwnUntaxedSquareLine() {
        let quote = Pricing.quote([item(.cup, [.vanilla])], donationCents: 300)
        let lines = Receipt.chargedLines(for: quote)
        XCTAssertEqual(lines.last?.title, "Donation")
        XCTAssertEqual(lines.reduce(0) { $0 + $1.cents }, 700)
        XCTAssertEqual(lines.filter(\.isDonation).map(\.cents), [300])
        let line = SquareAPI.donationLineItem(cents: 300, blockedTaxIDs: ["TAX1"])
        XCTAssertEqual(line["name"] as? String, "Donation")
        XCTAssertEqual((line["base_price_money"] as? [String: Any])?["amount"] as? Int, 300)
        let blocked = (line["pricing_blocklists"] as? [String: Any])?["blocked_taxes"] as? [[String: String]]
        XCTAssertEqual(blocked?.first?["tax_catalog_object_id"], "TAX1")
        XCTAssertNil(SquareAPI.donationLineItem(cents: 300, blockedTaxIDs: [])["pricing_blocklists"])
        XCTAssertEqual(SquareAPI.lineItems(for: quote).count, 1)
    }

    func testReceiptAndCatalogLinesRestartPerItem() {
        let quote = Pricing.quote([item(.cup, [.vanilla, .chocolate]), item(.cup, [.vanilla, .chocolate, .cookies])])
        XCTAssertEqual(Receipt.chargedLines(for: quote).map(\.title),
                       ["Ice Cream (First Scoop)", "Ice Cream (Second Scoop)", "Ice Cream (First Scoop)", "Ice Cream (Second Scoop)", "Ice Cream (Third Scoop)"])
        XCTAssertEqual(Receipt.chargedLines(for: quote).map(\.cents), [400, 300, 400, 300, 200])
    }
}
