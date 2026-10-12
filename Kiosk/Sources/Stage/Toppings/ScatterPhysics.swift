import simd

struct ScatterPose {
    var position: SIMD3<Float>
    var rotation: simd_quatf

    func mixed(_ other: ScatterPose, _ t: Float) -> ScatterPose {
        ScatterPose(position: simd_mix(position, other.position, SIMD3(repeating: t)),
                    rotation: simd_slerp(rotation, other.rotation, t))
    }
}

/// The solid a scattered piece is simulated as, fitted to its half extents: a rod becomes a capsule,
/// a disc or ball an ellipsoid, anything else a rounded box.
struct ScatterShape {
    enum Kind {
        case box(rounding: Float)
        case ellipsoid
        case capsule(axis: Int, radius: Float, halfLength: Float)
    }

    let kind: Kind
    let half: SIMD3<Float>
    /// Points on the surface that are tested for contact.
    let points: [SIMD3<Float>]
    let bound: Float
    /// Per unit mass, about the local axes.
    let inverseInertia: SIMD3<Float>

    init(half: SIMD3<Float>) {
        self.half = half
        let order = [0, 1, 2].sorted { half[$0] > half[$1] }
        let a = half[order[0]], b = half[order[1]], c = half[order[2]]
        var points: [SIMD3<Float>] = []
        if a > 2.2 * b, b < 1.4 * c {
            let axis = order[0]
            let radius = b
            let length = a - b
            kind = .capsule(axis: axis, radius: radius, halfLength: length)
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            for end: Float in [-1, 1] {
                var tip = SIMD3<Float>.zero
                tip[axis] = end * (length + radius)
                points.append(tip)
            }
            for along: Float in [-1, 1] {
                for k in 0..<6 {
                    let angle = Float(k) * .pi / 3 + (along < 0 ? .pi / 6 : 0)
                    var p = SIMD3<Float>.zero
                    p[axis] = along * length
                    p[u] = cos(angle) * radius
                    p[v] = sin(angle) * radius
                    points.append(p)
                }
            }
        } else if (a < 1.25 * b && c < 0.75 * b) || a < 1.15 * c {
            kind = .ellipsoid
            let count = 56
            for i in 0..<count {
                let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
                let r = (1 - y * y).squareRoot()
                let theta = Float(i) * 2.399_963
                points.append(SIMD3(r * cos(theta), y, r * sin(theta)) * half)
            }
            for axis in 0..<3 {
                for sign: Float in [-1, 1] {
                    var p = SIMD3<Float>.zero
                    p[axis] = sign * half[axis]
                    points.append(p)
                }
            }
        } else {
            let rounding = 0.45 * c
            kind = .box(rounding: rounding)
            for x: Float in [-1, 0, 1] {
                for y: Float in [-1, 0, 1] {
                    for z: Float in [-1, 0, 1] where x != 0 || y != 0 || z != 0 {
                        let sign = SIMD3(x, y, z)
                        points.append((half - rounding) * sign + simd_normalize(sign) * rounding)
                    }
                }
            }
        }
        self.points = points
        bound = points.map(simd_length).max() ?? simd_length(half)
        let squared = half * half
        let scale: Float
        switch kind {
        case .ellipsoid: scale = 1.0 / 5
        default: scale = 1.0 / 3
        }
        inverseInertia = 1 / (scale * SIMD3(squared.y + squared.z, squared.x + squared.z, squared.x + squared.y))
    }

    /// Signed distance from the local point to the surface (negative inside), and the outward normal there.
    func contact(_ p: SIMD3<Float>) -> (distance: Float, normal: SIMD3<Float>) {
        switch kind {
        case .box(let rounding):
            let core = half - rounding
            let q = simd_abs(p) - core
            let outside = simd_max(q, .zero)
            let outsideLength = simd_length(outside)
            if outsideLength > 1e-7 {
                let sign = SIMD3<Float>(p.x < 0 ? -1 : 1, p.y < 0 ? -1 : 1, p.z < 0 ? -1 : 1)
                return (outsideLength - rounding, outside / outsideLength * sign)
            }
            let axis = q.x > q.y ? (q.x > q.z ? 0 : 2) : (q.y > q.z ? 1 : 2)
            var normal = SIMD3<Float>.zero
            normal[axis] = p[axis] < 0 ? -1 : 1
            return (q[axis] - rounding, normal)
        case .ellipsoid:
            let k0 = simd_length(p / half)
            let gradient = p / (half * half)
            let k1 = simd_length(gradient)
            guard k1 > 1e-7 else { return (-half.min(), [0, 1, 0]) }
            return (k0 * (k0 - 1) / k1, gradient / k1)
        case let .capsule(axis, radius, length):
            var nearest = SIMD3<Float>.zero
            nearest[axis] = min(max(p[axis], -length), length)
            let offset = p - nearest
            let distance = simd_length(offset)
            guard distance > 1e-7 else {
                var normal = SIMD3<Float>.zero
                normal[(axis + 1) % 3] = 1
                return (-radius, normal)
            }
            return (distance - radius, offset / distance)
        }
    }
}

/// A piece resting on an item, as later pieces and later scatter layers see it.
struct ScatterFootprint {
    let shape: ScatterShape
    var position: SIMD3<Float>
    var rotation: simd_quatf
    /// Resting up on other pieces rather than down on the ice cream; nothing may rest on it in turn.
    var raised = false
}

