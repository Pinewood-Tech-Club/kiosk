import RealityKit
import UIKit

/// Hot fudge ladled onto the top scoop: a heavy ribbon falls from above the screen and coils where it lands, the fudge
/// spreads into a thick glossy cap and slumps down the sides in a few fat drips that slow and stall, each ending in a
/// rounded bead. The cap is a sheet over a grid of rays marched across the surface from the crown; past the fudge's edge
/// the sheet dips under the ice cream, so the edge is wherever the two surfaces cross.
@MainActor
final class FudgeLayer: ToppingLayer {
    let entity = Entity()
    var launchPoint: (() -> SIMD3<Float>)?
    private(set) var isFinished = false
    /// Set before `apply` when toppings already sit where the fudge goes: it wells up from beneath them instead of
    /// being ladled over them.
    var underToppings = false

    static let liftDuration: Double = 0.7
    static let removeDuration: Double = 0.55
    private static let streamLead: Double = 0.16
    private static let pourDuration: Double = 1.15
    private static let streamCut: Double = 0.22

    private let sheet = ModelEntity()
    private let stream = ModelEntity()
    private var sheetMesh: FudgeSheetMesh?
    private var streamMesh: FudgeStreamMesh?
    private weak var camera: Entity?

    private var seed: UInt64 = 0
    private var resting: FudgeRest? { didSet { restChanged = true } }
    private var restChanged = true
    private var shift: (from: FudgeRest, to: FudgeRest, start: Double, duration: Double)?
    private var pourStart: Double = -.infinity
    private var liftsIn = false
    private var removeStart: Double?
    private var animationEnd: Double = -.infinity
    private var landing = FudgeLanding(phase: 0, spin: 1)

    var growDuration: Double { liftsIn ? Self.liftDuration : Self.streamLead + Self.pourDuration + 0.9 }
    var coverDuration: Double { liftsIn ? Self.liftDuration : growDuration }
    var removeDuration: Double { Self.removeDuration }

