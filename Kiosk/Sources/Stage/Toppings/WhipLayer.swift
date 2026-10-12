import CoreGraphics
import RealityKit
import UIKit

/// Aerosol whipped cream: a fat, softly ridged foam rope laid in a loose rosette of about two coils, ending in a small tuft.
@MainActor
final class WhipLayer: ToppingLayer {
    static let growDuration: Double = 1.5
    static let removeDuration: Double = 0.5
    /// Share of `growDuration` spent spraying; the rest lets the freshest foam finish puffing up.
    private static let sprayShare: Float = 0.86

    let entity = Entity()
    private(set) var isFinished = false
    var launchPoint: (() -> SIMD3<Float>)?
    var growDuration: Double { Self.growDuration }
    var removeDuration: Double { Self.removeDuration }

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
    private var shown = WhipState(mix: -1, reveal: -1, settle: -1, deflate: -1)
    private var current = WhipState(mix: 1, reveal: 1, settle: 1, deflate: 0)
    private var buffers: WhipMesh?
    private var rings: [WhipRing] = []
    private var points: [SIMD3<Float>] = []
    private var shade: [Float] = []
    private var lobes: [SIMD2<Float>] = []
    private var wander: [SIMD2<Float>] = []

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
        shown = WhipState(mix: -1, reveal: -1, settle: -1, deflate: -1)
        let resources = WhipMesh(ridges: style.ridges, seed: seed)
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

    func settledSurfaceAbove(_ below: ToppingSurface) -> ToppingSurface {
        guard let groundTo, !isFinished, removeStart == nil else { return below }
        let ground = WhipGround(from: groundTo, to: groundTo, mix: 1)
        let saved = (current, sweep)
        defer { (current, sweep) = saved }
        current = WhipState(mix: 1, reveal: 1, settle: 1, deflate: 0)
        sweep = WhipSweep(style: style, ground: ground)
        return WhipSurface(below: below, tubes: tubes(), axis: sweep.axis, extent: sweep.outer)
    }

    private var currentGround: WhipGround {
        WhipGround(from: groundFrom!, to: groundTo!, mix: current.mix)
    }

    private func refreshState(now: Double) {
        var state = WhipState(mix: 1, reveal: 1, settle: 1, deflate: 0)
        if blendDuration > 0 {
            let t = Float((now - blendStart) / blendDuration)
            state.mix = t >= 1 ? 1 : Ease.inOutCubic(Ease.clamp01(t))
        }
        if let growStart {
            let t = Float((now - growStart) / Self.growDuration)
            state.reveal = t >= Self.sprayShare ? 1 : Self.extrusion(Ease.clamp01(t / Self.sprayShare))
            state.settle = t >= 1 ? 1 : Self.smoothstep(Self.sprayShare, 1, t)
            if t >= 1 { self.growStart = nil }
        }
        if let removeStart {
            state.deflate = Ease.clamp01(Float((now - removeStart) / Self.removeDuration))
        }
        current = state
    }

    /// Cream leaves a can at a near-constant rate: a quick start, steady volume, and the nozzle easing off at the end.
    private static let extrusion = TimingCurve(0.3, 0.12, 0.6, 1)

    nonisolated static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = Ease.clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    /// Foam leaves the nozzle narrow and puffs up over the next tube width or two.
    private func swell(_ arc: Float, length: Float) -> Float {
        guard current.settle < 1 else { return 1 }
        let a = sweep.tube
        let behind = length - arc + current.settle * 2.6 * a
        return 0.8 + 0.2 * Self.smoothstep(0, 2.4 * a, behind)
    }

    /// The creases leave the cream's cross-section a little inside its nominal radius.
    private static let meanScale: Float = 0.95