/// Drops one rigid piece onto a surface among pieces already at rest, with gravity, friction and a
/// little bounce, until it comes to rest or leaves the item. Fixed timestep, so the same inputs always
/// give the same result.
struct ScatterSettle {
    struct Outcome {
        var rest: ScatterPose
        /// Poses every `recordInterval` of simulated time from the start; the last one is `rest`.
        var track: [ScatterPose]
        var fell: Bool
        /// It came to rest touching only other pieces, none of the surface.
        var onPieces: Bool
    }

    static let step: Float = 1.0 / 240
    static let recordEvery = 4
    static var recordInterval: Float { step * Float(recordEvery) }
    static let gravity: Float = 9.8
    static let creamFriction: Float = 1.5
    static let candyFriction: Float = 0.4
    /// Candy pressed onto candy, as when laid by hand rather than tossed.
    static let tackyFriction: Float = 1
    static let creamBounce: Float = 0
    static let candyBounce: Float = 0.15
    /// Soft ice cream soaks up motion: per-second damping while touching it.
    static let creamDrag: Float = 30
    static let creamSpinDrag: Float = 60
    /// Rolling resistance of soft ice cream, as a fraction of the piece's thinnest half extent.
    static let rollingResistance: Float = 0.9
    /// Meters; more would let soft cream hold a big piece standing on end.
    static let maxRollingResistance: Float = 0.0012
    static let whipFriction: Float = 3
    static let whipRollingResistance: Float = 0.004
    static let whipSink: Float = 0.0009

    let surface: SurfaceField
    /// Below this height the piece has fallen off the item.
    let floor: Float

    private struct Contact {
        var r: SIMD3<Float>
        var n: SIMD3<Float>
        var depth: Float
        var friction: Float
        var bounce: Float
        var t1 = SIMD3<Float>.zero
        var t2 = SIMD3<Float>.zero
        var kn: Float = 1
        var k1: Float = 1
        var k2: Float = 1
        var target: Float = 0
        var jn: Float = 0
        var jt = SIMD2<Float>.zero
    }

