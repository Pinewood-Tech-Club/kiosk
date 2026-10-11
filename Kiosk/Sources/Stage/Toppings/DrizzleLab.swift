import QuartzCore
import RealityKit
import UIKit

/// Lab-only: `-kioskToppingLab chocolate|caramel` drizzles the current item on a stand-in surface built from its
/// scoops, then cycles: resurface onto a taller cream-like dome, back, remove, repeat with a new seed.
/// `-kioskToppingLabFreeze <s>` holds the cycle at that time, `-kioskToppingLabCream YES` starts on the dome,
/// `-kioskToppingLabSeed N`, `-kioskToppingLabYaw <rad>` stops the spin at a fixed yaw.
@MainActor
final class DrizzleLab {
    let style: DrizzleStyle
    let freeze: Double?
    let startOnCream: Bool
    let yaw: Float?
    let pitch: Float?
    let seed: UInt64
    private var rig: ItemRig?
    private var layer: DrizzleLayer?
    private var scoops: LabSurface?
    private var cream: LabSurface?
    private var start: Double?
    private var last: Double = -1
    private var costs: [Double] = []
    private var dome: ModelEntity?

    static let cycle: Double = 12

    init?() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "kioskToppingLab") else { return nil }
        style = name == "caramel" ? .caramel : .chocolate
        freeze = defaults.object(forKey: "kioskToppingLabFreeze") != nil ? defaults.double(forKey: "kioskToppingLabFreeze") : nil
        startOnCream = defaults.bool(forKey: "kioskToppingLabCream")
        yaw = defaults.object(forKey: "kioskToppingLabYaw") != nil ? Float(defaults.double(forKey: "kioskToppingLabYaw")) : nil
        pitch = defaults.object(forKey: "kioskToppingLabPitch") != nil ? Float(defaults.double(forKey: "kioskToppingLabPitch")) : nil
        seed = UInt64(max(0, defaults.integer(forKey: "kioskToppingLabSeed")))
    }

    func update(_ stage: Stage) {
        guard let hero = stage.heroes[stage.selectedVessel], !hero.scoops.isEmpty,
              hero.scoops.allSatisfy({ $0.isLanded }), hero.motion == nil, let assets = stage.assets else { return }
        if let yaw { hero.pose.yaw = yaw }
        if let pitch { hero.pose.pitch = pitch }
        if yaw != nil || pitch != nil { hero.apply() }
        if rig !== hero {
            rig = hero
            layer?.entity.removeFromParent()
            layer = nil
            let surface = LabSurface(rig: hero, assets: assets)
            scoops = surface
            let creamSurface = surface.withCream(height: 0.016)
            cream = creamSurface
            dome?.removeFromParent()
            let dome = creamSurface.domeModel()
            stage.applyLighting(dome)
            hero.body.addChild(dome)
            self.dome = dome
            start = stage.now + 0.4
            last = -1
            stage.log(String(format: "DrizzleLab: surface apex %.1f mm radius %.1f mm", surface.apex.y * 1000, surface.radius * 1000))
        }
        guard let start, let scoops, let cream else { return }
        var clock = stage.now - start
        if let freeze { clock = min(clock, freeze) }
        guard clock >= 0 else { return }
        let round = floor(clock / Self.cycle)
        let local = clock - round * Self.cycle
        let previous = last - round * Self.cycle
        func crossed(_ t: Double) -> Bool { previous < t && local >= t }
        let first: ToppingSurface = startOnCream ? cream : scoops
        let second: ToppingSurface = startOnCream ? scoops : cream

        if crossed(0) || (last < 0 && local >= 0) {
            layer?.entity.removeFromParent()
            let layer = DrizzleLayer(style: style)
            hero.body.addChild(layer.entity)
            let began = CACurrentMediaTime()
            layer.apply(onto: first, seed: seed &+ UInt64(round), animated: true, now: clock - local)
            stage.applyLighting(layer.entity)
            stage.log(String(format: "DrizzleLab: apply %.2f ms", (CACurrentMediaTime() - began) * 1000))
            self.layer = layer
            costs.removeAll()
        }
        guard let layer else { last = clock; return }
        let base = clock - local
        if crossed(4) {
            let began = CACurrentMediaTime()
            layer.resurface(to: second, duration: 0.7, now: base + 4)
            stage.log(String(format: "DrizzleLab: resurface %.2f ms", (CACurrentMediaTime() - began) * 1000))
        }
        if crossed(6.5) { layer.resurface(to: first, duration: 0.7, now: base + 6.5) }
        if crossed(9) { layer.remove(now: base + 9) }
        if let dome {
            func ramp(_ t: Double) -> Float { Ease.inOutSine(Ease.clamp01(Float((local - t) / 0.7))) }
            let up = startOnCream ? 1 - ramp(4) + ramp(6.5) : ramp(4) - ramp(6.5)
            dome.position.y = -0.0165 * (1 - up)
            dome.isEnabled = up > 0.001
        }
        let began = CACurrentMediaTime()
        layer.update(now: clock)
        let cost = CACurrentMediaTime() - began
        if cost > 0.00002 { costs.append(cost) }
        if crossed(8.9), !costs.isEmpty {
            let sorted = costs.sorted()
            stage.log(String(format: "DrizzleLab: update cost over %d built frames: mean %.3f ms, p90 %.3f ms, max %.3f ms",
                             sorted.count, sorted.reduce(0, +) / Double(sorted.count) * 1000,
                             sorted[Int(Double(sorted.count - 1) * 0.9)] * 1000, sorted.last! * 1000))
        }
        if layer.isFinished {
            layer.entity.removeFromParent()
            self.layer = nil
        }
        last = clock
    }
}

