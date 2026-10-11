import CoreGraphics
import RealityKit
import UIKit

/// Can-sprayed whipped cream: a star-nozzle tube swept along a rising, tightening spiral that ends in a soft peak.
@MainActor
final class WhipLayer: ToppingLayer {
    static let growDuration: Double = 1.5
    static let removeDuration: Double = 0.5

    let entity = Entity()
    private(set) var isFinished = false
    var launchPoint: (() -> SIMD3<Float>)?

    private let model = ModelEntity()
    private var style = WhipStyle(seed: 0)
    private var groundFrom: WhipHeightGrid?
    private var groundTo: WhipHeightGrid?
    private var blendStart: Double = 0
    private var blendDuration: Double = 0
    private var growStart: Double?
    private var removeStart: Double?

    private var sweep = WhipSweep()
    private var sweepMix: Float = -1
    private var shown = WhipState(mix: -1, reveal: -1, deflate: -1)
    private var current = WhipState(mix: 1, reveal: 1, deflate: 0)
    private var buffers: WhipMesh?
    private var rings: [WhipRing] = []
    private var points: [SIMD3<Float>] = []
    private var shade: [Float] = []

    init() {
        entity.name = "whip"
        model.name = "whip-cream"
        entity.addChild(model)
        model.isEnabled = false
    }

    /// A finished swirl on flat ground (base at y = 0, centered on the axis), for the topping card's icon.
    /// The caller still applies the stage's lighting to it.
    static func makeIconDollop(radius: Float = 0.02, seed: UInt64 = 7) -> Entity {
        let layer = WhipLayer()
        layer.apply(onto: FlatSurface(radius: radius), seed: seed, animated: false, now: 0)
        return layer.entity
    }

    private struct FlatSurface: ToppingSurface {
        let radius: Float
        var apex: SIMD3<Float> { .zero }

