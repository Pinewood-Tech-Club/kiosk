import RealityKit
import simd

/// Where a scattered piece rests, projected onto the item's xz plane in body space: a capsule from
/// `center - axis * halfLength` to `center + axis * halfLength`, `radius` wide, whose highest point is at `top`.
struct ScatterFootprint {
    var center: SIMD2<Float>
    var axis: SIMD2<Float>
    var halfLength: Float
    var radius: Float
    var top: Float = 0

    func contains(_ point: SIMD2<Float>) -> Bool {
        let along = simd_clamp(simd_dot(point - center, axis), -halfLength, halfLength)
        return simd_distance_squared(point, center + axis * along) < radius * radius
    }
}

/// Pieces of one `ScatterKind` dropped onto the surface beneath by hand.
///
/// Several scatter layers share one item. Before `apply` and `resurface`, set `occupied` to the
/// `footprints` of the scatter layers applied before this one, in stack order:
///
///     mms.occupied = gummies.footprints
///     sprinkles.occupied = gummies.footprints + mms.footprints
///
/// New pieces then land clear of those, or on top of them where the crown is too crowded. `footprints` always describes where this layer's pieces rest
/// or are heading, so after a resurface feed the layers in the same order again.
@MainActor
final class ScatterLayer: ToppingLayer {
    let kind: ScatterKind
    let entity = Entity()
    var occupied: [ScatterFootprint] = []
    private(set) var footprints: [ScatterFootprint] = []
    private(set) var isFinished = false
    var launchPoint: (() -> SIMD3<Float>)?

    private struct Pose {
        var position: SIMD3<Float>
        var rotation: simd_quatf

        func mixed(_ other: Pose, _ t: Float) -> Pose {
            Pose(position: simd_mix(position, other.position, SIMD3(repeating: t)),
                 rotation: simd_slerp(rotation, other.rotation, t))
        }
    }

    private enum Motion {
        case none
        case drop(start: Double)
        case move(from: Pose, start: Double, duration: Double, falling: Bool)
        case pop(from: Pose, start: Double)
    }

    private struct Piece {
        let model: ModelEntity
        let half: SIMD3<Float>
        let meshCenter: SIMD3<Float>
        /// Rest offset from the apex axis as a fraction of the surface radius, so it survives a resurface.
        var canonical = SIMD2<Float>.zero
        let yaw: Float
        let tilt: Float
        let tiltAxis: SIMD3<Float>

