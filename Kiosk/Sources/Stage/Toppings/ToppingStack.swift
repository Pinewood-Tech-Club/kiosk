import Foundation
import RealityKit
import UIKit

extension Topping {
    /// Whip and drizzle change the surface everything above them rests on; scattered pieces don't.
    var isLayered: Bool { self == .whip || self == .chocolate }

    var stackRank: Int {
        switch self {
        case .whip: 0
        case .chocolate: 1
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
    var isIdle: Bool { leaving.isEmpty && pendingCount == nil }

    /// Height of the topmost surface, for fitting the item into tray slots and order rows.
    var top: Float? {
        guard var surface: ToppingSurface = base, !placed.isEmpty else { return nil }
        for entry in placed { surface = entry.layer.surfaceAbove(surface) }
        let scattered = placed.compactMap { $0.layer as? ScatterLayer }
        let pieces = scattered.map(\.pieceHeight).max() ?? 0
        return max(surface.apex.y + pieces, scattered.compactMap(\.restingTop).max() ?? -.infinity)
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
        return detached
    }

    func update(now: Double) {
        for entry in placed { entry.layer.update(now: now) }
        guard !leaving.isEmpty else { return }
        for layer in leaving { layer.update(now: now) }
        leaving.removeAll { layer in
            guard layer.isFinished else { return false }
            layer.entity.removeFromParent()
            return true
        }
    }

    private func reconcile(animated: Bool, now: Double, baseDuration: Double, launch: ((Topping) -> ToppingLaunch?)?) {
        let wanted = base == nil ? [] : Topping.stacked(toppings)
        var changeDuration: Double = 0
        var scatterChangeDuration: Double = 0
        for entry in placed where !wanted.contains(entry.topping) {
            entry.layer.launchPoint = animated ? launch?(entry.topping)?.point : nil
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
            return
        }
        var surface: ToppingSurface = base
        var beneath: [Topping] = []
        var scatteredBeneath: [Topping] = []
        var scattered: [ScatterLayer] = []
        let crowd = wanted.filter { !$0.isLayered }.count
        var result: [Placed] = []
        for topping in wanted {
            let layer: any ToppingLayer
            let scatter: ScatterLayer?
            if let existing = placed.first(where: { $0.topping == topping }) {
                layer = existing.layer
                scatter = layer as? ScatterLayer
                let baseChanged = existing.baseVersion != baseVersion
                let scatteredChanged = existing.scatteredBeneath != scatteredBeneath
                if baseChanged || existing.beneath != beneath || scatteredChanged {
                    scatter?.occupied = scattered.flatMap(\.footprints)
                    let duration = animated
                        ? max(changeDuration, baseChanged ? baseDuration : 0, scatteredChanged ? scatterChangeDuration : 0) : 0
                    layer.resurface(to: surface, duration: duration, now: now)
                }
            } else {
                layer = ToppingFactory.layer(topping, candy: candy)
                scatter = layer as? ScatterLayer
                scatter?.occupied = scattered.flatMap(\.footprints)
                scatter?.crowd = crowd
                let tap = animated ? launch?(topping) : nil
                if let tap {
                    layer.launchPoint = tap.point
                    layer.cardIcon = tap.icon
                }
                root.addChild(layer.entity)
                layer.apply(onto: surface, seed: ToppingSeed.layer(item: itemSeed, topping: topping), animated: animated, now: now)
                light(layer.entity)
                if let icon = tap?.icon, layer.cardIcon == nil { icon.playTap(for: topping, layer: layer) }
                if animated, topping.isLayered { changeDuration = max(changeDuration, layer.growDuration) }
            }
            result.append(Placed(topping: topping, layer: layer, beneath: beneath, scatteredBeneath: scatteredBeneath,
                                 baseVersion: baseVersion))
            surface = layer.surfaceAbove(surface)
            if topping.isLayered { beneath.append(topping) }
            if let scatter {
                scatteredBeneath.append(topping)
                scattered.append(scatter)
            }
        }
        placed = result
    }
}

/// Topping → layer, card icon and scattered piece kind. Whip and drizzle are placeholders until their real layers land;
/// swapping them in only changes these functions.
@MainActor
enum ToppingFactory {
    static func layer(_ topping: Topping, candy: CandyLibrary?) -> any ToppingLayer {
        switch topping {
        case .whip: PlaceholderShellLayer(style: .whip)
        case .chocolate: PlaceholderShellLayer(style: .drizzle)
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
            return (PlaceholderShellLayer.iconModel(.whip), [])
        case .chocolate:
            return (PlaceholderShellLayer.iconModel(.drizzle), [])
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

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = Ease.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

/// A shell lying on the surface beneath, thick in the middle and thinning to nothing at its edge.
struct ShellProfile {
    enum Style { case whip, drizzle }

    var style: Style
    var center: SIMD2<Float>
    var radius: Float
    var phase: Float

    init(style: Style, below: ToppingSurface, phase: Float) {
        self.style = style
        self.center = SIMD2(below.apex.x, below.apex.z)
        self.radius = below.radius * (style == .whip ? 0.92 : 0.95)
        self.phase = phase
    }

    func edge(_ angle: Float) -> Float {
        switch style {
        case .whip: radius * (1 + 0.04 * sin(6 * angle + phase))
        case .drizzle: radius * (0.74 + 0.14 * sin(5 * angle + phase) + 0.12 * sin(11 * angle + 2 * phase))
        }
    }

    func thickness(_ x: Float, _ z: Float) -> Float {
        let offset = SIMD2(x, z) - center
        let angle = atan2(offset.y, offset.x)
        let d = simd_length(offset) / edge(angle)
        guard d < 1 else { return 0 }
        switch style {
        case .whip:
            let body = min(radius * 0.75, 0.017) * pow(1 - d * d, 0.6)
            let peak = min(radius * 0.45, 0.011) * pow(max(0, 1 - d / 0.38), 2)
            return (body + peak) * (1 + 0.1 * d * sin(7 * angle + 14 * d + phase))
        case .drizzle:
            return 0.0018 * (1 - pow(d, 6))
        }
    }
}

struct ShellSurface: ToppingSurface {
    let below: ToppingSurface
    let profile: ShellProfile

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        guard let s = below.sample(x: x, z: z) else { return nil }
        let t = profile.thickness(x, z)
        guard t > 0 else { return s }
        let e: Float = 0.0006
        let dx = (profile.thickness(x + e, z) - profile.thickness(x - e, z)) / (2 * e)
        let dz = (profile.thickness(x, z + e) - profile.thickness(x, z - e)) / (2 * e)
        let n = s.normal / max(s.normal.y, 0.2) - SIMD3(dx, 0, dz)
        return (s.height + t, simd_normalize(n))
    }

    var apex: SIMD3<Float> {
        let c = profile.center
        let h = (below.sample(x: c.x, z: c.y)?.height ?? below.apex.y) + profile.thickness(c.x, c.y)
        return [c.x, max(h, below.apex.y), c.y]
    }

    var radius: Float { profile.style == .whip ? profile.radius * 0.62 : below.radius }
    var floor: Float { below.floor }
}

/// Stand-in for the whip and drizzle layers: a conforming shell that grows out from the apex.
@MainActor
final class PlaceholderShellLayer: ToppingLayer {
    typealias Style = ShellProfile.Style

    static let rings = 14
    static let segments = 40

    let entity = Entity()
    let style: Style
    var launchPoint: (() -> SIMD3<Float>)?
    private let model: ModelEntity
    private var phase: Float = 0
    private var bases: [SIMD3<Float>] = []
    private var thicknesses: [Float] = []
    private var fromBases: [SIMD3<Float>] = []
    private var fromThicknesses: [Float] = []
    private var growth: Float = 0
    private var growthFrom: Float = 0
    private var growthTo: Float = 0
    private var growthStart: Double = 0
    private var growthDuration: Double = 0
    private var shapeStart: Double = 0
    private var shapeDuration: Double = 0
    private var dirty = true
    private var removing = false
    private(set) var isFinished = false

    var growDuration: Double { style == .whip ? 0.8 : 0.7 }
    var removeDuration: Double { 0.4 }

    init(style: Style) {
        self.style = style
        var material = PhysicallyBasedMaterial()
        switch style {
        case .whip:
            material.baseColor = .init(tint: UIColor(red: 0.98, green: 0.96, blue: 0.9, alpha: 1))
            material.roughness = .init(floatLiteral: 0.6)
        case .drizzle:
            material.baseColor = .init(tint: UIColor(red: 0.24, green: 0.11, blue: 0.05, alpha: 1))
            material.roughness = .init(floatLiteral: 0.18)
            material.specular = .init(floatLiteral: 0.8)
        }
        material.faceCulling = .none
        model = ModelEntity(mesh: .generateBox(size: 0.001), materials: [material])
        entity.name = style == .whip ? "placeholder-whip" : "placeholder-drizzle"
        entity.addChild(model)
    }

    static func iconModel(_ style: Style) -> Entity {
        let layer = PlaceholderShellLayer(style: style)
        layer.apply(onto: FlatSurface(radius: style == .whip ? 0.016 : 0.022), seed: 7, animated: false, now: 0)
        let root = Entity()
        root.addChild(layer.entity)
        return root
    }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        var random = ToppingRandom(seed: seed)
        phase = Float.random(in: 0..<(2 * .pi), using: &random)
        let target = shape(on: surface)
        bases = target.bases
        thicknesses = target.thicknesses
        fromBases = bases
        fromThicknesses = thicknesses
        shapeDuration = 0
        growth = animated ? 0 : 1
        animateGrowth(to: 1, duration: animated ? growDuration : 0, now: now)
        rebuild()
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        let target = shape(on: surface)
        fromBases = currentBases(now: now)
        fromThicknesses = currentThicknesses(now: now)
        bases = target.bases
        thicknesses = target.thicknesses
        shapeStart = now
        shapeDuration = duration
        dirty = true
        if duration <= 0 { rebuild(now: now) }
    }

    func remove(now: Double) {
        removing = true
        animateGrowth(to: 0, duration: removeDuration, now: now)
    }

    func update(now: Double) {
        guard !isFinished, dirty else { return }
        let p = growthDuration > 0 ? Ease.clamp01(Float((now - growthStart) / growthDuration)) : 1
        growth = lerp(growthFrom, growthTo, growthTo > growthFrom ? Ease.outCubic(p) : Ease.inOutSine(p))
        rebuild(now: now)
        let settled = p >= 1 && (shapeDuration <= 0 || now >= shapeStart + shapeDuration)
        dirty = !settled
        if settled, removing {
            isFinished = true
            entity.isEnabled = false
        }
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface {
        ShellSurface(below: below, profile: ShellProfile(style: style, below: below, phase: phase))
    }

    private func animateGrowth(to target: Float, duration: Double, now: Double) {
        growthFrom = growth
        growthTo = target
        growthStart = now
        growthDuration = duration
        if duration <= 0 { growth = target }
        dirty = true
    }

    private func shape(on surface: ToppingSurface) -> (bases: [SIMD3<Float>], thicknesses: [Float]) {
        let profile = ShellProfile(style: style, below: surface, phase: phase)
        var bases: [SIMD3<Float>] = []
        var thicknesses: [Float] = []
        let center = profile.center
        let top = surface.sample(x: center.x, z: center.y)?.height ?? surface.apex.y
        bases.append([center.x, top, center.y])
        thicknesses.append(profile.thickness(center.x, center.y))
        for segment in 0..<Self.segments {
            let angle = Float(segment) / Float(Self.segments) * 2 * .pi
            let edge = profile.edge(angle)
            var last = top
            for ring in 1...Self.rings {
                let r = edge * Float(ring) / Float(Self.rings)
                let x = center.x + cos(angle) * r, z = center.y + sin(angle) * r
                let h = surface.sample(x: x, z: z)?.height ?? last
                last = h
                bases.append([x, h, z])
                thicknesses.append(profile.thickness(x, z))
            }
        }
        return (bases, thicknesses)
    }

    private func shapeProgress(now: Double) -> Float {
        shapeDuration > 0 ? Ease.inOutSine(Ease.clamp01(Float((now - shapeStart) / shapeDuration))) : 1
    }

    private func currentBases(now: Double) -> [SIMD3<Float>] {
        let e = shapeProgress(now: now)
        return zip(fromBases, bases).map { simd_mix($0, $1, .init(repeating: e)) }
    }

    private func currentThicknesses(now: Double) -> [Float] {
        let e = shapeProgress(now: now)
        return zip(fromThicknesses, thicknesses).map { lerp($0, $1, e) }
    }

    private func rebuild(now: Double? = nil) {
        let bases = now.map(currentBases) ?? self.bases
        let thicknesses = now.map(currentThicknesses) ?? self.thicknesses
        let rings = Self.rings, segments = Self.segments
        var positions = [SIMD3<Float>](repeating: .zero, count: bases.count)
        for i in bases.indices {
            let ring = i == 0 ? 0 : (i - 1) % rings + 1
            let reveal = Ease.clamp01((growth * 1.35 - Float(ring) / Float(rings)) * 3)
            positions[i] = bases[i] + SIMD3(0, thicknesses[i] * growth * reveal + 0.0002, 0)
        }
        func index(_ segment: Int, _ ring: Int) -> UInt32 {
            ring == 0 ? 0 : UInt32(1 + (segment % segments) * rings + ring - 1)
        }
        var indices: [UInt32] = []
        for segment in 0..<segments {
            indices += [0, index(segment + 1, 1), index(segment, 1)]
            for ring in 1..<rings {
                let a = index(segment, ring), b = index(segment + 1, ring)
                let c = index(segment, ring + 1), d = index(segment + 1, ring + 1)
                indices += [a, b, d, a, d, c]
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            t += 3
            var n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            if n.y < 0 { n = -n }
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        normals = normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : [0, 1, 0] }
        var descriptor = MeshDescriptor(name: "shell")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        if let mesh = try? MeshResource.generate(from: [descriptor]) { model.model?.mesh = mesh }
        entity.isEnabled = growth > 0.001
    }
}