        func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
            x * x + z * z <= 4 * radius * radius ? (0, [0, 1, 0]) : nil
        }
    }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        style = WhipStyle(seed: seed)
        let grid = WhipHeightGrid(surface)
        groundFrom = grid
        groundTo = grid
        blendDuration = 0
        growStart = animated ? now : nil
        removeStart = nil
        isFinished = false
        entity.isEnabled = true
        entity.setOpacity(1)
        sweepMix = -1
        shown = WhipState(mix: -1, reveal: -1, deflate: -1)
        let resources = WhipMesh(ridges: style.ridges)
        buffers = resources
        model.model = ModelComponent(mesh: resources.resource, materials: [resources.material])
        update(now: now)
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        guard groundTo != nil else { return }
        refreshState(now: now)
        groundFrom = WhipHeightGrid(currentGround.surface)
        groundTo = WhipHeightGrid(surface)
        blendStart = now
        blendDuration = max(duration, 0)
        sweepMix = -1
        shown.mix = -1
        update(now: now)
    }

    func remove(now: Double) {
        guard removeStart == nil else { return }
        guard groundTo != nil else {
            isFinished = true
            return
        }
        removeStart = now
    }

    func update(now: Double) {
        guard !isFinished, groundTo != nil else { return }
        refreshState(now: now)
        if current.deflate >= 1 {
            isFinished = true
            entity.isEnabled = false
            return
        }
        guard current != shown else { return }
        if current.mix != sweepMix {
            sweep = WhipSweep(style: style, ground: currentGround)
            sweepMix = current.mix
        }
        rebuild()
        entity.setOpacity(1 - Self.smoothstep(0.55, 1, current.deflate))
        shown = current
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface {
        guard groundTo != nil, !isFinished, !sweep.center.isEmpty else { return below }
        return WhipSurface(below: below, tubes: tubes(), axis: sweep.axis, extent: sweep.outer)
    }

    private var currentGround: WhipGround {
        WhipGround(from: groundFrom!, to: groundTo!, mix: current.mix)
    }

    private func refreshState(now: Double) {
        var state = WhipState(mix: 1, reveal: 1, deflate: 0)
        if blendDuration > 0 {
            let t = Float((now - blendStart) / blendDuration)
            state.mix = t >= 1 ? 1 : Ease.inOutCubic(Ease.clamp01(t))
        }
        if let growStart {
            let t = Float((now - growStart) / Self.growDuration)
            state.reveal = t >= 1 ? 1 : Self.extrusion(Ease.clamp01(t))
            if t >= 1 { self.growStart = nil }
        }
        if let removeStart {
            state.deflate = Ease.clamp01(Float((now - removeStart) / Self.removeDuration))
        }
        current = state
    }

    /// Cream leaves a can at a near-constant rate: a quick start, steady volume, and the nozzle easing off at the peak.
    private static let extrusion = TimingCurve(0.3, 0.12, 0.6, 1)

    nonisolated static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = Ease.clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    /// Fine centerline samples as currently shown (revealed, deflated), with the head's rounded end.
    private func tubes() -> [WhipTube] {
        let length = sweep.length(atVolume: current.reveal)
        guard length > 0 else { return [] }
        let ground = currentGround
        var out: [WhipTube] = []
        out.reserveCapacity(sweep.center.count + 4)
        for i in sweep.center.indices where sweep.arc[i] <= length {
            out.append(deflated(sweep.center[i], radius: sweep.radius[i], ground: ground))
        }
        let head = sweep.sample(at: length)
        out.append(deflated(head.center, radius: head.radius, ground: ground))
        if head.radius > 1e-5 {
            let tip = head.center + head.tangent * head.radius * WhipMesh.capReach
            out.append(deflated(tip, radius: head.radius * 0.55, ground: ground))
        }
        return out
    }

    private func deflated(_ center: SIMD3<Float>, radius: Float, ground: WhipGround) -> WhipTube {
        let d = current.deflate
        guard d > 0 else { return WhipTube(center: center, radius: radius, squash: WhipMesh.squash) }
        let floor = ground.height(center.x, center.z)
        var c = center
        c.y = floor + (c.y - floor) * (1 - 0.8 * d)
        let axis = sweep.axis
        c.x = axis.x + (c.x - axis.x) * (1 + 0.12 * d)
        c.z = axis.y + (c.z - axis.y) * (1 + 0.12 * d)
        return WhipTube(center: c, radius: radius * (1 - 0.4 * d), squash: WhipMesh.squash * (1 - 0.55 * d))
    }

    private func rebuild() {
        guard let buffers else { return }
        let length = sweep.length(atVolume: current.reveal)
        guard length > 1e-5 else {
            model.isEnabled = false
            return
        }
        model.isEnabled = true
        makeRings(length: length)
        let profile = buffers.profile
        let stride = profile.count + 1
        let ground = currentGround
        let d = current.deflate
        points.removeAll(keepingCapacity: true)
        shade.removeAll(keepingCapacity: true)
        let axis = sweep.axis
        for ring in rings {
            let squash = WhipMesh.squash * (1 - 0.55 * d)
            let outward = simd_normalize(SIMD3(ring.center.x - axis.x, 0, ring.center.z - axis.y) + [0, 1e-5, 0])
            for j in 0...profile.count {
                let p = profile[j % profile.count]
                let angle = p.angle + ring.twist
                let u = cos(angle) * ring.normal + sin(angle) * ring.binormal
                let bump = 1 + 0.03 * sin(ring.arc * 610 + angle * 3 + style.phases.x)
                    * sin(ring.arc * 270 - angle * 2 + style.phases.y)
                var offset = u * (ring.radius * p.scale * bump)
                offset.y *= squash
                var point = ring.center + offset
                if ring.foot > 0, u.y < -0.1 {
                    let w = ring.foot * Self.smoothstep(0.1, 0.8, -u.y)
                    let floor = ground.height(point.x, point.z) - 0.0006
                    if point.y > floor { point.y -= min(point.y - floor, 0.9 * ring.radius) * w }
                }
                points.append(point)
                let under = Self.smoothstep(-0.1, 0.85, -u.y)
                let inner = Self.smoothstep(0.2, 1, -simd_dot(u, outward)) * Self.smoothstep(0.3, -0.2, u.y)
                shade.append(min(0.8 * under + 0.3 * inner, 1) * ring.occlusion)
            }
        }
        buffers.write(points: points, shade: shade, rings: rings, stride: stride)
    }

    private func makeRings(length: Float) {
        rings.removeAll(keepingCapacity: true)
        let ground = currentGround
        let step = sweep.length / Float(WhipMesh.bodyRings)
        let start = sweep.sample(at: 0)
        for k in 0..<WhipMesh.capRings {
            let angle = Float.pi / 2 * Float(k) / Float(WhipMesh.capRings)
            var tail = start
            tail.center -= start.tangent * start.radius * WhipMesh.capReach * 0.8 * cos(angle)
            tail.radius *= sin(angle)
            rings.append(ring(tail, ground: ground))
        }
        var arc: Float = 0
        while arc < length - 0.2 * step {
            rings.append(ring(sweep.sample(at: arc), ground: ground))
            arc += step
        }
        let head = sweep.sample(at: length)
        rings.append(ring(head, ground: ground))
        for k in 1...WhipMesh.capRings {
            let angle = Float.pi / 2 * Float(k) / Float(WhipMesh.capRings)
            var cap = head
            cap.center += head.tangent * head.radius * WhipMesh.capReach * sin(angle)
            cap.radius *= cos(angle)
            rings.append(ring(cap, ground: ground))
        }
    }

    private func ring(_ sample: WhipSweep.Sample, ground: WhipGround) -> WhipRing {
        let tube = deflated(sample.center, radius: sample.radius, ground: ground)
        return WhipRing(center: tube.center, tangent: sample.tangent, normal: sample.normal, binormal: sample.binormal,
                        radius: tube.radius, arc: sample.arc, twist: sample.twist, foot: sample.foot * (1 - current.deflate),
                        occlusion: 1 - current.deflate)
    }
}

