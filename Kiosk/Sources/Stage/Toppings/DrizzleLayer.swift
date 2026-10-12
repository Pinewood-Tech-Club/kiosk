import Accelerate
import RealityKit
import UIKit

struct DrizzleStyle {
    let name: String
    var color: UIColor
    /// Where it thins out: the ribbon's rims, the drips and the falling strand.
    var thinColor: UIColor
    /// Width of the settled ribbon, meters.
    var width: Float
    /// 0 runny to 1 thick: thicker syrup stands taller, pours a little slower and drips shorter and slower.
    var viscosity: Float
    /// 0 satin to 1 wet glass.
    var gloss: Float
    /// 0 to 1: how many drips run down the sides and how far.
    var dripTendency: Float

    static let chocolate = DrizzleStyle(name: "chocolate",
                                        color: UIColor(red: 0.085, green: 0.03, blue: 0.017, alpha: 1),
                                        thinColor: UIColor(red: 0.36, green: 0.15, blue: 0.075, alpha: 1),
                                        width: 0.0066, viscosity: 0.45, gloss: 1, dripTendency: 0.9)
    static let caramel = DrizzleStyle(name: "caramel",
                                      color: UIColor(red: 0.5, green: 0.21, blue: 0.04, alpha: 1),
                                      thinColor: UIColor(red: 0.86, green: 0.52, blue: 0.17, alpha: 1),
                                      width: 0.0068, viscosity: 0.75, gloss: 0.95, dripTendency: 0.5)

    var iconLift: CGFloat { name == "chocolate" ? 0.22 : 0.08 }
}

extension DrizzleStyle {
    @MainActor private static var materials: [String: PhysicallyBasedMaterial] = [:]

    @MainActor var material: PhysicallyBasedMaterial {
        if let cached = Self.materials[name] { return cached }
        var material = PhysicallyBasedMaterial()
        if let ramp = thicknessRamp(lift: 0) {
            material.baseColor = .init(texture: .init(ramp))
        } else {
            material.baseColor = .init(tint: color)
        }
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.24 - 0.12 * gloss)
        material.specular = .init(floatLiteral: 0.45)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.05 - 0.035 * gloss)
        Self.materials[name] = material
        return material
    }

    /// For the card icon: a little warmer in the body so it reads against the dark card, with a glassier reflection.
    @MainActor var iconMaterial: PhysicallyBasedMaterial {
        let key = name + "-icon"
        if let cached = Self.materials[key] { return cached }
        var material = PhysicallyBasedMaterial()
        if let ramp = thicknessRamp(lift: iconLift) {
            material.baseColor = .init(texture: .init(ramp))
        } else {
            material.baseColor = .init(tint: color)
        }
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.07)
        material.specular = .init(floatLiteral: 0.5)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.01)
        Self.materials[key] = material
        return material
    }

    /// Base color by the syrup's depth, read through the mesh's u coordinate; `lift` moves the thick end toward the
    /// thin color.
    @MainActor private func thicknessRamp(lift: CGFloat) -> TextureResource? {
        var thin: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var thick: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        thinColor.getRed(&thin.0, green: &thin.1, blue: &thin.2, alpha: &thin.3)
        color.getRed(&thick.0, green: &thick.1, blue: &thick.2, alpha: &thick.3)
        let width = 64
        var pixels = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let t = CGFloat(smoothstep(0, 0.4, Float(x) / Float(width - 1)))
            for (c, (a, b)) in [(thin.0, thick.0), (thin.1, thick.1), (thin.2, thick.2)].enumerated() {
                let body = b + (a - b) * lift
                pixels[x * 4 + c] = UInt8(max(0, min(255, ((a + (body - a) * t) * 255).rounded())))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }
}

/// Syrup squeezed over the top in a criss-crossing zigzag, with drips down the sides. The path is kept in
/// coordinates relative to the surface's apex and radius, so it can be laid back onto any surface beneath it.
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
    private var angle: Float = 0
    private weak var camera: Entity?
    private var streamBounds: (SIMD3<Float>, SIMD3<Float>)?
    private var removeStart: Double?
    private var animationEnd: Double = -.infinity
    private var mesh: LowLevelMesh?
    private var scratch: MeshScratch?
    /// Leading ribbon rings that have settled and are still in `scratch` from the last build.
    private var settledRings = 0
    /// Once the pour has finished, resurfacing and draining only move vertices, so they blend two prebuilt meshes.
    private var blend: Blend?

    private static let ringSides = 10
    private static let floatsPerVertex = 8
    private static let capRings = 4
    private static let dripRings = 15
    private static let dripPathPoints = 28
    private static let strandRings = 22
    private static let streamLead: Double = 0.12
    private static let streamCut: Double = 0.14
    /// Every drip has finished running this long after the pour.
    private static let dripTail: Float = 0.1
    /// Seconds the syrup takes to fall from the top of the screen, which sets how far the strand lags the hand.
    private static let fallTime: Float = 0.025
    /// World meters past the top edge of the screen that the strand starts, so its end is never seen.
    private static let skyMargin: Float = 0.03
    private static let removeDuration: Double = 0.5
    private static let nozzleHeight: Float = 0.017
    nonisolated private static let crown: Float = 0.6
    /// Per vertex of the ribbon's cross-section: x across the width, height, its slope, and 1 on the top face.
    private static let ribbonTable: [Float] = {
        var table: [Float] = []
        for k in 0...8 {
            let x = cos(Float.pi * Float(k) / 8)
            table += [x, crownShape(x), crownSlope(x), 1]
        }
        table += [0, 0, 0, 0]
        return table
    }()
    private static let roundTable: [Float] = {
        var table: [Float] = []
        for k in 0..<ringSides {
            let angle = 2 * Float.pi * Float(k) / Float(ringSides)
            table += [cos(angle), sin(angle)]
        }
        return table
    }()

    var growDuration: Double { Self.streamLead + pourDuration }
    var removeDuration: Double { Self.removeDuration }
    private var pourDuration: Double { 0.86 + 0.16 * Double(style.viscosity) }
    private var settleDuration: Float { 0.14 + 0.16 * style.viscosity }
    private var halfWidth: Float { style.width / 2 }
    private var lateralReach: Float { halfWidth * 1.6 }

    init(style: DrizzleStyle = .chocolate) {
        self.style = style
        entity = model
        model.name = "drizzle-\(style.name)"
    }

    /// The topping card's icon: a glossy pool of syrup just poured, still rising where the stream lands, with rings
    /// running out from there and the last thread of the pour stretching up from it. Real size, resting on y = 0.
    /// Needs the stage's lighting.
    static func makeIcon(style: DrizzleStyle = .chocolate, seed: UInt64 = 11) -> Entity {
        var rng = ToppingRandom(seed: seed)
        let root = Entity()
        root.name = "drizzle-icon"
        let pool = IconPool(rng: &rng)
        for part in [pool.mesh(), IconThread(base: pool.height(0, 0)).mesh()] {
            guard let mesh = try? MeshResource.generate(from: [part]) else { continue }
            root.addChild(ModelEntity(mesh: mesh, materials: [style.iconMaterial]))
        }
        return root
    }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        var rng = ToppingRandom(seed: seed)
        (path, angle) = Self.makePath(radius: max(surface.radius, 0.01), across: (surface as? DrizzleCoverSurface)?.angle, rng: &rng)
        drips = makeDrips(rng: &rng)
        resting = project(onto: surface)
        shift = nil
        removeStart = nil
        blend = nil
        isFinished = false
        settledRings = 0
        pourStart = animated ? now : now - 100
        let lead = Self.streamLead, pour = pourDuration
        animationEnd = drips.reduce(pourStart + lead + pour + max(Self.streamCut, Double(settleDuration))) { end, drip in
            max(end, pourStart + lead + Double(path[drip.origin].time) * pour + Double(drip.delay + drip.duration))
        }
        makeMesh()
        model.isEnabled = true
        model.setOpacity(1)
        build(now: now)
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        guard !path.isEmpty else { return }
        let target = project(onto: surface)
        settledRings = 0
        if blend?.drains == false { blend = nil }
        if duration <= 0 {
            resting = target
            shift = nil
        } else {
            let from = projection(at: now)
            shift = (from: from, to: target, start: now, duration: duration)
            if blend == nil, removeStart == nil, now >= animationEnd {
                startBlend(to: target, drain: 0, now: now, duration: duration, drains: false,
                           lower: simd_min(from.lower, target.lower), upper: simd_max(from.upper, target.upper))
            }
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
        settledRings = 0
        if blend == nil, shift == nil, now >= animationEnd {
            let geometry = projection(at: now)
            startBlend(to: geometry, drain: 1, now: now, duration: Self.removeDuration, drains: true,
                       lower: geometry.lower, upper: geometry.upper)
        }
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
            if blend?.drains == false { blend = nil }
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
            let (a, h) = profile(i, normal: projection.normals[i], pool: projection.pools[i], age: .infinity)
            points.append([projection.points[i].x, projection.points[i].z])
            widths.append(a)
            heights.append(h * 0.92)
        }
        return DrizzleCoverSurface(below: below, points: points, halfWidths: widths, heights: heights, angle: angle)
    }
}

