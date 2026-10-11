import RealityKit
import UIKit

struct DrizzleStyle {
    let name: String
    var color: UIColor
    /// Width of the laid ribbon, meters.
    var width: Float
    /// 0 runny to 1 thick: thicker syrup lands rounder, pools more, pours a little slower and drips shorter and slower.
    var viscosity: Float
    /// 0 satin to 1 wet glass.
    var gloss: Float
    /// 0 to 1: how many drips run down the sides and how far.
    var dripTendency: Float

    static let chocolate = DrizzleStyle(name: "chocolate", color: UIColor(red: 0.19, green: 0.078, blue: 0.042, alpha: 1),
                                        width: 0.0034, viscosity: 0.4, gloss: 0.95, dripTendency: 0.85)
    static let caramel = DrizzleStyle(name: "caramel", color: UIColor(red: 0.6, green: 0.3, blue: 0.075, alpha: 1),
                                      width: 0.0039, viscosity: 0.75, gloss: 0.9, dripTendency: 0.45)
}

extension DrizzleStyle {
    @MainActor private static var materials: [String: PhysicallyBasedMaterial] = [:]

    @MainActor var material: PhysicallyBasedMaterial {
        if let cached = Self.materials[name] { return cached }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.3 - 0.24 * gloss)
        material.specular = .init(floatLiteral: 0.75)
        material.clearcoat = .init(floatLiteral: gloss)
        material.clearcoatRoughness = .init(floatLiteral: 0.12 - 0.1 * gloss)
        Self.materials[name] = material
        return material
    }
}

/// Syrup squeezed over the top in a zigzag, with a few drips down the sides. The path is kept in coordinates
/// relative to the surface's apex and radius, so it can be laid back onto any surface beneath it.
@MainActor
final class DrizzleLayer: ToppingLayer {
    let style: DrizzleStyle
    let entity: Entity
    var launchPoint: (() -> SIMD3<Float>)?
    private(set) var isFinished = false

    private let model = ModelEntity()
    private var path: [PathSample] = []
    private var drips: [DripSpec] = []
    private var resting: Projection?
    private var shift: (from: Projection, to: Projection, start: Double, duration: Double)?
    private var pourStart: Double = -.infinity
    private var removeStart: Double?
    private var animationEnd: Double = -.infinity
    private var mesh: LowLevelMesh?
    private var vertices: [Float] = []
    private var indices: [UInt32] = []
    private var lowerBound = SIMD3<Float>(repeating: 0)
    private var upperBound = SIMD3<Float>(repeating: 0)

    private static let ringSides = 10
    private static let capRings = 4
    private static let dripRings = 16
    private static let dripPathPoints = 24
    private static let strandRings = 16
    private static let streamLead: Double = 0.12
    private static let streamCut: Double = 0.16
    private static let removeDuration: Double = 0.5
    private static let ringCos = (0..<ringSides).map { cos(2 * Float.pi * Float($0) / Float(ringSides)) }
    private static let ringSin = (0..<ringSides).map { sin(2 * Float.pi * Float($0) / Float(ringSides)) }

    private var pourDuration: Double { 1.3 + 0.25 * Double(style.viscosity) }
    private var settleDuration: Float { 0.22 + 0.35 * style.viscosity }
    private var halfWidth: Float { style.width / 2 }

