import CoreGraphics

/// Screen-space layout in points for the portrait 13" iPad Pro (1032 × 1376).
/// SwiftUI places controls at these coordinates and the 3D stage converts the same points to world space.
enum Layout {
    static let screen = CGSize(width: 1032, height: 1376)
    static let midX: CGFloat = 516

    static let backButtonCenter = CGPoint(x: 104, y: 112)
    static let stepIndicatorY: CGFloat = 112
    static let titleY: CGFloat = 190
    static let subtitleY: CGFloat = 246

    static let dragArea = CGRect(x: 150, y: 286, width: 732, height: 548)

    static func mainPivot(_ vessel: Vessel) -> CGPoint {
        switch vessel {
        case .cup: CGPoint(x: midX, y: 691)
        case .cone: CGPoint(x: midX, y: 666)
        }
    }

    static let cardsCenterY: CGFloat = 966
    static let cardSize = CGSize(width: 296, height: 232)
    static let cardCornerRadius: CGFloat = 34
    static let iconOffsetY: CGFloat = -23.5

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
        return CGPoint(x: card.x, y: card.y + iconOffsetY - 10)
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
    static let trayItemsRect = CGRect(x: 150, y: 1218, width: 514, height: 134)
    static let trayFirstCenterX: CGFloat = 213
    /// Slots that fit fully inside the tray's item area; scrolling snaps to whole slots.
    static let trayVisibleSlots = 4
    /// Box each tray mini is fitted into (padding included in the tray's 134 pt height).
    static let trayMiniBox = CGSize(width: 96, height: 100)
    static let summaryMiniBox = CGSize(width: 190, height: 150)
    static let trayPitch: CGFloat = 118
    static let trayCenterY: CGFloat = 1285
    static let viewOrderRect = CGRect(x: 684, y: 1238, width: 220, height: 94)
    static let resetCenter = CGPoint(x: 966, y: 1285)
}
