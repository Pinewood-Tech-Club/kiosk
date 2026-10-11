import QuartzCore
import RealityKit
import UIKit

/// `-kioskToppingLab scatter -kioskLabScene gummy|lentil|sprinkle|all|up|down|remove [-kioskLabFreeze s] [-kioskLabYaw r]`
@MainActor
final class ScatterLab {
    private static var lab: ScatterLab?
    private static var waitingSince: Double?

    static func tick(_ stage: Stage) {
        if let lab {
            lab.update(stage)
            return
        }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "kioskToppingLab") == "scatter", let assets = stage.assets,
              let rig = stage.heroes[stage.selectedVessel], !rig.scoops.isEmpty else { return }
        if waitingSince == nil { waitingSince = stage.now }
        guard stage.now - (waitingSince ?? 0) > 0.8 else { return }
        lab = ScatterLab(stage: stage, rig: rig, assets: assets)
    }

    let rig: ItemRig
    let scene: String
    let start: Double
    let freeze: Double?
    let yaw: Float
    let pitch: Float?
    let base: HeightfieldSurface
    let whip: WhipDome
    let whipEntity: ModelEntity
    var layers: [ScatterLayer] = []
    var steps: [(time: Double, action: () -> Void)] = []
    var updateTime: Double = 0
    var updateFrames = 0

    init(stage: Stage, rig: ItemRig, assets: AssetLibrary) {
        let defaults = UserDefaults.standard
        self.rig = rig
        scene = defaults.string(forKey: "kioskLabScene") ?? "all"
        start = stage.now
        freeze = defaults.object(forKey: "kioskLabFreeze") != nil ? defaults.double(forKey: "kioskLabFreeze") : nil
        yaw = defaults.object(forKey: "kioskLabYaw") != nil ? Float(defaults.double(forKey: "kioskLabYaw")) : 0.5
        pitch = defaults.object(forKey: "kioskLabPitch") != nil ? Float(defaults.double(forKey: "kioskLabPitch")) : nil
        base = HeightfieldSurface(rig: rig, assets: assets)
        whip = WhipDome(base: base)
        var cream = PhysicallyBasedMaterial()
        cream.baseColor = .init(tint: UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1))
        cream.roughness = 0.75
        whipEntity = ModelEntity(mesh: .generateSphere(radius: 1), materials: [cream])
        whipEntity.position = [base.apex.x, whip.baseY, base.apex.z]
        rig.body.addChild(whipEntity)
        stage.log(String(format: "ScatterLab: scene %@ apex (%.4f, %.4f, %.4f) radius %.4f", scene,
                         base.apex.x, base.apex.y, base.apex.z, base.radius))
        for actor in rig.scoops {
            let bounds = actor.model.visualBounds(relativeTo: rig.body)
            let mid = bounds.center
            stage.log(String(format: "ScatterLab: scoop %@ pose %@ visual max y %.4f center (%.4f, %.4f) field there %.4f", actor.flavor.rawValue,
                             actor.staticPose, bounds.max.y, mid.x, mid.z, base.sample(x: mid.x, z: mid.z)?.height ?? -1))
        }
        for shape in [PlaceholderScatterKind.Shape.gummy, .lentil, .sprinkle] {
            var rng = ToppingRandom(seed: 1)
            timed("make pieces", stage) { _ = PlaceholderScatterKind(shape: shape).makePieces(rng: &rng) }
        }
        build(stage)
        setWhip(scene == "down" ? 1 : 0)
    }

    private func kind(_ shape: PlaceholderScatterKind.Shape) -> ScatterLayer {
        let layer = ScatterLayer(kind: PlaceholderScatterKind(shape: shape))
        layer.occupied = layers.flatMap(\.footprints)
        layers.append(layer)
        rig.body.addChild(layer.entity)
        return layer
    }

    private func timed(_ label: String, _ stage: Stage, _ body: () -> Void) {
        let started = CACurrentMediaTime()
        body()
        stage.log(String(format: "ScatterLab: %@ %.2f ms", label, (CACurrentMediaTime() - started) * 1000))
    }

    private func build(_ stage: Stage) {
        let now = stage.now
        switch scene {
        case "gummy", "lentil", "sprinkle":
            let shape: PlaceholderScatterKind.Shape = scene == "gummy" ? .gummy : scene == "lentil" ? .lentil : .sprinkle
            steps = [(0.2, { [unowned self] in
                let layer = kind(shape)
                timed("apply \(scene)", stage) { layer.apply(onto: base, seed: 7, animated: true, now: stage.now) }
            })]
        case "all":
            steps = [
                (0.2, { [unowned self] in kind(.gummy).apply(onto: base, seed: 11, animated: true, now: stage.now) }),
                (1.4, { [unowned self] in kind(.lentil).apply(onto: base, seed: 12, animated: true, now: stage.now) }),
                (2.6, { [unowned self] in
                    let layer = kind(.sprinkle)
                    timed("apply sprinkles", stage) { layer.apply(onto: base, seed: 13, animated: true, now: stage.now) }
                }),
            ]
        case "up", "down", "remove":
            let surface: ToppingSurface = scene == "down" ? whip.full : base
            for (index, shape) in [PlaceholderScatterKind.Shape.gummy, .lentil, .sprinkle].enumerated() {
                kind(shape).apply(onto: surface, seed: UInt64(21 + index), animated: false, now: now)
            }
            if scene == "remove" {
                steps = [
                    (0.4, { [unowned self] in layers[1].remove(now: stage.now) }),
                    (0.55, { [unowned self] in
                        layers[2].occupied = layers[0].footprints
                        layers[2].resurface(to: base, duration: 0.4, now: stage.now)
                    }),
                ]
            } else {
                let rising = scene == "up"
                steps = [(0.4, { [unowned self] in
                    let target: ToppingSurface = rising ? whip.full : base
                    timed("resurface", stage) {
                        var occupied: [ScatterFootprint] = []
                        for layer in layers {
                            layer.occupied = occupied
                            layer.resurface(to: target, duration: 0.9, now: stage.now)
                            occupied += layer.footprints
                        }
                    }
                    whipFrom = rising ? 0 : 1
                    whipTo = rising ? 1 : 0
                    whipStart = stage.now
                })]
            }
        default:
            break
        }
    }

    var whipFrom: Float = 0
    var whipTo: Float = 0
    var whipStart: Double?

    private func setWhip(_ growth: Float) {
        whipEntity.isEnabled = growth > 0.01
        whipEntity.scale = [whip.a * max(growth, 0.01), whip.b * max(growth, 0.01), whip.a * max(growth, 0.01)]
    }

    private func update(_ stage: Stage) {
        let t = stage.now - start
        while let first = steps.first, t >= first.time {
            steps.removeFirst()
            first.action()
        }
        if let whipStart {
            let p = Float(min((stage.now - whipStart) / 0.9, 1))
            setWhip(lerp(whipFrom, whipTo, Ease.inOutCubic(p)))
            if p >= 1 { self.whipStart = nil }
        }
        let started = CACurrentMediaTime()
        for layer in layers { layer.update(now: stage.now) }
        updateTime += CACurrentMediaTime() - started
        updateFrames += 1
        if updateFrames % 120 == 0 {
            stage.log(String(format: "ScatterLab: layer update avg %.1f µs/frame", updateTime / Double(updateFrames) * 1e6))
        }
        if let freeze, t >= freeze, stage.timeScale > 0 {
            for layer in layers {
                stage.log("ScatterLab: rest " + layer.footprints.map { f in
                    let r = simd_distance(f.center, SIMD2(base.apex.x, base.apex.z)) / base.radius
                    let s = base.sample(x: f.center.x, z: f.center.y)
                    return String(format: "r%.2f n%.2f above%.1fmm", r, s?.normal.y ?? -1, (f.top - (s?.height ?? 0)) * 1000)
                }.joined(separator: " | "))
            }
            stage.timeScale = 0
            stage.log(String(format: "ScatterLab: frozen at %.2f s", t))
        }
        rig.pose.yaw = yaw
        if let pitch { rig.pose.pitch = pitch }
        rig.apply()
    }
}

