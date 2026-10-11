import QuartzCore
import RealityKit
import simd

/// Pieces of one `ScatterKind` tossed onto the surface beneath and settled by a small rigid-body
/// simulation, so they land, slide and come to rest the way real candy would.
///
/// Several scatter layers share one item. Before `apply` and `resurface`, set `occupied` to the
/// `footprints` of the scatter layers before this one, in stack order:
///
///     mms.occupied = gummies.footprints
///     sprinkles.occupied = gummies.footprints + mms.footprints
///
/// New pieces then collide with those as well as with the surface. `footprints` always describes
/// where this layer's pieces rest or are heading, so after a resurface feed the layers in the same
/// order again. When an earlier scatter layer is removed, give the later ones their new `occupied`
/// and `resurface` them onto the same surface, so pieces that were resting on the removed ones drop.
@MainActor
final class ScatterLayer: ToppingLayer {
    let kind: ScatterKind
    let entity = Entity()
    var occupied: [ScatterFootprint] = []
    var footprints: [ScatterFootprint] {
        finishSettling()
        return resting
    }
    private(set) var isFinished = false
    var isAnimating: Bool { animating }
    /// Where the topping's card icon is, in the layer's parent space; read every frame. When set,
    /// animated pieces are tossed from it and removed pieces fly back into it.
    var launchPoint: (() -> SIMD3<Float>)?

    private enum Motion {
        case none
        case arrive(start: Double)
        case settle(from: ScatterPose, start: Double, lift: Double)
        case leave(from: ScatterPose, start: Double)
    }

    private struct Piece {
        let model: ModelEntity
        let shape: ScatterShape
        let meshCenter: SIMD3<Float>
        var delay: Double
        let flight: Double
        let arcHeight: Float
        /// Where in the pinch it leaves from, relative to the launch point.
        let hand: SIMD3<Float>
        /// How far toward the item it's already heading as it rises.
        let lean: Float
        let tumbleAxis: SIMD3<Float>
        let tumble: Float
        let removeDelay: Double
        let jitter: Double
        var rest = ScatterPose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        /// The recorded fall and settle, every `ScatterSettle.recordInterval` of simulated time.
        var track: [ScatterPose] = []
        var shown = ScatterPose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        var scale: Float = 1
        var motion = Motion.none
        /// Found nowhere on the item to rest, so it isn't shown.
        var lost = false
    }

    private struct Toss {
        let candidates: [SIMD2<Float>]
        let orientation: simd_quatf
        let push: SIMD3<Float>
        let spin: SIMD3<Float>
    }

    private struct Pending {
        let surface: ToppingSurface
        let settle: ScatterSettle
        let next: Int
        let start: Double
    }

    private var pieces: [Piece] = []
    private var tosses: [Toss] = []
    private var resting: [ScatterFootprint] = []
    /// Everything the next piece can land on: `occupied` and this layer's pieces settled so far.
    private var bodies: [ScatterFootprint] = []
    private var pending: Pending?
    private var animating = false

    /// Simulated seconds shown per real second: slower than life so a fall on a small scoop reads.
    static let playbackRate: Float = 0.6
    static let dropHeight: Float = 0.014
    static let dropSpeed: Float = 0.35
    /// Spots tried before a piece that keeps falling off the item is left off.
    static let attempts = 7
    /// Cosine of the steepest slope pieces are aimed at; steeper spots can't hold them.
    static let steepestAim: Float = 0.82
    static let popGrow = 0.08
    static let popShrink = 0.13
    static let returnDuration = 0.42
    /// Seconds per frame spent settling pieces ahead of their toss.
    static let settleBudget = 0.002