    init() {
        entity.name = "fudge"
        sheet.name = "fudge-sheet"
        stream.name = "fudge-stream"
        entity.addChild(sheet)
        entity.addChild(stream)
        stream.isEnabled = false
    }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        self.seed = seed
        var rng = ToppingRandom(seed: seed)
        landing = FudgeLanding(phase: Float.random(in: 0..<(2 * .pi), using: &rng), spin: Bool.random(using: &rng) ? 1 : -1)
        resting = FudgeRest(surface: surface, seed: seed)
        shift = nil
        removeStart = nil
        isFinished = false
        liftsIn = animated && underToppings
        pourStart = animated ? now : now - 100
        let dripsEnd = resting.map { rest in
            rest.drips.map { Double(Self.pourDuration) * 0.75 + Double($0.delay + $0.duration) }.max() ?? 0
        } ?? 0
        animationEnd = animated ? now + max(growDuration, liftsIn ? 0 : Self.streamLead + dripsEnd) + 0.05 : now
        if sheetMesh == nil, let mesh = FudgeSheetMesh() {
            sheetMesh = mesh
            sheet.model = ModelComponent(mesh: mesh.resource, materials: [FudgeStyle.material])
        }
        if streamMesh == nil, let mesh = FudgeStreamMesh() {
            streamMesh = mesh
            stream.model = ModelComponent(mesh: mesh.resource, materials: [FudgeStyle.material])
        }
        entity.isEnabled = true
        sheet.isEnabled = true
        build(now: now)
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        guard resting != nil else { return }
        let target = FudgeRest(surface: surface, seed: seed)
        if duration <= 0 {
            resting = target
            shift = nil
        } else {
            shift = (from: rest(at: now), to: target, start: now, duration: duration)
        }
        build(now: now)
    }

    func remove(now: Double) {
        guard removeStart == nil else { return }
        guard resting != nil else {
            isFinished = true
            return
        }
        removeStart = now
    }

    func update(now: Double) {
        guard !isFinished, resting != nil else { return }
        if let removeStart, now - removeStart >= Self.removeDuration {
            isFinished = true
            entity.isEnabled = false
            return
        }
        if let shift, now - shift.start >= shift.duration {
            resting = shift.to
            self.shift = nil
            build(now: now)
            return
        }
        guard now < animationEnd || shift != nil || removeStart != nil else { return }
        build(now: now)
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface {
        guard let settled = shift?.to ?? resting, removeStart == nil else { return below }
        return FudgeCoverSurface(below: below, rest: settled)
    }

    private func rest(at now: Double) -> FudgeRest {
        guard let shift else { return resting! }
        let x = Ease.inOutSine(Ease.clamp01(Float((now - shift.start) / shift.duration)))
        return FudgeRest.mix(shift.from, shift.to, x)
    }

    private func build(now: Double) {
        guard let sheetMesh else { return }
        let rest = rest(at: now)
        let clock = Float(now - pourStart) - (liftsIn ? 0 : Float(Self.streamLead))
        var state = FudgeState(clock: liftsIn ? .infinity : clock, pour: Float(Self.pourDuration), rise: 1, drain: 0,
                               landing: landing)
        if liftsIn {
            state.rise = Ease.inOutSine(Ease.clamp01(Float((now - pourStart) / Self.liftDuration)))
        }
        if let removeStart {
            state.drain = Ease.inOutSine(Ease.clamp01(Float((now - removeStart) / Self.removeDuration)))
        }
        sheetMesh.write(rest: rest, state: state, sameRest: shift == nil && !restChanged)
        restChanged = false
        buildStream(rest: rest, state: state, clock: clock)
    }

    /// The ribbon off the ladle: wide and flat where it leaves the ladle above the screen, narrowing as it falls and
    /// slowly twisting, coiling over itself where it lands. When the pour ends it breaks off at the top and falls in.
    private func buildStream(rest: FudgeRest, state: FudgeState, clock: Float) {
        let lead = Float(Self.streamLead), pour = Float(Self.pourDuration), cut = Float(Self.streamCut)
        let t = clock + lead
        guard let streamMesh, !liftsIn, removeStart == nil, t > 0, t < lead + pour + cut else {
            stream.isEnabled = false
            return
        }
        let chart = landing.point(clock: max(clock, 0), pour: pour, radius: rest.crown)
        let base = rest.point(chart: chart)
        let mound = rest.thickness(chart: chart, state: state)
        let landingPoint = base.position + base.normal * max(mound - 0.0012, 0)
        guard let (height, up) = sky(above: landingPoint) else {
            stream.isEnabled = false
            return
        }
        var bottom: Float = 0, top = height, taper: Float = 1
        if t < lead {
            bottom = height * (1 - Ease.inQuad(t / lead))
        } else if t > lead + pour {
            let x = Ease.clamp01((t - lead - pour) / cut)
            top = max(0.004, height * (1 - Ease.inQuad(x)))
            bottom = min(top - 0.003, 0.004 * Ease.inQuad(x))
            taper = 1 - 0.5 * x
        }
        let coil = t >= lead && t <= lead + pour ? Ease.clamp01((t - lead) / 0.12) : 0
        streamMesh.write(from: landingPoint, up: up, bottom: bottom, top: top, height: height, taper: taper,
                         coil: coil, clock: t, spin: landing.spin) { [rest] z in
            let lag = min(z / 0.45, 1) * 0.06
            let c = self.landing.point(clock: max(clock - lag, 0), pour: pour, radius: rest.crown)
            let p = rest.point(chart: c).position
            return p - up * simd_dot(p - base.position, up)
        }
        stream.isEnabled = true
    }

    /// How far up from `point` a plumb line leaves the top of the stage camera's view (a little past the edge), and
    /// which way is up, in this layer's space.
    private func sky(above point: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        guard let camera = stageCamera(),
              let fieldOfView = camera.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees else { return nil }
        let toWorld = entity.transformMatrix(relativeTo: nil)
        let toCamera = camera.transformMatrix(relativeTo: nil).inverse
        let p = toCamera * (toWorld * SIMD4(point, 1))
        let rising = toCamera * SIMD4<Float>(0, 1, 0, 0)
        let slope = tan(fieldOfView * .pi / 360)
        let approach = rising.y + rising.z * slope
        guard approach > 1e-3 else { return nil }
        let rise = (-p.z * slope - p.y) / approach + 0.04
        let local = toWorld.inverse * SIMD4<Float>(0, 1, 0, 0)
        let up = SIMD3(local.x, local.y, local.z)
        let perMeter = simd_length(up)
        guard rise > 0, perMeter > 1e-6 else { return nil }
        return (rise * perMeter, up / perMeter)
    }

    private func stageCamera() -> Entity? {
        if let camera, camera.scene != nil { return camera }
        var top: Entity = entity
        while let parent = top.parent { top = parent }
        func search(_ entity: Entity) -> Entity? {
            if entity.components.has(PerspectiveCameraComponent.self) { return entity }
            for child in entity.children {
                if let found = search(child) { return found }
            }
            return nil
        }
        camera = search(top)
        return camera
    }
}

enum FudgeStyle {
    /// Dense, opaque and warm: a deep brown with no thin translucent rim, under a wet, mirror-like coat.
    static let color = UIColor(red: 0.2, green: 0.085, blue: 0.045, alpha: 1)

    @MainActor static let material: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.2)
        material.specular = .init(floatLiteral: 0.6)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.03)
        return material
    }()
}

/// Where the ribbon lands, in the crown's chart: it starts a little off center and the ladle drifts in a slow circle.
struct FudgeLanding {
    var phase: Float
    var spin: Float

    func point(clock: Float, pour: Float, radius: Float) -> SIMD2<Float> {
        let x = Ease.clamp01(clock / pour)
        let angle = phase + spin * 2.4 * x
        let r = radius * (0.16 + 0.1 * sin(.pi * x))
        return SIMD2(cos(angle), sin(angle)) * r
    }
}

struct FudgeState {
    /// Seconds since the ribbon first touched down; infinity when finished.
    var clock: Float
    var pour: Float
    /// 0 hidden under the surface to 1 full, when it wells up under other toppings.
    var rise: Float
    /// 0 to 1 as it melts away into the scoop.
    var drain: Float
    var landing: FudgeLanding
}

/// One drip, in the chart: it leaves the cap's edge at `angle` and runs `length` meters down the side.
struct FudgeDrip {
    var angle: Float
    var length: Float
    var halfWidth: Float
    var bead: Float
    var swell: Float
    var delay: Float
    var duration: Float
    var meander: Float
}