        func local(tiltScale: Float = 1) -> simd_quatf {
            simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: tilt * tiltScale, axis: tiltAxis)
        }
        let slider: Bool
        let slideFrom: Float
        let delay: Double
        let fall: Double
        let post: Double
        let dropHeight: Float
        let drift: SIMD2<Float>
        let spinAxis: SIMD3<Float>
        let spinAngle: Float
        let wobbleAxis: SIMD3<Float>
        let wobble: Float
        let hop: Float
        let removeDelay: Double
        let moveJitter: Double
        var rest = Pose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        /// Landing point of a slider and the poses it slides through to `rest`; empty for the others.
        var path: [Pose] = []
        var shown = Pose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        var scale: Float = 1
        var motion = Motion.none
    }

    private var pieces: [Piece] = []
    private var animating = false
    private var surfaceRadius: Float = 0.03

    static let maxReach: Float = 0.97
    /// Cosine of the steepest slope a piece stays on.
    static let steepest: Float = 0.45
    static let slideDuration = 0.24
    static let popGrow = 0.08
    static let popShrink = 0.13

    init(kind: ScatterKind) {
        self.kind = kind
        entity.name = "scatter"
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface { below }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        for piece in pieces { piece.model.removeFromParent() }
        pieces = []
        isFinished = false
        var rng = ToppingRandom(seed: seed)
        let specs = kind.makePieces(rng: &rng)
        surfaceRadius = max(surface.radius, 1e-3)
        let sweep = Self.unit2(Float.random(in: 0..<(2 * .pi), using: &rng))
        let spread: Double = specs.count > 20 ? 0.42 : 0.3

        var placed: [SIMD2<Float>] = []
        var placedRadius: [Float] = []
        for footprint in occupied {
            placed.append((footprint.center - Self.xz(surface.apex)) / surfaceRadius)
            placedRadius.append((footprint.halfLength + footprint.radius) / surfaceRadius)
        }

        for spec in specs {
            let half = spec.halfExtents
            let reach = max(half.x, half.z) / surfaceRadius
            let slider = Float.random(in: 0...1, using: &rng) < 0.2
            var best = SIMD2<Float>.zero
            var bestScore = -Float.infinity
            for _ in 0..<3 {
                let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
                let u = Float.random(in: 0...1, using: &rng)
                let fraction = slider ? 0.78 + 0.18 * u : 0.8 * pow(u, 0.6)
                let candidate = Self.unit2(angle) * fraction
                var score = Float.infinity
                for (index, other) in placed.enumerated() {
                    score = min(score, simd_distance(candidate, other) - placedRadius[index] - reach)
                }
                score -= 0.2 * fraction
                if score > bestScore {
                    bestScore = score
                    best = candidate
                }
            }
            placed.append(best)
            placedRadius.append(reach)

            let yaw = Float.random(in: 0..<(2 * .pi), using: &rng)
            let mode = Float.random(in: 0...1, using: &rng)
            let rawTilt: Float = mode < 0.55 ? Float.random(in: 0...0.17, using: &rng)
                : mode < 0.85 ? Float.random(in: 0.26...0.7, using: &rng)
                : Float.random(in: 0.95...1.45, using: &rng)
            let tiltAxis = Self.unit2(Float.random(in: 0..<(2 * .pi), using: &rng))
            let small = max(half.x, max(half.y, half.z)) < 0.005
            let tilt = small ? rawTilt : min(rawTilt, 0.35)
            let along = (simd_dot(best, sweep) + 1) / 2
            let delay = Double(along) * spread + Double.random(in: 0...0.1, using: &rng)
            let fall = Double.random(in: 0.22...0.3, using: &rng)
            let dropHeight = surfaceRadius * Float.random(in: 0.7...1.1, using: &rng)
            let drift = Self.unit2(Float.random(in: 0..<(2 * .pi), using: &rng)) * surfaceRadius * Float.random(in: 0.05...0.18, using: &rng)
            let spinAxis = Self.randomUnit(&rng)
            let spinAngle = Float.random(in: (small ? 2.5 : 1.2)...(small ? 5 : 2.6), using: &rng) * .pi
                * (Bool.random(using: &rng) ? 1 : -1)
            let wobbleAxis2 = Self.unit2(Float.random(in: 0..<(2 * .pi), using: &rng))
            let wobble = Float.random(in: 0.12...0.35, using: &rng)
            let hop = dropHeight * Float.random(in: 0.06...0.13, using: &rng)
            let removeDelay = Double.random(in: 0...0.18, using: &rng)
            let moveJitter = Double.random(in: 0...1, using: &rng)
            let slideFrom = Float.random(in: 0.6...0.78, using: &rng)

            let model = ModelEntity(mesh: spec.mesh, materials: spec.materials)
            entity.addChild(model)
            var piece = Piece(model: model, half: half, meshCenter: spec.mesh.bounds.center,
                              yaw: yaw, tilt: tilt, tiltAxis: [tiltAxis.x, 0, tiltAxis.y],
                              slider: slider, slideFrom: slideFrom, delay: delay, fall: fall,
                              post: Double.random(in: 0.24...0.32, using: &rng), dropHeight: dropHeight,
                              drift: drift, spinAxis: spinAxis, spinAngle: spinAngle,
                              wobbleAxis: [wobbleAxis2.x, 0, wobbleAxis2.y], wobble: wobble, hop: hop,
                              removeDelay: removeDelay, moveJitter: moveJitter)
            piece.canonical = best
            pieces.append(piece)
        }

        let apexXZ = Self.xz(surface.apex)
        var xzs = pieces.map { apexXZ + $0.canonical * surfaceRadius }
        relax(&xzs, on: surface, passes: 8)
        settleAll(&xzs, on: surface)
        for index in pieces.indices {
            pieces[index].canonical = (xzs[index] - apexXZ) / surfaceRadius
        }

        for index in pieces.indices {
            if animated {
                pieces[index].motion = .drop(start: now)
                pieces[index].scale = 0
                pieces[index].model.isEnabled = false
            } else {
                pieces[index].shown = pieces[index].rest
                pieces[index].motion = .none
                place(pieces[index])
            }
        }
        animating = animated
        if animated { update(now: now) }
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        guard !pieces.isEmpty else { return }
        surfaceRadius = max(surface.radius, 1e-3)
        let apexXZ = Self.xz(surface.apex)
        var xzs = pieces.map { apexXZ + $0.canonical * surfaceRadius }
        relax(&xzs, on: surface, passes: 4)
        settleAll(&xzs, on: surface)
        for index in pieces.indices {
            var piece = pieces[index]
            switch piece.motion {
            case .pop:
                break
            case .drop(let start) where now < start + piece.delay:
                break
            default:
                if duration <= 0 {
                    piece.shown = piece.rest
                    piece.motion = .none
                    place(piece)
                } else {
                    let falling = piece.rest.position.y < piece.shown.position.y - 1e-4
                    let lag = falling ? 0.14 * piece.moveJitter : 0
                    piece.motion = .move(from: piece.shown, start: now + duration * lag,
                                         duration: duration * (1 - lag), falling: falling)
                    piece.path = []
                    animating = true
                }
            }
            pieces[index] = piece
        }
    }

    func remove(now: Double) {
        guard !pieces.isEmpty else {
            isFinished = true
            return
        }
        for index in pieces.indices {
            pieces[index].motion = .pop(from: pieces[index].shown, start: now + pieces[index].removeDelay)
        }
        footprints = []
        animating = true
    }

    func update(now: Double) {
        guard animating else { return }
        var active = false
        var popping = false
        for index in pieces.indices {
            switch pieces[index].motion {
            case .none:
                continue
            case .drop(let start):
                active = stepDrop(index, t: now - start - pieces[index].delay) || active
            case let .move(from, start, duration, falling):
                active = stepMove(index, from: from, t: (now - start) / duration, falling: falling) || active
            case let .pop(from, start):
                popping = true
                active = stepPop(index, from: from, t: now - start) || active
            }
            place(pieces[index])
        }
        if !active {
            animating = false
            if popping { isFinished = true }
        }
    }

    // MARK: Motion

    private func stepDrop(_ index: Int, t: Double) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else {
            piece.model.isEnabled = false
            return true
        }
        piece.model.isEnabled = true
        piece.scale = 1
        let impact = piece.path.first ?? piece.rest
        if t < piece.fall {
            let s = Float(t / piece.fall)
            let top = impact.position + SIMD3(piece.drift.x, piece.dropHeight, piece.drift.y)
            var position = simd_mix(top, impact.position, SIMD3(s, s * s, s))
            position.y = max(position.y, impact.position.y)
            let spin = simd_quatf(angle: piece.spinAngle * (1 - s), axis: piece.spinAxis)
            piece.shown = Pose(position: position, rotation: impact.rotation * spin)
            return true
        }
        let after = t - piece.fall
        let slideEnd = piece.slider ? Self.slideDuration + 0.06 : 0
        let total = max(piece.post, slideEnd)
        let u = Float(min(after / piece.post, 1))
        var pose = impact
        if piece.slider, piece.path.count > 1 {
            let v = Ease.inOutSine(Float(min(max((after - 0.06) / Self.slideDuration, 0), 1)))
            pose = Self.along(piece.path, v)
        }
        let hopFraction: Float = 0.45
        let hopU = min(u / hopFraction, 1)
        let lift = (piece.slider ? 0.5 : 1) * piece.hop * 4 * hopU * (1 - hopU)
        let angle = piece.wobble * exp(-4 * u) * sin(3 * .pi * u)
        piece.shown = Self.rocked(pose, angle: angle, axis: piece.wobbleAxis, pivotDrop: min(piece.half.x, min(piece.half.y, piece.half.z)))
        piece.shown.position.y += lift
        if after >= total {
            piece.shown = piece.rest
            piece.path = []
            piece.motion = .none
            return false
        }
        return true
    }

    private func stepMove(_ index: Int, from: Pose, t: Double, falling: Bool) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        piece.model.isEnabled = true
        piece.scale = 1
        let p = Float(min(max(t, 0), 1))
        if !falling {
            let e = Ease.inOutCubic(p)
            piece.shown = from.mixed(piece.rest, e)
        } else {
            let land: Float = 0.8
            if p < land {
                let s = p / land
                var pose = from.mixed(piece.rest, Ease.inOutSine(s))
                pose.position.y = lerp(from.position.y, piece.rest.position.y, s * s)
                piece.shown = pose
            } else {
                let u = (p - land) / (1 - land)
                let drop = from.position.y - piece.rest.position.y
                let hop = min(0.12 * drop, 0.35 * piece.hop + 0.0015) * 4 * u * (1 - u)
                let angle = 0.5 * piece.wobble * exp(-3 * u) * sin(2 * .pi * u)
                piece.shown = Self.rocked(piece.rest, angle: angle, axis: piece.wobbleAxis,
                                          pivotDrop: min(piece.half.x, min(piece.half.y, piece.half.z)))
                piece.shown.position.y += hop
            }
        }
        if t >= 1 {
            piece.shown = piece.rest
            piece.motion = .none
            return false
        }
        return true
    }

    private func stepPop(_ index: Int, from: Pose, t: Double) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else { return true }
        if t < Self.popGrow {
            let s = Float(t / Self.popGrow)
            piece.scale = 1 + 0.2 * Ease.outQuad(s)
            piece.shown = from
            piece.shown.position.y += 0.4 * piece.hop * Ease.outQuad(s)
            return true
        }
        let s = Float(min((t - Self.popGrow) / Self.popShrink, 1))
        piece.scale = 1.2 * (1 - Ease.inCubic(s))
        piece.shown = from
        piece.shown.position.y += piece.hop * (0.4 + 0.6 * s)
        if s >= 1 {
            piece.scale = 0
            piece.model.isEnabled = false
            piece.motion = .none
            return false
        }
        return true
    }

    private func place(_ piece: Piece) {
        let scale = max(piece.scale, 1e-4)
        let rotation = piece.shown.rotation
        piece.model.transform = Transform(scale: SIMD3(repeating: scale), rotation: rotation,
                                          translation: piece.shown.position - rotation.act(piece.meshCenter * scale))
    }

    private static func rocked(_ pose: Pose, angle: Float, axis: SIMD3<Float>, pivotDrop: Float) -> Pose {
        guard abs(angle) > 1e-5 else { return pose }
        let rock = simd_quatf(angle: angle, axis: axis)
        let pivot = pose.position - SIMD3(0, pivotDrop, 0)
        return Pose(position: pivot + rock.act(pose.position - pivot), rotation: rock * pose.rotation)
    }

    private static func along(_ path: [Pose], _ v: Float) -> Pose {
        let scaled = v * Float(path.count - 1)
        let index = min(Int(scaled), path.count - 2)
        return path[index].mixed(path[index + 1], scaled - Float(index))
    }

    // MARK: Placement

    /// Settles pieces in order, each on the surface and the pieces before it. One that would land on
    /// top of another first looks a little around the crown for a spot where it can lie on the surface.
    private func settleAll(_ xzs: inout [SIMD2<Float>], on surface: ToppingSurface) {
        footprints.removeAll(keepingCapacity: true)
        let apexXZ = Self.xz(surface.apex)
        var below = occupied
        for index in pieces.indices {
            var piece = pieces[index]
            var (rest, footprint) = settle(xzs[index], piece: piece, on: surface, over: below)
            let thinnest = min(piece.half.x, min(piece.half.y, piece.half.z))
            var stacked = rest.position.y - settle(xzs[index], piece: piece, on: surface, over: []).0.position.y
            var attempt = 1
            while stacked > 0.3 * thinnest, attempt <= 10 {
                let ring = Float((attempt + 1) / 2)
                let turn = simd_quatf(angle: (attempt % 2 == 0 ? -0.32 : 0.32) * ring, axis: [0, 1, 0])
                let offset = turn.act(SIMD3(xzs[index].x - apexXZ.x, 0, xzs[index].y - apexXZ.y)) * (1 + 0.05 * ring)
                let candidate = clampToSurface(apexXZ + SIMD2(offset.x, offset.z), on: surface)
                let tried = settle(candidate, piece: piece, on: surface, over: below)
                let lift = tried.0.position.y - settle(candidate, piece: piece, on: surface, over: []).0.position.y
                if lift < stacked {
                    stacked = lift
                    (rest, footprint) = tried
                    xzs[index] = candidate
                }
                attempt += 1
            }
            piece.rest = rest
            footprints.append(footprint)
            if piece.slider {
                let start = apexXZ + (xzs[index] - apexXZ) * piece.slideFrom
                piece.path = (0...4).map { step in
                    let t = Float(step) / 4
                    return settle(simd_mix(start, xzs[index], SIMD2(repeating: t)), piece: piece, on: surface, over: below).0
                }
                piece.path[4] = piece.rest
            } else {
                piece.path = []
            }
            below.append(footprint)
            pieces[index] = piece
        }
    }

    /// Lies the piece along the surface's slope under its footprint and lifts it until no part of its
    /// rounded box is below the surface or inside a piece already there, less a slight nestle so it
    /// reads as resting rather than hovering. A tipped piece that could only clear the slope by
    /// hanging in the air under its middle is tipped less until it rests.
    private func settle(_ xz: SIMD2<Float>, piece: Piece, on surface: ToppingSurface,
                        over pieces: [ScatterFootprint]) -> (Pose, ScatterFootprint) {
        let center = surface.sample(x: xz.x, z: xz.y) ?? (surface.apex.y, SIMD3<Float>(0, 1, 0))
        let span = max(max(piece.half.x, piece.half.z) * 0.6, 0.001)
        let align = simd_quatf(from: [0, 1, 0], to: simd_normalize(Self.fittedNormal(xz, span: span, surface: surface) ?? center.normal))
        let thinnest = min(piece.half.x, min(piece.half.y, piece.half.z))
        let nestle = 0.08 * thinnest
        let reachable = pieces.filter { simd_distance($0.center, xz) < $0.halfLength + $0.radius + simd_length(piece.half) }
        var result: (Pose, ScatterFootprint)?
        for tiltScale: Float in [1, 0.5, 0.2, 0] {
            let rotation = align * piece.local(tiltScale: tiltScale)
            var footprint = Self.footprint(xz, rotation: rotation, half: piece.half)
            var height = center.height + piece.half.y
            var found = false
            var reach: Float = 0, depth: Float = 0
            var floorUnder = center.height
            for other in reachable where other.contains(xz) { floorUnder = max(floorUnder, other.top) }
            for direction in Self.support {
                let offset = rotation.act(direction * piece.half)
                reach = max(reach, offset.y)
                depth = max(depth, -offset.y)
                let point = SIMD2(xz.x + offset.x, xz.y + offset.z)
                guard var floor = surface.sample(x: point.x, z: point.y)?.height else { continue }
                for other in reachable where other.contains(point) { floor = max(floor, other.top) }
                let needed = floor - offset.y
                height = found ? max(height, needed) : needed
                found = true
            }
            footprint.top = height - nestle + reach * 0.92
            result = (Pose(position: [xz.x, height - nestle, xz.y], rotation: rotation), footprint)
            let hang = height - depth - floorUnder
            if hang < 0.3 * thinnest + 0.0004 { break }
        }
        return result!
    }

    private func relax(_ xzs: inout [SIMD2<Float>], on surface: ToppingSurface, passes: Int) {
        var shapes = [ScatterFootprint](repeating: ScatterFootprint(center: .zero, axis: [1, 0], halfLength: 0, radius: 0),
                                        count: xzs.count)
        for _ in 0..<passes {
            for index in xzs.indices {
                let normal = surface.sample(x: xzs[index].x, z: xzs[index].y)?.normal ?? [0, 1, 0]
                let rotation = simd_quatf(from: [0, 1, 0], to: simd_normalize(normal)) * pieces[index].local()
                shapes[index] = Self.footprint(xzs[index], rotation: rotation, half: pieces[index].half)
            }
            for i in xzs.indices {
                for footprint in occupied {
                    if let push = Self.separation(shapes[i], footprint) {
                        xzs[i] += push
                        shapes[i].center += push
                    }
                }
                for j in xzs.indices where j > i {
                    if let push = Self.separation(shapes[i], shapes[j]) {
                        xzs[i] += push * 0.5
                        xzs[j] -= push * 0.5
                        shapes[i].center += push * 0.5
                        shapes[j].center -= push * 0.5
                    }
                }
            }
            for index in xzs.indices {
                xzs[index] = clampToSurface(xzs[index], on: surface)
            }
        }
    }

    /// Pulls a spot in toward the apex until it's within reach and not too steep to rest on.
    private func clampToSurface(_ xz: SIMD2<Float>, on surface: ToppingSurface) -> SIMD2<Float> {
        let apexXZ = Self.xz(surface.apex)
        let limit = surfaceRadius * Self.maxReach
        var offset = xz - apexXZ
        let length = simd_length(offset)
        if length > limit { offset *= limit / length }
        var tries = 0
        while tries < 16, (surface.sample(x: apexXZ.x + offset.x, z: apexXZ.y + offset.y)?.normal.y ?? 0) < Self.steepest {
            offset *= 0.93
            tries += 1
        }
        return apexXZ + offset
    }

    private static func footprint(_ xz: SIMD2<Float>, rotation: simd_quatf, half: SIMD3<Float>) -> ScatterFootprint {
        let axes = [rotation.act([half.x, 0, 0]), rotation.act([0, half.y, 0]), rotation.act([0, 0, half.z])]
            .map { SIMD2<Float>($0.x, $0.z) }
        let lengths = axes.map(simd_length)
        let long = lengths[0] >= lengths[1] ? (lengths[0] >= lengths[2] ? 0 : 2) : (lengths[1] >= lengths[2] ? 1 : 2)
        let side = lengths.enumerated().filter { $0.offset != long }.map(\.element).max() ?? 0
        let axis = lengths[long] > 1e-6 ? axes[long] / lengths[long] : SIMD2<Float>(1, 0)
        return ScatterFootprint(center: xz, axis: axis, halfLength: max(lengths[long] - side, 0) * 0.95,
                                radius: side * 0.9)
    }

    /// How far to move `a` so it no longer overlaps `b`, or nil when they're already clear.
    private static func separation(_ a: ScatterFootprint, _ b: ScatterFootprint) -> SIMD2<Float>? {
        let (p, q) = closestPoints(a.center - a.axis * a.halfLength, a.center + a.axis * a.halfLength,
                                   b.center - b.axis * b.halfLength, b.center + b.axis * b.halfLength)
        let gap = p - q
        let distance = simd_length(gap)
        let overlap = a.radius + b.radius - distance
        guard overlap > 0 else { return nil }
        let direction = distance > 1e-6 ? gap / distance : unit2(Float(a.center.x * 9137 + a.center.y * 7331))
        return direction * overlap
    }

    private static func closestPoints(_ p1: SIMD2<Float>, _ q1: SIMD2<Float>, _ p2: SIMD2<Float>, _ q2: SIMD2<Float>)
        -> (SIMD2<Float>, SIMD2<Float>) {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s: Float = 0, t: Float = 0
        if a <= 1e-10, e <= 1e-10 { return (p1, p2) }
        if a <= 1e-10 {
            t = Ease.clamp01(f / e)
        } else {
            let c = simd_dot(d1, r)
            if e <= 1e-10 {
                s = Ease.clamp01(-c / a)
            } else {
                let b = simd_dot(d1, d2)
                let denominator = a * e - b * b
                s = denominator > 1e-10 ? Ease.clamp01((b * f - c * e) / denominator) : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = Ease.clamp01(-c / a)
                } else if t > 1 {
                    t = 1
                    s = Ease.clamp01((b - c) / a)
                }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    private static func fittedNormal(_ xz: SIMD2<Float>, span: Float, surface: ToppingSurface) -> SIMD3<Float>? {
        guard let east = surface.sample(x: xz.x + span, z: xz.y), let west = surface.sample(x: xz.x - span, z: xz.y),
              let north = surface.sample(x: xz.x, z: xz.y + span), let south = surface.sample(x: xz.x, z: xz.y - span)
        else { return nil }
        let normal = SIMD3<Float>(-(east.height - west.height) / (2 * span), 1, -(north.height - south.height) / (2 * span))
        return simd_normalize(normal)
    }

    /// A rounded box: face centers, edge midpoints and corners pulled in, so discs and beans don't hover on their box corners.
    private static let support: [SIMD3<Float>] = {
        var points: [SIMD3<Float>] = []
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                var p = SIMD3<Float>.zero
                p[axis] = sign
                points.append(p)
            }
        }
        for a in [Float(-1), 1] {
            for b in [Float(-1), 1] {
                points.append(SIMD3(a, b, 0) * 0.82)
                points.append(SIMD3(a, 0, b) * 0.82)
                points.append(SIMD3(0, a, b) * 0.82)
                for c in [Float(-1), 1] { points.append(SIMD3(a, b, c) * 0.72) }
            }
        }
        return points
    }()

    private static func xz(_ point: SIMD3<Float>) -> SIMD2<Float> { [point.x, point.z] }
    private static func unit2(_ angle: Float) -> SIMD2<Float> { [cos(angle), sin(angle)] }

    private static func randomUnit(_ rng: inout ToppingRandom) -> SIMD3<Float> {
        let y = Float.random(in: -1...1, using: &rng)
        let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
        let r = (1 - y * y).squareRoot()
        return [r * cos(angle), y, r * sin(angle)]
    }
}