private struct IconMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    mutating func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>, shade: Float) {
        positions.append(p)
        normals.append(simd_normalize(n))
        // Kept off the ends: the ramp texture repeats, so u = 1 samples a blend with the thin end.
        uvs.append([0.02 + 0.96 * shade, 0.5])
    }

    mutating func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        indices += [a, b, c, b, d, c].map(UInt32.init)
    }

    var descriptor: MeshDescriptor {
        var descriptor = MeshDescriptor(name: "drizzle-icon")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }
}

/// A puddle with a rounded edge that thins to the warm color at its rim, a soft mound where the stream lands
/// and rings running out from it.
private struct IconPool {
    let radius: Float = 0.0165
    let depth: Float = 0.0016
    let phase: Float

    init(rng: inout ToppingRandom) {
        phase = Float.random(in: 0..<(2 * .pi), using: &rng)
    }

    func edge(_ angle: Float) -> Float {
        radius * (1 + 0.06 * sin(3 * angle + phase) + 0.035 * sin(5 * angle + 2 * phase) + 0.02 * sin(9 * angle - phase))
    }

    func height(_ r: Float, _ angle: Float) -> Float {
        let rho = min(r / edge(angle), 1)
        let calm = 1 - pow(rho, 4)
        let mound = 0.0021 * exp(-pow(r / 0.0034, 2))
        let fold = 0.00055 * exp(-pow((r - 0.0042) / 0.0013, 2)) * (1 + 0.3 * sin(2 * angle + phase))
        let rings = 0.00014 * sin((r - 0.0035) / 0.0026 * 2 * .pi) * smoothstep(0.003, 0.006, r) * exp(-r / 0.008)
        return depth * (1 - pow(rho, 6)).squareRoot() + (mound + fold + rings) * calm
    }

    func mesh() -> MeshDescriptor {
        var mesh = IconMesh()
        let rings = 48, sides = 128
        let e: Float = 0.00005
        mesh.add([0, height(0, 0), 0], [0, 1, 0], shade: 1)
        for i in 1...rings {
            let x = Float(i) / Float(rings)
            let rho = 1 - pow(1 - x, 1.7)
            for k in 0..<sides {
                let angle = Float(k) / Float(sides) * 2 * .pi
                let r = rho * edge(angle)
                let dr = (height(r + e, angle) - height(max(r - e, 0), angle)) / (2 * e)
                let da = (height(r, angle + 0.002) - height(r, angle - 0.002)) / (0.004 * max(r, 1e-4))
                let radial = SIMD3<Float>(cos(angle), 0, sin(angle)), tangent = SIMD3<Float>(-sin(angle), 0, cos(angle))
                let normal = i == rings ? radial : SIMD3<Float>(0, 1, 0) - radial * dr - tangent * da
                mesh.add(radial * r + [0, height(r, angle), 0], normal, shade: 0.03 + 0.97 * (1 - smoothstep(0.8, 1, rho)))
            }
        }
        for k in 0..<sides {
            mesh.indices += [0, UInt32(1 + k), UInt32(1 + (k + 1) % sides)]
        }
        for i in 1..<rings {
            for k in 0..<sides {
                let a = 1 + (i - 1) * sides + k, b = 1 + (i - 1) * sides + (k + 1) % sides
                mesh.quad(a, b, a + sides, b + sides)
            }
        }
        return mesh.descriptor
    }
}

/// The last of the stream, stretching up from the pool and swaying as it thins to a hair while the bottle lifts away.
private struct IconThread {
    let base: Float
    let height: Float = 0.026

