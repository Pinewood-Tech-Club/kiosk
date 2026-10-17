import Foundation
import RealityKit
import UIKit

extension Topping {
    /// Fudge, whip and drizzle change the surface everything above them rests on; scattered pieces don't.
    var isLayered: Bool { self == .fudge || self == .whip || drizzleStyle != nil }

    var drizzleStyle: DrizzleStyle? {
        switch self {
        case .chocolate: .chocolate
        case .caramel: .caramel
        default: nil
        }
    }

    var stackRank: Int {
        switch self {
        case .fudge: 0
        case .whip: 1
        case .chocolate, .caramel: 2
        case .gummies, .mms, .sprinkles: 3
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

/// The toppings on one item rig, always stacked scoops → fudge → whip → drizzle → scattered (in the order they were added),
/// each layer resting on the surface of everything beneath it. When a layer beneath others changes, the ones above are
/// handed their finished surface at once and move onto it over the change's duration, with the same easing, so the
/// whole stack moves as one.
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

    private struct Placed {
        let topping: Topping
        let layer: any ToppingLayer
        var beneath: [Topping]
        var scatteredBeneath: [Topping]
        var baseVersion: Int
    }

    static let scoopsAddedDuration = 0.45
    static let scoopsRemovedDuration = 0.5
    /// A scoop lifted off the top takes a moment to clear the toppings that sat on it before they sink.
    static let scoopsRemovedDelay = 0.25

    init(rig: ItemRig) {
        self.rig = rig
        root.name = "toppings"
        rig.body.addChild(root)
    }

    var shownToppings: [Topping] { placed.map(\.topping) }
    var isIdle: Bool {
        leaving.isEmpty && pendingCount == nil && !placed.contains { ($0.layer as? ScatterLayer)?.isSettling == true }
    }

    func isSettled(now: Double) -> Bool {
        isIdle && !placed.contains { ($0.layer as? DrizzleLayer)?.isPouring(now: now) == true }
    }

    /// Height of the topmost surface once every layer has settled, for framing and fitting the item into tray slots
    /// and order rows.
    var top: Float? {
        guard let settledTop, !placed.isEmpty else { return nil }
        let scattered = placed.compactMap { $0.layer as? ScatterLayer }
        let pieces = scattered.map(\.pieceHeight).max() ?? 0
        let resting = scattered.compactMap(\.restingTop).max() ?? -.infinity
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
        var detached = leaving
        for entry in placed {
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
        guard !leaving.isEmpty else { return }
        leaving.removeAll { layer in
            guard layer.isFinished else { return false }
            layer.entity.removeFromParent()
            return true
        }
    }

    private func reconcile(animated: Bool, now: Double, baseDuration: Double, launch: ((Topping) -> ToppingLaunch?)?) {
        let wanted = base == nil ? [] : Topping.stacked(toppings)
        let staying = placed.filter { wanted.contains($0.topping) }
        var changeDuration: Double = 0
        var scatterChangeDuration: Double = 0
        for entry in placed where !wanted.contains(entry.topping) {
            let tap = animated ? launch?(entry.topping) : nil
            entry.layer.launchPoint = tap?.point
            entry.layer.cardIcon = tap?.icon
            (entry.layer as? ScatterLayer)?.ceiling = tap?.ceiling
            (entry.layer as? ScatterLayer)?.home = tap?.icon
            (entry.layer as? WhipLayer)?.underToppings = animated && staying.contains { $0.topping.stackRank > entry.topping.stackRank }
            entry.layer.remove(now: now)
            leaving.append(entry.layer)
            if entry.topping.isLayered {
                changeDuration = max(changeDuration, entry.layer.removeDuration)
            } else {
                scatterChangeDuration = max(scatterChangeDuration, entry.layer.removeDuration)
            }
        }
        guard let base else {
            placed = []
            settledTop = nil
            return
        }
        var surface: any ToppingSurface = base
        var beneath: [Topping] = []
        var scatteredBeneath: [Topping] = []
        var scattered: [ScatterLayer] = []
        let crowd = wanted.filter { !$0.isLayered }.count
        let partnered = wanted.filter { $0.drizzleStyle != nil }.count > 1
        var result: [Placed] = []
        for topping in wanted {
            let layer: any ToppingLayer
            let scatter: ScatterLayer?
            if let existing = placed.first(where: { $0.topping == topping }) {
                layer = existing.layer
                scatter = layer as? ScatterLayer
                let baseChanged = existing.baseVersion != baseVersion
                let scatteredChanged = existing.scatteredBeneath != scatteredBeneath
                var partnerChanged = false
                if let drizzle = layer as? DrizzleLayer, drizzle.partnered != partnered {
                    drizzle.partnered = partnered
                    partnerChanged = true
                }
                if baseChanged || existing.beneath != beneath || scatteredChanged || partnerChanged {
                    scatter?.beneath = scattered
                    let duration = animated
                        ? max(changeDuration, baseChanged ? baseDuration : 0, scatteredChanged ? scatterChangeDuration : 0,
                              partnerChanged ? DrizzleLayer.liftDuration : 0) : 0
                    layer.resurface(to: surface, duration: duration, now: now)
                }
            } else {
                layer = ToppingFactory.layer(topping, candy: candy)
                scatter = layer as? ScatterLayer
                scatter?.beneath = scattered
                scatter?.crowd = crowd
                let underToppings = animated && staying.contains { $0.topping.stackRank > topping.stackRank }
                (layer as? WhipLayer)?.underToppings = underToppings
                if let drizzle = layer as? DrizzleLayer {
                    drizzle.underToppings = underToppings
                    drizzle.partnered = partnered
                }
                (layer as? FudgeLayer)?.underToppings = underToppings
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
                if animated, topping.isLayered {
                    changeDuration = max(changeDuration, (layer as? DrizzleLayer)?.coverDuration
                                         ?? (layer as? FudgeLayer)?.coverDuration ?? layer.growDuration)
                }
            }
            result.append(Placed(topping: topping, layer: layer, beneath: beneath, scatteredBeneath: scatteredBeneath,
                                 baseVersion: baseVersion))
            surface = layer.settledSurfaceAbove(surface)
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

/// Topping → layer, card icon and scattered piece kind.
@MainActor
enum ToppingFactory {
    static func layer(_ topping: Topping, candy: CandyLibrary?) -> any ToppingLayer {
        switch topping {
        case .whip: WhipLayer()
        case .fudge: FudgeLayer()
        case .chocolate, .caramel: DrizzleLayer(style: topping.drizzleStyle ?? .chocolate)
        case .gummies, .mms, .sprinkles: ScatterLayer(kind: scatterKind(topping, candy: candy))
        }
    }

    /// The placeholder pieces show only if the candy meshes failed to build.
    static func scatterKind(_ topping: Topping, candy: CandyLibrary?) -> any ScatterKind {
        candy?.kind(topping) ?? PlaceholderScatterKind(shape: topping == .gummies ? .gummy : topping == .mms ? .lentil : .sprinkle)
    }

    static func iconModel(_ topping: Topping, candy: CandyLibrary?) -> (model: Entity, pieces: [ModelEntity], jiggles: Bool) {
        switch topping {
        case .whip:
            return (WhipLayer.makeIconDollop(), [], false)
        case .fudge:
            return (FudgeIcon.make(), [], false)
        case .chocolate, .caramel:
            return (DrizzleLayer.makeIcon(style: topping.drizzleStyle ?? .chocolate), [], false)
        case .gummies, .mms, .sprinkles:
            var random = ToppingRandom(seed: ToppingSeed.layer(item: 0x5EED, topping: topping))
            let pile = scatterKind(topping, candy: candy).makeIconPile(rng: &random)
            return (pile, pile.children.compactMap { $0 as? ModelEntity }, topping == .gummies)
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
