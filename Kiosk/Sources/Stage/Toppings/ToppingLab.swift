import RealityKit
import UIKit

/// Temporary test hook: `-kioskToppingLab whip` pipes a whip onto the current item on a height field of its scoops.
/// `-kioskToppingLabFreeze <s>` holds the growth at that many seconds, `-kioskToppingLabRemove <s>` removes after the
/// growth and holds that many seconds into the removal, `-kioskToppingLabResurface 1` drops the surface 1 cm after
/// growing, `-kioskToppingLabProbe 1` marks surfaceAbove with dots, `-kioskToppingLabLoop 1` repeats.
@MainActor
final class ToppingLab {
    let rig: ItemRig
    let layer: WhipLayer
    let surface: ScoopHeightField
    let defaults = UserDefaults.standard
    var start: Double
    var seed: UInt64
    var probes: [ModelEntity] = []
    var removed = false
    var resurfaced = false

    init(stage: Stage, rig: ItemRig) {
        self.rig = rig
        surface = ScoopHeightField(stage: stage, rig: rig)
        layer = WhipLayer()
        seed = UInt64(defaults.integer(forKey: "kioskToppingLabSeed"))
        start = stage.now + 0.8
        rig.body.addChild(layer.entity)
        stage.applyLighting(layer.entity)
        if defaults.bool(forKey: "kioskToppingLabProbe") {
            let mesh = MeshResource.generateSphere(radius: 0.0007)
            let material = UnlitMaterial(color: .red)
            for _ in 0..<400 {
                let dot = ModelEntity(mesh: mesh, materials: [material])
                dot.isEnabled = false
                rig.body.addChild(dot)
                probes.append(dot)
            }
        }
        if defaults.bool(forKey: "kioskToppingLabDollop") {
            let dollop = WhipLayer.makeIconDollop()
            stage.applyLighting(dollop)
            dollop.scale = .init(repeating: 4)
            dollop.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
            dollop.position = stage.world(CGPoint(x: 200, y: 420))
            stage.root.addChild(dollop)
        }
        if defaults.bool(forKey: "kioskToppingLabStatic") {
            layer.apply(onto: surface, seed: seed, animated: false, now: stage.now)
            start = -100
        }
    }

    private var applied = false

    func update(now realNow: Double) {
        var now = realNow
        if defaults.object(forKey: "kioskToppingLabYaw") != nil {
            rig.pose.yaw = Float(defaults.double(forKey: "kioskToppingLabYaw"))
            if defaults.object(forKey: "kioskToppingLabPitch") != nil {
                rig.pose.pitch = Float(defaults.double(forKey: "kioskToppingLabPitch"))
            }
            rig.apply()
        }
        if defaults.object(forKey: "kioskToppingLabZoom") != nil {
            rig.apply()
            rig.root.scale *= Float(defaults.double(forKey: "kioskToppingLabZoom"))
            let focus = rig.body.convert(position: surface.apex + [0, Float(defaults.double(forKey: "kioskToppingLabFocus")), 0], to: nil)
            rig.root.position += SIMD3<Float>(0, 0.3, rig.root.position.z) - [focus.x, focus.y, rig.root.position.z]
        }
        if !applied {
            guard now >= start else { return }
            applied = true
            layer.apply(onto: surface, seed: seed, animated: true, now: start)
        }
        if defaults.object(forKey: "kioskToppingLabFreeze") != nil {
            now = min(now, start + defaults.double(forKey: "kioskToppingLabFreeze"))
        }
        let grown = start + WhipLayer.growDuration + 0.6
        if defaults.bool(forKey: "kioskToppingLabResurface"), !resurfaced, now > grown {
            resurfaced = true
            layer.resurface(to: surface.lowered(0.01), duration: 0.6, now: now)
        }
        if defaults.object(forKey: "kioskToppingLabRemove") != nil {
            if !removed, now > grown {
                removed = true
                layer.remove(now: grown)
            }
            if removed { now = min(now, grown + defaults.double(forKey: "kioskToppingLabRemove")) }
        }
        let started = CACurrentMediaTime()
        layer.update(now: now)
        let cost = CACurrentMediaTime() - started
        if cost > 0.0003 {
            costs.append(cost)
            let surfaceStarted = CACurrentMediaTime()
            _ = layer.surfaceAbove(surface)
            surfaceCosts.append(CACurrentMediaTime() - surfaceStarted)
        }
        if costs.count == 60 {
            let sorted = costs.sorted(), surfaceSorted = surfaceCosts.sorted()
            surfaceCosts.removeAll()
            let line = String(format: "WhipLab update cost: median %.2f ms, max %.2f ms; surfaceAbove median %.2f ms, max %.2f ms\n",
                              sorted[30] * 1000, sorted[59] * 1000, surfaceSorted[30] * 1000, surfaceSorted[59] * 1000)
            let path = NSTemporaryDirectory() + "whipcost.txt"
            let previous = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (previous + line).write(toFile: path, atomically: true, encoding: .utf8)
            costs.removeAll()
        }
        if !probes.isEmpty { updateProbes() }
        if defaults.bool(forKey: "kioskToppingLabLoop"), layer.isFinished || now > grown + 2.5 {
            if !layer.isFinished {
                if !removed { removed = true; layer.remove(now: now) }
            } else {
                seed &+= 1
                removed = false
                applied = false
                start = realNow + 0.5
            }
        }
    }

