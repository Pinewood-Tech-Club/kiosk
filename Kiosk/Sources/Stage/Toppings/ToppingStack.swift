import Foundation
import RealityKit
import UIKit

extension Topping {
    /// Whip and drizzle change the surface everything above them rests on; scattered pieces don't.
    var isLayered: Bool { self == .whip || drizzleStyle != nil }

    var drizzleStyle: DrizzleStyle? {
        switch self {
        case .chocolate: .chocolate
        case .caramel: .caramel
        default: nil
        }
    }

    var stackRank: Int {
        switch self {
        case .whip: 0
        case .chocolate, .caramel: 1
        case .gummies, .mms, .sprinkles: 2
        }
    }

    static func stacked(_ toppings: [Topping]) -> [Topping] {
        var unique: [Topping] = []
        for topping in toppings where !unique.contains(topping) { unique.append(topping) }
        return unique.enumerated().sorted { ($0.element.stackRank, $0.offset) < ($1.element.stackRank, $1.offset) }.map(\.element)
    }
}

struct ToppingLaunch {
    let point: () -> SIMD3<Float>
    let icon: ToppingCardIcon?
    /// Height in the rig's body space that tossed pieces stay under: the bottom of the step's title.
    var ceiling: (() -> Float)?
}

enum ToppingSeed {
    static func item(_ id: UUID) -> UInt64 {
        let u = id.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    /// Stable across launches (unlike `hashValue`), so a rebuilt item looks the same.
    static func layer(item: UInt64, topping: Topping) -> UInt64 {
        var hash = item
        for byte in topping.rawValue.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        var random = ToppingRandom(seed: hash)
        return random.next()
    }
}

/// The toppings on one item rig, always stacked scoops → whip → drizzle → scattered (in the order they were added),
/// each layer resting on the surface of everything beneath it.
@MainActor
final class ToppingStack {
    let root = Entity()
    weak var rig: ItemRig?
    var light: (Entity) -> Void = { _ in }
    var candy: CandyLibrary?
    private(set) var toppings: [Topping] = []
    private(set) var itemSeed: UInt64 = 0
    private(set) var base: (any ToppingSurface)?
    private(set) var scoopCount = 0
    var framedTop: Float?
    private var baseVersion = 0
    private var placed: [Placed] = []
    private var leaving: [any ToppingLayer] = []
    private var pendingCount: (count: Int, at: Double)?
    private var settledTop: (any ToppingSurface)?
    private var ride: Ride?

    private struct Placed {
        let topping: Topping
        let layer: any ToppingLayer
        var beneath: [Topping]
        var scatteredBeneath: [Topping]
        var baseVersion: Int
        /// The surface under the drizzle (the whip's, or the scoops') this layer was last fitted to.
        var fittedOn: any ToppingSurface
    }

    /// The whip growing or deflating under other layers: they follow its live surface every frame, then settle
    /// onto the finished surface once it's done.
    private struct Ride {
        let whip: any ToppingLayer
        let below: any ToppingSurface
        let target: any ToppingSurface
        let start: Double
        let duration: Double
        let removing: Bool

        func progress(_ now: Double) -> Float { duration > 0 ? Ease.clamp01(Float((now - start) / duration)) : 1 }

        /// The deflating whip fades out before it's flat, so the layers above ease onto what's under it instead.
        @MainActor func surface(now: Double) -> any ToppingSurface {
            let p = progress(now)
            guard p < 1 else { return target }
            let live = whip.surfaceAbove(below)
            let handover = removing ? Ride.smoothstep(0.55, 1, p) : Ride.smoothstep(0.85, 1, p)
            return handover > 0 ? MixedSurface(a: live, b: target, t: handover) : live
        }

        private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = Ease.clamp01((x - a) / (b - a))
            return t * t * (3 - 2 * t)
        }
    }

    static let scoopsAddedDuration = 0.45
    static let scoopsRemovedDuration = 0.5
    /// A scoop lifted off the top takes a moment to clear the toppings that sat on it before they sink.
    static let scoopsRemovedDelay = 0.25
    static let rideSettleDuration = 0.3

