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

    let surface: ToppingSurface
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
             among obstacles: [ScatterFootprint], maxTime: Float = 1.6) -> Outcome {
        let dt = Self.step
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
            if wasOnCream {
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
                    let give = surface.softness(x: p.x, z: p.z)
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
                                                friction: Self.candyFriction, bounce: Self.candyBounce))
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
                                                friction: Self.candyFriction, bounce: Self.candyBounce))
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
                        let give = surface.softness(x: gx, z: gz)
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