/// The settled fudge laid onto one surface: rays from the crown, sampled every `step` along the surface, with the cap's
/// reach along each ray and the drips.
struct FudgeRest: Sendable {
    static let rays = 168
    static let rings = 116
    static let step: Float = 0.0004
    static let sink: Float = 0.0016
    static let edge: Float = 0.0026
    static let capHeight: Float = 0.0027

    var center: SIMD3<Float>
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    /// Horizontal distance from the crown's axis, per sample.
    var spread: [Float]
    var reach: [Int]
    var cap: [Float]
    var drips: [FudgeDrip]
    var crown: Float
    /// Where ladlefuls piled a little higher before they ran together: chart x, z and extra height.
    var heaps: [SIMD3<Float>] = []
    /// Per ray, the drips close enough to reach it and the sine of the angle between them.
    var rayDrips: [[(drip: Int, sine: Float)]] = []
    /// Where each drip leaves the cap.
    var roots: [Float] = []
    /// Per ray, the first ring past anything the fudge could cover.
    var limit: [Int] = []
    /// The settled fudge's height at each sample, before the drips and the pour.
    var crest: [Float] = []

    static let cosines: [Float] = (0..<rays).map { cos(Float($0) / Float(rays) * 2 * .pi) }
    static let sines: [Float] = (0..<rays).map { sin(Float($0) / Float(rays) * 2 * .pi) }

    init(surface: ToppingSurface, seed: UInt64) {
        let radius = max(surface.radius, 0.008)
        let c = Self.crownCenter(surface, radius: radius)
        let centerHit = surface.sample(x: c.x, z: c.y)
        center = [c.x, centerHit?.height ?? surface.apex.y, c.y]
        crown = radius
        let count = Self.rays * Self.rings
        positions = .init(repeating: center, count: count)
        normals = .init(repeating: centerHit?.normal ?? [0, 1, 0], count: count)
        spread = .init(repeating: 0, count: count)
        reach = .init(repeating: 1, count: Self.rays)
        for k in 0..<Self.rays {
            Self.march(surface, ray: k, from: c, center: center, normal: normals[0], lowest: surface.floor + 0.002,
                       positions: &positions, normals: &normals, spread: &spread, reach: &reach[k])
        }
        Self.smooth(&positions, &normals, reach: reach)
        Self.smooth(&positions, &normals, reach: reach)

        var rng = ToppingRandom(seed: seed ^ 0xF0D6E)
        var edges = [Float](repeating: 0, count: Self.rays)
        let capDrop = min(max(0.6 * (center.y - surface.floor - 0.002), 0.004), 0.011)
        for k in 0..<Self.rays {
            var j = 1
            while j < reach[k] - 1, normals[k * Self.rings + j].y > 0.6,
                  center.y - positions[k * Self.rings + j].y < capDrop { j += 1 }
            edges[k] = Float(j) * Self.step
        }
        let phases = (0..<4).map { _ in Float.random(in: 0..<(2 * .pi), using: &rng) }
        let window = 14
        let reach = reach
        cap = (0..<Self.rays).map { k in
            var sum: Float = 0, weight: Float = 0
            for o in -window...window {
                let w = Float(window + 1 - abs(o))
                sum += edges[(k + o + Self.rays) % Self.rays] * w
                weight += w
            }
            let angle = Float(k) / Float(Self.rays) * 2 * .pi
            let lumps = 1 + 0.07 * sin(3 * angle + phases[0]) + 0.045 * sin(5 * angle + phases[1])
                + 0.03 * sin(8 * angle + phases[2]) + 0.02 * sin(13 * angle + phases[3])
            let limit = Float(max(reach[k] - 4, 2)) * Self.step
            return min(min(max(sum / weight * 1.05, 0.35 * radius), 1.2 * radius) * lumps, limit)
        }

        drips = []
        let major = Int.random(in: 6...7, using: &rng)
        let minor = Int.random(in: 4...6, using: &rng)
        let turn = Float.random(in: 0..<(2 * .pi), using: &rng)
        var angles: [Float] = []
        for i in 0..<major {
            angles.append(turn + (Float(i) + Float.random(in: -0.28...0.28, using: &rng)) / Float(major) * 2 * .pi)
        }
        for i in 0..<minor {
            angles.append(turn + (Float(i) + 0.5 + Float.random(in: -0.2...0.2, using: &rng)) / Float(minor) * 2 * .pi)
        }
        for (index, angle) in angles.enumerated() {
            let isMajor = index < major
            let k = Self.ray(at: angle)
            let edge = cap[k]
            let room = Float((-6...6).map { reach[(k + $0 + Self.rays) % Self.rays] }.min()! - 4) * Self.step - edge
            let halfWidth = isMajor ? Float.random(in: 0.0022...0.0031, using: &rng) : Float.random(in: 0.0016...0.0022, using: &rng)
            var bead = halfWidth * Float.random(in: 1.18...1.34, using: &rng)
            var swell = isMajor ? Float.random(in: 0.0004...0.0008, using: &rng) : 0.0002
            let wanted = isMajor
                ? (index % 3 == 0 ? Float.random(in: 0.013...0.019, using: &rng) : Float.random(in: 0.007...0.013, using: &rng))
                : Float.random(in: 0.0015...0.0042, using: &rng)
            var length = wanted
            if room < wanted + bead {
                length = max(room - bead * 0.4, 0.001)
                bead *= 1.22
                swell += 0.0004
            }
            drips.append(FudgeDrip(angle: angle, length: length, halfWidth: halfWidth, bead: bead, swell: swell,
                                   delay: Float.random(in: 0...0.35, using: &rng) + (isMajor ? 0 : 0.15),
                                   duration: (isMajor ? 1.0 : 0.6) + length * 22 + Float.random(in: -0.1...0.15, using: &rng),
                                   meander: Float.random(in: -0.12...0.12, using: &rng)))
        }
        heaps = (0..<3).map { _ in
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let r = radius * Float.random(in: 0.1...0.45, using: &rng)
            return SIMD3(cos(angle) * r, sin(angle) * r, Float.random(in: 0.00025...0.0006, using: &rng))
        }
        index()
    }