private struct WhipState: Equatable {
    var mix: Float
    var reveal: Float
    var deflate: Float
}

struct WhipTube {
    var center: SIMD3<Float>
    var radius: Float
    var squash: Float
}

struct WhipRing {
    var center: SIMD3<Float>
    var tangent: SIMD3<Float>
    var normal: SIMD3<Float>
    var binormal: SIMD3<Float>
    var radius: Float
    var arc: Float
    var twist: Float
    var foot: Float
    var occlusion: Float
}

/// Per-item variation drawn from the seed.
struct WhipStyle {
    var startAngle: Float
    var direction: Float
    var turns: Float
    var ridges: Int
    var twist: Float
    var spread: Float
    var tube: Float
    var peak: Float
    var curl: Float
    var phases: SIMD4<Float>

    init(seed: UInt64) {
        var rng = ToppingRandom(seed: seed ^ 0x5717_C0DE)
        startAngle = .random(in: 0..<(2 * .pi), using: &rng)
        direction = Bool.random(using: &rng) ? 1 : -1
        turns = .random(in: 2.1...2.35, using: &rng)
        ridges = Float.random(in: 0...1, using: &rng) < 0.7 ? 8 : 7
        twist = .random(in: 0.6...0.8, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        spread = .random(in: 0.6...0.66, using: &rng)
        tube = .random(in: 0.44...0.48, using: &rng)
        peak = .random(in: 2.5...3.0, using: &rng)
        curl = .random(in: 0.9...1.3, using: &rng)
        phases = SIMD4((0..<4).map { _ in Float.random(in: 0..<(2 * .pi), using: &rng) })
    }
}

/// A snapshot of the surface beneath, so the sweep can be rebuilt every frame without probing it again.
struct WhipHeightGrid {
    let origin: SIMD2<Float>
    let cell: Float
    let count: Int
    let heights: [Float]
    let apex: SIMD3<Float>
    let radius: Float