    init(kind: ScatterKind) {
        self.kind = kind
        entity.name = "scatter"
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface { below }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        for piece in pieces { piece.model.removeFromParent() }
        pieces = []
        tosses = []
        resting = []
        isFinished = false
        var rng = ToppingRandom(seed: seed)
        let specs = kind.makePieces(rng: &rng)
        let radius = max(surface.radius, 1e-3)
        let pinches = specs.count > 20 ? 3 : specs.count > 4 ? 2 : 1
        for (index, spec) in specs.enumerated() {
            let candidates = (0..<5).map { _ in
                let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
                return SIMD2(cos(angle), sin(angle)) * 0.85 * pow(Float.random(in: 0...1, using: &rng), 0.6)
            }
            let orientation = simd_quatf(angle: Float.random(in: 0..<(2 * .pi), using: &rng), axis: [0, 1, 0])
                * simd_quatf(angle: Float.random(in: 0...1.2, using: &rng), axis: Self.randomUnit(&rng))
            let push = Self.randomUnit(&rng) * Float.random(in: 0...0.04, using: &rng)
            let spin = Self.randomUnit(&rng) * Float.random(in: 1...5, using: &rng)
            tosses.append(Toss(candidates: candidates, orientation: orientation, push: push, spin: spin))
            let along = specs.count > 1 ? Double(index) / Double(specs.count - 1) : 0
            let pinch = min(Int(along * Double(pinches)), pinches - 1)
            let model = ModelEntity(mesh: spec.mesh, materials: spec.materials)
            model.isEnabled = false
            entity.addChild(model)
            var piece = Piece(model: model, shape: ScatterShape(half: spec.halfExtents), meshCenter: spec.mesh.bounds.center,
                              delay: Double(pinch) * 0.24 + Double.random(in: 0...0.12, using: &rng),
                              flight: Double.random(in: 0.42...0.6, using: &rng),
                              arcHeight: radius * Float.random(in: 1.0...2.2, using: &rng),
                              hand: Self.randomUnit(&rng) * radius * Float.random(in: 0...0.5, using: &rng),
                              lean: Float.random(in: 0.15...0.55, using: &rng),
                              tumbleAxis: Self.randomUnit(&rng), tumble: Float.random(in: 2...5, using: &rng) * .pi,
                              removeDelay: along * (specs.count > 20 ? 0.35 : 0.2), jitter: Double.random(in: 0...1, using: &rng))
            if animated { piece.motion = .arrive(start: now) }
            pieces.append(piece)
        }
        bodies = occupied
        pending = pieces.isEmpty ? nil : Pending(surface: surface, settle: ScatterSettle(surface: surface, floor: surface.apex.y - 2.5 * radius),
                                                 next: 0, start: now)
        if animated {
            animating = true
            update(now: now)
        } else {
            finishSettling()
            for index in pieces.indices where !pieces[index].lost {
                pieces[index].shown = pieces[index].rest
                pieces[index].model.isEnabled = true
                place(pieces[index])
            }
        }
    }

    /// Simulates every piece not yet settled. Animated applies settle each piece just before it's tossed.
    func finishSettling() {
        while pending != nil { settleNext(now: nil) }
    }