    func mesh() -> MeshDescriptor {
        var mesh = IconMesh()
        let steps = 80, sides = 20
        func radius(_ y: Float) -> Float {
            let x = Ease.clamp01(y / height)
            return 0.0007 * pow(1 - x, 1.3) + 0.00005 + 0.0009 * exp(-y / 0.0006)
        }
        func center(_ y: Float) -> SIMD3<Float> {
            let x = y / height
            return [0.0016 * sin(x * 3.6) * x, base - 0.0012 + y, -0.0006 * x * x]
        }
        for j in 0...steps {
            let y = height * pow(Float(j) / Float(steps), 1.4)
            let r = radius(y)
            let slope = (radius(y + 0.00005) - radius(max(y - 0.00005, 0))) / 0.0001
            for k in 0..<sides {
                let angle = Float(k) / Float(sides) * 2 * .pi
                let radial = SIMD3<Float>(cos(angle), 0, sin(angle))
                mesh.add(center(y) + radial * r, radial - SIMD3<Float>(0, 1, 0) * slope, shade: 0.06 + 0.1 * (1 - y / height))
            }
        }
        let tip = mesh.positions.count
        mesh.add(center(height) + [0, 0.0001, 0], [0, 1, 0], shade: 0.06)
        for j in 0..<steps {
            for k in 0..<sides {
                let a = j * sides + k, b = j * sides + (k + 1) % sides
                mesh.quad(a, a + sides, b, b + sides)
            }
        }
        for k in 0..<sides {
            mesh.indices += [UInt32(steps * sides + k), UInt32(tip), UInt32(steps * sides + (k + 1) % sides)]
        }
        return mesh.descriptor
    }
}

private struct PathSample {
    /// Offset from the apex in units of the surface radius.
    var q: SIMD2<Float>
    /// When the stream lands here, as a fraction of the pour.
    var time: Float
    /// Width factor: syrup piles up where the hand slows in a turn, and the squeeze is never quite even.
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
    var sides: [SIMD3<Float>]
    /// Surface offset along the normal at `lateralReach` to the left (x) and right (y), so the ribbon's rims
    /// follow the scoop across its width.
    var lifts: [SIMD2<Float>]
    /// Curvature of the path toward `sides`, 1/m.
    var bends: [Float]
    var pools: [Float]
    var drips: [DripPath]
    var top: Float
    var lower: SIMD3<Float>
    var upper: SIMD3<Float>
}

private struct DrizzleCoverSurface: ToppingSurface {
    let below: ToppingSurface
    let points: [SIMD2<Float>]
    let halfWidths: [Float]
    let heights: [Float]
    /// The main direction of the zigzag on top, so a second syrup can cross it.
    let angle: Float
    private let cells: [SIMD2<Int32>: [Int32]]
    private static let cell: Float = 0.005