    init(_ surface: ToppingSurface, count: Int = 40) {
        apex = surface.apex
        radius = surface.radius
        let half = max(surface.radius * 1.5, 0.02)
        self.count = count
        origin = [apex.x - half, apex.z - half]
        cell = 2 * half / Float(count - 1)
        var h = [Float](repeating: .nan, count: count * count)
        var valid = 0
        for iz in 0..<count {
            for ix in 0..<count {
                if let s = surface.sample(x: origin.x + Float(ix) * cell, z: origin.y + Float(iz) * cell) {
                    h[iz * count + ix] = s.height
                    valid += 1
                }
            }
        }
        if valid == 0 {
            h = [Float](repeating: surface.apex.y - surface.radius, count: count * count)
        } else if valid < count * count {
            Self.fillGaps(&h, count: count)
        }
        heights = h
    }

    /// Spreads the nearest known heights outward over cells past the surface's edge.
    private static func fillGaps(_ h: inout [Float], count: Int) {
        var changed = true
        while changed {
            changed = false
            let source = h
            for iz in 0..<count {
                for ix in 0..<count where source[iz * count + ix].isNaN {
                    var sum: Float = 0, n: Float = 0
                    for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let x = ix + dx, z = iz + dz
                        guard x >= 0, z >= 0, x < count, z < count else { continue }
                        let v = source[z * count + x]
                        if !v.isNaN { sum += v; n += 1 }
                    }
                    if n > 0 {
                        h[iz * count + ix] = sum / n
                        changed = true
                    }
                }
            }
        }
    }

    func height(_ x: Float, _ z: Float) -> Float {
        let limit = Float(count - 1) - 1e-3
        let fx = min(max((x - origin.x) / cell, 0), limit)
        let fz = min(max((z - origin.y) / cell, 0), limit)
        let ix = Int(fx), iz = Int(fz)
        let tx = fx - Float(ix), tz = fz - Float(iz)
        let i = iz * count + ix
        let top = heights[i] + (heights[i + 1] - heights[i]) * tx
        let bottom = heights[i + count] + (heights[i + count + 1] - heights[i + count]) * tx
        return top + (bottom - top) * tz
    }
}

struct WhipGround {
    let from: WhipHeightGrid
    let to: WhipHeightGrid
    let mix: Float

    func height(_ x: Float, _ z: Float) -> Float {
        if mix <= 0 { return from.height(x, z) }
        if mix >= 1 { return to.height(x, z) }
        return lerp(from.height(x, z), to.height(x, z), mix)
    }

    var apex: SIMD3<Float> { simd_mix(from.apex, to.apex, .init(repeating: mix)) }
    var radius: Float { lerp(from.radius, to.radius, mix) }

    var surface: ToppingSurface { BlendedSurface(ground: self) }

    private struct BlendedSurface: ToppingSurface {
        let ground: WhipGround

        func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
            let e: Float = 0.001
            let h = ground.height(x, z)
            let dx = ground.height(x + e, z) - ground.height(x - e, z)
            let dz = ground.height(x, z + e) - ground.height(x, z - e)
            return (h, simd_normalize(SIMD3(-dx, 2 * e, -dz)))
        }

        var apex: SIMD3<Float> { ground.apex }
        var radius: Float { ground.radius }
    }
}

/// The swirl's centerline: a spiral stacked turn on turn over the ground, then a rising, tapering peak.
struct WhipSweep {
    struct Sample {
        var center: SIMD3<Float>
        var tangent: SIMD3<Float>
        var normal: SIMD3<Float>
        var binormal: SIMD3<Float>
        var radius: Float
        var arc: Float
        var twist: Float
        var foot: Float
    }

    var center: [SIMD3<Float>] = []
    var radius: [Float] = []
    var tangent: [SIMD3<Float>] = []
    var normal: [SIMD3<Float>] = []
    var arc: [Float] = []
    var volume: [Float] = []
    var foot: [Float] = []
    var twist: [Float] = []
    var axis: SIMD2<Float> = .zero
    var outer: Float = 0

    var length: Float { arc.last ?? 0 }

    init() {}