    /// A piece settled after its planned toss time is tossed `now` instead.
    private func settleNext(now: Double?) {
        guard let job = pending else { return }
        let index = job.next
        let surface = job.surface
        var piece = pieces[index]
        let toss = tosses[index]
        let radius = max(surface.radius, 1e-3)
        let apexXZ = SIMD2(surface.apex.x, surface.apex.z)
        var spot = apexXZ
        var bestScore = -Float.infinity
        for offset in toss.candidates {
            let candidate = apexXZ + offset * radius
            var score = Float.infinity
            for other in bodies {
                let gap = simd_distance(candidate, SIMD2(other.position.x, other.position.z))
                score = min(score, gap - other.shape.bound - piece.shape.bound)
            }
            score -= 0.1 * simd_length(offset) * radius
            if (surface.sample(x: candidate.x, z: candidate.y)?.normal.y ?? 0) < Self.steepestAim { score -= radius }
            if score > bestScore {
                bestScore = score
                spot = candidate
            }
        }
        var landed: ScatterSettle.Outcome?
        var stacked: ScatterSettle.Outcome?
        let firstAngle = atan2(spot.y - apexXZ.y, spot.x - apexXZ.x)
        for attempt in 0..<Self.attempts {
            if attempt > 0 {
                let angle = firstAngle + Float(attempt) * 2.4
                let reach: Float = attempt % 2 == 0 ? 0.35 : 0.65
                spot = apexXZ + SIMD2(cos(angle), sin(angle)) * reach * radius
            }
            let ground = surface.sample(x: spot.x, z: spot.y)?.height ?? surface.apex.y
            let start = ScatterPose(position: [spot.x, ground + Self.dropHeight + piece.shape.bound, spot.y], rotation: toss.orientation)
            let result = job.settle.run(piece.shape, from: start, velocity: [toss.push.x, -Self.dropSpeed, toss.push.z],
                                        spin: attempt == 0 ? toss.spin : .zero, among: bodies)
            if result.fell { continue }
            if result.onPieces || Self.standsOnEnd(piece.shape, result.rest) {
                if stacked == nil { stacked = result }
                continue
            }
            landed = result
            break
        }
        if landed == nil { landed = stacked }
        if let landed {
            piece.rest = landed.rest
            piece.track = landed.track
            let footprint = ScatterFootprint(shape: piece.shape, position: piece.rest.position, rotation: piece.rest.rotation)
            bodies.append(footprint)
            resting.append(footprint)
        } else {
            piece.lost = true
            piece.track = []
            piece.motion = .none
            piece.model.isEnabled = false
        }
        if let now { piece.delay = max(piece.delay, now - job.start) }
        pieces[index] = piece
        pending = index + 1 < pieces.count ? Pending(surface: surface, settle: job.settle, next: index + 1, start: job.start) : nil
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        finishSettling()
        guard !pieces.isEmpty else { return }
        let settle = ScatterSettle(surface: surface, floor: surface.apex.y - 2.5 * max(surface.radius, 1e-3))
        let apexXZ = SIMD2(surface.apex.x, surface.apex.z)
        var settled = occupied
        var restingAfter = [ScatterFootprint?](repeating: nil, count: pieces.count)
        for index in pieces.indices.sorted(by: { pieces[$0].rest.position.y < pieces[$1].rest.position.y }) {
            var piece = pieces[index]
            if piece.lost { continue }
            if case .leave = piece.motion { continue }
            var start = piece.rest
            var outcome: ScatterSettle.Outcome?
            var rising = false
            for attempt in 0..<4 {
                let lift = Self.clearance(piece.shape, at: start, on: surface)
                if lift > 0 {
                    start.position.y += lift + 0.0004
                    rising = true
                }
                let result = settle.run(piece.shape, from: start, velocity: .zero, spin: .zero, among: settled)
                outcome = result
                if !result.fell || attempt == 3 { break }
                let xz = apexXZ + (SIMD2(start.position.x, start.position.z) - apexXZ) * 0.6
                start.position = [xz.x, (surface.sample(x: xz.x, z: xz.y)?.height ?? surface.apex.y) + piece.shape.bound, xz.y]
            }
            if let outcome, !outcome.fell {
                piece.rest = outcome.rest
                piece.track = outcome.track
            } else {
                piece.rest = start
                piece.track = [start]
            }
            let footprint = ScatterFootprint(shape: piece.shape, position: piece.rest.position, rotation: piece.rest.rotation)
            settled.append(footprint)
            restingAfter[index] = footprint
            if duration <= 0 {
                piece.shown = piece.rest
                piece.motion = .none
                piece.model.isEnabled = true
                piece.scale = 1
                place(piece)
            } else {
                let delay = rising ? 0 : duration * (0.2 + 0.15 * piece.jitter)
                piece.motion = .settle(from: piece.shown, start: now + delay, lift: rising ? duration : min(0.12, duration))
                animating = true
            }
            pieces[index] = piece
        }
        resting = restingAfter.compactMap { $0 }
    }

    func remove(now: Double) {
        guard !pieces.isEmpty else {
            isFinished = true
            return
        }
        pending = nil
        for index in pieces.indices {
            pieces[index].motion = .leave(from: pieces[index].shown, start: now + pieces[index].removeDelay)
        }
        resting = []
        animating = true
    }

    func update(now: Double) {
        guard animating else { return }
        if pending != nil {
            let started = CACurrentMediaTime()
            repeat {
                settleNext(now: now)
            } while pending != nil && CACurrentMediaTime() - started < Self.settleBudget
        }
        var active = false
        var leaving = false
        let launch = launchPoint?()
        for index in pieces.indices {
            switch pieces[index].motion {
            case .none:
                continue
            case .arrive(let start):
                if pieces[index].lost { continue }
                active = stepArrive(index, t: now - start - pieces[index].delay, launch: launch) || active
            case let .settle(from, start, lift):
                active = stepSettle(index, from: from, t: now - start, lift: lift) || active
            case let .leave(from, start):
                leaving = true
                active = stepLeave(index, from: from, t: now - start, launch: launch) || active
            }
            place(pieces[index])
        }
        if !active {
            animating = false
            if leaving { isFinished = true }
        }
    }

    // MARK: Motion