/// The top of the rig's landed scoops, gridded from their pose vertices.
struct HeightfieldSurface: ToppingSurface {
    let origin: SIMD2<Float>
    let cell: Float
    let size: Int
    let heights: [Float]
    let normals: [SIMD3<Float>]
    let apex: SIMD3<Float>
    let radius: Float

    @MainActor
    init(rig: ItemRig, assets: AssetLibrary) {
        var points: [SIMD3<Float>] = []
        var topBounds = (min: SIMD3<Float>(repeating: .infinity), max: SIMD3<Float>(repeating: -.infinity))
        for (index, actor) in rig.scoops.enumerated() {
            let matrix = actor.model.transformMatrix(relativeTo: rig.body)
            for p in assets.scoopSet(actor.slot).data.positions(actor.staticPose) {
                let q = matrix * SIMD4(p, 1)
                let point = SIMD3(q.x, q.y, q.z)
                points.append(point)
                if index == rig.scoops.count - 1 {
                    topBounds.min = simd_min(topBounds.min, point)
                    topBounds.max = simd_max(topBounds.max, point)
                }
            }
        }
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for p in points {
            lo = simd_min(lo, [p.x, p.z])
            hi = simd_max(hi, [p.x, p.z])
        }
        let n = 80
        size = n
        cell = max(hi.x - lo.x, hi.y - lo.y) / Float(n - 1)
        origin = lo
        var grid = [Float](repeating: -.infinity, count: n * n)
        for p in points {
            let i = min(max(Int(((p.x - lo.x) / cell).rounded()), 0), n - 1)
            let j = min(max(Int(((p.z - lo.y) / cell).rounded()), 0), n - 1)
            grid[j * n + i] = max(grid[j * n + i], p.y)
        }
        for _ in 0..<3 {
            let source = grid
            for j in 1..<(n - 1) {
                for i in 1..<(n - 1) where source[j * n + i] == -.infinity {
                    let around = [source[j * n + i - 1], source[j * n + i + 1], source[(j - 1) * n + i], source[(j + 1) * n + i]]
                        .filter { $0 > -.infinity }
                    if around.count >= 3 { grid[j * n + i] = around.reduce(0, +) / Float(around.count) }
                }
            }
        }
        heights = grid
        var normals = [SIMD3<Float>](repeating: [0, 1, 0], count: n * n)
        for j in 0..<n {
            for i in 0..<n where grid[j * n + i] > -.infinity {
                func h(_ a: Int, _ b: Int) -> Float {
                    let a = min(max(a, 0), n - 1), b = min(max(b, 0), n - 1)
                    let v = grid[b * n + a]
                    return v > -.infinity ? v : grid[j * n + i]
                }
                let dx = (h(i + 2, j) - h(i - 2, j)) / (4 * cell)
                let dz = (h(i, j + 2) - h(i, j - 2)) / (4 * cell)
                normals[j * n + i] = simd_normalize([-dx, 1, -dz])
            }
        }
        self.normals = normals
        let center = (topBounds.min + topBounds.max) / 2
        radius = min(topBounds.max.x - topBounds.min.x, topBounds.max.z - topBounds.min.z) / 2
        apex = [center.x, topBounds.max.y, center.z]
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let fx = (x - origin.x) / cell, fz = (z - origin.y) / cell
        let i = Int(fx.rounded(.down)), j = Int(fz.rounded(.down))
        guard i >= 0, j >= 0, i < size - 1, j < size - 1 else { return nil }
        let corners = [j * size + i, j * size + i + 1, (j + 1) * size + i, (j + 1) * size + i + 1]
        guard corners.allSatisfy({ heights[$0] > -.infinity }) else { return nil }
        let u = fx - Float(i), v = fz - Float(j)
        let weights = [(1 - u) * (1 - v), u * (1 - v), (1 - u) * v, u * v]
        var height: Float = 0
        var normal = SIMD3<Float>.zero
        for k in 0..<4 {
            height += heights[corners[k]] * weights[k]
            normal += normals[corners[k]] * weights[k]
        }
        return (height, simd_normalize(normal))
    }
}