    init(style: WhipStyle, ground: WhipGround) {
        let n = 420
        let spiralEnd: Float = 0.86
        let squash = WhipMesh.squash
        let apex = ground.apex
        axis = [apex.x, apex.z]
        let r0 = ground.radius * style.spread
        let a0 = r0 * style.tube
        outer = r0 + a0
        let rEnd = a0 * 0.66
        let omega = 2 * Float.pi * style.turns / spiralEnd
        let ramp: Float = 0.8

        var theta = [Float](repeating: 0, count: n + 1)
        var spiralRadius = [Float](repeating: 0, count: n + 1)
        var stackRadius = [Float](repeating: 0, count: n + 1)
        var base = [Float](repeating: 0, count: n + 1)
        center.reserveCapacity(n + 1)
        var back = 0
        var peakStart = SIMD3<Float>.zero
        var heading = SIMD3<Float>(1, 0, 0)
        var rise = SIMD3<Float>.zero
        let du = 1 / (Float(n) * (1 - spiralEnd))
        for i in 0...n {
            let s = Float(i) / Float(n)
            let u = max(0, (s - spiralEnd) / (1 - spiralEnd))
            let spiral = min(s / spiralEnd, 1)
            let a = a0 * (1 - 0.35 * spiral) * (0.55 + 0.45 * WhipLayer.smoothstep(0, 0.1, s))
            if u > 0 {
                // The nozzle stops circling and lifts: the rope rises, then flops over to one side.
                let pitch = 1.35 * sin(.pi * 0.9 * u) - 0.55 * u
                let turn = style.direction * style.curl * u
                let along = simd_quatf(angle: turn, axis: [0, 1, 0]).act(heading)
                rise += (cos(pitch) * along + SIMD3(0, sin(pitch), 0)) * (a0 * style.peak * du)
                theta[i] = theta[i - 1]
                spiralRadius[i] = spiralRadius[i - 1]
                stackRadius[i] = a
                base[i] = base[i - 1]
                foot.append(0)
                center.append(peakStart + rise)
                radius.append(a * (1 + 1.1 * u) * pow(max(1 - pow(u, 1.6), 0), 0.75))
                continue
            }
            theta[i] = omega * s
            let angle = style.startAngle + style.direction * theta[i]
            let wobble = 1 + 0.03 * sin(angle * 2 + style.phases.z) + 0.015 * sin(theta[i] * 0.7 + style.phases.w)
            let r = (rEnd + (r0 - rEnd) * pow(1 - spiral, 1.05)) * wobble
            spiralRadius[i] = r
            stackRadius[i] = a
            let x = axis.x + r * cos(angle)
            let z = axis.y + r * sin(angle)
            let onGround = ground.height(x, z) + squash * a * 0.4
            var onCream = onGround - a0
            while back < i, theta[back + 1] <= theta[i] - 2 * .pi { back += 1 }
            if theta[i] - 2 * .pi > -ramp {
                let behind = theta[i] - 2 * .pi
                let span = theta[back + 1] - theta[back]
                let t = behind > 0 && span > 0 ? Ease.clamp01((behind - theta[back]) / span) : 0
                let below = lerp(base[back], base[back + 1], t)
                let belowR = lerp(spiralRadius[back], spiralRadius[back + 1], t)
                let belowA = lerp(stackRadius[back], stackRadius[back + 1], t)
                let reach = 0.92 * (belowA + a)
                let d = belowR - r
                let climb = WhipLayer.smoothstep(-ramp, 0, behind)
                onCream = below + climb * squash * sqrt(max(reach * reach - d * d, 0))
            }
            let k = 0.3 * a0
            let h = Ease.clamp01(0.5 + 0.5 * (onGround - onCream) / k)
            base[i] = lerp(onCream, onGround, h) + k * h * (1 - h)
            foot.append(WhipLayer.smoothstep(-0.3 * a0, 0.3 * a0, onGround - onCream))
            center.append([x, base[i], z])
            radius.append(a)
            peakStart = center[i]
            heading = style.direction * SIMD3(-sin(angle), 0, cos(angle))
        }
        for _ in 0..<10 {
            let source = center
            for i in 1..<n {
                center[i].y = (source[i - 1].y + 2 * source[i].y + source[i + 1].y) / 4
            }
        }

        arc = [0]
        volume = [0]
        twist = [0]
        for i in 1...n {
            let dl = simd_distance(center[i], center[i - 1])
            arc.append(arc[i - 1] + dl)
            twist.append(twist[i - 1] + style.twist * dl / max(radius[i], 0.4 * a0))
            let a = (radius[i] + radius[i - 1]) / 2
            volume.append(volume[i - 1] + .pi * a * a * squash * dl)
        }
        for i in 0...n {
            let next = center[min(i + 1, n)], previous = center[max(i - 1, 0)]
            tangent.append(simd_normalize(next - previous))
        }
        var r = simd_normalize(SIMD3(center[0].x - axis.x, 0, center[0].z - axis.y))
        r = simd_normalize(r - tangent[0] * simd_dot(r, tangent[0]))
        normal = [r]
        for i in 0..<n {
            let v1 = center[i + 1] - center[i]
            let c1 = simd_dot(v1, v1)
            guard c1 > 1e-14 else {
                normal.append(normal[i])
                continue
            }
            let rl = normal[i] - (2 / c1) * simd_dot(v1, normal[i]) * v1
            let tl = tangent[i] - (2 / c1) * simd_dot(v1, tangent[i]) * v1
            let v2 = tangent[i + 1] - tl
            let c2 = simd_dot(v2, v2)
            let next = c2 > 1e-14 ? rl - (2 / c2) * simd_dot(v2, rl) * v2 : rl
            normal.append(simd_normalize(next))
        }
    }

