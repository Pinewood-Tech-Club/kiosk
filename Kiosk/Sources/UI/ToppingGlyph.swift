import SwiftUI

/// Flat stand-in for a topping card's icon until the stage draws its 3D icon there (`Layout.toppingIconFrame`).
struct ToppingGlyph: View {
    let topping: Topping
    var size: CGFloat = 72

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 64, y: canvas.height / 64)
            switch topping {
            case .whip: Self.whip(&context)
            case .fudge: Self.fudge(&context)
            case .chocolate: Self.syrup(&context, dark: Self.chocolate, light: Self.chocolateLight)
            case .caramel: Self.syrup(&context, dark: Self.caramel, light: Self.caramelLight)
            case .gummies: Self.gummies(&context)
            case .mms: Self.candies(&context)
            case .sprinkles: Self.sprinkles(&context)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let cream = Color(red: 0.98, green: 0.95, blue: 0.90)
    private static let creamShade = Color(red: 0.84, green: 0.79, blue: 0.72)
    private static let chocolate = Color(red: 0.36, green: 0.20, blue: 0.12)
    private static let chocolateLight = Color(red: 0.55, green: 0.33, blue: 0.20)
    private static let fudge = Color(red: 0.24, green: 0.11, blue: 0.06)
    private static let fudgeLight = Color(red: 0.42, green: 0.22, blue: 0.13)
    private static let steel = Color(red: 0.78, green: 0.79, blue: 0.81)
    private static let steelShade = Color(red: 0.52, green: 0.53, blue: 0.56)
    private static let caramel = Color(red: 0.62, green: 0.32, blue: 0.08)
    private static let caramelLight = Color(red: 0.88, green: 0.58, blue: 0.24)

    private static func whip(_ context: inout GraphicsContext) {
        let tiers: [(CGRect, CGFloat)] = [
            (CGRect(x: 8, y: 40, width: 48, height: 16), 8),
            (CGRect(x: 13, y: 28, width: 38, height: 15), 7.5),
            (CGRect(x: 19, y: 17, width: 26, height: 14), 7),
        ]
        for (rect, radius) in tiers {
            let shape = Path(roundedRect: rect, cornerRadius: radius)
            context.fill(shape, with: .linearGradient(Gradient(colors: [cream, creamShade]),
                                                     startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                     endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        var peak = Path()
        peak.move(to: CGPoint(x: 23, y: 20))
        peak.addQuadCurve(to: CGPoint(x: 35, y: 6), control: CGPoint(x: 27, y: 9))
        peak.addQuadCurve(to: CGPoint(x: 41, y: 20), control: CGPoint(x: 37, y: 14))
        peak.closeSubpath()
        context.fill(peak, with: .color(cream))
    }

    private static func fudge(_ context: inout GraphicsContext) {
        var handle = Path()
        handle.move(to: CGPoint(x: 13, y: 30))
        handle.addCurve(to: CGPoint(x: 16, y: 5), control1: CGPoint(x: 8, y: 20), control2: CGPoint(x: 9, y: 9))
        context.stroke(handle, with: .color(steel), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        var bowl = Path()
        bowl.move(to: CGPoint(x: 8, y: 30))
        bowl.addCurve(to: CGPoint(x: 56, y: 30), control1: CGPoint(x: 9, y: 58), control2: CGPoint(x: 55, y: 58))
        bowl.closeSubpath()
        context.fill(bowl, with: .linearGradient(Gradient(colors: [steel, steelShade]),
                                                startPoint: CGPoint(x: 20, y: 30), endPoint: CGPoint(x: 48, y: 56)))
        var top = Path(ellipseIn: CGRect(x: 8, y: 23, width: 48, height: 14))
        var drip = Path()
        drip.move(to: CGPoint(x: 40, y: 32))
        drip.addLine(to: CGPoint(x: 41, y: 44))
        drip.addArc(center: CGPoint(x: 45, y: 45), radius: 4.6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        drip.addLine(to: CGPoint(x: 50, y: 32))
        drip.closeSubpath()
        top.addPath(drip)
        context.fill(top, with: .linearGradient(Gradient(colors: [fudgeLight, fudge]),
                                               startPoint: CGPoint(x: 18, y: 22), endPoint: CGPoint(x: 44, y: 50)))
        var shine = Path()
        shine.move(to: CGPoint(x: 20, y: 27))
        shine.addQuadCurve(to: CGPoint(x: 34, y: 26), control: CGPoint(x: 27, y: 25))
        context.stroke(shine, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }

    private static func syrup(_ context: inout GraphicsContext, dark: Color, light: Color) {
        var drop = Path()
        drop.move(to: CGPoint(x: 32, y: 6))
        drop.addCurve(to: CGPoint(x: 50, y: 40), control1: CGPoint(x: 38, y: 18), control2: CGPoint(x: 50, y: 27))
        drop.addArc(center: CGPoint(x: 32, y: 40), radius: 18, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        drop.addCurve(to: CGPoint(x: 32, y: 6), control1: CGPoint(x: 14, y: 27), control2: CGPoint(x: 26, y: 18))
        drop.closeSubpath()
        context.fill(drop, with: .linearGradient(Gradient(colors: [light, dark]),
                                                startPoint: CGPoint(x: 20, y: 14), endPoint: CGPoint(x: 44, y: 58)))
        var shine = Path()
        shine.addArc(center: CGPoint(x: 32, y: 40), radius: 11, startAngle: .degrees(160), endAngle: .degrees(215), clockwise: false)
        context.stroke(shine, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
    }

    private static func bear(at origin: CGPoint, scale: CGFloat, color: Color, _ context: inout GraphicsContext) {
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: origin.x + (x - r) * scale, y: origin.y + (y - r) * scale, width: 2 * r * scale, height: 2 * r * scale))
        }
        var shape = Path()
        shape.addPath(circle(-6, -15, 3.6))
        shape.addPath(circle(6, -15, 3.6))
        shape.addPath(circle(0, -9, 8))
        shape.addPath(Path(roundedRect: CGRect(x: origin.x - 9 * scale, y: origin.y - 3 * scale, width: 18 * scale, height: 19 * scale),
                           cornerRadius: 8 * scale))
        shape.addPath(circle(-10, 3, 3.6))
        shape.addPath(circle(10, 3, 3.6))
        shape.addPath(circle(-6, 16, 4))
        shape.addPath(circle(6, 16, 4))
        context.fill(shape, with: .color(color))
        context.fill(circle(-2.5, -11, 2.2), with: .color(.white.opacity(0.4)))
    }

    private static func gummies(_ context: inout GraphicsContext) {
        bear(at: CGPoint(x: 21, y: 35), scale: 0.9, color: Color(red: 0.42, green: 0.70, blue: 0.30), &context)
        bear(at: CGPoint(x: 43, y: 35), scale: 0.9, color: Color(red: 0.95, green: 0.62, blue: 0.18), &context)
        bear(at: CGPoint(x: 32, y: 40), scale: 1.05, color: Color(red: 0.86, green: 0.22, blue: 0.24), &context)
    }

    private static func candies(_ context: inout GraphicsContext) {
        let pieces: [(CGPoint, Color)] = [
            (CGPoint(x: 22, y: 24), Color(red: 0.96, green: 0.78, blue: 0.16)),
            (CGPoint(x: 43, y: 22), Color(red: 0.20, green: 0.48, blue: 0.85)),
            (CGPoint(x: 18, y: 44), Color(red: 0.25, green: 0.66, blue: 0.36)),
            (CGPoint(x: 42, y: 44), Color(red: 0.93, green: 0.48, blue: 0.16)),
            (CGPoint(x: 31, y: 34), Color(red: 0.85, green: 0.20, blue: 0.20)),
        ]
        for (center, color) in pieces {
            let rect = CGRect(x: center.x - 11, y: center.y - 10, width: 22, height: 20)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.black.opacity(0.25)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 7, width: 7, height: 4.5)), with: .color(.white.opacity(0.45)))
        }
    }

    private static func sprinkles(_ context: inout GraphicsContext) {
        let colors = [
            Color(red: 0.93, green: 0.42, blue: 0.56), Color(red: 0.98, green: 0.82, blue: 0.30),
            Color(red: 0.40, green: 0.72, blue: 0.90), Color(red: 0.52, green: 0.80, blue: 0.48),
            Color(red: 0.98, green: 0.95, blue: 0.90), Color(red: 0.70, green: 0.52, blue: 0.88),
        ]
        let pieces: [(x: CGFloat, y: CGFloat, angle: Double)] = [
            (16, 14, 30), (34, 10, -40), (50, 18, 70), (24, 28, -15), (42, 31, 45), (12, 40, 80),
            (30, 44, 20), (50, 44, -60), (20, 54, -35), (40, 56, 10), (56, 31, 5), (8, 24, -70),
        ]
        for (index, piece) in pieces.enumerated() {
            var local = context
            local.translateBy(x: piece.x, y: piece.y)
            local.rotate(by: .degrees(piece.angle))
            local.fill(Path(roundedRect: CGRect(x: -6, y: -2, width: 12, height: 4), cornerRadius: 2),
                       with: .color(colors[index % colors.count]))
        }
    }
}