    @_optimize(speed)
    func run(_ shape: ScatterShape, from start: ScatterPose, velocity: SIMD3<Float>, spin: SIMD3<Float>,
             among obstacles: [ScatterFootprint], grip: Float = 0, maxTime: Float = 1.6) -> Outcome {
        let dt = Self.step
        let candyFriction = lerp(Self.candyFriction, Self.tackyFriction, grip)
        var x = start.position
        var q = start.rotation
        var v = velocity
        var w = spin
        var track = [start]
        var contacts: [Contact] = []
        contacts.reserveCapacity(64)
        let near = obstacles.filter { simd_distance($0.position, x) < $0.shape.bound + shape.bound + 0.02 }
        var touching: [Int] = []
        touching.reserveCapacity(near.count)
        let slop: Float = 0.0003
        let gridSpacing: Float = 0.0025
        let usesGrid = shape.bound > 0.006
        var still: Float = 0
        let steps = Int(maxTime / dt)
        var fell = false
        var wasOnCream = false
        var touchedLast = false
        for i in 1...steps {
            if wasOnCream || (grip > 0 && touchedLast) {
                v *= max(1 - Self.creamDrag * dt, 0)
                w *= max(1 - Self.creamSpinDrag * dt, 0)
            }
            v.y -= Self.gravity * dt
            contacts.removeAll(keepingCapacity: true)
            touching.removeAll(keepingCapacity: true)
            for (index, other) in near.enumerated() where simd_distance(other.position, x) < other.shape.bound + shape.bound + 0.001 {
                touching.append(index)
            }
            let inverse = q.inverse
            var onCream = false
            var soft: Float = 0
            var sink: Float = 0
            var overlap = SIMD3<Float>.zero
            var overlapDepth: Float = 0
            var lowest = Float.infinity
            for s in shape.points {
                let r = q.act(s)
                let p = x + r
                if let ground = surface.sample(x: p.x, z: p.z) {
                    let give = max(surface.softness(x: p.x, z: p.z), grip)
                    let height = ground.height - give * Self.whipSink
                    let depth = (height - p.y) * ground.normal.y
                    sink = max(sink, height - p.y)
                    lowest = min(lowest, p.y - height)
                    if depth > -slop {
                        onCream = true
                        soft = max(soft, give)
                        contacts.append(Contact(r: r, n: ground.normal, depth: depth,
                                                friction: lerp(Self.creamFriction, Self.whipFriction, give),
                                                bounce: Self.creamBounce))
                    }
                }
                for index in touching {
                    let other = near[index]
                    let local = other.rotation.inverse.act(p - other.position)
                    guard simd_length_squared(local) < other.shape.bound * other.shape.bound else { continue }
                    let hit = other.shape.contact(local)
                    if hit.distance < slop {
                        let normal = other.rotation.act(hit.normal)
                        contacts.append(Contact(r: r, n: normal, depth: -hit.distance,
                                                friction: candyFriction, bounce: Self.candyBounce))
                        if -hit.distance > overlapDepth {
                            overlapDepth = -hit.distance
                            overlap = normal
                        }
                    }
                }
            }
            for index in touching {
                let other = near[index]
                for s in other.shape.points {
                    let p = other.position + other.rotation.act(s)
                    let local = inverse.act(p - x)
                    guard simd_length_squared(local) < shape.bound * shape.bound else { continue }
                    let hit = shape.contact(local)
                    if hit.distance < slop {
                        let normal = -q.act(hit.normal)
                        contacts.append(Contact(r: p - x, n: normal, depth: -hit.distance,
                                                friction: candyFriction, bounce: Self.candyBounce))
                        if -hit.distance > overlapDepth {
                            overlapDepth = -hit.distance
                            overlap = normal
                        }
                    }
                }
            }

            if usesGrid, lowest < shape.bound {
                let reach = shape.bound
                let cells = Int((2 * reach / gridSpacing).rounded(.up))
                for gi in 0...cells {
                    for gj in 0...cells {
                        let gx = x.x - reach + Float(gi) * gridSpacing
                        let gz = x.z - reach + Float(gj) * gridSpacing
                        guard let ground = surface.sample(x: gx, z: gz) else { continue }
                        let give = max(surface.softness(x: gx, z: gz), grip)
                        let g = SIMD3(gx, ground.height - give * Self.whipSink, gz)
                        let local = inverse.act(g - x)
                        guard simd_length_squared(local) < shape.bound * shape.bound else { continue }
                        let hit = shape.contact(local)
                        if hit.distance < slop {
                            let normal = -q.act(hit.normal)
                            onCream = true
                            soft = max(soft, give)
                            contacts.append(Contact(r: g - x, n: normal, depth: -hit.distance,
                                                    friction: lerp(Self.creamFriction, Self.whipFriction, give),
                                                    bounce: Self.creamBounce))
                            if -hit.distance > overlapDepth {
                                overlapDepth = -hit.distance
                                overlap = normal
                            }
                        }
                    }
                }
            }

            let rotation = simd_float3x3(q)
            let inertia = rotation * simd_float3x3(diagonal: shape.inverseInertia) * rotation.transpose
            for k in contacts.indices {
                var c = contacts[k]
                c.t1 = simd_normalize(simd_cross(c.n, abs(c.n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
                c.t2 = simd_cross(c.n, c.t1)
                let rn = simd_cross(c.r, c.n), r1 = simd_cross(c.r, c.t1), r2 = simd_cross(c.r, c.t2)
                c.kn = 1 + simd_dot(rn, inertia * rn)
                c.k1 = 1 + simd_dot(r1, inertia * r1)
                c.k2 = 1 + simd_dot(r2, inertia * r2)
                let vn = simd_dot(v + simd_cross(w, c.r), c.n)
                c.target = vn < -0.1 ? -c.bounce * vn : 0
                contacts[k] = c
            }
            let rolling = lerp(min(Self.rollingResistance * shape.half.min(), Self.maxRollingResistance),
                               Self.whipRollingResistance, soft)
            var rollingImpulse: Float = 0
            for _ in 0..<6 {
                var creamImpulse: Float = 0
                for k in contacts.indices {
                    var c = contacts[k]
                    let vn = simd_dot(v + simd_cross(w, c.r), c.n)
                    let total = max(c.jn + (c.target - vn) / c.kn, 0)
                    let jn = total - c.jn
                    c.jn = total
                    v += c.n * jn
                    w += inertia * simd_cross(c.r, c.n * jn)
                    let vp = v + simd_cross(w, c.r)
                    var jt = c.jt - SIMD2(simd_dot(vp, c.t1) / c.k1, simd_dot(vp, c.t2) / c.k2)
                    let limit = c.friction * c.jn
                    let length = simd_length(jt)
                    if length > limit { jt *= limit / length }
                    let delta = jt - c.jt
                    c.jt = jt
                    let impulse = c.t1 * delta.x + c.t2 * delta.y
                    v += impulse
                    w += inertia * simd_cross(c.r, impulse)
                    if c.friction >= Self.creamFriction { creamImpulse += c.jn }
                    contacts[k] = c
                }
                let speed = simd_length(w)
                if speed > 1e-6, creamImpulse > 0 {
                    let axis = w / speed
                    let response = simd_dot(axis, inertia * axis)
                    let wanted = speed / response
                    let allowed = max(rolling * creamImpulse - rollingImpulse, 0)
                    let applied = min(wanted, allowed)
                    rollingImpulse += applied
                    w -= inertia * axis * applied
                }
            }
            wasOnCream = onCream
            touchedLast = !contacts.isEmpty
            x += v * dt
            if sink > slop { x.y += (sink - slop) * 0.5 }
            if overlapDepth > slop { x += overlap * (overlapDepth - slop) * 0.5 }
            let spinning = simd_quatf(ix: w.x, iy: w.y, iz: w.z, r: 0)
            q = simd_normalize(q + (spinning * q) * (0.5 * dt))
            if i % Self.recordEvery == 0 { track.append(ScatterPose(position: x, rotation: q)) }
            if !contacts.isEmpty, simd_length(v) < 0.004, simd_length(w) < 0.3 {
                still += dt
                if still > 0.15 { break }
            } else {
                still = 0
            }
            if x.y < floor {
                fell = true
                break
            }
        }
        let rest = ScatterPose(position: x, rotation: q)
        track.append(rest)
        return Outcome(rest: rest, track: track, fell: fell || !touchedLast, onPieces: touchedLast && !wasOnCream)
    }
}

/// The surface beneath, probed once per corner of a fine grid the first time a settle touches it: a settle makes
/// hundreds of thousands of probes, and walking every layer of the stack for each would dominate its cost.
/// Each settle job owns its own field.
final class SurfaceField: ToppingSurface, @unchecked Sendable {
    private struct Corner {
        var height: Float = 0
        var softness: Float = 0
        var normal = SIMD3<Float>(0, 1, 0)
        var state: UInt8 = 0
    }

    static let cell: Float = 0.0005
    let source: any ToppingSurface
    let apex: SIMD3<Float>
    let radius: Float
    let floor: Float
    private let originX: Float
    private let originZ: Float
    private let size: Int
    private let corners: UnsafeMutablePointer<Corner>

    init(_ source: any ToppingSurface) {
        self.source = source
        apex = source.apex
        radius = source.radius
        floor = source.floor
        let reach = 2.8 * max(radius, 0.004) + 0.012
        size = Int((2 * reach / Self.cell).rounded(.up)) + 2
        originX = apex.x - reach
        originZ = apex.z - reach
        corners = .allocate(capacity: size * size)
        corners.initialize(repeating: Corner(), count: size * size)
    }

    deinit {
        corners.deinitialize(count: size * size)
        corners.deallocate()
    }

    private func corner(_ c: Int, _ r: Int) -> Corner? {
        let entry = corners + (r * size + c)
        switch entry.pointee.state {
        case 1: return entry.pointee
        case 2: return nil
        default:
            let x = originX + Float(c) * Self.cell, z = originZ + Float(r) * Self.cell
            guard let hit = source.sample(x: x, z: z) else {
                entry.pointee.state = 2
                return nil
            }
            entry.pointee = Corner(height: hit.height, softness: source.softness(x: x, z: z), normal: hit.normal, state: 1)
            return entry.pointee
        }
    }

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let fx = (x - originX) / Self.cell, fz = (z - originZ) / Self.cell
        guard fx >= 0, fz >= 0, fx < Float(size - 1), fz < Float(size - 1) else { return source.sample(x: x, z: z) }
        let c = Int(fx), r = Int(fz)
        let tx = fx - Float(c), tz = fz - Float(r)
        var weight: Float = 0
        var height: Float = 0
        var normal = SIMD3<Float>.zero
        for (dc, dr, w) in [(0, 0, (1 - tx) * (1 - tz)), (1, 0, tx * (1 - tz)), (0, 1, (1 - tx) * tz), (1, 1, tx * tz)] {
            guard w > 0, let k = corner(c + dc, r + dr) else { continue }
            weight += w
            height += k.height * w
            normal += k.normal * w
        }
        guard weight > 0.5, simd_length_squared(normal) > 1e-12 else { return nil }
        return (height / weight, simd_normalize(normal))
    }

    func softness(x: Float, z: Float) -> Float {
        let fx = (x - originX) / Self.cell, fz = (z - originZ) / Self.cell
        guard fx >= 0, fz >= 0, fx < Float(size - 1), fz < Float(size - 1) else { return source.softness(x: x, z: z) }
        return corner(Int(fx.rounded()), Int(fz.rounded()))?.softness ?? source.softness(x: x, z: z)
    }
}

/// How one piece is tossed: where it may land (offsets from the apex in units of the radius) and how it leaves the hand.
struct ScatterToss: Sendable {
    let candidates: [SIMD2<Float>]
    let orientation: simd_quatf
    let push: SIMD3<Float>
    let spin: SIMD3<Float>
}

struct ScatterLanding: Sendable {
    var rest: ScatterPose
    /// The recorded fall and settle, every `ScatterSettle.recordInterval` of simulated time; the last pose is `rest`.
    var track: [ScatterPose]
    var lost = false
}

struct ScatterPlan: Sendable {
    var landings: [ScatterLanding]
    var resting: [ScatterFootprint]
    var tally: [String: Int]
    var seconds: Double
}

/// Where each piece of a scatter layer lands, worked out from value snapshots only, so it can run off the main thread
/// and gives the same result for the same inputs.
struct ScatterPlanner {
    static let dropHeight: Float = 0.014
    static let dropSpeed: Float = 0.35
    /// Landings simulated for a piece, the roomiest spots first, before it falls back to resting on a lying piece, being
    /// left pressed where it was laid, or, with nowhere for either, left off.
    static let attempts = 10
    /// The first attempts toss the piece the way a hand would; the rest lay it on the slope, as a server presses it on.
    static let tossAttempts = 3
    /// Cosine of the steepest slope a piece is laid on.
    static let steepestLay: Float = 0.7
    /// Further landings simulated on steeper and lower spots, once the rest of the top is taken.
    static let lastResortAttempts = 4
    /// Steeper than `steepestLay`, a piece is only laid where the slope faces the camera (+z), not out to the side, where
    /// it would show edge-on past the scoop's outline.
    static let steepFacing: Float = 0.3
    /// A piece isn't laid where the slope faces this far toward the side: seen from the front it would stick out past
    /// the scoop's outline.
    static let sideways: Float = 0.5
    static let layGap: Float = 0.0008
    static let laySpeed: Float = 0.03
    /// A piece this small laid flat already follows the curve beneath it, so it's left where it's laid rather than settled.
    static let smallPiece: Float = 0.006
    /// A laid piece may start this far up to clear the pieces beneath it.
    static let highestLay: Float = 0.016
    /// Lifted no more than this, a piece left where it was laid is on the cream rather than on other pieces.
    static let pressedLift: Float = 0.002
    /// Laid pieces stay this far above the floor. Toward the back the camera sees down past a cup's rim; toward the
    /// front (+z) a piece much below the rim would be hidden by the cup's wall.
    static let lowestLay: Float = 0.002
    static let lowestInFront: Float = 0.006
    /// A piece with no room on the ice cream may rest on one lying piece, never on a heap.
    static let perchHeight: Float = 0.010
    /// With the whole serving to place and no room left anywhere else, a piece may be laid this far up onto others.
    static let pileHeight: Float = 0.03
    /// Cosine of the steepest slope pieces are aimed at; steeper spots can't hold them.
    static let steepestAim: Float = 0.6
    /// Carried onto a new surface, a piece tips with it by no more than this (radians), so pieces near the edge of a
    /// fresh swirl of cream lean on its side instead of standing up against it.
    static let steepestCarry: Float = 0.7

    let field: SurfaceField
    let settle: ScatterSettle
    private(set) var bodies: [ScatterFootprint]
    private(set) var tally: [String: Int] = [:]

    init(surface: any ToppingSurface, among below: [ScatterFootprint]) {
        field = SurfaceField(surface)
        settle = ScatterSettle(surface: field, floor: field.floor)
        bodies = below
    }

    /// `landed` hears each piece's landing as soon as it's worked out; later pieces never change earlier ones.
    static func toss(_ shapes: [ScatterShape], _ tosses: [ScatterToss], onto surface: any ToppingSurface,
                     among below: [ScatterFootprint], full: Bool, landed: (ScatterLanding) -> Void = { _ in }) -> ScatterPlan {
        let clock = ContinuousClock.now
        var planner = ScatterPlanner(surface: surface, among: below)
        var landings: [ScatterLanding] = []
        var resting: [ScatterFootprint] = []
        for index in shapes.indices {
            let landing = planner.land(shapes[index], toss: tosses[index], index: index, full: full)
            if !landing.lost, let footprint = planner.bodies.last { resting.append(footprint) }
            landings.append(landing)
            landed(landing)
        }
        return ScatterPlan(landings: landings, resting: resting, tally: planner.tally, seconds: Self.seconds(since: clock))
    }

    /// Each piece carried onto `surface` where it rests, by however much the surface beneath it rose or fell and tilted
    /// with it, then set down onto the surface (a little into whipped cream) or onto the pieces already moved, lowest
    /// first, so it keeps its place and way up rather than tumbling into a new one.
    static func resurface(_ shapes: [ScatterShape], _ landings: [ScatterLanding], from previous: (any ToppingSurface)?,
                          onto surface: any ToppingSurface, among below: [ScatterFootprint]) -> ScatterPlan {
        let clock = ContinuousClock.now
        let field = SurfaceField(surface)
        let old = previous.map(SurfaceField.init)
        let apexXZ = SIMD2(field.apex.x, field.apex.z)
        let order = landings.indices.sorted { landings[$0].rest.position.y < landings[$1].rest.position.y }
        var settled = below
        var after: [ScatterFootprint?] = Array(repeating: nil, count: landings.count)
        var out = landings
        for index in order where !landings[index].lost {
            let shape = shapes[index]
            var pose = landings[index].rest
            let from = SIMD2(pose.position.x, pose.position.z)
            let reach = 0.6 * shape.half.max()
            var xz = from
            var ground = lay(field, xz, reach)
            for _ in 0..<8 where ground == nil {
                xz = apexXZ + (xz - apexXZ) * 0.8
                ground = lay(field, xz, reach)
            }
            if let ground {
                if let then = old.flatMap({ lay($0, from, reach) }) {
                    pose.position.y += ground.height - then.height
                    var tilt = simd_quatf(from: then.normal, to: ground.normal)
                    if tilt.angle > Self.steepestCarry { tilt = simd_quatf(angle: Self.steepestCarry, axis: tilt.axis) }
                    pose.rotation = simd_normalize(tilt * pose.rotation)
                }
                pose.position.x = xz.x
                pose.position.z = xz.y
                var gap = Float.infinity
                for s in shape.points {
                    let p = pose.position + pose.rotation.act(s)
                    guard let under = field.sample(x: p.x, z: p.z) else { continue }
                    gap = min(gap, p.y - under.height)
                }
                if gap.isFinite { pose.position.y -= gap + field.softness(x: xz.x, z: xz.y) * ScatterSettle.whipSink }
                let near = settled.filter { simd_distance($0.position, pose.position) < $0.shape.bound + shape.bound + Self.perchHeight }
                var lift: Float = 0
                while lift < Self.perchHeight, !near.allSatisfy({ clear(shape, ScatterPose(position: pose.position + [0, lift, 0],
                                                                                             rotation: pose.rotation), of: $0) }) {
                    lift += 0.0005
                }
                pose.position.y += lift
            }
            out[index] = ScatterLanding(rest: pose, track: [pose])
            let footprint = ScatterFootprint(shape: shape, position: pose.position, rotation: pose.rotation,
                                             raised: isRaised(shape, pose, on: field, among: settled))
            settled.append(footprint)
            after[index] = footprint
        }
        return ScatterPlan(landings: out, resting: after.compactMap { $0 }, tally: [:], seconds: Self.seconds(since: clock))
    }

    /// The surface's height at `xz` and its normal averaged over a piece's footprint, so one lump doesn't tip it over.
    private static func lay(_ field: SurfaceField, _ xz: SIMD2<Float>, _ reach: Float) -> (height: Float, normal: SIMD3<Float>)? {
        guard let center = field.sample(x: xz.x, z: xz.y) else { return nil }
        var normal = center.normal
        for offset: SIMD2<Float> in [[reach, 0], [-reach, 0], [0, reach], [0, -reach]] {
            if let hit = field.sample(x: xz.x + offset.x, z: xz.y + offset.y) { normal += hit.normal }
        }
        return (center.height, simd_normalize(normal))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }

    /// Lands one piece among the bodies so far and adds it to them.
    mutating func land(_ shape: ScatterShape, toss: ScatterToss, index: Int, full: Bool) -> ScatterLanding {
        typealias P = ScatterPlanner
        let firstAngle = atan2(toss.candidates[0].y, toss.candidates[0].x)
        let ring = (0..<12).map { k -> SIMD2<Float> in
            let angle = firstAngle + Float(k) * 2.4
            return SIMD2(cos(angle), sin(angle)) * [0.3, 0.55, 0.8][k % 3]
        }
        let tossed = ranked(toss.candidates + ring, piece: shape, steepest: P.steepestAim, lowest: 0).prefix(P.tossAttempts)
        let wide = (0..<240).map { k -> SIMD2<Float> in
            let angle = firstAngle + Float(k) * 2.4
            return SIMD2(cos(angle), sin(angle)) * (0.15 + 2.25 * Float(k % 12) / 11)
        }
        let laid = ranked(wide, piece: shape, steepest: P.steepestLay, lowest: P.lowestLay, laying: true)
        let lastResort = ranked(wide, piece: shape, steepest: P.steepestAim, lowest: 0, laying: true)
        let spots: [(spot: SIMD2<Float>, lays: Bool)] = tossed.map { ($0, false) } + (laid + lastResort).map { ($0, true) }
        let small = shape.bound < P.smallPiece
        var attempt = 0
        var simulated = 0
        var placed: ScatterPose?
        var placedLift = Float.infinity
        var climbing = false
        var awkward: ScatterSettle.Outcome?
        var perched: ScatterSettle.Outcome?
        var landed: ScatterSettle.Outcome?
        var verdict = "lost"
        while attempt < spots.count {
            let (spot, lays) = spots[attempt]
            let simulating = simulated < P.attempts + P.lastResortAttempts
            var result: ScatterSettle.Outcome?
            if !lays {
                if simulating {
                    let ground = field.sample(x: spot.x, z: spot.y)?.height ?? field.apex.y
                    let start = ScatterPose(position: [spot.x, ground + P.dropHeight + shape.bound, spot.y], rotation: toss.orientation)
                    result = settle.run(shape, from: start, velocity: [toss.push.x, -P.dropSpeed, toss.push.z],
                                        spin: attempt == 0 ? toss.spin : .zero, among: bodies)
                    simulated += 1
                }
            } else if let found = layingPose(shape, at: spot, turn: Float(index) * 2.4 + Float(attempt) * 1.3,
                                             highest: small ? (climbing ? min(P.highestLay, placedLift - 1e-4) : 0) : P.highestLay) {
                consider(found, for: shape, placed: &placed, placedLift: &placedLift)
                let onCream = placedLift == 0
                if small {
                    if onCream, let placed {
                        landed = ScatterSettle.Outcome(rest: placed, track: [placed], fell: false, onPieces: false)
                        verdict = "laid"
                    }
                } else if simulating || onCream {
                    result = settle.run(shape, from: found.pose, velocity: -found.pose.rotation.act([0, 1, 0]) * P.laySpeed,
                                        spin: .zero, among: bodies, grip: 1)
                    simulated += 1
                }
                if onCream, let placed, let settled = result, judge(settled, shape: shape) != .lies {
                    landed = ScatterSettle.Outcome(rest: placed, track: [placed], fell: false, onPieces: false)
                    verdict = "laid"
                    result = nil
                }
            }
            if let result {
                switch judge(result, shape: shape) {
                case .lies where Self.isRaised(shape, result.rest, on: field, among: bodies):
                    if perched == nil { perched = result }
                case .lies:
                    landed = result
                    verdict = "lies"
                case .perches: if perched == nil { perched = result }
                case .wedges: if awkward == nil, !full { awkward = result }
                case .rejected: break
                }
            }
            if landed != nil { break }
            let searching = simulating || (perched == nil && awkward == nil && placedLift > 0)
            if searching, attempt + 1 < spots.count {
                attempt += 1
                continue
            }
            if small, !climbing, placed == nil, let firstLaid = spots.firstIndex(where: \.lays) {
                climbing = true
                attempt = firstLaid
                continue
            }
            break
        }
        if landed == nil, let perched {
            landed = perched
            verdict = "perches"
        } else if landed == nil, let awkward {
            landed = awkward
            verdict = "wedges"
        } else if landed == nil, let placed {
            landed = ScatterSettle.Outcome(rest: placed, track: [placed], fell: false, onPieces: placedLift > 0)
            verdict = "pressed"
        } else if landed == nil, full, let piled = pile(shape, spots: spots.filter(\.lays).map(\.spot), index: index, highest: Self.pileHeight)
                    ?? pile(shape, spots: wide.map { SIMD2(field.apex.x, field.apex.z) + $0 * max(field.radius, 1e-3) }, index: index,
                            highest: 2 * Self.pileHeight) {
            landed = ScatterSettle.Outcome(rest: piled, track: [piled], fell: false, onPieces: true)
            verdict = "pressed"
        }
        tally[verdict, default: 0] += 1
        guard let landed else {
            return ScatterLanding(rest: ScatterPose(position: field.apex, rotation: toss.orientation), track: [], lost: true)
        }
        bodies.append(ScatterFootprint(shape: shape, position: landed.rest.position, rotation: landed.rest.rotation,
                                       raised: Self.isRaised(shape, landed.rest, on: field, among: bodies)))
        return ScatterLanding(rest: landed.rest, track: Self.trimmed(landed.track, rest: landed.rest))
    }

    /// The recording runs on until the piece has been still for a while; the still end is cut so playback ends as it stops.
    static func trimmed(_ track: [ScatterPose], rest: ScatterPose) -> [ScatterPose] {
        guard track.count > 2 else { return track }
        let tilt = cos(Float(0.03))
        var last = track.count - 1
        while last > 1 {
            let pose = track[last - 1]
            if simd_distance(pose.position, rest.position) > 0.0003 || abs(simd_dot(pose.rotation.vector, rest.rotation.vector)) < tilt {
                break
            }
            last -= 1
        }
        var out = Array(track[...last])
        out[last] = rest
        return out
    }

    /// The whole serving has to go on: the lowest a piece can be laid onto the pieces already there.
    private func pile(_ shape: ScatterShape, spots: [SIMD2<Float>], index: Int, highest: Float) -> ScatterPose? {
        var best: (pose: ScatterPose, lift: Float)?
        for (k, spot) in spots.prefix(40).enumerated() {
            guard let found = layingPose(shape, at: spot, turn: Float(index) * 2.4 + Float(k) * 1.3, highest: highest),
                  found.lift < best?.lift ?? .infinity else { continue }
            best = found
            if found.lift < Self.pressedLift { break }
        }
        return best.map { found in
            var pose = found.pose
            pose.position.y -= Self.layGap
            return pose
        }
    }

    /// Keeps the lowest pose where the piece could be left pressed onto the slope, or onto pieces but no higher than a
    /// perch, so never up a heap, as the fallback when nothing it was dropped or laid onto settled.
    private func consider(_ found: (pose: ScatterPose, lift: Float), for shape: ScatterShape, placed: inout ScatterPose?,
                          placedLift: inout Float) {
        var pressed = found.pose
        pressed.position.y -= Self.layGap
        guard found.lift < placedLift, let ground = field.sample(x: pressed.position.x, z: pressed.position.z) else { return }
        if found.lift > Self.pressedLift {
            guard !Self.supports(shape, pressed, among: bodies).isEmpty,
                  Self.above(pressed, ground) < Self.perchHeight + shape.half.min() else { return }
        } else if Self.restsOnRaised(shape, pressed, among: bodies) {
            return
        }
        placed = pressed
        placedLift = found.lift
    }

    /// Lying flat on the slope just clear of the surface, turned the way that needs the least lift to clear the pieces
    /// already there, so a piece laid where they lie comes down on top of them. Nil if it would have to rise too far.
    private func layingPose(_ shape: ScatterShape, at spot: SIMD2<Float>, turn: Float, highest: Float) -> (pose: ScatterPose, lift: Float)? {
        guard highest >= 0, let ground = field.sample(x: spot.x, z: spot.y) else { return nil }
        let tilt = simd_quatf(from: [0, 1, 0], to: ground.normal)
        let base = SIMD3(spot.x, ground.height, spot.y) + ground.normal * (shape.half.y + Self.layGap)
        let near = bodies.filter { simd_distance($0.position, base) < $0.shape.bound + shape.bound + highest }
        let step: Float = 0.0005
        var best: ScatterPose?
        var lowest = highest
        for k in 0..<6 {
            let rotation = tilt * simd_quatf(angle: turn + Float(k) * .pi / 6, axis: [0, 1, 0])
            func pose(_ i: Int) -> ScatterPose { ScatterPose(position: base + SIMD3(0, Float(i) * step, 0), rotation: rotation) }
            func fits(_ i: Int) -> Bool { near.allSatisfy { Self.clear(shape, pose(i), of: $0) } }
            var high = Int(lowest / step + 1e-3)
            guard fits(high) else { continue }
            var low = -1
            while high - low > 1 {
                let mid = (low + high) / 2
                if fits(mid) { high = mid } else { low = mid }
            }
            let lift = Float(high) * step
            if lift < lowest || best == nil {
                best = pose(high)
                lowest = lift
            }
            if high == 0 { break }
        }
        return best.map { ($0, lowest) }
    }

    private static func clear(_ shape: ScatterShape, _ pose: ScatterPose, of other: ScatterFootprint) -> Bool {
        let toOther = other.rotation.inverse
        let toPiece = pose.rotation.inverse
        let otherReach = (other.shape.bound + layGap) * (other.shape.bound + layGap)
        let reach = (shape.bound + layGap) * (shape.bound + layGap)
        return !shape.points.contains { s in
            let local = toOther.act(pose.position + pose.rotation.act(s) - other.position)
            return simd_length_squared(local) < otherReach && other.shape.contact(local).distance < layGap
        } && !other.shape.points.contains { s in
            let local = toPiece.act(other.position + other.rotation.act(s) - pose.position)
            return simd_length_squared(local) < reach && shape.contact(local).distance < layGap
        }
    }

    /// Spots by room around them, roomiest first. Spots too low to see are dropped, and too steep ones sorted last, or dropped
    /// for a piece that's laid rather than tossed.
    private func ranked(_ offsets: [SIMD2<Float>], piece: ScatterShape, steepest: Float, lowest: Float,
                        laying: Bool = false) -> [SIMD2<Float>] {
        let radius = max(field.radius, 1e-3)
        let apexXZ = SIMD2(field.apex.x, field.apex.z)
        return offsets.compactMap { offset -> (spot: SIMD2<Float>, score: Float)? in
            let candidate = apexXZ + offset * radius
            let facing = max(offset.y, 0) / max(simd_length(offset), 1e-4)
            guard let ground = field.sample(x: candidate.x, z: candidate.y),
                  ground.height > field.floor + lowest + (Self.lowestInFront - lowest) * facing else { return nil }
            var score = radius
            for other in bodies {
                let gap = simd_distance(candidate, SIMD2(other.position.x, other.position.z))
                score = min(score, gap - other.shape.bound - piece.bound)
            }
            score -= 0.1 * simd_length(offset) * radius
            if ground.normal.y < steepest {
                if laying { return nil }
                score -= radius
            }
            if laying, ground.normal.y < Self.steepestLay, ground.normal.z < Self.steepFacing { return nil }
            if laying, abs(ground.normal.x) > Self.sideways { return nil }
            return (candidate, score)
        }.sorted { $0.score > $1.score }.map(\.spot)
    }

    private enum Judgement { case lies, perches, wedges, rejected }

    /// Lying on the ice cream is best; resting on one lying piece, or wedged on edge low down, will do if nothing
    /// better turns up; standing on end, falling off, or leaning on a piece that's already up on others never will.
    private func judge(_ result: ScatterSettle.Outcome, shape: ScatterShape) -> Judgement {
        let rest = result.rest
        let up: SIMD3<Float> = [0, 1, 0]
        guard !result.fell, !Self.restsOnRaised(shape, rest, among: bodies) else { return .rejected }
        guard let ground = field.sample(x: rest.position.x, z: rest.position.z) else { return .rejected }
        if result.onPieces {
            let low = Self.above(rest, ground) < Self.perchHeight + shape.half.min()
            return low && !Self.standsOnEnd(shape, rest, ground: up) && !Self.onEdge(shape, rest, ground: up) ? .perches : .rejected
        }
        if Self.standsOnEnd(shape, rest, ground: ground.normal) || Self.standsOnEnd(shape, rest, ground: up, upright: 0.8) {
            return .rejected
        }
        if Self.onEdge(shape, rest, ground: ground.normal) || Self.onEdge(shape, rest, ground: up, flat: 0.6) {
            let low = Self.above(rest, ground) < 1.1 * shape.half.max()
            return low && !Self.standsOnEnd(shape, rest, ground: up) ? .wedges : .rejected
        }
        return .lies
    }

    /// Up off the surface, or held up by a piece below it: either way nothing may rest on it in turn.
    static func isRaised(_ shape: ScatterShape, _ pose: ScatterPose, on surface: any ToppingSurface,
                         among bodies: [ScatterFootprint]) -> Bool {
        guard let ground = surface.sample(x: pose.position.x, z: pose.position.z) else { return true }
        return above(pose, ground) > 1.6 * shape.half.min() + 0.0005 || !supports(shape, pose, among: bodies).isEmpty
    }

    /// The pieces below this one that hold it up, rather than just touch its side.
    private static func supports(_ shape: ScatterShape, _ pose: ScatterPose, among bodies: [ScatterFootprint]) -> [ScatterFootprint] {
        let touch: Float = 0.0006, upward: Float = 0.5
        return bodies.filter { other in
            guard other.position.y < pose.position.y,
                  simd_distance(other.position, pose.position) < other.shape.bound + shape.bound + touch else { return false }
            let toOther = other.rotation.inverse
            let rests = shape.points.contains { s in
                let hit = other.shape.contact(toOther.act(pose.position + pose.rotation.act(s) - other.position))
                return hit.distance < touch && other.rotation.act(hit.normal).y > upward
            }
            if rests { return true }
            let toPiece = pose.rotation.inverse
            return other.shape.points.contains { s in
                let hit = shape.contact(toPiece.act(other.position + other.rotation.act(s) - pose.position))
                return hit.distance < touch && pose.rotation.act(hit.normal).y < -upward
            }
        }
    }

    /// Distance from the surface to the piece's center, square to the slope, so a piece lying on a steep shoulder isn't
    /// mistaken for one up on others.
    private static func above(_ pose: ScatterPose, _ ground: (height: Float, normal: SIMD3<Float>)) -> Float {
        (pose.position.y - ground.height) * ground.normal.y
    }

    /// Whether a piece would rest on one that's already up on other pieces: that's how heaps start.
    private static func restsOnRaised(_ shape: ScatterShape, _ pose: ScatterPose, among bodies: [ScatterFootprint]) -> Bool {
        supports(shape, pose, among: bodies).contains(where: \.raised)
    }

    /// An elongated piece whose long axis points mostly up: stable for a box, but rare for real candy.
    private static func standsOnEnd(_ shape: ScatterShape, _ pose: ScatterPose, ground: SIMD3<Float>, upright: Float = 0.75) -> Bool {
        let half = shape.half
        let long = half.x > half.y ? (half.x > half.z ? 0 : 2) : (half.y > half.z ? 1 : 2)
        let others = (0..<3).filter { $0 != long }.map { half[$0] }
        guard half[long] > 1.4 * (others.max() ?? 0) else { return false }
        var axis = SIMD3<Float>.zero
        axis[long] = 1
        return abs(simd_dot(pose.rotation.act(axis), ground)) > upright
    }

    /// A disc (an M&M) standing on its rim, or a gummy bear on its side, wedged rather than lying.
    private static func onEdge(_ shape: ScatterShape, _ pose: ScatterPose, ground: SIMD3<Float>, flat: Float = 0.5) -> Bool {
        let half = shape.half
        let thin = half.x < half.y ? (half.x < half.z ? 0 : 2) : (half.y < half.z ? 1 : 2)
        guard half[thin] < 0.7 * ((0..<3).filter { $0 != thin }.map { half[$0] }.min() ?? 0) else { return false }
        var axis = SIMD3<Float>.zero
        axis[thin] = 1
        return abs(simd_dot(pose.rotation.act(axis), ground)) < flat
    }
}