    init(rig: ItemRig) {
        self.rig = rig
        root.name = "toppings"
        rig.body.addChild(root)
    }

    var shownToppings: [Topping] { placed.map(\.topping) }
    var isIdle: Bool { leaving.isEmpty && pendingCount == nil && ride == nil }

    /// Height of the topmost surface once every layer has settled, for framing and fitting the item into tray slots
    /// and order rows.
    var top: Float? {
        guard let settledTop, !placed.isEmpty else { return nil }
        let scattered = placed.compactMap { $0.layer as? ScatterLayer }
        let pieces = scattered.map(\.pieceHeight).max() ?? 0
        let resting = ride == nil ? scattered.compactMap(\.restingTop).max() ?? -.infinity : -.infinity
        return max(settledTop.apex.y + pieces, resting)
    }

    func setSeed(_ seed: UInt64) { itemSeed = seed }

    func setToppings(_ toppings: [Topping], animated: Bool, now: Double, launch: ((Topping) -> ToppingLaunch?)? = nil) {
        self.toppings = toppings
        reconcile(animated: animated, now: now, baseDuration: 0, launch: launch)
    }

    /// Takes over another stack's toppings without showing them until this rig's scoops settle.
    func adopt(_ other: ToppingStack) {
        toppings = other.toppings
        itemSeed = other.itemSeed
    }

    func setScoops(_ count: Int, surface: (any ToppingSurface)?, animated: Bool, now: Double) {
        pendingCount = nil
        guard count != scoopCount || (surface == nil) != (base == nil) else { return }
        endRide(now: now, settle: false)
        let grew = count > scoopCount
        scoopCount = count
        base = count > 0 ? surface : nil
        baseVersion += 1
        reconcile(animated: animated, now: now,
                  baseDuration: grew ? Self.scoopsAddedDuration : Self.scoopsRemovedDuration, launch: nil)
    }

    /// Follows the rig's settled scoop count, waiting a beat when the top scoop has just been lifted away.
    func follow(scoops count: Int, surface: () -> ScoopSurface?, now: Double) {
        if count == scoopCount {
            pendingCount = nil
            return
        }
        if pendingCount?.count != count {
            let delay = count < scoopCount && count > 0 ? Self.scoopsRemovedDelay : 0
            pendingCount = (count, now + delay)
        }
        if let pending = pendingCount, now >= pending.at {
            setScoops(count, surface: surface(), animated: true, now: now)
        }
    }

    /// Hands every shown layer to `container` (already placed at this stack's world transform) to finish removing there.
    func detachLayers(into container: Entity, now: Double) -> [any ToppingLayer] {
        ride = nil
        var detached = leaving
        for entry in placed {
            (entry.layer as? ScatterLayer)?.heave = nil
            entry.layer.launchPoint = nil
            entry.layer.remove(now: now)
            detached.append(entry.layer)
        }
        for layer in detached {
            let matrix = layer.entity.transformMatrix(relativeTo: root)
            container.addChild(layer.entity)
            layer.entity.transform = Transform(matrix: matrix)
        }
        placed = []
        leaving = []
        toppings = []
        settledTop = nil
        return detached
    }

    func update(now: Double) {
        for entry in placed { entry.layer.update(now: now) }
        for layer in leaving { layer.update(now: now) }
        if let ride { steer(ride, now: now) }
        guard !leaving.isEmpty else { return }
        leaving.removeAll { layer in
            guard layer.isFinished else { return false }
            layer.entity.removeFromParent()
            return true
        }
    }

    private func steer(_ ride: Ride, now: Double) {
        guard ride.progress(now) < 1 else {
            endRide(now: now)
            return
        }
        let riders = placed.filter { $0.topping != .whip }
        guard !riders.isEmpty else { return }
        let live = ride.surface(now: now)
        var drape: any ToppingSurface = live
        var drizzled: (any ToppingLayer)?
        for entry in riders {
            if let scatter = entry.layer as? ScatterLayer {
                scatter.heave = live.sampleDelta(against: entry.fittedOn)
            } else {
                if let drizzled { drape = drizzled.surfaceAbove(drape) }
                entry.layer.resurface(to: drape, duration: 0, now: now)
                drizzled = entry.layer
            }
        }
    }