    private func stepArrive(_ index: Int, t: Double, launch: SIMD3<Float>?) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else {
            piece.model.isEnabled = false
            return true
        }
        guard !piece.track.isEmpty else { return true }
        piece.model.isEnabled = true
        let first = piece.track[0]
        if let launch {
            if t < piece.flight {
                let s = Float(t / piece.flight)
                let start = launch + piece.hand
                let peak = first.position.y + piece.arcHeight
                let entry = Self.entryVelocity(piece.track)
                let ahead = simd_mix(start, first.position, SIMD3(repeating: piece.lean))
                let rise = SIMD3(ahead.x, peak + 0.3 * piece.arcHeight, ahead.z)
                var fall = first.position - entry * Float(piece.flight) / 3
                fall.y = max(fall.y, peak)
                let position = cubicBezier(start, rise, fall, first.position, s)
                let spin = simd_quatf(angle: piece.tumble * (1 - s), axis: piece.tumbleAxis)
                piece.shown = ScatterPose(position: position, rotation: first.rotation * spin)
                piece.scale = 0.45 + 0.55 * Ease.outCubic(min(s * 2.5, 1))
                return true
            }
            piece.scale = 1
            return playTrack(&piece, t: t - piece.flight)
        }
        piece.scale = Ease.outCubic(Float(min(t / 0.08, 1)))
        return playTrack(&piece, t: t)
    }

    private func stepSettle(_ index: Int, from: ScatterPose, t: Double, lift: Double) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else { return true }
        piece.model.isEnabled = true
        piece.scale = 1
        let first = piece.track.first ?? piece.rest
        if t < lift {
            piece.shown = from.mixed(first, Ease.inOutCubic(Float(t / lift)))
            return true
        }
        return playTrack(&piece, t: t - lift)
    }

    private func playTrack(_ piece: inout Piece, t: Double) -> Bool {
        let frame = Float(t) * Self.playbackRate / ScatterSettle.recordInterval
        let last = piece.track.count - 1
        guard last > 0, frame < Float(last) else {
            piece.shown = piece.rest
            piece.motion = .none
            return false
        }
        let index = Int(frame)
        piece.shown = piece.track[index].mixed(piece.track[index + 1], frame - Float(index))
        return true
    }

    private func stepLeave(_ index: Int, from: ScatterPose, t: Double, launch: SIMD3<Float>?) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else { return true }
        if let launch {
            let s = Float(min(t / Self.returnDuration, 1))
            let e = Ease.inOutSine(s)
            let lifted = (from.position + launch) / 2 + SIMD3(0, piece.arcHeight * 0.8, 0)
            let u = 1 - e
            let position = u * u * from.position + 2 * u * e * lifted + e * e * launch
            piece.shown = ScatterPose(position: position,
                                      rotation: from.rotation * simd_quatf(angle: piece.tumble * e, axis: piece.tumbleAxis))
            piece.scale = 1 - 0.55 * Ease.inCubic(s)
            if s >= 1 {
                piece.model.isEnabled = false
                piece.motion = .none
                return false
            }
            return true
        }
        let lift = 0.15 * piece.shape.bound
        if t < Self.popGrow {
            let s = Float(t / Self.popGrow)
            piece.scale = 1 + 0.2 * Ease.outQuad(s)
            piece.shown = from
            piece.shown.position.y += lift * Ease.outQuad(s)
            return true
        }
        let s = Float(min((t - Self.popGrow) / Self.popShrink, 1))
        piece.scale = 1.2 * (1 - Ease.inCubic(s))
        piece.shown = from
        piece.shown.position.y += lift * (1 + 1.5 * s)
        if s >= 1 {
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

    /// An elongated piece whose long axis points mostly up: stable for a box, but rare for real candy.
    private static func standsOnEnd(_ shape: ScatterShape, _ pose: ScatterPose) -> Bool {
        let half = shape.half
        let long = half.x > half.y ? (half.x > half.z ? 0 : 2) : (half.y > half.z ? 1 : 2)
        let others = (0..<3).filter { $0 != long }.map { half[$0] }
        guard half[long] > 1.4 * (others.max() ?? 0) else { return false }
        var axis = SIMD3<Float>.zero
        axis[long] = 1
        return abs(pose.rotation.act(axis).y) > 0.75
    }

    /// Real-time velocity at the start of a recorded track, so a toss flows into the fall.
    private static func entryVelocity(_ track: [ScatterPose]) -> SIMD3<Float> {
        guard track.count > 1 else { return [0, -dropSpeed * playbackRate, 0] }
        return (track[1].position - track[0].position) / ScatterSettle.recordInterval * playbackRate
    }

    /// How far the piece must rise so none of its contact points is below `surface`.
    private static func clearance(_ shape: ScatterShape, at pose: ScatterPose, on surface: ToppingSurface) -> Float {
        var lift: Float = 0
        for s in shape.points {
            let p = pose.position + pose.rotation.act(s)
            guard let ground = surface.sample(x: p.x, z: p.z) else { continue }
            lift = max(lift, ground.height - p.y)
        }
        return lift
    }

    private static func randomUnit(_ rng: inout ToppingRandom) -> SIMD3<Float> {
        let y = Float.random(in: -1...1, using: &rng)
        let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
        let r = (1 - y * y).squareRoot()
        return [r * cos(angle), y, r * sin(angle)]
    }
}