    mutating func index() {
        roots = drips.map { cap[Self.ray(at: $0.angle)] }
        let windows = drips.indices.map { index in
            let k = Self.ray(at: drips[index].angle)
            let ring = min(max(Int(((roots[index] - 0.004) / Self.step).rounded(.down)), 0), reach[k] - 1)
            let rho = spread[k * Self.rings + ring]
            let reach = drips[index].bead + 0.0025 + abs(drips[index].meander) * drips[index].length * 0.35
            return rho > reach ? min(1.25 * asin(reach / rho) + 0.05, 1.3) : 1.3
        }
        rayDrips = []
        limit = []
        crest = .init(repeating: 0, count: Self.rays * Self.rings)
        let spread2 = 0.16 * crown * crown
        for k in 0..<Self.rays {
            let theta = Float(k) / Float(Self.rays) * 2 * .pi
            for j in 0..<reach[k] {
                let i = k * Self.rings + j, s = Float(j) * Self.step
                let here = SIMD2<Float>(Self.cosines[k], Self.sines[k]) * s
                var height = Self.capHeight * (0.78 + 0.22 * normals[i].y) + 0.00045 * exp(-s * s / (0.008 * 0.008))
                for heap in heaps {
                    let dx = here.x - heap.x, dz = here.y - heap.y
                    height += heap.z * exp(-(dx * dx + dz * dz) / spread2)
                }
                height += 0.00018 * cos(2 * .pi * s / 0.0052 - theta) * exp(-s / 0.012) * FudgeMath.smoothstep(0.003, 0.006, s)
                crest[i] = height
            }
        }
        for k in 0..<Self.rays {
            let theta = Float(k) / Float(Self.rays) * 2 * .pi
            var near: [(drip: Int, sine: Float)] = []
            var extent = cap[k] + 0.004
            for (index, drip) in drips.enumerated() {
                let delta = remainder(theta - drip.angle, 2 * .pi)
                guard abs(delta) < windows[index] else { continue }
                near.append((index, sin(delta)))
                extent = max(extent, roots[index] + drip.length + drip.bead + 0.004)
            }
            rayDrips.append(near)
            limit.append(min(reach[k], Int((extent / Self.step).rounded(.up)) + 2))
        }
    }

    static func ray(at angle: Float) -> Int {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return Int((a / (2 * .pi) * Float(rays)).rounded()) % rays
    }

    static func mix(_ a: FudgeRest, _ b: FudgeRest, _ x: Float) -> FudgeRest {
        var out = b
        out.center = a.center + (b.center - a.center) * x
        for i in out.positions.indices {
            out.positions[i] = a.positions[i] + (b.positions[i] - a.positions[i]) * x
            out.normals[i] = simd_normalize(a.normals[i] + (b.normals[i] - a.normals[i]) * x)
            out.spread[i] = a.spread[i] + (b.spread[i] - a.spread[i]) * x
        }
        for k in out.reach.indices {
            out.reach[k] = x < 0.5 ? a.reach[k] : b.reach[k]
            out.cap[k] = a.cap[k] + (b.cap[k] - a.cap[k]) * x
        }
        for d in out.drips.indices where d < a.drips.count {
            out.drips[d].length = a.drips[d].length + (b.drips[d].length - a.drips[d].length) * x
            out.drips[d].bead = a.drips[d].bead + (b.drips[d].bead - a.drips[d].bead) * x
            out.drips[d].swell = a.drips[d].swell + (b.drips[d].swell - a.drips[d].swell) * x
        }
        out.crown = a.crown + (b.crown - a.crown) * x
        out.index()
        return out
    }

    /// The middle of the top as it looks: a leaning scoop's highest point sits off toward one side.
    static func crownCenter(_ surface: ToppingSurface, radius: Float) -> SIMD2<Float> {
        let apex = SIMD2<Float>(surface.apex.x, surface.apex.z)
        let floor = surface.apex.y - 0.6 * radius
        let reach = 1.5 * radius, steps = 8
        var sum = SIMD2<Float>.zero, weight: Float = 0
        for i in -steps...steps {
            for j in -steps...steps {
                let offset = SIMD2<Float>(Float(i), Float(j)) * (reach / Float(steps))
                guard simd_length(offset) <= reach, let hit = surface.sample(x: apex.x + offset.x, z: apex.y + offset.y) else { continue }
                let w = max(0, hit.height - floor)
                sum += offset * w
                weight += w
            }
        }
        guard weight > 0 else { return apex }
        let shift = sum / weight, length = simd_length(shift), limit = 0.4 * radius
        return apex + (length > limit ? shift * (limit / length) : shift)
    }