    private var costs: [Double] = []
    private var surfaceCosts: [Double] = []

    private func updateProbes() {
        let above = layer.surfaceAbove(surface)
        let n = 20
        let span = surface.radius * 1.2
        var k = 0
        for iz in 0..<n {
            for ix in 0..<n {
                let x = surface.apex.x + (Float(ix) / Float(n - 1) * 2 - 1) * span
                let z = surface.apex.z + (Float(iz) / Float(n - 1) * 2 - 1) * span
                let dot = probes[k]
                k += 1
                if let s = above.sample(x: x, z: z) {
                    dot.position = [x, s.height, z]
                    dot.isEnabled = true
                } else {
                    dot.isEnabled = false
                }
            }
        }
    }
}

/// Stand-in for the stack's scoop surface: max height of the placed scoops' vertices over a grid.
struct ScoopHeightField: ToppingSurface {
    let origin: SIMD2<Float>
    let cell: Float
    let count: Int
    var heights: [Float]
    var apex: SIMD3<Float>
    let radius: Float

    @MainActor
    init(stage: Stage, rig: ItemRig) {
        var all: [SIMD3<Float>] = []
        var top: [SIMD3<Float>] = []
        for actor in rig.scoops {
            guard let set = stage.assets?.scoopSet(actor.slot) else { continue }
            let matrix = actor.root.transform.matrix * actor.model.transform.matrix
            let points = set.data.positions(actor.staticPose, stride: 2).map { p -> SIMD3<Float> in
                let w = matrix * SIMD4<Float>(p, 1)
                return [w.x, w.y, w.z]
            }
            all += points
            if actor === rig.scoops.last { top = points }
        }
        if all.isEmpty { all = [[0, stage.assets?.vesselTop(rig.vessel) ?? 0.05, 0]] }
        if top.isEmpty { top = all }
        count = 72
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in all {
            lo = simd_min(lo, [p.x, p.z])
            hi = simd_max(hi, [p.x, p.z])
        }
        let size = max(hi.x - lo.x, hi.y - lo.y, 0.01)
        origin = lo
        cell = size / Float(count - 1)
        var h = [Float](repeating: -.infinity, count: count * count)
        for p in all {
            let ix = min(max(Int(((p.x - origin.x) / cell).rounded()), 0), count - 1)
            let iz = min(max(Int(((p.z - origin.y) / cell).rounded()), 0), count - 1)
            h[iz * count + ix] = max(h[iz * count + ix], p.y)
        }
        for _ in 0..<2 {
            let source = h
            for iz in 1..<(count - 1) {
                for ix in 1..<(count - 1) where !source[iz * count + ix].isFinite {
                    let around = [source[iz * count + ix - 1], source[iz * count + ix + 1],
                                  source[(iz - 1) * count + ix], source[(iz + 1) * count + ix]].filter(\.isFinite)
                    if around.count >= 3 { h[iz * count + ix] = around.reduce(0, +) / Float(around.count) }
                }
            }
        }
        heights = h
        let peak = top.max { $0.y < $1.y }!
        let topMid = (top.map(\.y).min()! + peak.y) / 2
        let upper = top.filter { $0.y > topMid }
        let centroid = upper.reduce(SIMD3<Float>.zero, +) / Float(max(upper.count, 1))
        let distances = upper.map { simd_length(SIMD2($0.x - centroid.x, $0.z - centroid.z)) }.sorted()
        apex = [centroid.x, peak.y, centroid.z]
        radius = distances.isEmpty ? 0.02 : distances[distances.count * 9 / 10]
        print("WhipLab surface: apex \(apex) peak \(peak) radius \(radius) scoops \(rig.scoops.map { "\($0.slot):\($0.staticPose)" })")
    }

    func lowered(_ amount: Float) -> ScoopHeightField {
        var copy = self
        copy.heights = heights.map { $0 - amount }
        copy.apex.y -= amount
        return copy
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let fx = (x - origin.x) / cell, fz = (z - origin.y) / cell
        guard fx >= 0, fz >= 0, fx < Float(count - 1), fz < Float(count - 1) else { return nil }
        let ix = Int(fx), iz = Int(fz)
        let tx = fx - Float(ix), tz = fz - Float(iz)
        let i = iz * count + ix
        let h00 = heights[i], h10 = heights[i + 1], h01 = heights[i + count], h11 = heights[i + count + 1]
        guard h00.isFinite, h10.isFinite, h01.isFinite, h11.isFinite else { return nil }
        let top = h00 + (h10 - h00) * tx
        let bottom = h01 + (h11 - h01) * tx
        let dx = ((h10 - h00) * (1 - tz) + (h11 - h01) * tz) / cell
        let dz = ((h01 - h00) * (1 - tx) + (h11 - h10) * tx) / cell
        return (top + (bottom - top) * tz, simd_normalize(SIMD3(-dx, 1, -dz)))
    }
}
