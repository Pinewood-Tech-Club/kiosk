import CoreGraphics

/// Screen-space layout in points for the portrait 13" iPad Pro (1032 × 1376).
/// SwiftUI places controls at these coordinates and the 3D stage converts the same points to world space.
enum Layout {
    static let screen = CGSize(width: 1032, height: 1376)
    static let midX: CGFloat = 516

    static let backButtonCenter = CGPoint(x: 104, y: 112)
    static let stepIndicatorY: CGFloat = 106
    static let titleY: CGFloat = 190
    static let subtitleY: CGFloat = 246

    static let dragArea = CGRect(x: 150, y: 286, width: 732, height: 548)

    /// Space between the title and the cards that the item at the center is fitted into.
    static let heroBand = CGRect(x: 166, y: 262, width: 700, height: 582)

    static let cardsCenterY: CGFloat = 966
    static let cardSize = CGSize(width: 296, height: 232)
    static let cardCornerRadius: CGFloat = 34
    /// Card icons sit in the card's upper part, clear of the label beneath them.
    static let iconOffsetY: CGFloat = -38

    static func vesselCardCenter(_ vessel: Vessel) -> CGPoint {
        CGPoint(x: midX + (vessel == .cup ? -166 : 166), y: cardsCenterY)
    }

    static func flavorCardCenter(_ flavor: Flavor) -> CGPoint {
        let offsets: [Flavor: CGFloat] = [.vanilla: -312, .chocolate: 0, .cookies: 312]
        return CGPoint(x: midX + offsets[flavor, default: 0], y: cardsCenterY)
    }

    static func vesselIconCenter(_ vessel: Vessel) -> CGPoint {
        let card = vesselCardCenter(vessel)
        return CGPoint(x: card.x, y: card.y + iconOffsetY)
    }

    static func flavorIconCenter(_ flavor: Flavor) -> CGPoint {
        let card = flavorCardCenter(flavor)
        return CGPoint(x: card.x, y: card.y + iconOffsetY - 8)
    }

    static let captionY: CGFloat = 1106
    static let primaryButtonCenter = CGPoint(x: midX, y: 1158)
    static let primaryButtonSize = CGSize(width: 380, height: 72)

    static let sheetRect = CGRect(x: 0, y: 64, width: 1032, height: 1376)
    static let summaryListRect = CGRect(x: 0, y: 206, width: 1032, height: 846)
    static let summaryRowPitch: CGFloat = 172
    static let summaryRowHeight: CGFloat = 172
    static var summaryRowsThatFit: Int { Int((summaryListRect.height - 52) / summaryRowPitch) }
    static let summaryItemCenterX: CGFloat = 176

    static func summaryRowCenterY(_ index: CGFloat) -> CGFloat {
        summaryListRect.minY + 12 + summaryRowHeight / 2 + index * summaryRowPitch
    }

    static let trayGlassRect = CGRect(x: 24, y: 1218, width: 640, height: 134)
    static let trayNewItemRect = CGRect(x: 38, y: 1232, width: 100, height: 106)
    /// Starts halfway across the gap after the New item tile.
    static let trayItemsRect = CGRect(x: 152, y: 1218, width: 512, height: 134)
    /// Item tiles repeat the New item tile with equal gaps: 4 fit between it and the glass's inner edge.
    static let trayTileSize = CGSize(width: 100, height: 106)
    static let trayFirstCenterX: CGFloat = 216
    /// Slots that fit fully inside the tray's item area; scrolling snaps to whole slots.
    static let trayVisibleSlots = 4
    /// Box each tray mini is fitted into (padding included in the tray's 134 pt height).
    static let trayMiniBox = CGSize(width: 82, height: 88)
    static let summaryMiniBox = CGSize(width: 190, height: 150)
    static let trayPitch: CGFloat = 128
    static let trayCenterY: CGFloat = 1285
    /// View Order and reset line up with the tray tiles' top and bottom edges and share their corner radius.
    static let viewOrderRect = CGRect(x: 680, y: 1232, width: 206, height: 106)
    static let resetRect = CGRect(x: 902, y: 1232, width: 106, height: 106)
    static let trayTileRadius: CGFloat = 26
}