    /// Walks one ray outward across the surface, recording a sample every `step` meters along it, until the surface
    /// drops away, turns nearly vertical or falls off a ledge.
    private static func march(_ surface: ToppingSurface, ray k: Int, from c: SIMD2<Float>, center: SIMD3<Float>, normal: SIMD3<Float>, lowest: Float,
                              positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>], spread: inout [Float], reach: inout Int) {
        let direction = SIMD2<Float>(cosines[k], sines[k])
        let base = k * rings
        positions[base] = center
        normals[base] = normal
        var xz = c
        var p = center, n = normal
        var arc: Float = 0
        var j = 1
        let sub: Float = 0.0001
        var guardCount = 0
        while j < rings, guardCount < 4000 {
            guardCount += 1
            let lateral = SIMD2<Float>(n.x, n.z)
            let slope = -simd_dot(lateral, direction) / max(n.y, 0.05)
            let dx = sub / (1 + slope * slope).squareRoot()
            let next = xz + direction * max(dx, 0.00002)
            guard let hit = surface.sample(x: next.x, z: next.y) else { break }
            let q = SIMD3<Float>(next.x, hit.height, next.y)
            let drop = p.y - q.y
            guard drop < 0.0006, hit.normal.y > 0.12, q.y > lowest else { break }
            arc += simd_length(q - p)
            xz = next
            p = q
            n = simd_normalize(hit.normal)
            while j < rings, Float(j) * step <= arc {
                positions[base + j] = p
                normals[base + j] = n
                spread[base + j] = simd_length(xz - c)
                j += 1
            }
        }
        reach = j
        for r in j..<rings {
            positions[base + r] = positions[base + j - 1]
            normals[base + r] = normals[base + j - 1]
            spread[base + r] = spread[base + j - 1]
        }
    }

    /// Fudge bridges the ice cream's small lumps: the base is evened out along and across the rays, but never sunk far
    /// into the bumps it smooths over.
    private static func smooth(_ positions: inout [SIMD3<Float>], _ normals: inout [SIMD3<Float>], reach: [Int]) {
        let raw = positions, rawNormals = normals
        for k in 0..<rays {
            for j in 1..<rings where j < reach[k] {
                var sum = SIMD3<Float>.zero, nsum = SIMD3<Float>.zero, weight: Float = 0
                for dk in -3...3 {
                    let kk = (k + dk + rays) % rays
                    for dj in -5...5 {
                        let jj = j + dj
                        guard jj >= 0, jj < reach[kk] else { continue }
                        let w = Float(4 - abs(dk)) * Float(6 - abs(dj))
                        sum += raw[kk * rings + jj] * w
                        nsum += rawNormals[kk * rings + jj] * w
                        weight += w
                    }
                }
                let i = k * rings + j
                let n = simd_normalize(nsum)
                var p = raw[i]
                let rise = simd_dot(sum / weight - raw[i], n)
                p += n * max(rise, -0.0003)
                positions[i] = p
                normals[i] = n
            }
        }
    }

    func point(chart: SIMD2<Float>) -> (position: SIMD3<Float>, normal: SIMD3<Float>) {
        let r = simd_length(chart)
        guard r > 1e-6 else { return (positions[0], normals[0]) }
        var angle = atan2(chart.y, chart.x)
        if angle < 0 { angle += 2 * .pi }
        let f = angle / (2 * .pi) * Float(Self.rays)
        let k0 = Int(f) % Self.rays, k1 = (k0 + 1) % Self.rays, a = f - Float(Int(f))
        let g = min(r / Self.step, Float(Self.rings - 1) - 0.001)
        let j0 = Int(g), b = g - Float(j0)
        func at(_ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let i = k * Self.rings + j0
            return (positions[i] + (positions[i + 1] - positions[i]) * b, normals[i] + (normals[i + 1] - normals[i]) * b)
        }
        let (p0, n0) = at(k0), (p1, n1) = at(k1)
        return (p0 + (p1 - p0) * a, simd_normalize(n0 + (n1 - n0) * a))
    }

    func thickness(chart: SIMD2<Float>, state: FudgeState) -> Float {
        let r = simd_length(chart)
        var angle = atan2(chart.y, chart.x)
        if angle < 0 { angle += 2 * .pi }
        let k = Self.ray(at: angle)
        let j = min(Int((r / Self.step).rounded()), Self.rings - 1)
        return thickness(ray: k, ring: j, state: state)
    }

    /// Height of the fudge above the base at one sample, along its normal; negative past the edge, where the sheet
    /// runs under the ice cream.
    /// What changes only with time, worked out once per frame.
    struct Moment {
        var state: FudgeState
        var settled: Bool
        var fill: Float
        var swollen: Float
        var spot: SIMD2<Float>
        var active: Float
        var runs: [Float]
    }

    func moment(_ state: FudgeState) -> Moment {
        let t = state.clock
        let settled = t.isInfinite
        let fill = settled ? 1 : 0.06 + 0.86 * pow(Ease.clamp01(t / state.pour), 0.6)
            + 0.08 * FudgeMath.smoothstep(state.pour, state.pour + 0.9, t)
        let active = settled ? 0 : t < state.pour ? FudgeMath.smoothstep(0, 0.1, t) : exp(-(t - state.pour) / 0.3)
        let runs = drips.map { drip in
            settled ? 1 : FudgeMath.ooze(Ease.clamp01((t - state.pour * 0.75 - drip.delay) / drip.duration))
        }
        return Moment(state: state, settled: settled, fill: fill, swollen: 1 + 0.3 * (1 - fill),
                      spot: settled ? .zero : state.landing.point(clock: max(t, 0), pour: state.pour, radius: crown),
                      active: active > 0.002 ? active : 0, runs: runs)
    }

    func thickness(ray k: Int, ring j: Int, state: FudgeState) -> Float {
        thickness(ray: k, ring: j, moment(state))
    }

    func thickness(ray k: Int, ring j: Int, _ m: Moment) -> Float {
        guard j < limit[k] else { return finish(-Self.sink, m.state) }
        let i = k * Self.rings + j
        let s = Float(j) * Self.step
        var d = cap[k] * m.fill - s
        var bulge: Float = 0
        let rho = spread[i]
        for near in rayDrips[k] {
            let run = m.runs[near.drip]
            guard run > 0 else { continue }
            let root = roots[near.drip] * m.fill
            guard s > root - 0.004 else { continue }
            let drip = drips[near.drip]
            let bead = drip.bead * (0.75 + 0.25 * run)
            let along = s - root
            let lateral = rho * near.sine - drip.meander * max(along, 0) * 0.35
            guard abs(lateral) < bead + 0.0025 else { continue }
            let length = drip.length * run
            let dz = s - (root + length - bead)
            guard dz < 0.0025 + bead else { continue }
            let inside: Float
            if dz <= 0 {
                let width = drip.halfWidth + (bead - drip.halfWidth) * FudgeMath.smoothstep(-2.6 * bead, 0, dz)
                inside = width * (1 - 0.1 * FudgeMath.smoothstep(0, 0.5, along / max(length, 1e-4))) - abs(lateral)
            } else {
                inside = bead - (lateral * lateral + dz * dz).squareRoot()
            }
            d = FudgeMath.smoothMax(d, inside, 0.0018)
            if abs(lateral) < 2.5 * bead, abs(dz) < 2.5 * bead {
                bulge += drip.swell * run * exp(-(lateral * lateral + dz * dz) / (bead * bead))
            }
        }
        var mound: Float = 0
        if m.active > 0 {
            let here = SIMD2<Float>(Self.cosines[k], Self.sines[k]) * s
            let dist2 = simd_length_squared(here - m.spot)
            if dist2 < 0.0001 {
                mound = 0.0026 * m.active * exp(-dist2 / (0.0042 * 0.0042))
                d = max(d, 0.0034 * m.active - dist2.squareRoot())
            }
        }
        guard d > 0 else { return finish(max(-Self.sink, d * 1.2), m.state) }
        let height = (crest[i] + bulge) * m.swollen + mound
        let x = min(d / Self.edge, 1)
        let profile = x >= 1 ? 1 : pow(1 - (1 - x) * (1 - x), 0.55)
        return finish(height * profile, m.state)
    }

    private func finish(_ thickness: Float, _ state: FudgeState) -> Float {
        var h = thickness
        if state.rise < 1 { h = -Self.sink + (h + Self.sink) * state.rise }
        if state.drain > 0 { h = h * (1 - state.drain) - Self.sink * state.drain }
        return h
    }
}