    /// Arc length at which the given fraction of the cream's volume has come out.
    func length(atVolume fraction: Float) -> Float {
        guard let total = volume.last, total > 0 else { return 0 }
        if fraction >= 1 { return length }
        let target = fraction * total
        var lo = 0, hi = volume.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if volume[mid] < target { lo = mid } else { hi = mid }
        }
        let span = volume[hi] - volume[lo]
        let t = span > 0 ? (target - volume[lo]) / span : 0
        return lerp(arc[lo], arc[hi], t)
    }

    func sample(at length: Float) -> Sample {
        var lo = 0, hi = arc.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if arc[mid] <= length { lo = mid } else { hi = mid }
        }
        let span = arc[hi] - arc[lo]
        let t = span > 0 ? Ease.clamp01((length - arc[lo]) / span) : 0
        let tv = SIMD3<Float>(repeating: t)
        let tan = simd_normalize(simd_mix(tangent[lo], tangent[hi], tv))
        var nor = simd_mix(normal[lo], normal[hi], tv)
        nor = simd_normalize(nor - tan * simd_dot(nor, tan))
        return Sample(center: simd_mix(center[lo], center[hi], tv), tangent: tan, normal: nor,
                      binormal: simd_cross(tan, nor), radius: lerp(radius[lo], radius[hi], t),
                      arc: length, twist: lerp(twist[lo], twist[hi], t), foot: lerp(foot[lo], foot[hi], t))
    }
}

/// One whip's mesh, rebuilt in place every animated frame; the material is shared per ridge count.
@MainActor
final class WhipMesh {
    nonisolated static let squash: Float = 0.86
    static let bodyRings = 230
    static let capRings = 5
    static let capReach: Float = 0.62
    static let samplesPerRidge = 8
    static let maxRings = bodyRings + 2 + 2 * capRings + 2

    struct ProfilePoint {
        var angle: Float
        var scale: Float
    }

    let mesh: LowLevelMesh
    let resource: MeshResource
    let material: PhysicallyBasedMaterial
    let profile: [ProfilePoint]
    private var normals: [SIMD3<Float>] = []

    private static var materials: [Int: PhysicallyBasedMaterial] = [:]