    /// Leaves every layer that rode the whip where it is shown and, with `settle`, settles it onto the finished surfaces.
    private func endRide(now: Double, settle: Bool = true) {
        guard let ride else { return }
        self.ride = nil
        guard settle else {
            let live = ride.surface(now: now)
            for entry in placed {
                guard let scatter = entry.layer as? ScatterLayer else { continue }
                scatter.heave = live.sampleDelta(against: entry.fittedOn)
                scatter.bakeHeave()
            }
            return
        }
        guard let base else { return }
        var surface: any ToppingSurface = base
        var underDrizzle: any ToppingSurface = base
        for index in placed.indices {
            let entry = placed[index]
            if entry.topping == .whip {
                surface = entry.layer.settledSurfaceAbove(surface)
                underDrizzle = surface
                continue
            }
            if let scatter = entry.layer as? ScatterLayer {
                scatter.heave = ride.surface(now: now).sampleDelta(against: entry.fittedOn)
                scatter.bakeHeave()
                scatter.resurface(to: surface, duration: Self.rideSettleDuration, now: now)
            } else {
                entry.layer.resurface(to: surface, duration: 0, now: now)
            }
            placed[index].fittedOn = underDrizzle
            surface = entry.layer.settledSurfaceAbove(surface)
        }
    }

    private func reconcile(animated: Bool, now: Double, baseDuration: Double, launch: ((Topping) -> ToppingLaunch?)?) {
        let wanted = base == nil ? [] : Topping.stacked(toppings)
        var changeDuration: Double = 0
        var scatterChangeDuration: Double = 0
        for entry in placed where !wanted.contains(entry.topping) {
            let tap = animated ? launch?(entry.topping) : nil
            entry.layer.launchPoint = tap?.point
            (entry.layer as? ScatterLayer)?.ceiling = tap?.ceiling
            (entry.layer as? ScatterLayer)?.heave = nil
            entry.layer.remove(now: now)
            leaving.append(entry.layer)
            if entry.topping == .whip, animated, let base {
                ride = Ride(whip: entry.layer, below: base, target: base, start: now, duration: entry.layer.removeDuration,
                            removing: true)
            } else if entry.topping.isLayered {
                changeDuration = max(changeDuration, entry.layer.removeDuration)
            } else {
                scatterChangeDuration = max(scatterChangeDuration, entry.layer.removeDuration)
            }
        }
        guard let base else {
            placed = []
            settledTop = nil
            ride = nil
            return
        }
        var surface: any ToppingSurface = base
        var underDrizzle: any ToppingSurface = base
        var beneath: [Topping] = []
        var scatteredBeneath: [Topping] = []
        var scattered: [ScatterLayer] = []
        let crowd = wanted.filter { !$0.isLayered }.count
        var result: [Placed] = []
        for topping in wanted {
            let layer: any ToppingLayer
            let scatter: ScatterLayer?
            var fittedOn = underDrizzle
            if let existing = placed.first(where: { $0.topping == topping }) {
                layer = existing.layer
                scatter = layer as? ScatterLayer
                fittedOn = existing.fittedOn
                let baseChanged = existing.baseVersion != baseVersion
                let scatteredChanged = existing.scatteredBeneath != scatteredBeneath
                let riding = ride != nil && topping != .whip
                if riding, !baseChanged, !scatteredChanged {
                    scatter?.beneath = scattered
                } else if baseChanged || existing.beneath != beneath || scatteredChanged {
                    scatter?.beneath = scattered
                    let duration = animated
                        ? max(changeDuration, baseChanged ? baseDuration : 0, scatteredChanged ? scatterChangeDuration : 0) : 0
                    scatter?.bakeHeave()
                    layer.resurface(to: surface, duration: duration, now: now)
                    fittedOn = underDrizzle
                }
            } else {
                layer = ToppingFactory.layer(topping, candy: candy)
                scatter = layer as? ScatterLayer
                scatter?.beneath = scattered
                scatter?.crowd = crowd
                let tap = animated ? launch?(topping) : nil
                if let tap {
                    layer.launchPoint = tap.point
                    scatter?.ceiling = tap.ceiling
                    layer.cardIcon = tap.icon
                }
                root.addChild(layer.entity)
                layer.apply(onto: surface, seed: ToppingSeed.layer(item: itemSeed, topping: topping), animated: animated, now: now)
                light(layer.entity)
                if let icon = tap?.icon, layer.cardIcon == nil { icon.playTap(for: topping, layer: layer) }
                if animated, topping == .whip {
                    ride = Ride(whip: layer, below: surface, target: layer.settledSurfaceAbove(surface), start: now,
                                duration: layer.growDuration, removing: false)
                } else if animated, topping.isLayered {
                    changeDuration = max(changeDuration, layer.growDuration)
                }
            }
            result.append(Placed(topping: topping, layer: layer, beneath: beneath, scatteredBeneath: scatteredBeneath,
                                 baseVersion: baseVersion, fittedOn: fittedOn))
            surface = layer.settledSurfaceAbove(surface)
            if topping == .whip { underDrizzle = surface }
            if topping.isLayered { beneath.append(topping) }
            if let scatter {
                scatteredBeneath.append(topping)
                scattered.append(scatter)
            }
        }
        placed = result
        settledTop = surface
    }
}