    init(style: DrizzleStyle = .chocolate) {
        self.style = style
        entity = model
        model.name = "drizzle-\(style.name)"
    }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        var rng = ToppingRandom(seed: seed)
        path = Self.makePath(radius: max(surface.radius, 0.01), width: style.width, rng: &rng)
        drips = makeDrips(rng: &rng)
        let projection = project(onto: surface)
        resting = projection
        shift = nil
        removeStart = nil
        isFinished = false
        pourStart = animated ? now : now - 100
        let lead = Self.streamLead, pour = pourDuration
        animationEnd = drips.reduce(pourStart + lead + pour + max(Self.streamCut, Double(settleDuration))) { end, drip in
            max(end, pourStart + lead + Double(path[drip.origin].time) * pour + Double(drip.delay + drip.duration))
        }
        makeMesh()
        model.setOpacity(1)
        build(now: now)
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        guard !path.isEmpty else { return }
        let target = project(onto: surface)
        if duration <= 0 {
            resting = target
            shift = nil
        } else {
            shift = (from: projection(at: now), to: target, start: now, duration: duration)
        }
        build(now: now)
    }

    func remove(now: Double) {
        guard removeStart == nil else { return }
        if path.isEmpty {
            isFinished = true
            return
        }
        removeStart = now
    }

    func update(now: Double) {
        guard !isFinished, !path.isEmpty else { return }
        if let removeStart, now - removeStart >= Self.removeDuration {
            isFinished = true
            model.isEnabled = false
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
        guard !path.isEmpty, removeStart == nil else { return below }
        let projection = project(onto: below, withDrips: false)
        var points: [SIMD2<Float>] = []
        var widths: [Float] = []
        var heights: [Float] = []
        for i in path.indices {
            let (a, h) = profile(i, normal: projection.normals[i], age: .infinity)
            points.append([projection.points[i].x, projection.points[i].z])
            widths.append(a)
            heights.append(h * 1.02)
        }
        return DrizzleCoverSurface(below: below, points: points, halfWidths: widths, heights: heights)
    }
}

private struct PathSample {
    /// Offset from the apex in units of the surface radius.
    var q: SIMD2<Float>
    /// When the stream lands here, as a fraction of the pour.
    var time: Float
    /// Width factor from the hand's speed: syrup piles up where the hand slows in a turn.
    var flow: Float
}

private struct DripSpec {
    var origin: Int
    var length: Float
    var delay: Float
    var duration: Float
    var halfWidth: Float
    var meander: Float
    var phase: Float
}

private struct DripPath {
    var points: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var length: Float
}

private struct Projection {
    var points: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var drips: [DripPath]
    var top: Float
}

private struct DrizzleCoverSurface: ToppingSurface {
    let below: ToppingSurface
    let points: [SIMD2<Float>]
    let halfWidths: [Float]
    let heights: [Float]
    private let cells: [SIMD2<Int32>: [Int32]]
    private static let cell: Float = 0.003

    init(below: ToppingSurface, points: [SIMD2<Float>], halfWidths: [Float], heights: [Float]) {
        self.below = below
        self.points = points
        self.halfWidths = halfWidths
        self.heights = heights
        var cells: [SIMD2<Int32>: [Int32]] = [:]
        for (i, p) in points.enumerated() {
            cells[Self.key(p), default: []].append(Int32(i))
        }
        self.cells = cells
    }

