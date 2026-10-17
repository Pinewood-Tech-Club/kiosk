import RealityKit
import SwiftUI

/// A topping card's live 3D icon: holder (card position, press, step visibility) → presence (hidden while pieces
/// return to it) → scaler (pop, squish) → spinner (idle turn) → fitted model.
/// Layers that store `cardIcon` drive it: `takeOut()` as their pieces leave the card, `putBack(after:)` to refill it,
/// `react()` for a squish while an invisible dispenser works on the item. Otherwise the stack plays `playTap`.
/// Candy taken off the item comes home the way a scoop flies back to its flavor card: the icon shrinks away as the
/// pieces leave (`beginReturn`), they land on the live poses of the icon's own pieces (`slotMatrices`), and
/// `completeReturn` swaps them for the icon in one frame.
@MainActor
final class ToppingCardIcon {
    let topping: Topping
    let holder = Entity()
    let presence = Entity()
    let scaler = Entity()
    let spinner = Entity()
    let slots: [ModelEntity]
    let slotLooks: [ScatterLook]
    private let jiggles: Bool
    private let slotRest: [Transform]
    private let slotModels: [ModelComponent?]
    /// The slots show pieces that came home rather than the icon's own; put back the next time the icon is out of sight.
    private var borrowed = false
    private var slotGrowth: [Int: Double] = [:]
    var restOrientation = simd_quatf(angle: 0.5, axis: [1, 0, 0])
    private(set) var appear: Float = 1
    private var appearMotion: (start: Double, from: Float, to: Float, duration: Double, curve: TimingCurve)?
    private weak var returner: AnyObject?
    private var returnAlive: (() -> Bool)?
    private(set) var clock: Double = 0
    private var outAt: Double?
    private var backAt: Double?
    private var reactAt: Double?

    static let popDuration = 0.18
    static let refillDuration = 0.36
    static let squishDuration = 0.55
    static let hideDuration = 0.2
    static let showDuration = 0.26
    static let slotGrowDuration = 0.22

    init(topping: Topping, candy: CandyLibrary?) {
        self.topping = topping
        let (model, slots, jiggles) = ToppingFactory.iconModel(topping, candy: candy)
        self.slots = slots
        self.jiggles = jiggles
        slotLooks = slots.map { $0.components[ScatterLookComponent.self]?.look ?? ScatterLook() }
        slotRest = slots.map(\.transform)
        slotModels = slots.map(\.model)
        holder.name = "topping-\(topping.rawValue)"
        holder.addChild(presence)
        presence.addChild(scaler)
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
        returner = nil
        returnAlive = nil
        appearMotion = nil
        appear = 1
        slotGrowth = [:]
        if borrowed { restoreSlotModels() }
        applyPresence()
        poseSlots(force: true)
    }

    func playTap(for topping: Topping, layer: any ToppingLayer) {
        if topping.isLayered {
            react()
        } else {
            takeOut()
            putBack(after: 0.55)
        }
    }

    /// `owner`'s pieces are on their way back, so the icon shrinks away until they land. A later return takes over.
    func beginReturn(_ owner: AnyObject, alive: @escaping () -> Bool) {
        returner = owner
        returnAlive = alive
        animateAppear(to: 0, duration: Self.hideDuration, curve: .swiftUIEaseIn)
    }

    func isReturning(_ owner: AnyObject) -> Bool { returner === owner }

    /// Each slot's world transform as the icon shows it, leaving out only the hiding in `presence`.
    func slotMatrices() -> [simd_float4x4] {
        guard let parent = slots.first?.parent else { return [] }
        var above = matrix_identity_float4x4
        var entity: Entity? = parent
        while let current = entity, current !== presence {
            above = current.transform.matrix * above
            entity = current.parent
        }
        let base = holder.transformMatrix(relativeTo: nil) * above
        return slots.map { base * $0.transform.matrix }
    }

    /// The returning pieces have landed: each slot takes on the model of the piece resting in it, slots nothing
    /// landed in grow back, and the icon shows again in the same frame.
    func completeReturn(_ owner: AnyObject, models: [Int: ModelComponent]) {
        guard returner === owner else { return }
        returner = nil
        returnAlive = nil
        for index in slots.indices {
            if let model = models[index] {
                slots[index].model = model
                borrowed = true
            } else {
                slotGrowth[index] = clock
            }
        }
        appearMotion = nil
        appear = 1
        applyPresence()
        poseSlots(force: true)
    }

    func update(now: Double) {
        clock = now
        if returner == nil || returnAlive?() != true {
            returner = nil
            returnAlive = nil
            if appear < 1 || appearMotion != nil {
                animateAppear(to: 1, duration: Self.showDuration, curve: .swiftUIEaseOut)
            }
        }
        if let motion = appearMotion {
            let t = motion.duration > 0 ? Float((now - motion.start) / motion.duration) : 1
            appear = lerp(motion.from, motion.to, motion.curve(Ease.clamp01(t)))
            if t >= 1 { appearMotion = nil }
        }
        applyPresence()
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
        if borrowed, !scaler.isEnabled || !presence.isEnabled { restoreSlotModels() }
        spinner.orientation = simd_quatf(angle: Float((now * 0.35).truncatingRemainder(dividingBy: 2 * .pi)), axis: [0, 1, 0])
        poseSlots()
    }