struct MixedSurface: ToppingSurface {
    let a: any ToppingSurface
    let b: any ToppingSurface
    let t: Float

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let sa = a.sample(x: x, z: z), sb = b.sample(x: x, z: z)
        guard let sa else { return sb }
        guard let sb else { return sa }
        return (lerp(sa.height, sb.height, t), simd_normalize(simd_mix(sa.normal, sb.normal, SIMD3(repeating: t))))
    }

    var apex: SIMD3<Float> { simd_mix(a.apex, b.apex, SIMD3(repeating: t)) }
    var radius: Float { lerp(a.radius, b.radius, t) }
    var floor: Float { lerp(a.floor, b.floor, t) }
    func softness(x: Float, z: Float) -> Float { max(a.softness(x: x, z: z), b.softness(x: x, z: z)) }
}

extension ToppingSurface {
    func sampleDelta(against other: any ToppingSurface) -> (Float, Float) -> Float {
        { x, z in
            guard let now = sample(x: x, z: z)?.height, let then = other.sample(x: x, z: z)?.height else { return 0 }
            return now - then
        }
    }
}

/// Topping → layer, card icon and scattered piece kind.
@MainActor
enum ToppingFactory {
    static func layer(_ topping: Topping, candy: CandyLibrary?) -> any ToppingLayer {
        switch topping {
        case .whip: WhipLayer()
        case .chocolate, .caramel: DrizzleLayer(style: topping.drizzleStyle ?? .chocolate)
        case .gummies, .mms, .sprinkles: ScatterLayer(kind: scatterKind(topping, candy: candy))
        }
    }

    /// The placeholder pieces show only if the candy meshes failed to build.
    static func scatterKind(_ topping: Topping, candy: CandyLibrary?) -> any ScatterKind {
        candy?.kind(topping) ?? PlaceholderScatterKind(shape: topping == .gummies ? .gummy : topping == .mms ? .lentil : .sprinkle)
    }

    static func iconModel(_ topping: Topping, candy: CandyLibrary?) -> (model: Entity, jiggling: [Entity]) {
        switch topping {
        case .whip:
            return (WhipLayer.makeIconDollop(), [])
        case .chocolate, .caramel:
            return (DrizzleLayer.makeIcon(style: topping.drizzleStyle ?? .chocolate), [])
        case .gummies, .mms, .sprinkles:
            var random = ToppingRandom(seed: ToppingSeed.layer(item: 0x5EED, topping: topping))
            let pile = scatterKind(topping, candy: candy).makeIconPile(rng: &random)
            return (pile, topping == .gummies ? Array(pile.children) : [])
        }
    }
}

struct FlatSurface: ToppingSurface {
    var height: Float = 0
    var radius: Float

    var apex: SIMD3<Float> { [0, height, 0] }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        x * x + z * z <= radius * radius * 2.25 ? (height, [0, 1, 0]) : nil
    }
}
