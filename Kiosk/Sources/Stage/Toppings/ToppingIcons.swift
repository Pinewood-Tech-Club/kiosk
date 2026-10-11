import RealityKit
import SwiftUI

/// A topping card's live 3D icon: holder (card position, press, step visibility) → scaler (pop, squish) →
/// spinner (idle turn) → fitted model.
/// Layers that store `cardIcon` drive it: `takeOut()` as their pieces leave the card, `putBack(after:)` to refill it,
/// `react()` for a squish while an invisible dispenser works on the item. Otherwise the stack plays `playTap`.
@MainActor
final class ToppingCardIcon {
    let topping: Topping
    let holder = Entity()
    let scaler = Entity()
    let spinner = Entity()
    let jiggling: [Entity]
    private let jiggleRest: [Transform]
    var restOrientation = simd_quatf(angle: 0.5, axis: [1, 0, 0])
    var appear: Float = 1
    private(set) var clock: Double = 0
    private var outAt: Double?
    private var backAt: Double?
    private var reactAt: Double?

    static let popDuration = 0.18
    static let refillDuration = 0.36
    static let squishDuration = 0.55

    init(topping: Topping) {
        self.topping = topping
        let (model, jiggling) = ToppingFactory.iconModel(topping)
        self.jiggling = jiggling
        jiggleRest = jiggling.map(\.transform)
        holder.name = "topping-\(topping.rawValue)"
        holder.addChild(scaler)
        scaler.addChild(spinner)
        let bounds = model.visualBounds(relativeTo: nil)
        let fit = Entity()
        let extent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z, 1e-4)
        fit.scale = .init(repeating: 1 / extent)
        fit.position = -bounds.center / extent
        fit.addChild(model)
        spinner.addChild(fit)
    }

    func takeOut() {
        outAt = clock
        backAt = nil
    }

    func putBack(after delay: Double = 0) {
        if outAt == nil { outAt = clock - Self.popDuration }
        backAt = clock + delay
    }

    func react() { reactAt = clock }

    func reset() {
        outAt = nil
        backAt = nil
        reactAt = nil
    }

    func playTap(for topping: Topping, layer: any ToppingLayer) {
        if topping.isLayered {
            react()
        } else {
            takeOut()
            putBack(after: 0.55)
        }
    }

    func update(now: Double) {
        clock = now
        guard holder.isEnabled else { return }
        var size: Float = 1
        if let outAt {
            let t = Float((now - outAt) / Self.popDuration)
            size = t < 0.35 ? lerp(1, 1.12, Ease.outQuad(t / 0.35)) : max(0, lerp(1.12, 0, Ease.inQuad(Ease.clamp01((t - 0.35) / 0.65))))
            if let backAt, now >= backAt {
                let p = Ease.clamp01(Float((now - backAt) / Self.refillDuration))
                size = Self.outBack(p)
                if p >= 1 {
                    self.outAt = nil
                    self.backAt = nil
                }
            }
        }
        var squash: Float = 0
        if let reactAt {
            let t = Float((now - reactAt) / Self.squishDuration)
            if t >= 1 {
                self.reactAt = nil
            } else {
                squash = 0.22 * sin(t * 3 * .pi) * pow(1 - t, 1.6)
            }
        }
        let y = size * (1 - squash)
        let xz = size * (1 + squash * 0.5)
        scaler.scale = [max(xz, 1e-4), max(y, 1e-4), max(xz, 1e-4)]
        scaler.isEnabled = size > 0.001
        spinner.orientation = simd_quatf(angle: Float((now * 0.35).truncatingRemainder(dividingBy: 2 * .pi)), axis: [0, 1, 0])
        for (i, piece) in jiggling.enumerated() {
            let phase = Float(i) * 1.7
            let w = Float(now) * 5.2 + phase
            let s = 0.05 * sin(w)
            var t = jiggleRest[i]
            t.scale = jiggleRest[i].scale * SIMD3(1 - s * 0.5, 1 + s, 1 - s * 0.5)
            piece.transform = t
        }
    }

    private static func outBack(_ t: Float) -> Float {
        let c: Float = 1.6
        let u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }

    static func pile(_ kind: any ScatterKind, topping: Topping) -> (root: Entity, pieces: [Entity]) {
        var random = ToppingRandom(seed: 0x5EED_0000 &+ UInt64(topping.stackRank))
        let made = kind.makePieces(rng: &random)
        let count = min(made.count, topping == .sprinkles ? 36 : 7)
        let largest = made.prefix(count).map { max($0.halfExtents.x, $0.halfExtents.z) }.max() ?? 0.004
        let spread = largest * (topping == .sprinkles ? 3.2 : 2.3)
        let root = Entity()
        var pieces: [Entity] = []
        for i in 0..<count {
            let piece = made[i]
            let f = Float(i) / Float(max(count - 1, 1))
            let r = spread * sqrt(f)
            let angle = Float(i) * 2.39996
            let mound = largest * 1.6 * (1 - f)
            let model = ModelEntity(mesh: piece.mesh, materials: piece.materials)
            let tilt = simd_quatf(angle: Float.random(in: -0.5...0.5, using: &random), axis: simd_normalize(SIMD3(cos(angle), 0, sin(angle))))
            model.orientation = tilt * simd_quatf(angle: Float.random(in: 0..<(2 * .pi), using: &random), axis: [0, 1, 0])
            model.position = [cos(angle) * r, mound + piece.halfExtents.y, sin(angle) * r]
            root.addChild(model)
            pieces.append(model)
        }
        return (root, pieces)
    }
}