    private func animateAppear(to target: Float, duration: Double, curve: TimingCurve) {
        if let motion = appearMotion {
            if motion.to == target { return }
        } else if appear == target {
            return
        }
        appearMotion = (clock, appear, target, duration, curve)
    }

    private func restoreSlotModels() {
        for (slot, model) in zip(slots, slotModels) { slot.model = model }
        borrowed = false
    }

    private func applyPresence() {
        presence.scale = .init(repeating: max(appear, 1e-5))
        presence.isEnabled = appear > 0.001
    }

    private func poseSlots(force: Bool = false) {
        guard force || jiggles || !slotGrowth.isEmpty else { return }
        for index in slots.indices {
            var transform = slotRest[index]
            if jiggles {
                let s = 0.05 * sin(Float(clock) * 5.2 + Float(index) * 1.7)
                transform.scale *= SIMD3(1 - s * 0.5, 1 + s, 1 - s * 0.5)
            }
            if let grownAt = slotGrowth[index] {
                let t = Ease.clamp01(Float((clock - grownAt) / Self.slotGrowDuration))
                transform.scale *= max(TimingCurve.swiftUIEaseOut(t), 1e-4)
                if t >= 1 { slotGrowth[index] = nil }
            }
            slots[index].transform = transform
        }
    }

    private static func outBack(_ t: Float) -> Float {
        let c: Float = 1.6
        let u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}

extension Stage {
    func reportToppingScroll(_ offset: CGFloat) {
        toppingScrollReported = offset
    }

    func latchToppingScroll() {
        toppingScroll.update(toppingScrollReported)
    }

    func toppingCardFrame(_ topping: Topping) -> CGRect {
        Layout.toppingCardFrame(topping).offsetBy(dx: -toppingScroll.offset, dy: 0)
    }

    func makeToppingIcons() {
        for topping in Topping.allCases {
            let icon = ToppingCardIcon(topping: topping, candy: assets?.candy)
            if topping.drizzleStyle != nil { icon.restOrientation = simd_quatf(angle: 0.85, axis: [1, 0, 0]) }
            applyLighting(icon.holder)
            toppingIcons[topping] = icon
            root.addChild(icon.holder)
        }
    }

    func toppingIconPlacement(_ topping: Topping) -> (position: SIMD3<Float>, scale: Float) {
        let card = toppingCardFrame(topping)
        let icon = Layout.toppingIconFrame(inCard: card)
        let (position, press) = pressed(world(CGPoint(x: icon.midX, y: icon.midY)), card: .topping(topping),
                                        center: CGPoint(x: card.midX, y: card.midY))
        return (position, Float(min(icon.width, icon.height)) * 0.001 * 0.82 * press)
    }

    /// Placed even while hidden, so candy flying home to a card scrolled out of view still lands where it is.
    func updateToppingIcons() {
        for (topping, icon) in toppingIcons {
            let shown = iconShown[.topping(topping)] ?? 0
            let card = toppingCardFrame(topping)
            icon.holder.isEnabled = shown > 0.001 && card.maxX > viewFrame.minX && card.minX < viewFrame.maxX
            icon.update(now: now)
            let placement = toppingIconPlacement(topping)
            icon.holder.position = placement.position
            icon.holder.orientation = icon.restOrientation
            icon.holder.scale = .init(repeating: max(placement.scale * shown, 1e-5))
        }
    }

    /// The card icon's position in `rig`'s body space, live.
    func toppingLaunch(_ topping: Topping, onto rig: ItemRig) -> ToppingLaunch {
        if staging.offscreenCards {
            return ToppingLaunch(point: { [weak self, weak rig] in
                guard let self, let rig else { return .zero }
                let local = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * SIMD4<Float>(self.toppingPort(topping), 1)
                return [local.x, local.y, local.z]
            }, icon: nil)
        }
        return ToppingLaunch(point: { [weak self, weak rig] in
            guard let self, let rig else { return .zero }
            let world = self.toppingIconPlacement(topping).position
            let local = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * SIMD4<Float>(world, 1)
            return [local.x, local.y, local.z]
        }, icon: toppingIcons[topping], ceiling: { [weak self, weak rig] in
            guard let self, let rig else { return .infinity }
            let body = rig.body.transformMatrix(relativeTo: nil)
            var line = body.columns.3
            line.y = self.world(CGPoint(x: 0, y: Self.flightCeilingY), z: line.z).y
            return (simd_inverse(body) * line).y
        })
    }
}