    /// Fine centerline samples as currently shown (revealed, deflated), with the head's rounded end.
    private func tubes() -> [WhipTube] {
        let length = sweep.length(atVolume: current.reveal)
        guard length > 0 else { return [] }
        let ground = currentGround
        var out: [WhipTube] = []
        out.reserveCapacity(sweep.center.count + 4)
        for i in sweep.center.indices where sweep.arc[i] <= length {
            out.append(deflated(sweep.center[i], radius: sweep.radius[i] * swell(sweep.arc[i], length: length) * Self.meanScale,
                                ground: ground))
        }
        let head = sweep.sample(at: length)
        let headRadius = head.radius * swell(length, length: length) * Self.meanScale
        out.append(deflated(head.center, radius: headRadius, ground: ground))
        if headRadius > 1e-5 {
            let tip = head.center + head.tangent * headRadius * WhipMesh.capReach
            out.append(deflated(tip, radius: headRadius * 0.55, ground: ground))
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
        let count = profile.count
        let stride = count + 1
        let grain = buffers.grain
        let squash = WhipMesh.squash * (1 - 0.55 * current.deflate)
        let ridges = style.ridges
        let noise = style.noise
        let a0 = max(sweep.tube, 1e-5)
        let axis = sweep.axis
        if lobes.count != ridges {
            lobes = .init(repeating: .zero, count: ridges)
            wander = .init(repeating: .zero, count: ridges)
        }
        let half = Float(ridges) / 2
        points.removeAll(keepingCapacity: true)
        shade.removeAll(keepingCapacity: true)
        for (i, ring) in rings.enumerated() {
            let outward = simd_normalize(SIMD3(ring.center.x - axis.x, 0, ring.center.z - axis.y) + [0, 1e-5, 0])
            let ct = cos(ring.twist), st = sin(ring.twist)
            let e1 = ct * ring.normal + st * ring.binormal
            let e2 = ct * ring.binormal - st * ring.normal
            let x = ring.arc / a0
            let ends = 1 + 0.6 * (1 - Self.smoothstep(0, 2.5, x)) + 1.1 * (1 - Self.smoothstep(0, 2, (sweep.length - ring.arc) / a0))
            for k in 0..<ridges {
                let o = Float(k) * 17.3
                let puff = 0.35 * noise(x * 1.1 + o) + 0.3 * noise(x * 2.6 + o + 101) + 0.35 * noise(x * 5.5 + o + 151)
                let depth = 0.7 + 0.5 * noise(x * 1.2 + o + 211) + 0.45 * noise(x * 3.1 + o + 241)
                lobes[k] = [puff * ends, max(depth, 0.08)]
                let shift = half * 0.45 * (2 * .pi / Float(ridges)) * noise(x * 2 + o + 307)
                wander[k] = [cos(shift), sin(shift)]
            }
            let fade = Self.smoothstep(0.12, 0.55, ring.radius / a0)
            let row = min(i, WhipMesh.maxRings - 1) * count
            for j in 0...count {
                let jj = j % count
                let p = profile[jj]
                let u = p.cos * e1 + p.sin * e2
                let lobe = simd_mix(lobes[p.lobe], lobes[p.next], SIMD2(repeating: p.blend)) * fade
                let turn = simd_mix(wander[p.lobe], wander[p.next], SIMD2(repeating: p.blend))
                let c = p.halfCos * turn.x - p.halfSin * turn.y
                let c2 = c * c
                let crease = c2 * lobe.y
                let scale = (1 + WhipMesh.puff * lobe.x) * (1 - WhipMesh.groove * crease) * (1 + WhipMesh.grain * grain[row + jj])
                var offset = u * (ring.radius * scale)
                offset.y *= squash
                if ring.foot > 0, u.y < -0.1 {
                    offset.y *= 1 - 0.35 * ring.foot * Self.smoothstep(0.1, 0.8, -u.y)
                }
                points.append(ring.center + offset)
                let under = Self.smoothstep(-0.1, 0.85, -u.y)
                let inner = Self.smoothstep(0.2, 1, -simd_dot(u, outward)) * Self.smoothstep(0.3, -0.2, u.y)
                shade.append(min(0.6 * under + 0.3 * inner + 0.75 * crease, 1) * ring.occlusion)
            }
        }
        buffers.write(points: points, shade: shade, rings: rings, stride: stride)
    }

    private func makeRings(length: Float) {
        rings.removeAll(keepingCapacity: true)
        let ground = currentGround
        let step = sweep.length / Float(WhipMesh.bodyRings)
        let start = sweep.sample(at: 0)
        let startSwell = swell(0, length: length)
        for k in 0..<WhipMesh.capRings {
            let angle = Float.pi / 2 * Float(k) / Float(WhipMesh.capRings)
            var tail = start
            tail.center -= start.tangent * start.radius * startSwell * WhipMesh.capReach * 0.8 * cos(angle)
            tail.radius *= sin(angle)
            rings.append(ring(tail, scale: startSwell, ground: ground))
        }
        var arc: Float = 0
        while arc < length - 0.2 * step {
            rings.append(ring(sweep.sample(at: arc), scale: swell(arc, length: length), ground: ground))
            arc += step
        }
        let head = sweep.sample(at: length)
        let headSwell = swell(length, length: length)
        rings.append(ring(head, scale: headSwell, ground: ground))
        for k in 1...WhipMesh.capRings {
            let angle = Float.pi / 2 * Float(k) / Float(WhipMesh.capRings)
            var cap = head
            cap.center += head.tangent * head.radius * headSwell * WhipMesh.capReach * sin(angle)
            cap.radius *= cos(angle)
            rings.append(ring(cap, scale: headSwell, ground: ground))
        }
    }

    private func ring(_ sample: WhipSweep.Sample, scale: Float, ground: WhipGround) -> WhipRing {
        let tube = deflated(sample.center, radius: sample.radius * scale, ground: ground)
        return WhipRing(center: tube.center, tangent: sample.tangent, normal: sample.normal, binormal: sample.binormal,
                        radius: tube.radius, arc: sample.arc, twist: sample.twist, foot: sample.foot * (1 - current.deflate),
                        occlusion: 1 - current.deflate)
    }
}

private struct WhipState: Equatable {
    var mix: Float
    var reveal: Float
    var settle: Float
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

/// Smooth 1D value noise in [-1, 1] with a period of 256.
struct WhipNoise {
    private let table: [Float]