    init(ridges: Int) {
        let count = ridges * Self.samplesPerRidge
        profile = (0..<count).map { j in
            let angle = 2 * Float.pi * Float(j) / Float(count)
            let groove = pow(1 - abs(sin(Float(ridges) * angle / 2)), 1.6)
            return ProfilePoint(angle: angle, scale: 1 - 0.34 * groove)
        }
        let stride = count + 1
        let vertexCapacity = Self.maxRings * stride
        let indexCapacity = (Self.maxRings - 1) * count * 6
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: 24),
            .init(bufferIndex: 1, bufferStride: 8),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCapacity, vertexAttributes: attributes,
                                                 vertexLayouts: layouts, indexCapacity: indexCapacity, indexType: .uint32)
        mesh = try! LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uv = raw.bindMemory(to: SIMD2<Float>.self)
            for ring in 0..<Self.maxRings {
                for j in 0...count { uv[ring * stride + j] = [0, Float(j) / Float(count)] }
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let index = raw.bindMemory(to: UInt32.self)
            var k = 0
            for ring in 0..<(Self.maxRings - 1) {
                for j in 0..<count {
                    let a = UInt32(ring * stride + j), b = a + UInt32(stride)
                    index[k] = a; index[k + 1] = a + 1; index[k + 2] = b
                    index[k + 3] = a + 1; index[k + 4] = b + 1; index[k + 5] = b
                    k += 6
                }
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: 0, topology: .triangle,
                                                 bounds: BoundingBox(min: .zero, max: .zero))])
        resource = try! MeshResource(from: mesh)
        if let cached = Self.materials[ridges] {
            material = cached
        } else {
            material = Self.makeMaterial(ridges: ridges)
            Self.materials[ridges] = material
        }
    }

    func write(points: [SIMD3<Float>], shade: [Float], rings: [WhipRing], stride: Int) {
        let ringCount = min(rings.count, Self.maxRings)
        let count = stride - 1
        if normals.count < points.count { normals = .init(repeating: .zero, count: points.count) }
        for i in 0..<ringCount {
            let ring = rings[i]
            for j in 0..<count {
                let o = i * stride + j
                let along = points[min(i + 1, ringCount - 1) * stride + j] - points[max(i - 1, 0) * stride + j]
                let around = points[i * stride + (j + 1) % count] - points[i * stride + (j + count - 1) % count]
                var n = simd_cross(around, along)
                let length = simd_length(n)
                if length < 1e-12 || ring.radius < 1e-6 {
                    n = i < ringCount / 2 ? -ring.tangent : ring.tangent
                } else {
                    n /= length
                }
                normals[o] = n
            }
            normals[i * stride + count] = normals[i * stride]
        }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let used = ringCount * stride
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let out = raw.bindMemory(to: Float.self)
            for v in 0..<used {
                let p = points[v], n = normals[v]
                lo = simd_min(lo, p)
                hi = simd_max(hi, p)
                let o = v * 6
                out[o] = p.x; out[o + 1] = p.y; out[o + 2] = p.z
                out[o + 3] = n.x; out[o + 4] = n.y; out[o + 5] = n.z
            }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uv = raw.bindMemory(to: SIMD2<Float>.self)
            for ring in 0..<ringCount {
                for j in 0...count {
                    let v = ring * stride + j
                    uv[v] = [shade[v], Float(j) / Float(count)]
                }
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: max(ringCount - 1, 0) * count * 6, topology: .triangle,
                                                 bounds: BoundingBox(min: lo, max: hi))])
    }

    /// No subsurface scattering in RealityKit: a warm, slightly emissive white with soft highlights stands in
    /// for light diffusing through the foam, and a texture across the profile darkens and warms the grooves.
    private static func makeMaterial(ridges: Int) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.5)
        material.specular = .init(floatLiteral: 0.42)
        material.clearcoat = .init(floatLiteral: 0.06)
        material.clearcoatRoughness = .init(floatLiteral: 0.45)
        material.sheen = .init(tint: UIColor(red: 0.3, green: 0.29, blue: 0.27, alpha: 1))
        material.emissiveColor = .init(color: UIColor(red: 1, green: 0.94, blue: 0.84, alpha: 1))
        material.emissiveIntensity = 0.12
        let tint = UIColor(red: 1, green: 0.985, blue: 0.95, alpha: 1)
        if let image = grooveImage(ridges: ridges),
           let texture = try? TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: tint, texture: .init(texture))
        } else {
            material.baseColor = .init(tint: tint)
        }
        return material
    }

    /// Across (v): the star profile, darker and warmer down in each groove. Along (u): how occluded the vertex is
    /// (the underside of a turn resting on the one below, the inner side under the next turn).
    private static func grooveImage(ridges: Int) -> CGImage? {
        let width = 32, height = 512
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let groove = SIMD3<Float>(0.84, 0.79, 0.71)
        let shadow = SIMD3<Float>(0.66, 0.6, 0.52)
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            let depth = pow(1 - abs(sin(.pi * Float(ridges) * v)), 2.2)
            let ridge = simd_mix(SIMD3<Float>(1, 1, 1), groove, .init(repeating: depth))
            for x in 0..<width {
                let occlusion = Float(x) / Float(width - 1)
                let color = simd_mix(ridge, ridge * shadow, .init(repeating: occlusion))
                let o = (y * width + x) * 4
                bytes[o] = UInt8(min(color.x, 1) * 255)
                bytes[o + 1] = UInt8(min(color.y, 1) * 255)
                bytes[o + 2] = UInt8(min(color.z, 1) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The top of the cream (a sweep of squashed spheres along the centerline) over whatever is beneath it.
struct WhipSurface: ToppingSurface {
    private let below: ToppingSurface
    private let origin: SIMD2<Float>
    private let cell: Float
    private let count: Int
    private let heights: [Float]
    let apex: SIMD3<Float>
    let radius: Float

    init(below: ToppingSurface, tubes: [WhipTube], axis: SIMD2<Float>, extent: Float, count: Int = 44) {
        self.below = below
        self.count = count
        radius = below.radius
        let half = extent * 1.15 + 0.002
        origin = axis - SIMD2(repeating: half)
        cell = 2 * half / Float(count - 1)
        var h = [Float](repeating: -.infinity, count: count * count)
        for tube in tubes where tube.radius > 1e-5 {
            let reach = tube.radius
            let x0 = max(Int(((tube.center.x - reach) - origin.x) / cell), 0)
            let x1 = min(Int(((tube.center.x + reach) - origin.x) / cell) + 1, count - 1)
            let z0 = max(Int(((tube.center.z - reach) - origin.y) / cell), 0)
            let z1 = min(Int(((tube.center.z + reach) - origin.y) / cell) + 1, count - 1)
            guard x0 <= x1, z0 <= z1 else { continue }
            for iz in z0...z1 {
                let dz = origin.y + Float(iz) * cell - tube.center.z
                for ix in x0...x1 {
                    let dx = origin.x + Float(ix) * cell - tube.center.x
                    let d2 = reach * reach - dx * dx - dz * dz
                    guard d2 > 0 else { continue }
                    let top = tube.center.y + tube.squash * sqrt(d2)
                    if top > h[iz * count + ix] { h[iz * count + ix] = top }
                }
            }
        }
        var best = below.apex
        for iz in 0..<count {
            for ix in 0..<count {
                let i = iz * count + ix
                let x = origin.x + Float(ix) * cell, z = origin.y + Float(iz) * cell
                if let under = below.sample(x: x, z: z)?.height, under > h[i] { h[i] = under }
                if h[i] > best.y { best = [x, h[i], z] }
            }
        }
        heights = h
        apex = best
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let fx = (x - origin.x) / cell, fz = (z - origin.y) / cell
        guard fx >= 0, fz >= 0, fx < Float(count - 1), fz < Float(count - 1) else { return below.sample(x: x, z: z) }
        let ix = Int(fx), iz = Int(fz)
        let tx = fx - Float(ix), tz = fz - Float(iz)
        let i = iz * count + ix
        let h00 = heights[i], h10 = heights[i + 1], h01 = heights[i + count], h11 = heights[i + count + 1]
        guard h00.isFinite, h10.isFinite, h01.isFinite, h11.isFinite else { return below.sample(x: x, z: z) }
        let top = h00 + (h10 - h00) * tx
        let bottom = h01 + (h11 - h01) * tx
        let height = top + (bottom - top) * tz
        let dx = ((h10 - h00) * (1 - tz) + (h11 - h01) * tz) / cell
        let dz = ((h01 - h00) * (1 - tx) + (h11 - h10) * tx) / cell
        return (height, simd_normalize(SIMD3(-dx, 1, -dz)))
    }
}
