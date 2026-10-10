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
        case .cup: CGPoint(x: midX, y: 648)
        case .cone: CGPoint(x: midX, y: 618)
        }
    }

    static let cardsCenterY: CGFloat = 966
    static let cardSize = CGSize(width: 296, height: 232)
    static let cardCornerRadius: CGFloat = 34
    static let iconOffsetY: CGFloat = -36

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
        return CGPoint(x: card.x, y: card.y + iconOffsetY + 10)
    }

    static let captionY: CGFloat = 1106
    static let primaryButtonCenter = CGPoint(x: midX, y: 1158)
    static let primaryButtonSize = CGSize(width: 380, height: 72)

    static let trayRect = CGRect(x: 24, y: 1218, width: 984, height: 134)
    static let trayItemsRect = CGRect(x: 24, y: 1218, width: 638, height: 134)
    static let trayFirstCenterX: CGFloat = 104
    static let trayPitch: CGFloat = 118
    static let trayCenterY: CGFloat = 1285
    static let viewOrderRect = CGRect(x: 674, y: 1238, width: 250, height: 94)
    static let resetCenter = CGPoint(x: 966, y: 1285)
}