    init(rng: inout ToppingRandom) {
        table = (0..<256).map { _ in Float.random(in: -1...1, using: &rng) }
    }

    func callAsFunction(_ x: Float) -> Float {
        let f = x.rounded(.down)
        let i = Int(f) & 255
        let t = x - f
        return lerp(table[i], table[(i + 1) & 255], t * t * (3 - 2 * t))
    }
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
    var noise: WhipNoise

    init(seed: UInt64) {
        var rng = ToppingRandom(seed: seed ^ 0x5717_C0DE)
        startAngle = .random(in: 0..<(2 * .pi), using: &rng)
        direction = Bool.random(using: &rng) ? 1 : -1
        turns = .random(in: 1.5...1.75, using: &rng)
        ridges = Float.random(in: 0...1, using: &rng) < 0.6 ? 8 : 7
        twist = .random(in: 0.25...0.45, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
        spread = .random(in: 0.68...0.74, using: &rng)
        tube = .random(in: 0.66...0.74, using: &rng)
        peak = .random(in: 0.9...1.2, using: &rng)
        curl = .random(in: 1.2...1.8, using: &rng)
        noise = WhipNoise(rng: &rng)
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
        Self.soften(&h, count: count)
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

    /// Blurs away the stair steps of coarse height fields so the cream's squashed foot follows a smooth floor.
    private static func soften(_ h: inout [Float], count: Int) {
        for _ in 0..<2 {
            let source = h
            for iz in 1..<(count - 1) {
                for ix in 1..<(count - 1) {
                    let i = iz * count + ix
                    h[i] = (4 * source[i] + source[i - 1] + source[i + 1] + source[i - count] + source[i + count]) / 8
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

/// The rosette's centerline: a loose spiral, each coil slumping onto the one below, then a short lift that tips over.
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
    var tube: Float = 0

    var length: Float { arc.last ?? 0 }

    init() {}

    init(style: WhipStyle, ground: WhipGround) {
        let n = 420
        let spiralEnd: Float = 0.88
        let squash = WhipMesh.squash
        let noise = style.noise
        let apex = ground.apex
        axis = [apex.x, apex.z]
        let r0 = ground.radius * style.spread
        let a0 = r0 * style.tube
        tube = a0
        outer = r0 + a0 * 1.3
        let rEnd = a0 * 0.3
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
            let puff = 1 + 0.13 * noise(s * 8 + 400) + 0.07 * noise(s * 21 + 450)
            let a = a0 * (1 - 0.3 * spiral) * (0.6 + 0.4 * WhipLayer.smoothstep(0, 0.08, s)) * puff
            if u > 0 {
                let pitch = 1.2 * sin(.pi * 0.8 * u) - 1.3 * u
                let turn = style.direction * style.curl * u
                let along = simd_quatf(angle: turn, axis: [0, 1, 0]).act(heading)
                rise += (cos(pitch) * along + SIMD3(0, sin(pitch), 0)) * (a0 * style.peak * du)
                theta[i] = theta[i - 1]
                spiralRadius[i] = spiralRadius[i - 1]
                stackRadius[i] = a
                base[i] = base[i - 1]
                foot.append(0)
                center.append(peakStart + rise)
                radius.append(a * (1 + 0.15 * u) * pow(max(1 - u * u * u, 0), 0.5))
                continue
            }
            theta[i] = omega * s
            let angle = style.startAngle + style.direction * theta[i]
            let wobble = 1 + 0.06 * noise(s * 6 + 300) + 0.02 * noise(s * 17 + 350)
            let r = (rEnd + (r0 - rEnd) * pow(1 - spiral, 0.9)) * wobble
            spiralRadius[i] = r
            stackRadius[i] = a
            let x = axis.x + r * cos(angle)
            let z = axis.y + r * sin(angle)
            let onGround = ground.height(x, z) + squash * a * 0.35
            var onCream = onGround - a0
            while back < i, theta[back + 1] <= theta[i] - 2 * .pi { back += 1 }
            if theta[i] - 2 * .pi > -ramp {
                let behind = theta[i] - 2 * .pi
                let span = theta[back + 1] - theta[back]
                let t = behind > 0 && span > 0 ? Ease.clamp01((behind - theta[back]) / span) : 0
                let below = lerp(base[back], base[back + 1], t)
                let belowR = lerp(spiralRadius[back], spiralRadius[back + 1], t)
                let belowA = lerp(stackRadius[back], stackRadius[back + 1], t)
                let reach = 0.78 * (belowA + a)
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
            let rate = style.twist * (1 + 0.8 * noise(arc[i] / a0 * 0.4 + 500))
            twist.append(twist[i - 1] + rate * dl / max(radius[i], 0.4 * a0))
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

/// One whip's mesh, rebuilt in place every animated frame; the material is shared by every whip.
@MainActor
final class WhipMesh {
    nonisolated static let squash: Float = 0.86
    static let bodyRings = 230
    static let capRings = 5
    static let capReach: Float = 0.62
    static let samplesPerRidge = 9
    static let maxRings = bodyRings + 2 + 2 * capRings + 2
    static let puff: Float = 0.22
    static let groove: Float = 0.3
    static let grain: Float = 0.035
    static let bubble: Float = 0.12

    struct ProfilePoint {
        var cos: Float
        var sin: Float
        var halfCos: Float
        var halfSin: Float
        var lobe: Int
        var next: Int
        var blend: Float
    }

    let mesh: LowLevelMesh
    let resource: MeshResource
    let material: PhysicallyBasedMaterial
    let profile: [ProfilePoint]
    /// Fixed per-vertex jitter that gives the foam its faintly bubbly surface.
    let grain: [Float]
    private var normals: [SIMD3<Float>] = []
    private let bubbles: [SIMD3<Float>]

    private static var sharedMaterial: PhysicallyBasedMaterial?

    init(ridges: Int, seed: UInt64) {
        let count = ridges * Self.samplesPerRidge
        profile = (0..<count).map { j in
            let angle = 2 * Float.pi * Float(j) / Float(count)
            let f = Float(ridges) * angle / (2 * .pi) - 0.5
            let k = Int(f.rounded(.down))
            let t = f - f.rounded(.down)
            let c = cos(Float(ridges) * angle / 2)
            return ProfilePoint(cos: cos(angle), sin: sin(angle), halfCos: c, halfSin: sin(Float(ridges) * angle / 2),
                                lobe: (k + ridges) % ridges, next: (k + 1 + ridges) % ridges, blend: t * t * (3 - 2 * t))
        }
        var rng = ToppingRandom(seed: seed ^ 0xB0B_B1E5)
        let raw = (0..<(Self.maxRings * count)).map { _ in Float.random(in: -1...1, using: &rng) }
        let coarseRings = Self.maxRings / 4 + 2, coarseAround = count / 4
        let coarse = (0..<(coarseRings * coarseAround)).map { _ in Float.random(in: -1...1, using: &rng) }
        grain = (0..<(Self.maxRings * count)).map { v in
            let ring = v / count, j = v % count
            let up = min(ring + 1, Self.maxRings - 1) * count + j, down = max(ring - 1, 0) * count + j
            let left = ring * count + (j + count - 1) % count, right = ring * count + (j + 1) % count
            let fine = (2 * raw[v] + raw[up] + raw[down] + raw[left] + raw[right]) / 6
            let fr = Float(ring) / 4, fj = Float(j) / 4
            let r0 = Int(fr), j0 = Int(fj), tr = fr - Float(r0), tj = fj - Float(j0)
            let j1 = (j0 + 1) % coarseAround
            let top = lerp(coarse[r0 * coarseAround + j0], coarse[r0 * coarseAround + j1], tj)
            let bottom = lerp(coarse[(r0 + 1) * coarseAround + j0], coarse[(r0 + 1) * coarseAround + j1], tj)
            return fine + 0.8 * lerp(top, bottom, tr)
        }
        let stride = count + 1
        bubbles = (0..<(Self.maxRings * stride)).map { _ in
            SIMD3(Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng), Float.random(in: -1...1, using: &rng))
        }
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
                for j in 0...count { uv[ring * stride + j] = [0, 0.5] }
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
        if let shared = Self.sharedMaterial {
            material = shared
        } else {
            material = Self.makeMaterial()
            Self.sharedMaterial = material
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
                    n = simd_normalize(n / length + Self.bubble * bubbles[o])
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
            for v in 0..<used { uv[v].x = shade[v] }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: max(ringCount - 1, 0) * count * 6, topology: .triangle,
                                                 bounds: BoundingBox(min: lo, max: hi))])
    }

    /// No subsurface scattering in RealityKit: a rough, barely sheened white with a faint emissive lift on exposed foam
    /// stands in for light diffusing through it. uv0.x indexes how occluded or creased each vertex is.
    private static func makeMaterial() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.86)
        material.specular = .init(floatLiteral: 0.18)
        material.sheen = .init(tint: UIColor(white: 0.2, alpha: 1))
        let tint = UIColor(red: 0.93, green: 0.925, blue: 0.915, alpha: 1)
        if let image = shadeImage(open: [1, 1, 1], hidden: [0.66, 0.645, 0.625]),
           let texture = try? TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
            material.baseColor = .init(tint: tint, texture: .init(texture))
        } else {
            material.baseColor = .init(tint: tint)
        }
        if let image = shadeImage(open: [1, 0.98, 0.95], hidden: [0.25, 0.24, 0.22]),
           let texture = try? TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
            material.emissiveColor = .init(color: .white, texture: .init(texture))
        } else {
            material.emissiveColor = .init(color: UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1))
        }
        material.emissiveIntensity = 0.09
        return material
    }

    private static func shadeImage(open: SIMD3<Float>, hidden: SIMD3<Float>) -> CGImage? {
        let width = 64, height = 2
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            let t = Float(x) / Float(width - 1)
            let color = simd_mix(open, hidden, SIMD3(repeating: t * t * (3 - 2 * t)))
            for y in 0..<height {
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
    private let cream: [Bool]
    let apex: SIMD3<Float>
    let radius: Float
    var floor: Float { below.floor }

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
        var cream = [Bool](repeating: false, count: count * count)
        for iz in 0..<count {
            for ix in 0..<count {
                let i = iz * count + ix
                let x = origin.x + Float(ix) * cell, z = origin.y + Float(iz) * cell
                if let under = below.sample(x: x, z: z)?.height {
                    cream[i] = h[i] > under + 0.0003
                    if under > h[i] { h[i] = under }
                }
                if h[i] > best.y { best = [x, h[i], z] }
            }
        }
        heights = h
        self.cream = cream
        apex = best
    }

    func softness(x: Float, z: Float) -> Float {
        let fx = (x - origin.x) / cell, fz = (z - origin.y) / cell
        guard fx >= 0, fz >= 0, fx < Float(count - 1), fz < Float(count - 1) else { return below.softness(x: x, z: z) }
        let i = Int(fz.rounded()) * count + Int(fx.rounded())
        return cream[i] ? 1 : below.softness(x: x, z: z)
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