/// Heightfield of the item's landed scoops, with an optional cream-like dome on top.
struct LabSurface: ToppingSurface {
    let origin: SIMD2<Float>
    let cell: Float
    let columns: Int
    let rows: Int
    let heights: [Float]
    let baseApex: SIMD3<Float>
    let radius: Float
    var creamHeight: Float = 0

    @MainActor
    init(rig: ItemRig, assets: AssetLibrary) {
        var points: [SIMD3<Float>] = []
        var top: [SIMD3<Float>] = []
        for (index, actor) in rig.scoops.enumerated() {
            let matrix = actor.model.transformMatrix(relativeTo: rig.body)
            let local = assets.scoopSet(actor.slot).data.positions(actor.staticPose).map { p -> SIMD3<Float> in
                let w = matrix * SIMD4<Float>(p, 1)
                return [w.x, w.y, w.z]
            }
            points += local
            if index == rig.scoops.count - 1 { top = local }
        }
        cell = 0.0008
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in points {
            lo = simd_min(lo, [p.x, p.z])
            hi = simd_max(hi, [p.x, p.z])
        }
        origin = lo - 0.002
        columns = Int((hi.x - lo.x + 0.004) / cell) + 1
        rows = Int((hi.y - lo.y + 0.004) / cell) + 1
        var grid = [Float](repeating: -.infinity, count: columns * rows)
        for p in points {
            let c = Int((p.x - origin.x) / cell), r = Int((p.z - origin.y) / cell)
            guard c >= 0, c < columns, r >= 0, r < rows else { continue }
            grid[r * columns + c] = max(grid[r * columns + c], p.y)
        }
        let columns = self.columns, rows = self.rows
        func neighbors(_ g: [Float], _ c: Int, _ r: Int) -> [Float] {
            var out: [Float] = []
            for dr in -1...1 {
                for dc in -1...1 where !(dr == 0 && dc == 0) {
                    let cc = c + dc, rr = r + dr
                    guard cc >= 0, cc < columns, rr >= 0, rr < rows else { continue }
                    let v = g[rr * columns + cc]
                    if v.isFinite { out.append(v) }
                }
            }
            return out
        }
        for _ in 0..<3 {
            var next = grid
            for r in 0..<rows {
                for c in 0..<columns where !grid[r * columns + c].isFinite {
                    let n = neighbors(grid, c, r)
                    if n.count >= 4 { next[r * columns + c] = n.reduce(0, +) / Float(n.count) }
                }
            }
            grid = next
        }
        var smooth = grid
        for r in 0..<rows {
            for c in 0..<columns where grid[r * columns + c].isFinite {
                let n = neighbors(grid, c, r)
                smooth[r * columns + c] = (n.reduce(0, +) + 2 * grid[r * columns + c]) / Float(n.count + 2)
            }
        }
        heights = smooth
        var centroid = SIMD2<Float>(0, 0)
        var topY: Float = -.greatestFiniteMagnitude
        for p in top { topY = max(topY, p.y) }
        var count: Float = 0
        for p in top where p.y > topY - 0.012 {
            centroid += [p.x, p.z]
            count += 1
        }
        centroid /= max(count, 1)
        let fx = Int((centroid.x - origin.x) / cell), fz = Int((centroid.y - origin.y) / cell)
        let centerHeight = smooth[min(max(fz, 0), rows - 1) * columns + min(max(fx, 0), columns - 1)]
        let best = SIMD3<Float>(centroid.x, centerHeight.isFinite ? centerHeight : topY, centroid.y)
        baseApex = best
        var reach = [Float](repeating: 0, count: 24)
        for p in top {
            let d = SIMD2<Float>(p.x - best.x, p.z - best.z)
            let bin = (Int((atan2(d.y, d.x) + .pi) / (2 * .pi) * 24) % 24 + 24) % 24
            reach[bin] = max(reach[bin], simd_length(d))
        }
        radius = 0.9 * reach.sorted()[12]
    }