enum FudgeMath {
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = Ease.clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    static func smoothMax(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return max(a, b) + h * h * k * 0.25
    }

    /// A thick drip: it gathers for a moment, slides off and then slows to a stall as it cools on the ice cream.
    static func ooze(_ x: Float) -> Float {
        let start = smoothstep(0, 0.18, x)
        return start * (1 - pow(1 - x, 2.6))
    }
}

/// The settled fudge as a surface for the toppings above it.
struct FudgeCoverSurface: ToppingSurface {
    let below: ToppingSurface
    let rest: FudgeRest
    let lift: [Float]

    init(below: ToppingSurface, rest: FudgeRest) {
        self.below = below
        self.rest = rest
        let moment = rest.moment(FudgeState(clock: .infinity, pour: 1, rise: 1, drain: 0, landing: FudgeLanding(phase: 0, spin: 1)))
        var lift = [Float](repeating: 0, count: FudgeRest.rays * FudgeRest.rings)
        for k in 0..<FudgeRest.rays {
            for j in 0..<FudgeRest.rings {
                lift[k * FudgeRest.rings + j] = max(0, rest.thickness(ray: k, ring: j, moment))
            }
        }
        self.lift = lift
    }

    func bump(x: Float, z: Float) -> Float {
        let q = SIMD2<Float>(x - rest.center.x, z - rest.center.z)
        let r = simd_length(q)
        var angle = atan2(q.y, q.x)
        if angle < 0 { angle += 2 * .pi }
        let f = angle / (2 * .pi) * Float(FudgeRest.rays)
        let k0 = Int(f) % FudgeRest.rays, k1 = (k0 + 1) % FudgeRest.rays, a = f - Float(Int(f))
        func along(_ k: Int) -> Float {
            let base = k * FudgeRest.rings
            let last = rest.reach[k] - 1
            guard last > 0, r <= rest.spread[base + last] else { return 0 }
            var lo = 0, hi = last
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if rest.spread[base + mid] < r { lo = mid } else { hi = mid }
            }
            let r0 = rest.spread[base + lo], r1 = rest.spread[base + hi]
            let b = r1 > r0 ? Ease.clamp01((r - r0) / (r1 - r0)) : 0
            let h = lift[base + lo] + (lift[base + hi] - lift[base + lo]) * b
            let n = rest.normals[base + lo]
            return h / max(n.y, 0.5)
        }
        return along(k0) * (1 - a) + along(k1) * a
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        guard let base = below.sample(x: x, z: z) else { return nil }
        return (base.height + bump(x: x, z: z), base.normal)
    }

    var apex: SIMD3<Float> {
        let a = below.apex
        return a + [0, bump(x: a.x, z: a.z), 0]
    }

    var radius: Float { below.radius }
    var floor: Float { below.floor }

    func softness(x: Float, z: Float) -> Float {
        bump(x: x, z: z) > 0.0005 ? 0.4 : below.softness(x: x, z: z)
    }
}