    private static func key(_ p: SIMD2<Float>) -> SIMD2<Int32> {
        SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)))
    }

    func bump(x: Float, z: Float) -> Float {
        let q = SIMD2<Float>(x, z)
        let k = Self.key(q)
        var best: Float = 0
        for dx: Int32 in -1...1 {
            for dz: Int32 in -1...1 {
                for i in cells[k &+ SIMD2(dx, dz)] ?? [] {
                    let a = halfWidths[Int(i)]
                    let d = simd_length(points[Int(i)] - q)
                    guard d < a else { continue }
                    let u = d / a
                    best = max(best, heights[Int(i)] * (1 - u * u).squareRoot())
                }
            }
        }
        return best
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
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = Ease.clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

private extension DrizzleLayer {
    // MARK: Path

    static func makePath(radius: Float, width: Float, rng: inout ToppingRandom) -> [PathSample] {
        let span: Float = 0.76
        let spacing = width * 2.05 / radius
        let lineCount = max(3, Int((2 * span / spacing).rounded()) + 1)
        let step = 2 * span / Float(lineCount - 1)
        let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
        let turnRadius = step / 2

        struct Line { var a: SIMD2<Float>; var b: SIMD2<Float>; var bow: Float; var dir: Float }
        var lines: [Line] = []
        for k in 0..<lineCount {
            let v = -span + Float(k) * step + Float.random(in: -0.1...0.1, using: &rng) * step
            let dir: Float = k % 2 == 0 ? 1 : -1
            let tilt = Float.random(in: -0.45...0.45, using: &rng) * step
            let reach = 0.98 * max(0.2, 1 - v * v).squareRoot()
            let start = reach * Float.random(in: 0.86...1.02, using: &rng) - turnRadius * 0.8
            let end = reach * Float.random(in: 0.86...1.02, using: &rng) - turnRadius * 0.8
            lines.append(Line(a: [-dir * start, v - tilt], b: [dir * end, v + tilt],
                              bow: Float.random(in: -0.55...0.55, using: &rng) * step, dir: dir))
        }

        for k in 1..<lines.count {
            let gap = min(lines[k].a.y, lines[k].b.y) - max(lines[k - 1].a.y, lines[k - 1].b.y)
            if gap < 0.65 * step {
                lines[k].a.y += 0.65 * step - gap
                lines[k].b.y += 0.65 * step - gap
            }
        }

        var dense: [(q: SIMD2<Float>, speed: Float)] = []
        for (k, line) in lines.enumerated() {
            let mid = (line.a + line.b) / 2 + [0, line.bow]
            let count = 56
            for j in 0..<count {
                let x = Float(j) / Float(count)
                let p = quadraticBezier([line.a.x, line.a.y, 0], [mid.x, mid.y, 0], [line.b.x, line.b.y, 0], x)
                dense.append(([p.x, p.y], 1 + 0.15 * sin(.pi * x)))
            }
            guard k + 1 < lines.count else {
                dense.append((line.b, 1))
                break
            }
            let next = lines[k + 1]
            let gap: SIMD2<Float> = simd_abs(next.a - line.b)
            let handle: Float = 0.667 * gap.y + 0.3 * gap.x
            let c0 = line.b + [line.dir * handle, 0]
            let c1 = next.a + [line.dir * handle, 0]
            let turnCount = 28
            for j in 0..<turnCount {
                let x = Float(j) / Float(turnCount)
                let p = cubicBezier([line.b.x, line.b.y, 0], [c0.x, c0.y, 0], [c1.x, c1.y, 0], [next.a.x, next.a.y, 0], x)
                let mid = abs(2 * x - 1)
                dense.append(([p.x, p.y], 0.6 + 0.4 * mid * mid))
            }
        }

        let f1 = Float.random(in: 1.5...2.5, using: &rng), f2 = Float.random(in: 2...3.5, using: &rng)
        let p1 = Float.random(in: 0..<(2 * .pi), using: &rng), p2 = Float.random(in: 0..<(2 * .pi), using: &rng)
        let c = cos(angle), s = sin(angle)
        for i in dense.indices {
            let x = Float(i) / Float(dense.count) * 2 * .pi
            var q = dense[i].q + 0.026 * SIMD2(sin(f1 * x + p1), sin(f2 * x + p2))
            q = [c * q.x - s * q.y, s * q.x + c * q.y]
            dense[i].q = q
        }

        let spacingUnit = 0.0009 / radius
        var samples: [PathSample] = [PathSample(q: dense[0].q, time: 0, flow: dense[0].speed)]
        var carried: Float = 0
        var time: Float = 0
        for i in 1..<dense.count {
            let a = dense[i - 1], b = dense[i]
            let segment = simd_length(b.q - a.q)
            guard segment > 1e-7 else { continue }
            var along = spacingUnit - carried
            while along <= segment {
                let x = along / segment
                let speed = a.speed + (b.speed - a.speed) * x
                time += spacingUnit / speed
                samples.append(PathSample(q: a.q + (b.q - a.q) * x, time: time, flow: speed))
                along += spacingUnit
            }
            carried = segment - (along - spacingUnit)
        }
        let total = max(time, 1e-6)
        for i in samples.indices {
            samples[i].time /= total
            let dollop = 1 + 0.3 * exp(-Float(i) / 3)
            samples[i].flow = min(max(pow(samples[i].flow, -0.45), 0.88), 1.3) * dollop
        }
        return samples
    }

    func makeDrips(rng: inout ToppingRandom) -> [DripSpec] {
        var tips: [(index: Int, reach: Float)] = []
        for i in 2..<max(2, path.count - 2) {
            let r = simd_length(path[i].q)
            if r > 0.55, r >= simd_length(path[i - 1].q), r >= simd_length(path[i + 1].q),
               r > simd_length(path[i - 2].q), r > simd_length(path[i + 2].q) {
                tips.append((i, r + Float.random(in: 0...0.15, using: &rng)))
            }
        }
        tips.sort { $0.reach > $1.reach }
        let most = 2 + Int((3 * style.dripTendency).rounded())
        let count = min(tips.count, Int.random(in: 2...max(2, most), using: &rng))
        var chosen = Array(tips.prefix(count + 2)).shuffled(using: &rng).prefix(count)
        chosen.sort { $0.index < $1.index }
        let reach = 0.6 + 0.5 * style.dripTendency
        let slow = 0.8 + 0.9 * style.viscosity
        return chosen.map { tip in
            let length = Float.random(in: 0.006...0.014, using: &rng) * reach
            return DripSpec(origin: tip.index, length: length,
                            delay: Float.random(in: 0.08...0.25, using: &rng),
                            duration: slow * Float.random(in: 0.85...1.2, using: &rng) + length * 40,
                            halfWidth: style.width * Float.random(in: 0.3...0.38, using: &rng),
                            meander: Float.random(in: -0.25...0.25, using: &rng),
                            phase: Float.random(in: 0..<(2 * .pi), using: &rng))
        }
    }

    // MARK: Projection onto a surface

    static func probe(_ surface: ToppingSurface, _ xz: SIMD2<Float>, center: SIMD2<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        var q = xz
        for _ in 0..<12 {
            if let hit = surface.sample(x: q.x, z: q.y) {
                return ([q.x, hit.height, q.y], simd_normalize(hit.normal))
            }
            q = center + (q - center) * 0.92
        }
        return (surface.apex, [0, 1, 0])
    }

    func project(onto surface: ToppingSurface, withDrips: Bool = true) -> Projection {
        let center = SIMD2<Float>(surface.apex.x, surface.apex.z)
        let radius = max(surface.radius, 0.01)
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(path.count)
        normals.reserveCapacity(path.count)
        for sample in path {
            let (p, n) = Self.probe(surface, center + sample.q * radius, center: center)
            points.append(p)
            normals.append(n)
        }
        smoothAlongPath(&points, &normals)
        let dripPaths = withDrips
            ? drips.map { march($0, from: points[$0.origin], on: surface, center: center, radius: radius) }
            : []
        return Projection(points: points, normals: normals, drips: dripPaths, top: surface.apex.y)
    }

    /// Evens out a bumpy surface along the ribbon (frilled scoop edges) so it drapes instead of crinkling,
    /// without letting it sink more than a fraction of its thickness.
    func smoothAlongPath(_ points: inout [SIMD3<Float>], _ normals: inout [SIMD3<Float>]) {
        let count = points.count, reach = 3
        guard count > 2 * reach else { return }
        let raw = points, rawNormals = normals
        let sink = halfWidth * 0.25
        for i in 0..<count {
            var height: Float = 0, weight: Float = 0
            var normal = SIMD3<Float>.zero
            for j in max(0, i - reach)...min(count - 1, i + reach) {
                let w = Float(reach + 1 - abs(j - i))
                height += raw[j].y * w
                normal += rawNormals[j] * w
                weight += w
            }
            points[i].y = max(height / weight, raw[i].y - sink)
            normals[i] = simd_normalize(normal)
        }
    }

    /// Runs a drip downhill from `start` along the surface, resampled to evenly spaced points over the length it reaches.
    func march(_ drip: DripSpec, from start: SIMD3<Float>, on surface: ToppingSurface, center: SIMD2<Float>, radius: Float) -> DripPath {
        let step: Float = 0.0002
        var xz = SIMD2<Float>(start.x, start.z)
        var (p, n) = Self.probe(surface, xz, center: center)
        var raw: [(p: SIMD3<Float>, n: SIMD3<Float>, arc: Float)] = [(p, n, 0)]
        var arc: Float = 0
        var guardCount = 0
        while arc < drip.length, guardCount < 400 {
            guardCount += 1
            let outward = simd_length(xz - center) > 1e-5 ? simd_normalize(xz - center) : SIMD2<Float>(1, 0)
            let downhill = SIMD2<Float>(n.x, n.z)
            var dir = simd_length(downhill) > 0.05 ? simd_normalize(downhill) : outward
            dir = simd_normalize(dir * 0.7 + outward * 0.3)
            dir += SIMD2(-dir.y, dir.x) * drip.meander * sin(drip.phase + arc / 0.003)
            dir = simd_normalize(dir)
            let next = xz + dir * step * max(n.y, 0.15)
            guard simd_length(next - center) < radius * 1.12, let hit = surface.sample(x: next.x, z: next.y) else { break }
            let q = SIMD3<Float>(next.x, hit.height, next.y)
            arc += simd_length(q - p)
            xz = next
            p = q
            let wasSteep = n.y < 0.75
            n = simd_normalize(hit.normal)
            raw.append((p, n, arc))
            if wasSteep, n.y > 0.85 { break }
        }
        let length = min(arc, drip.length)
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var cursor = 0
        for j in 0...Self.dripPathPoints {
            let target = length * Float(j) / Float(Self.dripPathPoints)
            while cursor + 1 < raw.count, raw[cursor + 1].arc < target { cursor += 1 }
            let a = raw[cursor], b = raw[min(cursor + 1, raw.count - 1)]
            let x = b.arc > a.arc ? Ease.clamp01((target - a.arc) / (b.arc - a.arc)) : 0
            points.append(a.p + (b.p - a.p) * x)
            normals.append(simd_normalize(a.n + (b.n - a.n) * x))
        }
        return DripPath(points: points, normals: normals, length: length)
    }

    func projection(at now: Double) -> Projection {
        guard let shift else { return resting! }
        let x = Float(Ease.inOutSine(Ease.clamp01(Float((now - shift.start) / shift.duration))))
        let a = shift.from, b = shift.to
        func mixPoints(_ p: [SIMD3<Float>], _ q: [SIMD3<Float>]) -> [SIMD3<Float>] {
            zip(p, q).map { $0 + ($1 - $0) * x }
        }
        func mixNormals(_ p: [SIMD3<Float>], _ q: [SIMD3<Float>]) -> [SIMD3<Float>] {
            zip(p, q).map { simd_normalize($0 + ($1 - $0) * x) }
        }
        let drips = zip(a.drips, b.drips).map { from, to in
            DripPath(points: mixPoints(from.points, to.points), normals: mixNormals(from.normals, to.normals),
                     length: from.length + (to.length - from.length) * x)
        }
        return Projection(points: mixPoints(a.points, b.points), normals: mixNormals(a.normals, b.normals),
                          drips: drips, top: a.top + (b.top - a.top) * x)
    }

    // MARK: Geometry

    /// Half width and height of the ribbon at sample `i`: flatter as it settles, fuller where it pools on the crown,
    /// thinner where it runs over a steep shoulder.
    func profile(_ i: Int, normal n: SIMD3<Float>, age: Float) -> (Float, Float) {
        let flat = smoothstep(0.8, 0.985, n.y)
        let steep = smoothstep(0.2, 0.75, n.y)
        let fresh = 1 - smoothstep(0, settleDuration, age)
        let a = halfWidth * path[i].flow * (1 + 0.24 * flat) * (0.8 + 0.2 * steep) * (1 - 0.2 * fresh)
        let settled = 0.5 + 0.25 * style.viscosity
        let h = a * (settled + (0.95 - settled) * fresh) * (1 + 0.22 * flat)
        return (a, h)
    }

    func makeMesh() {
        let rings = (path.count + 2 * Self.capRings + 2) + drips.count * (Self.dripRings + 1) + (Self.strandRings + 1)
        let vertexCount = rings * Self.ringSides
        let indexCount = rings * Self.ringSides * 6
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: [.init(bufferIndex: 0, bufferStride: 24)],
                                                 indexCapacity: indexCount, indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: descriptor), let resource = try? MeshResource(from: mesh) else { return }
        self.mesh = mesh
        vertices.reserveCapacity(vertexCount * 6)
        indices.reserveCapacity(indexCount)
        model.model = ModelComponent(mesh: resource, materials: [style.material])
    }

    struct Ring {
        var center: SIMD3<Float>
        var side: SIMD3<Float>
        var up: SIMD3<Float>
        var along: SIMD3<Float>
        var a: Float
        var h: Float
        /// Scales the cross-section without changing its normals, for rounded ends.
        var scale: Float = 1
        /// Tilts normals along the tube where its width changes (caps, the drip's bulb).
        var lean: Float = 0
        var round = false
    }

    func emit(_ ring: Ring) {
        let a = max(ring.a, 1e-6), h = max(ring.h, 1e-6), d = ring.round ? h : h * 0.35
        let normalLean = ring.along * ring.lean
        for k in 0..<Self.ringSides {
            let c = Self.ringCos[k], s = Self.ringSin[k]
            let height = s >= 0 ? h : d
            let p = ring.center + (ring.side * (a * c) + ring.up * (height * s)) * ring.scale
            let n = simd_normalize(simd_normalize(ring.side * (c * height) + ring.up * (s * a)) + normalLean)
            vertices.append(p.x); vertices.append(p.y); vertices.append(p.z)
            vertices.append(n.x); vertices.append(n.y); vertices.append(n.z)
            lowerBound = simd_min(lowerBound, p)
            upperBound = simd_max(upperBound, p)
        }
    }

    /// Connects `count` rings emitted consecutively, ending at the current vertex count.
    func stitch(rings count: Int) {
        guard count > 1 else { return }
        let sides = Self.ringSides
        let first = vertices.count / 6 - count * sides
        for r in 0..<(count - 1) {
            let base = first + r * sides
            for k in 0..<sides {
                let k1 = (k + 1) % sides
                let a = UInt32(base + k), b = UInt32(base + sides + k)
                let c = UInt32(base + k1), d = UInt32(base + sides + k1)
                indices.append(a); indices.append(b); indices.append(c)
                indices.append(b); indices.append(d); indices.append(c)
            }
        }
    }

    func frame(_ along: SIMD3<Float>, _ normal: SIMD3<Float>) -> (side: SIMD3<Float>, up: SIMD3<Float>, along: SIMD3<Float>) {
        var t = along - normal * simd_dot(along, normal)
        t = simd_length(t) > 1e-8 ? simd_normalize(t) : simd_normalize(simd_cross(normal, [1, 0, 0]))
        let side = simd_normalize(simd_cross(t, normal))
        return (side, normal, simd_cross(normal, side))
    }

    func cap(from ring: Ring, direction: Float, tipFirst: Bool) -> [Ring] {
        var rings: [Ring] = []
        for k in 1...Self.capRings {
            let theta = Float(k) / Float(Self.capRings) * .pi / 2
            var r = ring
            r.center += ring.along * (direction * ring.a * 0.9 * sin(theta))
            r.scale = cos(theta)
            r.lean = k == Self.capRings ? direction * 1e4 : direction * tan(theta)
            rings.append(r)
        }
        return tipFirst ? rings.reversed() : rings
    }

    func build(now: Double) {
        guard let mesh, !path.isEmpty else { return }
        let geometry = projection(at: now)
        vertices.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        lowerBound = SIMD3(repeating: .greatestFiniteMagnitude)
        upperBound = SIMD3(repeating: -.greatestFiniteMagnitude)

        var drain: Float = 0
        var clockLimit = now
        if let removeStart {
            drain = Ease.inOutSine(Ease.clamp01(Float((now - removeStart) / Self.removeDuration)))
            clockLimit = removeStart
            model.setOpacity(1 - smoothstep(0.55, 1, drain))
        }
        let clock = Float(min(now, clockLimit) - pourStart)
        let lead = Float(Self.streamLead), pour = Float(pourDuration)
        let hand = (clock - lead) / pour
        let thin = 1 - 0.3 * drain, flatten = 1 - drain

        func sampleRing(_ i: Int, tangent: SIMD3<Float>) -> Ring {
            let n = geometry.normals[i]
            let age = clock - lead - path[i].time * pour
            let (a, h) = profile(i, normal: n, age: age)
            let f = frame(tangent, n)
            let center = geometry.points[i] + n * (-0.1 * h - drain * h * 1.1)
            return Ring(center: center, side: f.side, up: f.up, along: f.along, a: a * thin, h: h * flatten)
        }

        var headIndex = -1
        var headPoint = geometry.points[0]
        var headFraction: Float = 0
        if hand > 0 {
            while headIndex + 1 < path.count, path[headIndex + 1].time <= hand { headIndex += 1 }
            headIndex = max(headIndex, 0)
            if headIndex + 1 < path.count {
                let t0 = path[headIndex].time, t1 = path[headIndex + 1].time
                headFraction = t1 > t0 ? Ease.clamp01((hand - t0) / (t1 - t0)) : 0
                headPoint = geometry.points[headIndex] + (geometry.points[headIndex + 1] - geometry.points[headIndex]) * headFraction
            } else {
                headPoint = geometry.points[headIndex]
            }

            var rings: [Ring] = []
            rings.reserveCapacity(headIndex + 2 * Self.capRings + 2)
            for i in 0...headIndex {
                let ahead = i + 1 <= headIndex ? geometry.points[i + 1] : (headIndex + 1 < path.count ? geometry.points[i + 1] : geometry.points[i])
                let behind = i > 0 ? geometry.points[i - 1] : geometry.points[i]
                rings.append(sampleRing(i, tangent: ahead - behind))
            }
            if headIndex + 1 < path.count, headFraction > 0.02 {
                var head = sampleRing(headIndex + 1, tangent: geometry.points[headIndex + 1] - geometry.points[headIndex])
                let previous = rings[rings.count - 1]
                head.center = previous.center + (head.center - previous.center) * headFraction
                rings.append(head)
            }
            let ringsBody = rings
            for ring in cap(from: ringsBody[0], direction: -1, tipFirst: true) { emit(ring) }
            for ring in ringsBody { emit(ring) }
            for ring in cap(from: ringsBody[ringsBody.count - 1], direction: 1, tipFirst: false) { emit(ring) }
            stitch(rings: ringsBody.count + 2 * Self.capRings)
        }

        for (d, drip) in drips.enumerated() where d < geometry.drips.count {
            let start = lead + path[drip.origin].time * pour + drip.delay
            let x = Ease.clamp01((clock - start) / drip.duration)
            guard x > 0 else { continue }
            let route = geometry.drips[d]
            let grow = 1 - pow(1 - x, 3)
            let length = route.length * grow
            guard length > 0.0003 else { continue }
            let origin = geometry.normals[drip.origin]
            let ribbonA = profile(drip.origin, normal: origin, age: .infinity).0
            var bulb = drip.halfWidth * (1.12 + 0.38 * grow)
            bulb = min(bulb, length / 2)
            let bulbCenter = length - bulb
            func width(_ s: Float) -> Float {
                if s >= bulbCenter { return (max(0, bulb * bulb - (s - bulbCenter) * (s - bulbCenter))).squareRoot() }
                let neck = ribbonA * 0.85 + (drip.halfWidth - ribbonA * 0.85) * smoothstep(0, 0.0025, s)
                let rise = s - bulbCenter
                return max(neck, (max(0, bulb * bulb - rise * rise)).squareRoot())
            }
            for j in 0...Self.dripRings {
                let u = Float(j) / Float(Self.dripRings)
                let s = length * (1 - pow(1 - u, 1.7))
                let along = route.length > 1e-6 ? s / route.length * Float(Self.dripPathPoints) : 0
                let k = min(Int(along), Self.dripPathPoints - 1)
                let x = along - Float(k)
                let p = route.points[k] + (route.points[k + 1] - route.points[k]) * x
                let n = simd_normalize(route.normals[k] + (route.normals[k + 1] - route.normals[k]) * x)
                let f = frame(route.points[k + 1] - route.points[k], n)
                let a = width(s)
                let h = a * 0.82
                let epsilon: Float = 0.0001
                let slope = (width(s + epsilon) - width(max(s - epsilon, 0))) / (2 * epsilon)
                let center = p + n * (-0.1 * h - drain * h * 1.1)
                emit(Ring(center: center, side: f.side, up: f.up, along: f.along, a: a * thin, h: h * flatten,
                          lean: j == Self.dripRings ? 1e4 : -slope))
            }
            stitch(rings: Self.dripRings + 1)
        }

        if drain == 0 { emitStream(clock: clock, geometry: geometry, headIndex: headIndex, headPoint: headPoint) }

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            vertices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.withUnsafeMutableIndices { raw in
            indices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bounds = indices.isEmpty
            ? BoundingBox(min: geometry.points[0], max: geometry.points[0])
            : BoundingBox(min: lowerBound, max: upperBound)
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle, bounds: bounds)])
    }

    /// The falling strand between the invisible bottle and where the syrup lands, while it pours.
    func emitStream(clock: Float, geometry: Projection, headIndex: Int, headPoint: SIMD3<Float>) {
        let lead = Float(Self.streamLead), pour = Float(pourDuration), cut = Float(Self.streamCut)
        guard clock > 0, clock < lead + pour + cut else { return }
        let nozzleHeight = geometry.top + 0.05
        func handPoint(_ time: Float) -> SIMD3<Float> {
            let t = min(max(time, 0), 1)
            var i = 0
            while i + 1 < path.count, path[i + 1].time <= t { i += 1 }
            guard i + 1 < path.count else { return geometry.points[i] }
            let t0 = path[i].time, t1 = path[i + 1].time
            let x = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            return geometry.points[i] + (geometry.points[i + 1] - geometry.points[i]) * x
        }
        let hand = (clock - lead) / pour
        let landing: SIMD3<Float>
        if hand <= 0 {
            landing = geometry.points[0]
        } else {
            landing = headIndex >= 0 ? headPoint : geometry.points[0]
        }
        let above = handPoint(hand + 0.035)
        var top = SIMD3<Float>(above.x, nozzleHeight, above.z)
        var bottom = landing + geometry.normals[max(headIndex, 0)] * (halfWidth * 0.3)
        var radius = halfWidth * 0.62
        if clock < lead {
            let fall = Ease.inQuad(clock / lead)
            bottom = top + (bottom - top) * fall
        } else if clock > lead + pour {
            let x = Ease.clamp01((clock - lead - pour) / cut)
            top = top + (bottom - top) * Ease.inQuad(x)
            radius *= 1 - 0.5 * x
        }
        let axis = top - bottom
        guard simd_length(axis) > 0.0005 else { return }
        var reference = SIMD3<Float>(1, 0, 0)
        if abs(simd_dot(simd_normalize(axis), reference)) > 0.9 { reference = [0, 0, 1] }
        for j in 0...Self.strandRings {
            let s = Float(j) / Float(Self.strandRings)
            let horizontal = s * s
            let p = SIMD3<Float>(bottom.x + (top.x - bottom.x) * horizontal, bottom.y + axis.y * s,
                                 bottom.z + (top.z - bottom.z) * horizontal)
            let ds: Float = 1 / Float(Self.strandRings)
            let tangent = SIMD3<Float>((top.x - bottom.x) * 2 * s * ds, axis.y * ds, (top.z - bottom.z) * 2 * s * ds)
            let t = simd_normalize(tangent)
            let side = simd_normalize(simd_cross(t, reference))
            let up = simd_cross(side, t)
            let r = radius * (1 - 0.5 * s) * smoothstep(1.0, 0.9, s).squareRoot()
            emit(Ring(center: p, side: side, up: up, along: t, a: max(r, 1e-5), h: max(r, 1e-5), round: true))
        }
        stitch(rings: Self.strandRings + 1)
    }
}