    func withCream(height: Float) -> LabSurface {
        var copy = self
        copy.creamHeight = height
        return copy
    }

    private func base(_ x: Float, _ z: Float) -> Float? {
        let fx = (x - origin.x) / cell - 0.5, fz = (z - origin.y) / cell - 0.5
        let c = Int(floor(fx)), r = Int(floor(fz))
        guard c >= 0, c + 1 < columns, r >= 0, r + 1 < rows else { return nil }
        let h00 = heights[r * columns + c], h10 = heights[r * columns + c + 1]
        let h01 = heights[(r + 1) * columns + c], h11 = heights[(r + 1) * columns + c + 1]
        guard h00.isFinite, h10.isFinite, h01.isFinite, h11.isFinite else { return nil }
        let u = fx - Float(c), v = fz - Float(r)
        return (h00 * (1 - u) + h10 * u) * (1 - v) + (h01 * (1 - u) + h11 * u) * v
    }

    private func height(_ x: Float, _ z: Float) -> Float? {
        guard let h = base(x, z) else { return nil }
        guard creamHeight > 0 else { return h }
        let d = simd_length(SIMD2<Float>(x - baseApex.x, z - baseApex.z)) / (radius * 1.08)
        guard d < 1 else { return h }
        return h + creamHeight * pow(1 - d * d, 0.8)
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        guard let h = height(x, z) else { return nil }
        let e: Float = 0.0008
        let hx0 = height(x - e, z) ?? h, hx1 = height(x + e, z) ?? h
        let hz0 = height(x, z - e) ?? h, hz1 = height(x, z + e) ?? h
        let n = simd_normalize(SIMD3<Float>(-(hx1 - hx0) / (2 * e), 1, -(hz1 - hz0) / (2 * e)))
        return (h, n)
    }

    var apex: SIMD3<Float> { baseApex + [0, creamHeight, 0] }

    @MainActor
    func domeModel() -> ModelEntity {
        let rings = 40, segments = 96
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for ring in 0...rings {
            let r = radius * 1.08 * Float(ring) / Float(rings)
            for segment in 0..<segments {
                let a = Float(segment) / Float(segments) * 2 * .pi
                let x = baseApex.x + r * cos(a), z = baseApex.z + r * sin(a)
                if let hit = sample(x: x, z: z) {
                    positions.append([x, hit.height - 0.0003, z])
                    normals.append(hit.normal)
                } else {
                    positions.append([baseApex.x, baseApex.y - 0.03, baseApex.z])
                    normals.append([0, 1, 0])
                }
            }
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * segments + segment), b = UInt32(ring * segments + (segment + 1) % segments)
                let c = a + UInt32(segments), d = b + UInt32(segments)
                indices += [a, b, c, b, d, c]
            }
        }
        var descriptor = MeshDescriptor(name: "lab-cream")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1))
        material.roughness = .init(floatLiteral: 0.55)
        material.faceCulling = .none
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generateSphere(radius: 0.001)
        return ModelEntity(mesh: mesh, materials: [material])
    }
}