@MainActor
final class FudgeSheetMesh {
    let mesh: LowLevelMesh
    let resource: MeshResource
    private var points: [SIMD3<Float>]
    private var normals: [SIMD3<Float>]
    private var last: FudgeRest.Moment?
    private var bounds: BoundingBox?

    init?() {
        let rays = FudgeRest.rays, rings = FudgeRest.rings
        let count = rays * rings
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: count, vertexAttributes: attributes,
                                                 vertexLayouts: [.init(bufferIndex: 0, bufferStride: 24)],
                                                 indexCapacity: rays * (rings - 1) * 6, indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else { return nil }
        mesh.withUnsafeMutableIndices { raw in
            let index = raw.bindMemory(to: UInt32.self)
            var o = 0
            for k in 0..<rays {
                let k1 = (k + 1) % rays
                for j in 0..<(rings - 1) {
                    let a = UInt32(k * rings + j), b = a + 1
                    let c = UInt32(k1 * rings + j), d = c + 1
                    index[o] = a; index[o + 1] = c; index[o + 2] = b
                    index[o + 3] = b; index[o + 4] = c; index[o + 5] = d
                    o += 6
                }
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: rays * (rings - 1) * 6, topology: .triangle,
                                                 bounds: BoundingBox(min: .zero, max: .zero))])
        guard let resource = try? MeshResource(from: mesh) else { return nil }
        self.mesh = mesh
        self.resource = resource
        points = .init(repeating: .zero, count: count)
        normals = .init(repeating: [0, 1, 0], count: count)
    }

    /// Rewrites the sheet. With `sameRest`, rays whose shape can't have changed since the last write are kept.
    func write(rest: FudgeRest, state: FudgeState, sameRest: Bool) {
        let rays = FudgeRest.rays, rings = FudgeRest.rings
        let moment = rest.moment(state)
        let global = !sameRest || last == nil || last!.fill != moment.fill || last!.active != moment.active
            || last!.state.rise != state.rise || last!.state.drain != state.drain
        var dirty = [Bool](repeating: global, count: rays)
        if !global, let last {
            for k in 0..<rays where !dirty[k] {
                dirty[k] = rest.rayDrips[k].contains { last.runs[$0.drip] != moment.runs[$0.drip] }
            }
        }
        last = moment
        for k in 0..<rays where dirty[k] {
            for j in 0..<rings {
                let i = k * rings + j
                let h = rest.thickness(ray: k, ring: j, moment)
                points[i] = rest.positions[i] + rest.normals[i] * h
            }
        }
        for k in 0..<rays {
            let kp = (k + 1) % rays, km = (k + rays - 1) % rays
            guard dirty[k] || dirty[kp] || dirty[km] else { continue }
            for j in 0..<rings {
                let i = k * rings + j
                guard j > 0 else {
                    normals[i] = rest.normals[i]
                    continue
                }
                let along = points[k * rings + min(j + 1, rings - 1)] - points[k * rings + j - 1]
                let around = points[kp * rings + j] - points[km * rings + j]
                let n = simd_cross(around, along)
                let length = simd_length(n)
                normals[i] = length > 1e-14 ? n / length : rest.normals[i]
            }
        }
        if global { bounds = nil }
        var lo = bounds?.min ?? SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = bounds?.max ?? SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for k in 0..<rays where dirty[k] {
            for j in 0..<rings {
                lo = simd_min(lo, points[k * rings + j])
                hi = simd_max(hi, points[k * rings + j])
            }
        }
        bounds = BoundingBox(min: lo, max: hi)
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let out = raw.bindMemory(to: Float.self)
            for i in 0..<(rays * rings) {
                let p = points[i], n = normals[i], o = i * 6
                out[o] = p.x; out[o + 1] = p.y; out[o + 2] = p.z
                out[o + 3] = n.x; out[o + 4] = n.y; out[o + 5] = n.z
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: rays * (rings - 1) * 6, topology: .triangle,
                                                 bounds: BoundingBox(min: lo, max: hi))])
    }
}

/// The falling ribbon, one tube with a flattened, twisting cross-section and rounded ends.
@MainActor
final class FudgeStreamMesh {
    static let rings = 48
    static let sides = 16
    let mesh: LowLevelMesh
    let resource: MeshResource