extension Stage {
    /// Where the topping cards' icons sit when the UI hasn't reported their frames: two groups along the cards row.
    static func defaultToppingIconFrame(_ topping: Topping) -> CGRect {
        let xs: [Topping: CGFloat] = [.whip: 150, .chocolate: 330, .gummies: 560, .mms: 740, .sprinkles: 920]
        let size: CGFloat = 104
        return CGRect(x: (xs[topping] ?? Layout.midX) - size / 2, y: Layout.cardsCenterY - 30 - size / 2, width: size, height: size)
    }

    /// The topping cards report their icon frames (screen points) here, like the order receipt's cells.
    func setToppingIconFrame(_ topping: Topping, _ frame: CGRect) {
        toppingIconFrames[topping] = frame
    }

    func toppingIconFrame(_ topping: Topping) -> CGRect {
        toppingIconFrames[topping] ?? Self.defaultToppingIconFrame(topping)
    }

    func makeToppingIcons() {
        for topping in Topping.allCases {
            let icon = ToppingCardIcon(topping: topping)
            applyLighting(icon.holder)
            toppingIcons[topping] = icon
            root.addChild(icon.holder)
        }
    }

    func toppingIconPlacement(_ topping: Topping) -> (position: SIMD3<Float>, scale: Float) {
        let frame = toppingIconFrame(topping)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let (position, press) = pressed(world(center), card: .topping(topping), center: center)
        return (position, Float(min(frame.width, frame.height)) * 0.001 * 0.82 * press)
    }

    func updateToppingIcons() {
        for (topping, icon) in toppingIcons {
            let shown = iconShown[.topping(topping)] ?? 0
            icon.holder.isEnabled = shown > 0.001
            icon.update(now: now)
            guard icon.holder.isEnabled else { continue }
            let placement = toppingIconPlacement(topping)
            icon.holder.position = placement.position
            icon.holder.orientation = icon.restOrientation
            icon.holder.scale = .init(repeating: max(placement.scale * shown * icon.appear, 1e-5))
        }
    }

    /// The card icon's position in `rig`'s body space, live.
    func toppingLaunch(_ topping: Topping, onto rig: ItemRig) -> ToppingLaunch {
        ToppingLaunch(point: { [weak self, weak rig] in
            guard let self, let rig else { return .zero }
            let world = self.toppingIconPlacement(topping).position
            let local = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * SIMD4<Float>(world, 1)
            return [local.x, local.y, local.z]
        }, icon: toppingIcons[topping])
    }
}