/// A half-ellipsoid of cream on the crown, standing in for whipped cream.
struct WhipDome {
    let base: HeightfieldSurface
    let center: SIMD2<Float>
    let baseY: Float
    let a: Float
    let b: Float

    init(base: HeightfieldSurface) {
        self.base = base
        center = [base.apex.x, base.apex.z]
        baseY = base.apex.y - 0.4 * base.radius
        a = 0.88 * base.radius
        b = 0.4 * base.radius + 0.6 * base.radius
    }

    var full: Surface { Surface(dome: self) }

    struct Surface: ToppingSurface {
        let dome: WhipDome

        var apex: SIMD3<Float> { [dome.center.x, dome.baseY + dome.b, dome.center.y] }
        var radius: Float { dome.base.radius }

        func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
            let below = dome.base.sample(x: x, z: z)
            let d = SIMD2(x, z) - dome.center
            let k = simd_length_squared(d) / (dome.a * dome.a)
            guard k < 1 else { return below }
            let h = dome.b * (1 - k).squareRoot()
            let height = dome.baseY + h
            if let below, below.height >= height { return below }
            let normal = simd_normalize(SIMD3(d.x / (dome.a * dome.a), h / (dome.b * dome.b), d.y / (dome.a * dome.a)))
            return (height, normal)
        }
    }
}