    init?() {
        let vertexCount = Self.rings * Self.sides + 2
        let indexCount = (Self.rings - 1) * Self.sides * 6 + 2 * Self.sides * 3
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: [.init(bufferIndex: 0, bufferStride: 24)],
                                                 indexCapacity: indexCount, indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else { return nil }
        let sides = Self.sides
        mesh.withUnsafeMutableIndices { raw in
            let index = raw.bindMemory(to: UInt32.self)
            var o = 0
            for r in 0..<(Self.rings - 1) {
                for s in 0..<sides {
                    let a = UInt32(r * sides + s), b = UInt32(r * sides + (s + 1) % sides)
                    let c = a + UInt32(sides), d = b + UInt32(sides)
                    index[o] = a; index[o + 1] = b; index[o + 2] = c
                    index[o + 3] = b; index[o + 4] = d; index[o + 5] = c
                    o += 6
                }
            }
            let bottom = UInt32(Self.rings * sides), top = bottom + 1
            let last = UInt32((Self.rings - 1) * sides)
            for s in 0..<sides {
                index[o] = bottom; index[o + 1] = UInt32((s + 1) % sides); index[o + 2] = UInt32(s)
                index[o + 3] = top; index[o + 4] = last + UInt32(s); index[o + 5] = last + UInt32((s + 1) % sides)
                o += 6
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle,
                                                 bounds: BoundingBox(min: .zero, max: .zero))])
        guard let resource = try? MeshResource(from: mesh) else { return nil }
        self.mesh = mesh
        self.resource = resource
    }

    /// `axis(z)` is where the ribbon's center would be `z` meters up the plumb line from the landing point, before the
    /// coil near the bottom.
    func write(from landing: SIMD3<Float>, up: SIMD3<Float>, bottom: Float, top: Float, height: Float, taper: Float,
               coil: Float, clock: Float, spin: Float, axis: (Float) -> SIMD3<Float>) {
        let rings = Self.rings, sides = Self.sides
        var reference = simd_cross(up, [1, 0, 0])
        if simd_length(reference) < 0.1 { reference = simd_cross(up, [0, 0, 1]) }
        reference = simd_normalize(reference)
        let other = simd_cross(up, reference)
        let coilHeight: Float = 0.0065
        func radius(_ z: Float) -> Float {
            let fall = Ease.clamp01(z / max(height, 1e-4))
            return 0.0025 * taper * (1 + 0.6 * fall.squareRoot())
        }
        func center(_ z: Float) -> SIMD3<Float> {
            var p = axis(z) + up * z
            let low = Ease.clamp01(1 - z / coilHeight)
            if coil > 0, low > 0 {
                let angle = spin * (clock * 13 + z / 0.0011)
                let r = 0.0021 * coil * low * low
                p += (reference * cos(angle) + other * sin(angle)) * r
                p -= up * 0.0012 * coil * low
            }
            return p
        }
        var lo = landing, hi = landing
        var ringPoints: [SIMD3<Float>] = []
        var ringNormals: [SIMD3<Float>] = []
        ringPoints.reserveCapacity(rings * sides)
        ringNormals.reserveCapacity(rings * sides)
        var ends: [(SIMD3<Float>, SIMD3<Float>)] = []
        for r in 0..<rings {
            let u = Float(r) / Float(rings - 1)
            let zz = bottom + (top - bottom) * pow(u, 1.8)
            let dz = max((top - bottom) * 0.002, 1e-5)
            let p = center(zz)
            let tangent = simd_normalize(center(zz + dz) - center(zz - dz))
            var side = simd_cross(tangent, reference)
            if simd_length(side) < 1e-4 { side = simd_cross(tangent, other) }
            side = simd_normalize(side)
            let normal = simd_cross(side, tangent)
            let twist = zz / 0.06 * .pi + clock * 1.3
            let s0 = side * cos(twist) + normal * sin(twist), n0 = simd_cross(s0, tangent)
            var rr = radius(zz)
            let roundEnd = min(Ease.clamp01((zz - bottom) / (rr * 1.2)), Ease.clamp01((top - zz) / (rr * 1.2)))
            rr *= (1 - pow(1 - roundEnd, 2)).squareRoot() * 0.85 + 0.15
            let wide = rr * 1.45, thin = rr * 0.72
            for s in 0..<sides {
                let a = Float(s) / Float(sides) * 2 * .pi
                let c = cos(a), sn = sin(a)
                let q = p + s0 * (c * wide) + n0 * (sn * thin)
                ringPoints.append(q)
                ringNormals.append(simd_normalize(s0 * (c / wide) + n0 * (sn / thin)))
                lo = simd_min(lo, q)
                hi = simd_max(hi, q)
            }
            if r == 0 { ends.append((p, -tangent)) }
            if r == rings - 1 { ends.append((p, tangent)) }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let out = raw.bindMemory(to: Float.self)
            for i in 0..<ringPoints.count {
                let p = ringPoints[i], n = ringNormals[i], o = i * 6
                out[o] = p.x; out[o + 1] = p.y; out[o + 2] = p.z
                out[o + 3] = n.x; out[o + 4] = n.y; out[o + 5] = n.z
            }
            for (e, end) in ends.enumerated() {
                let o = (ringPoints.count + e) * 6
                out[o] = end.0.x; out[o + 1] = end.0.y; out[o + 2] = end.0.z
                out[o + 3] = end.1.x; out[o + 4] = end.1.y; out[o + 5] = end.1.z
            }
        }
        let pad = SIMD3<Float>(repeating: 0.004)
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: (rings - 1) * sides * 6 + 2 * sides * 3, topology: .triangle,
                                                 bounds: BoundingBox(min: lo - pad, max: hi + pad))])
    }
}