    init(below: ToppingSurface, points: [SIMD2<Float>], halfWidths: [Float], heights: [Float], angle: Float) {
        self.below = below
        self.points = points
        self.halfWidths = halfWidths
        self.heights = heights
        self.angle = angle
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
                    best = max(best, heights[Int(i)] * DrizzleLayer.crownShape(d / a))
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
    var floor: Float { below.floor }
    func softness(x: Float, z: Float) -> Float { below.softness(x: x, z: z) }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = Ease.clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

private extension DrizzleLayer {
    nonisolated static func crownShape(_ x: Float) -> Float {
        let x2 = x * x
        return max(0, (1 - x2) * (1 + crown * x2))
    }

    nonisolated static func crownSlope(_ x: Float) -> Float {
        -2 * x * (1 - crown) - 4 * crown * x * x * x
    }

    struct Pass {
        var a: SIMD2<Float>
        var mid: SIMD2<Float>
        var b: SIMD2<Float>
        var pace: Float
    }

    static func sweep(count: Int, span: Float, rng: inout ToppingRandom) -> [Pass] {
        let step = 2 * span / Float(count - 1)
        var passes: [Pass] = []
        var previousEnd: Float = -.infinity
        for k in 0..<count {
            let v = -span + Float(k) * step + Float.random(in: -0.15...0.15, using: &rng) * step
            let dir: Float = k % 2 == 0 ? 1 : -1
            let tilt = Float.random(in: -0.45...0.45, using: &rng) * step
            var a = SIMD2<Float>(0, v - tilt / 2), b = SIMD2<Float>(0, v + tilt / 2)
            let gap = a.y - previousEnd
            if gap < 0.7 * step {
                a.y += 0.7 * step - gap
                b.y += 0.7 * step - gap
            }
            previousEnd = b.y
            a.x = -dir * max(0.3, 1 - a.y * a.y).squareRoot() * Float.random(in: 1.08...1.3, using: &rng)
            b.x = dir * max(0.3, 1 - b.y * b.y).squareRoot() * Float.random(in: 1.08...1.3, using: &rng)
            let mid = (a + b) / 2 + [0, Float.random(in: -0.35...0.35, using: &rng) * step]
            passes.append(Pass(a: a, mid: mid, b: b, pace: Float.random(in: 0.85...1.15, using: &rng)))
        }
        return passes
    }

    static func transformed(_ passes: [Pass], flip: SIMD2<Float>, angle: Float) -> [Pass] {
        let c = cos(angle), s = sin(angle)
        func map(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let f = p * flip
            return [c * f.x - s * f.y, s * f.x + c * f.y]
        }
        return passes.map { Pass(a: map($0.a), mid: map($0.mid), b: map($0.b), pace: $0.pace) }
    }

    /// The samples, and the direction the main passes run along.
    static func makePath(radius: Float, across: Float?, rng: inout ToppingRandom) -> ([PathSample], Float) {
        var angle = Float.random(in: 0..<(2 * .pi), using: &rng)
        if let across { angle = across + .pi / 2 + (angle / (2 * .pi) - 0.5) * 0.5 }
        let countA = Int.random(in: 4...5, using: &rng)
        var passes = transformed(sweep(count: countA, span: countA == 5 ? 0.72 : 0.62, rng: &rng),
                                 flip: [Bool.random(using: &rng) ? 1 : -1, 1], angle: angle)
        let countB = Int.random(in: 2...3, using: &rng)
        let local = sweep(count: countB, span: countB == 3 ? 0.46 : 0.32, rng: &rng)
        let crossing = angle + (Bool.random(using: &rng) ? 1 : -1) * Float.random(in: 0.95...1.3, using: &rng)
        let end = passes[passes.count - 1].b
        var second: [Pass] = []
        var nearest = Float.greatestFiniteMagnitude
        for flip: SIMD2<Float> in [[1, 1], [-1, 1], [1, -1], [-1, -1]] {
            let candidate = transformed(local, flip: flip, angle: crossing)
            let d = simd_length(candidate[0].a - end)
            if d < nearest {
                nearest = d
                second = candidate
            }
        }
        passes += second

        var dense: [(q: SIMD2<Float>, speed: Float)] = []
        for (k, pass) in passes.enumerated() {
            let count = 64
            for j in 0..<count {
                let x = Float(j) / Float(count)
                let p = quadraticBezier([pass.a.x, pass.a.y, 0], [pass.mid.x, pass.mid.y, 0], [pass.b.x, pass.b.y, 0], x)
                dense.append(([p.x, p.y], pass.pace * (1 + 0.25 * sin(.pi * x))))
            }
            guard k + 1 < passes.count else {
                dense.append((pass.b, pass.pace))
                break
            }
            let next = passes[k + 1]
            let out = simd_normalize(pass.b - pass.mid), into = simd_normalize(next.mid - next.a)
            let handle = 0.6 * simd_length(next.a - pass.b) + 0.08
            let c0 = pass.b + out * handle, c1 = next.a - into * handle
            let turnCount = 28
            for j in 0..<turnCount {
                let x = Float(j) / Float(turnCount)
                let p = cubicBezier([pass.b.x, pass.b.y, 0], [c0.x, c0.y, 0], [c1.x, c1.y, 0], [next.a.x, next.a.y, 0], x)
                let mid = abs(2 * x - 1)
                dense.append(([p.x, p.y], 0.5 + 0.5 * mid * mid))
            }
        }

        let f1 = Float.random(in: 2...3, using: &rng), f2 = Float.random(in: 3...4.5, using: &rng)
        let p1 = Float.random(in: 0..<(2 * .pi), using: &rng), p2 = Float.random(in: 0..<(2 * .pi), using: &rng)
        for i in dense.indices {
            let x = Float(i) / Float(dense.count) * 2 * .pi
            var q = dense[i].q + 0.022 * SIMD2(sin(f1 * x + p1), sin(f2 * x + p2))
            let r = simd_length(q)
            if r > 1.2 { q *= (1.2 + 0.12 * tanh((r - 1.2) / 0.12)) / r }
            dense[i].q = q
        }

        let spacingUnit = 0.0012 / radius
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
        let n1 = Float.random(in: 0..<(2 * .pi), using: &rng), n2 = Float.random(in: 0..<(2 * .pi), using: &rng)
        let last = Float(samples.count - 1)
        for i in samples.indices {
            samples[i].time /= total
            let arc = Float(i) * spacingUnit
            let squeeze = 1 + 0.12 * sin(arc / 0.21 + n1) + 0.07 * sin(arc / 0.083 + n2)
            let dollop = 1 + 0.4 * exp(-Float(i) / 4)
            let tail = 1 - 0.4 * (1 - smoothstep(0, 12, last - Float(i)))
            samples[i].flow = min(max(pow(samples[i].flow, -0.5), 0.85), 1.3) * squeeze * dollop * tail
        }
        return (samples, angle)
    }

    /// Drips start where the hand turned past the rim, favoring the side that faces the camera at rest.
    func makeDrips(rng: inout ToppingRandom) -> [DripSpec] {
        let window = 10
        guard path.count > 2 * window + 1 else { return [] }
        var tips: [(index: Int, score: Float, angle: Float)] = []
        for i in window..<(path.count - window) {
            let r = simd_length(path[i].q)
            guard r > 0.78 else { continue }
            var peak = true
            for j in (i - window)...(i + window) where j != i && simd_length(path[j].q) > r {
                peak = false
                break
            }
            guard peak else { continue }
            let front = path[i].q.y / r
            tips.append((i, r + 0.35 * front + Float.random(in: 0...0.3, using: &rng), atan2(path[i].q.y, path[i].q.x)))
        }
        tips.sort { $0.score > $1.score }
        let wanted = 3 + Int(Float.random(in: 0...0.999, using: &rng) * 4 * style.dripTendency)
        var chosen: [(index: Int, score: Float, angle: Float)] = []
        for tip in tips where chosen.count < wanted {
            let apart = chosen.allSatisfy { other in
                let d = abs(remainder(tip.angle - other.angle, 2 * .pi))
                return d > 0.45
            }
            if apart { chosen.append(tip) }
        }
        chosen.sort { $0.index < $1.index }
        let reach = 0.6 + 0.5 * style.dripTendency
        let slow = 0.25 + 0.3 * style.viscosity
        let lead = Float(Self.streamLead), pour = Float(pourDuration)
        return chosen.map { tip in
            let length = Float.random(in: 0.009...0.022, using: &rng) * reach
            let delay = Float.random(in: 0.02...0.1, using: &rng)
            let left = lead + pour + Self.dripTail - (lead + path[tip.index].time * pour + delay)
            let duration = slow * Float.random(in: 0.8...1.1, using: &rng) + length * 12
            return DripSpec(origin: tip.index, length: length, delay: delay,
                            duration: max(0.22, min(duration, left)),
                            halfWidth: style.width * Float.random(in: 0.36...0.42, using: &rng),
                            meander: Float.random(in: -0.2...0.2, using: &rng),
                            phase: Float.random(in: 0..<(2 * .pi), using: &rng))
        }
    }

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

    /// The middle of the top as it looks: a leaning scoop's highest point sits off toward one side, so the
    /// pattern centers on the part of the scoop near the top instead.
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

    static let limitDirections = 64

    /// How far out, in units of the radius, the surface goes in each direction before it drops away or turns
    /// steeper than about 80°.
    static func reachLimits(_ surface: ToppingSurface, center: SIMD2<Float>, radius: Float) -> [Float] {
        let step: Float = 0.0005
        return (0..<limitDirections).map { k in
            let angle = Float(k) / Float(limitDirections) * 2 * .pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var r: Float = 0
            var previous = surface.sample(x: center.x, z: center.y)?.height ?? surface.apex.y
            while r < radius * 1.6 {
                let next = r + step
                let q = center + direction * next
                guard let hit = surface.sample(x: q.x, z: q.y), previous - hit.height < 5.7 * step else { break }
                previous = hit.height
                r = next
            }
            return max(r / radius, 0.3)
        }
    }

    static func fitted(_ q: SIMD2<Float>, _ limits: [Float]) -> SIMD2<Float> {
        let r = simd_length(q)
        guard r > 1e-5 else { return q }
        var angle = atan2(q.y, q.x)
        if angle < 0 { angle += 2 * .pi }
        let position = angle / (2 * .pi) * Float(limitDirections)
        let k = Int(position) % limitDirections, x = position - Float(Int(position))
        let limit = limits[k] + (limits[(k + 1) % limitDirections] - limits[k]) * x
        let knee = 0.6 * limit
        guard r > knee else { return q }
        return q * ((knee + (limit - knee) * tanh((r - knee) / (limit - knee))) / r)
    }

    func project(onto surface: ToppingSurface, withDrips: Bool = true) -> Projection {
        let radius = max(surface.radius, 0.01)
        let center = Self.crownCenter(surface, radius: radius)
        let count = path.count
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        normals.reserveCapacity(count)
        let limits = Self.reachLimits(surface, center: center, radius: radius)
        for q in Self.smoothed(path.map { Self.fitted($0.q, limits) }, reach: 4) {
            let (p, n) = Self.probe(surface, center + q * radius, center: center)
            points.append(p)
            normals.append(n)
        }
        let raw = points
        smoothAlongPath(&points, &normals)

        var sides: [SIMD3<Float>] = []
        var lifts: [SIMD2<Float>] = []
        var pools: [Float] = []
        sides.reserveCapacity(count)
        lifts.reserveCapacity(count)
        pools.reserveCapacity(count)
        let reach = lateralReach
        for i in 0..<count {
            let p = points[i], n = normals[i]
            let side = frame(points[min(i + 1, count - 1)] - points[max(i - 1, 0)], n).side
            sides.append(side)
            var lift = SIMD2<Float>(repeating: .nan)
            for (k, sign) in [Float(-1), 1].enumerated() {
                let q = p + side * (sign * reach)
                if let hit = surface.sample(x: q.x, z: q.z) {
                    lift[k] = min(max(simd_dot(SIMD3(q.x, hit.height, q.z) - p, n), -0.25 * reach), 0.15 * reach)
                }
            }
            if lift.x.isNaN { lift.x = lift.y.isNaN ? -0.25 * reach : lift.y }
            if lift.y.isNaN { lift.y = lift.x }
            lifts.append(lift)
            var around: Float = 0, found: Float = 0
            for offset: SIMD2<Float> in [[0.004, 0], [-0.004, 0], [0, 0.004], [0, -0.004]] {
                if let hit = surface.sample(x: raw[i].x + offset.x, z: raw[i].z + offset.y) {
                    around += hit.height
                    found += 1
                }
            }
            pools.append(found < 4 ? 0 : smoothstep(-0.0002, 0.0004, around / found - raw[i].y))
        }
        lifts = Self.smoothed(lifts, reach: 5)
        var bends: [Float] = (0..<count).map { i in
            let p0 = points[max(i - 4, 0)], p1 = points[i], p2 = points[min(i + 4, count - 1)]
            let d1 = p1 - p0, d2 = p2 - p1, chord = simd_length(p2 - p0)
            guard simd_length(d1) > 1e-6, simd_length(d2) > 1e-6, chord > 1e-6 else { return 0 }
            return simd_dot(simd_normalize(d2) - simd_normalize(d1), sides[i]) / (0.5 * chord)
        }
        bends = Self.smoothed(bends.map { SIMD2($0, 0) }, reach: 2).map(\.x)
        pools = Self.smoothed(pools.map { SIMD2($0, 0) }, reach: 4).map(\.x)

        let dripPaths = withDrips
            ? drips.map { march($0, from: points[$0.origin], on: surface, center: center, radius: radius) }
            : []
        var lower = points[0], upper = points[0]
        for p in points {
            lower = simd_min(lower, p)
            upper = simd_max(upper, p)
        }
        for drip in dripPaths {
            for p in drip.points {
                lower = simd_min(lower, p)
                upper = simd_max(upper, p)
            }
        }
        let pad = SIMD3<Float>(repeating: halfWidth * 3)
        upper.y = max(upper.y, surface.apex.y + Self.nozzleHeight)
        return Projection(points: points, normals: normals, sides: sides, lifts: lifts, bends: bends, pools: pools, drips: dripPaths,
                          top: surface.apex.y, lower: lower - pad, upper: upper + pad)
    }

    static func smoothed(_ values: [SIMD2<Float>], reach: Int) -> [SIMD2<Float>] {
        let count = values.count
        guard count > 2 * reach else { return values }
        return (0..<count).map { i in
            var sum = SIMD2<Float>.zero
            var weight: Float = 0
            for j in max(0, i - reach)...min(count - 1, i + reach) {
                let w = Float(reach + 1 - abs(j - i))
                sum += values[j] * w
                weight += w
            }
            return sum / weight
        }
    }

    /// Evens out a bumpy surface along the ribbon (frilled scoop edges) so it drapes instead of crinkling,
    /// without letting it sink far into the bumps.
    func smoothAlongPath(_ points: inout [SIMD3<Float>], _ normals: inout [SIMD3<Float>]) {
        let count = points.count, reach = 3
        guard count > 2 * reach else { return }
        let raw = points, rawNormals = normals
        let sink: Float = 0.0004
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

    /// Runs a drip downhill from `start` along the surface until it reaches its length, settles on a ledge or
    /// runs off the surface, resampled to evenly spaced points.
    func march(_ drip: DripSpec, from start: SIMD3<Float>, on surface: ToppingSurface, center: SIMD2<Float>, radius: Float) -> DripPath {
        let step: Float = 0.0003
        var xz = SIMD2<Float>(start.x, start.z)
        var (p, n) = Self.probe(surface, xz, center: center)
        var raw: [(p: SIMD3<Float>, n: SIMD3<Float>, arc: Float)] = [(p, n, 0)]
        var arc: Float = 0
        var guardCount = 0
        while arc < drip.length, guardCount < 800 {
            guardCount += 1
            let outward = simd_length(xz - center) > 1e-5 ? simd_normalize(xz - center) : SIMD2<Float>(1, 0)
            let downhill = SIMD2<Float>(n.x, n.z)
            var dir = simd_length(downhill) > 0.05 ? simd_normalize(downhill) : outward
            dir = simd_normalize(dir * 0.75 + outward * 0.25)
            dir += SIMD2(-dir.y, dir.x) * drip.meander * sin(drip.phase + arc / 0.004)
            dir = simd_normalize(dir)
            let next = xz + dir * step * max(n.y, 0.12)
            guard simd_length(next - center) < radius * 1.6, let hit = surface.sample(x: next.x, z: next.y),
                  p.y - hit.height < 0.002 else { break }
            let q = SIMD3<Float>(next.x, hit.height, next.y)
            arc += simd_length(q - p)
            xz = next
            p = q
            let wasSteep = n.y < 0.7
            n = simd_normalize(hit.normal)
            raw.append((p, n, arc))
            if wasSteep, n.y > 0.88 { break }
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
        func mix(_ p: [SIMD3<Float>], _ q: [SIMD3<Float>]) -> [SIMD3<Float>] { zip(p, q).map { $0 + ($1 - $0) * x } }
        func mixUnit(_ p: [SIMD3<Float>], _ q: [SIMD3<Float>]) -> [SIMD3<Float>] {
            zip(p, q).map { simd_normalize($0 + ($1 - $0) * x) }
        }
        let drips = zip(a.drips, b.drips).map { from, to in
            DripPath(points: mix(from.points, to.points), normals: mixUnit(from.normals, to.normals),
                     length: from.length + (to.length - from.length) * x)
        }
        return Projection(points: mix(a.points, b.points), normals: mixUnit(a.normals, b.normals),
                          sides: mixUnit(a.sides, b.sides),
                          lifts: zip(a.lifts, b.lifts).map { $0 + ($1 - $0) * x },
                          bends: zip(a.bends, b.bends).map { $0 + ($1 - $0) * x },
                          pools: zip(a.pools, b.pools).map { $0 + ($1 - $0) * x },
                          drips: drips, top: a.top + (b.top - a.top) * x,
                          lower: simd_min(a.lower, b.lower), upper: simd_max(a.upper, b.upper))
    }

    /// Half width and height of the ribbon at sample `i`: narrow and tall as it lands, then spreading flat;
    /// wider in hollows and on the flat crown, thinner where it runs over a steep shoulder.
    func profile(_ i: Int, normal n: SIMD3<Float>, pool: Float, age: Float) -> (Float, Float) {
        let flat = smoothstep(0.8, 0.98, n.y)
        let upright = smoothstep(0.1, 0.65, n.y)
        let fresh = 1 - smoothstep(0, settleDuration, age)
        let spread = (1 + 0.15 * flat + 0.3 * pool) * (0.62 + 0.38 * upright)
        let a = min(halfWidth * path[i].flow * spread, halfWidth * 1.6) * (1 - 0.32 * fresh)
        let settled = 0.32 + 0.16 * style.viscosity
        let ratio = (settled + (0.85 - settled) * fresh) * (1 + 0.1 * pool) * (0.85 + 0.15 * upright)
        return (a, a * ratio)
    }

    func makeMesh() {
        let rings = (path.count + 2 * Self.capRings + 2) + drips.count * (Self.dripRings + 1) + (Self.strandRings + 1 + 2 * Self.capRings)
        let vertexCount = rings * Self.ringSides
        let indexCount = rings * Self.ringSides * 6
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: 24),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: [.init(bufferIndex: 0, bufferStride: Self.floatsPerVertex * 4)],
                                                 indexCapacity: indexCount, indexType: .uint32)
        guard let mesh = try? LowLevelMesh(descriptor: descriptor), let resource = try? MeshResource(from: mesh) else { return }
        self.mesh = mesh
        scratch = MeshScratch(floats: vertexCount * Self.floatsPerVertex, indices: indexCount)
        model.model = ModelComponent(mesh: resource, materials: [style.material])
    }

    struct Ring {
        var center: SIMD3<Float>
        var side: SIMD3<Float>
        var up: SIMD3<Float>
        var along: SIMD3<Float>
        var a: Float
        var h: Float
        var lift = SIMD2<Float>(0, 0)
        /// Curvature toward `side`; the inside of a tight turn is pulled in so the strip doesn't fold over itself.
        var bend: Float = 0
        /// Scales the cross-section without changing its normals, for rounded ends.
        var scale: Float = 1
        /// Tilts normals along the strip where its width changes (caps, the drip's bulb).
        var lean: Float = 0
        var round = false
        /// Base color coordinate of a round ring: low is the thin, warm color.
        var shade: Float = 0.3
    }

    func emit(_ ring: Ring) {
        guard let scratch, scratch.floatCount + Self.ringSides * Self.floatsPerVertex <= scratch.floatCapacity else { return }
        var out = scratch.floats + scratch.floatCount
        scratch.floatCount += Self.ringSides * Self.floatsPerVertex
        let a: Float = ring.a > 1e-6 ? ring.a : 1e-6, h: Float = ring.h > 1e-6 ? ring.h : 1e-6, scale = ring.scale
        let cx = ring.center.x, cy = ring.center.y, cz = ring.center.z
        let sx = ring.side.x, sy = ring.side.y, sz = ring.side.z
        let ux = ring.up.x, uy = ring.up.y, uz = ring.up.z
        let lx = ring.along.x * ring.lean, ly = ring.along.y * ring.lean, lz = ring.along.z * ring.lean
        let leans = ring.lean != 0
        let round = ring.round
        let reach = lateralReach
        let tilt = (ring.lift.y - ring.lift.x) * 0.5 / reach
        let bend = (ring.lift.y + ring.lift.x) / (reach * reach)
        let depth = 1 / (halfWidth * 0.55)
        let right = ring.bend > 0 && 0.85 / ring.bend < a ? 0.85 / ring.bend : a
        let left = ring.bend < 0 && -0.85 / ring.bend < a ? -0.85 / ring.bend : a
        let table = round ? Self.roundTable : Self.ribbonTable
        table.withUnsafeBufferPointer { table in
            let t = table.baseAddress!
            for k in 0..<Self.ringSides {
                var px: Float, py: Float, pz: Float, nx: Float, ny: Float, nz: Float, u: Float
                if round {
                    let c = t[2 * k], s = t[2 * k + 1], r = a * scale
                    nx = sx * c + ux * s; ny = sy * c + uy * s; nz = sz * c + uz * s
                    px = cx + nx * r; py = cy + ny * r; pz = cz + nz * r
                    u = ring.shade
                } else {
                    let x = t[4 * k], a = x >= 0 ? right : left, l = x * a
                    let lift = (tilt + 0.5 * bend * l) * l
                    let lateral = l * scale
                    if t[4 * k + 3] > 0 {
                        let rise = h * t[4 * k + 1]
                        let slope = h * t[4 * k + 2] / a + tilt + bend * l
                        let normal = (rise + lift) * scale
                        let inverse = 1 / (1 + slope * slope).squareRoot()
                        px = cx + sx * lateral + ux * normal; py = cy + sy * lateral + uy * normal; pz = cz + sz * lateral + uz * normal
                        nx = (ux - sx * slope) * inverse; ny = (uy - sy * slope) * inverse; nz = (uz - sz * slope) * inverse
                        let thickness = rise * depth
                        u = 0.02 + 0.96 * (thickness < 1 ? thickness : 1)
                    } else {
                        let normal = (lift - 0.4 * h) * scale
                        px = cx + sx * lateral + ux * normal; py = cy + sy * lateral + uy * normal; pz = cz + sz * lateral + uz * normal
                        nx = -ux; ny = -uy; nz = -uz
                        u = 0.5
                    }
                }
                if leans {
                    nx += lx; ny += ly; nz += lz
                    let inverse = 1 / (nx * nx + ny * ny + nz * nz).squareRoot()
                    nx *= inverse; ny *= inverse; nz *= inverse
                }
                out.pointee = px; out[1] = py; out[2] = pz
                out[3] = nx; out[4] = ny; out[5] = nz
                out[6] = u; out[7] = 0.5
                out += Self.floatsPerVertex
            }
        }
    }

    /// Connects rings `from...to`, counted from the start of the vertex buffer.
    func stitch(from: Int, to: Int) {
        guard let scratch, to > from, scratch.indexCount + (to - from) * Self.ringSides * 6 <= scratch.indexCapacity else { return }
        let sides = Self.ringSides
        var out = scratch.indices + scratch.indexCount
        scratch.indexCount += (to - from) * sides * 6
        for r in from..<to {
            let base = UInt32(r * sides)
            for k in 0..<sides {
                let k1 = (k + 1) % sides
                let a = base + UInt32(k), b = a + UInt32(sides)
                let c = base + UInt32(k1), d = c + UInt32(sides)
                out[0] = a; out[1] = b; out[2] = c
                out[3] = b; out[4] = d; out[5] = c
                out += 6
            }
        }
    }

    /// Connects `count` rings emitted consecutively, ending at the current vertex count.
    func stitch(rings count: Int) {
        guard let scratch, count > 1 else { return }
        let last = scratch.floatCount / Self.floatsPerVertex / Self.ringSides - 1
        stitch(from: last - count + 1, to: last)
    }

    func frame(_ along: SIMD3<Float>, _ normal: SIMD3<Float>) -> (side: SIMD3<Float>, up: SIMD3<Float>, along: SIMD3<Float>) {
        var t = along - normal * simd_dot(along, normal)
        t = simd_length(t) > 1e-8 ? simd_normalize(t) : simd_normalize(simd_cross(normal, [1, 0, 0]))
        let side = simd_normalize(simd_cross(t, normal))
        return (side, normal, simd_cross(normal, side))
    }

    /// Rounds a ribbon end; the start cap is emitted tip first so the ribbon stays one strip.
    func emitCap(from ring: Ring, direction: Float) {
        for step in 1...Self.capRings {
            let k = direction < 0 ? Self.capRings + 1 - step : step
            let theta = Float(k) / Float(Self.capRings) * .pi / 2
            var r = ring
            r.center += ring.along * (direction * ring.a * 0.9 * sin(theta))
            r.scale = cos(theta)
            r.lean = k == Self.capRings ? direction * 1e4 : direction * tan(theta)
            emit(r)
        }
    }

    func startBlend(to geometry: Projection, drain: Float, now: Double, duration: Double, drains: Bool,
                    lower: SIMD3<Float>, upper: SIMD3<Float>) {
        guard let scratch else { return }
        let from = Array(UnsafeBufferPointer(start: scratch.floats, count: scratch.floatCount))
        let indexCount = scratch.indexCount
        fill(geometry, now: now, drain: drain)
        guard scratch.floatCount == from.count, scratch.indexCount == indexCount else { return }
        let to = Array(UnsafeBufferPointer(start: scratch.floats, count: scratch.floatCount))
        blend = Blend(from: from, to: to, start: now, duration: duration, drains: drains, lower: lower, upper: upper)
    }

    func build(now: Double) {
        guard mesh != nil, let scratch, !path.isEmpty else { return }
        var drain: Float = 0
        if let removeStart {
            drain = Ease.inOutSine(Ease.clamp01(Float((now - removeStart) / Self.removeDuration)))
            model.setOpacity(1 - smoothstep(0.55, 1, drain))
        }
        if let blend {
            var x = Ease.inOutSine(Ease.clamp01(Float((now - blend.start) / blend.duration)))
            blend.from.withUnsafeBufferPointer { a in
                blend.to.withUnsafeBufferPointer { b in
                    vDSP_vintb(a.baseAddress!, 1, b.baseAddress!, 1, &x, scratch.floats, 1, vDSP_Length(a.count))
                }
            }
            upload(lower: blend.lower, upper: blend.upper)
            return
        }
        let geometry = projection(at: now)
        fill(geometry, now: now, drain: drain)
        let stream = streamBounds ?? (geometry.lower, geometry.upper)
        upload(lower: simd_min(geometry.lower, stream.0), upper: simd_max(geometry.upper, stream.1))
    }

    func upload(lower: SIMD3<Float>, upper: SIMD3<Float>) {
        guard let mesh, let scratch else { return }
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: scratch.floats, count: scratch.floatCount * 4))
        }
        mesh.withUnsafeMutableIndices { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: scratch.indices, count: scratch.indexCount * 4))
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: scratch.indexCount, topology: .triangle,
                                                 bounds: BoundingBox(min: lower, max: upper))])
    }

    func fill(_ geometry: Projection, now: Double, drain: Float) {
        guard let scratch else { return }
        streamBounds = nil
        let clock = Float(min(now, removeStart ?? now) - pourStart)
        let lead = Float(Self.streamLead), pour = Float(pourDuration)
        let hand = (clock - lead) / pour
        let thin = 1 - 0.3 * drain, flatten = 1 - drain
        let cacheable = shift == nil && removeStart == nil

        func age(_ i: Int) -> Float { clock - lead - path[i].time * pour }
        func ring(_ i: Int) -> Ring {
            let n = geometry.normals[i], side = geometry.sides[i]
            let (a, h) = profile(i, normal: n, pool: geometry.pools[i], age: age(i))
            let center = geometry.points[i] + n * (-(0.1 * h + 0.00012) - drain * h * 1.1)
            return Ring(center: center, side: side, up: n, along: simd_cross(n, side), a: a * thin, h: h * flatten,
                        lift: geometry.lifts[i], bend: geometry.bends[i])
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
        }

        let kept = cacheable && hand > 0 && settledRings <= headIndex + 1 ? settledRings : 0
        scratch.floatCount = kept > 0 ? (Self.capRings + kept) * Self.ringSides * Self.floatsPerVertex : 0
        scratch.indexCount = kept > 0 ? (Self.capRings + kept - 1) * Self.ringSides * 6 : 0
        settledRings = 0

        if hand > 0 {
            var last: Ring
            var next: Int
            if kept > 0 {
                last = ring(kept - 1)
                next = kept
            } else {
                last = ring(0)
                emitCap(from: last, direction: -1)
                emit(last)
                next = 1
            }
            if headIndex >= next {
                for i in next...headIndex {
                    last = ring(i)
                    emit(last)
                }
            }
            if headIndex + 1 < path.count, headFraction > 0.02 {
                var head = ring(headIndex + 1)
                head.center = last.center + (head.center - last.center) * headFraction
                last = head
                emit(last)
            }
            emitCap(from: last, direction: 1)
            let rings = scratch.floatCount / Self.floatsPerVertex / Self.ringSides
            stitch(from: kept > 0 ? Self.capRings + kept - 1 : 0, to: rings - 1)
            if cacheable {
                var stable = 0
                while stable <= headIndex, age(stable) >= settleDuration { stable += 1 }
                settledRings = stable
            }
        }

        for (d, drip) in drips.enumerated() where d < geometry.drips.count {
            let start = lead + path[drip.origin].time * pour + drip.delay
            let x = Ease.clamp01((clock - start) / drip.duration)
            guard x > 0 else { continue }
            let route = geometry.drips[d]
            let grow = 1 - pow(1 - x, 2.2)
            let length = route.length * grow
            let base = profile(drip.origin, normal: geometry.normals[drip.origin], pool: 0, age: .infinity).0
            var bulb = drip.halfWidth * (1.15 + 0.3 * grow)
            bulb = min(bulb, length / 2)
            let bulbCenter = length - bulb
            func width(_ s: Float) -> Float {
                if s >= bulbCenter { return (max(0, bulb * bulb - (s - bulbCenter) * (s - bulbCenter))).squareRoot() }
                let neck = base * 0.85 + (drip.halfWidth - base * 0.85) * smoothstep(0, 0.006, s)
                let taper = neck * (1 - 0.15 * s / max(length, 1e-4))
                let rise = s - bulbCenter
                return max(taper, (max(0, bulb * bulb - rise * rise)).squareRoot())
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
                let h = a * (0.45 + 0.4 * smoothstep(0, 0.004, s))
                let epsilon: Float = 0.0001
                let slope = (width(s + epsilon) - width(max(s - epsilon, 0))) / (2 * epsilon)
                let center = p + n * (-(0.1 * h + 0.00012) - drain * h * 1.1)
                emit(Ring(center: center, side: f.side, up: f.up, along: f.along, a: a * thin, h: h * flatten,
                          lean: j == Self.dripRings ? 1e4 : -slope))
            }
            stitch(rings: Self.dripRings + 1)
        }

        if drain == 0 { emitStream(clock: clock, geometry: geometry, headIndex: headIndex, headPoint: headPoint) }
    }

    /// The falling strand, from just above the top of the screen to where the syrup lands while it pours. It hangs
    /// straight down in the world wherever the item is and however it's turned, follows the pour path the way a
    /// stream from a moving bottle lags behind it, thins as it falls and pools a little where it lands. When the pour
    /// ends it breaks off at the top and falls in.
    func emitStream(clock: Float, geometry: Projection, headIndex: Int, headPoint: SIMD3<Float>) {
        let lead = Float(Self.streamLead), pour = Float(pourDuration), cut = Float(Self.streamCut)
        guard clock > 0, clock < lead + pour + cut else { return }
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
        let normal = geometry.normals[max(headIndex, 0)]
        let landing = (hand > 0 && headIndex >= 0 ? headPoint : geometry.points[0]) + normal * (halfWidth * 0.45)
        let (height, up) = sky(above: landing) ?? (geometry.top + Self.nozzleHeight * 4 - landing.y, [0, 1, 0])
        guard height > halfWidth else { return }

        let thin = halfWidth * 0.24
        var bottom: Float = -thin * 0.5, top = height, pool: Float = 0, taper: Float = 1
        if clock < lead {
            bottom = height * (1 - Ease.inQuad(clock / lead))
        } else if clock < lead + pour {
            pool = smoothstep(0, 0.08, clock - lead)
        } else {
            let x = Ease.clamp01((clock - lead - pour) / cut)
            top = max(bottom + thin * 4, height * (1 - Ease.inQuad(x)))
            pool = 1 - x
            taper = 1 - 0.4 * x
        }
        let lag = Self.fallTime / pour
        let now = min(hand, 1)
        func radius(_ z: Float) -> Float {
            let s = Ease.clamp01(z / height)
            return thin * taper * (1 + 0.7 * s.squareRoot()) + pool * halfWidth * 0.5 * exp(-max(z, 0) / (thin * 1.4))
        }
        func center(_ z: Float) -> SIMD3<Float> {
            let b = handPoint(now + lag * pow(Ease.clamp01(z / height), 0.8))
            return b - up * simd_dot(b - landing, up) + up * z
        }

        var reference = simd_cross(up, [1, 0, 0])
        if simd_length(reference) < 0.1 { reference = simd_cross(up, [0, 0, 1]) }
        var rings: [Ring] = []
        var low = landing, high = landing
        for j in 0...Self.strandRings {
            let u = Float(j) / Float(Self.strandRings)
            let z = bottom + (top - bottom) * pow(u, 2.2)
            let dz = max((top - bottom) * 0.002, 1e-5)
            let p = center(z)
            let tangent = simd_normalize(center(z + dz) - center(z - dz))
            let side = simd_normalize(simd_cross(tangent, reference))
            let r = radius(z)
            let slope = (radius(z + dz) - radius(z - dz)) / (2 * dz)
            rings.append(Ring(center: p, side: side, up: simd_cross(side, tangent), along: tangent, a: max(r, 1e-5), h: max(r, 1e-5),
                              lean: -slope, round: true, shade: 0.14 + 0.3 * min(1, r / (halfWidth * 0.7))))
            low = simd_min(low, p - r)
            high = simd_max(high, p + r)
        }
        emitCap(from: rings[0], direction: -1)
        for ring in rings { emit(ring) }
        emitCap(from: rings[rings.count - 1], direction: 1)
        stitch(rings: Self.strandRings + 1 + 2 * Self.capRings)
        streamBounds = (low, high)
    }

    /// How far up from `point` a plumb line leaves the top of the stage camera's view (a little past the edge), and
    /// which way is up, in this layer's space. Nil off the stage.
    func sky(above point: SIMD3<Float>) -> (Float, SIMD3<Float>)? {
        guard let camera = stageCamera(),
              let fieldOfView = camera.components[PerspectiveCameraComponent.self]?.fieldOfViewInDegrees else { return nil }
        let toWorld = model.transformMatrix(relativeTo: nil)
        let toCamera = camera.transformMatrix(relativeTo: nil).inverse
        let p = toCamera * (toWorld * SIMD4(point, 1))
        let rising = toCamera * SIMD4<Float>(0, 1, 0, 0)
        let slope = tan(fieldOfView * .pi / 360)
        let approach = rising.y + rising.z * slope
        guard approach > 1e-3 else { return nil }
        let rise = (-p.z * slope - p.y) / approach + Self.skyMargin
        let local = toWorld.inverse * SIMD4<Float>(0, 1, 0, 0)
        let up = SIMD3(local.x, local.y, local.z)
        let perMeter = simd_length(up)
        guard rise > 0, perMeter > 1e-6 else { return nil }
        return (rise * perMeter, up / perMeter)
    }

    func stageCamera() -> Entity? {
        if let camera, camera.scene != nil { return camera }
        var top: Entity = model
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

private struct Blend {
    var from: [Float]
    var to: [Float]
    var start: Double
    var duration: Double
    var drains: Bool
    var lower: SIMD3<Float>
    var upper: SIMD3<Float>
}

private final class MeshScratch {
    let floats: UnsafeMutablePointer<Float>
    let indices: UnsafeMutablePointer<UInt32>
    let floatCapacity: Int
    let indexCapacity: Int
    var floatCount = 0
    var indexCount = 0

    init(floats: Int, indices: Int) {
        floatCapacity = floats
        indexCapacity = indices
        self.floats = .allocate(capacity: floats)
        self.indices = .allocate(capacity: indices)
    }

    deinit {
        floats.deallocate()
        indices.deallocate()
    }
}
