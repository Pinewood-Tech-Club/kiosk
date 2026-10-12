import QuartzCore
import RealityKit
import simd

/// Pieces of one `ScatterKind` tossed onto the surface beneath and settled by a small rigid-body
/// simulation, so they land, slide and come to rest the way real candy would.
///
/// Several scatter layers share one item. Before `apply` and `resurface`, set `beneath` to the
/// scatter layers before this one, in stack order:
///
///     mms.beneath = [gummies]
///     sprinkles.beneath = [gummies, mms]
///
/// New pieces then collide with theirs as well as with the surface, once those have settled: a layer
/// waits for the ones beneath it rather than forcing them to finish in one frame. When an earlier
/// scatter layer is removed, give the later ones their new `beneath` and `resurface` them onto the
/// same surface, so pieces that were resting on the removed ones drop.
@MainActor
final class ScatterLayer: ToppingLayer {
    let kind: ScatterKind
    let entity = Entity()
    var beneath: [ScatterLayer] = []
    /// How many scattered toppings share the item; each gets its part of the room on the ice cream.
    var crowd = 1
    private(set) var isFinished = false
    var isSettling: Bool { pending != nil || resurfacing != nil }
    /// Where the topping's card icon is, in the layer's parent space; read every frame. When set,
    /// animated pieces are tossed from it and removed pieces fly back into it.
    var launchPoint: (() -> SIMD3<Float>)?
    /// Height in the layer's parent space that tossed and returning pieces stay under; read every frame.
    var ceiling: (() -> Float)?
    /// While set, each piece shows raised by this much at its (x, z): the cream beneath it is growing or
    /// deflating, and the pieces ride it until the stack resurfaces them onto the finished surface.
    var heave: ((Float, Float) -> Float)? {
        didSet { reheave = true }
    }
    private var reheave = false

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
        /// One attempt runs per call, so a piece that needs several never stalls a frame.
        var spots: [SIMD2<Float>] = []
        var attempt = 0
        var awkward: ScatterSettle.Outcome?
        var perched: ScatterSettle.Outcome?
    }

    private struct Resurfacing {
        let surface: ToppingSurface
        let settle: ScatterSettle
        let order: [Int]
        var next: Int
        var settled: [ScatterFootprint]?
        var restingAfter: [ScatterFootprint?]
        let duration: Double
        let start: Double
    }

    private var pieces: [Piece] = []
    private var tosses: [Toss] = []
    private var resting: [ScatterFootprint] = []
    /// Everything the next piece can land on: the pieces beneath and this layer's pieces settled so far.
    private var bodies: [ScatterFootprint] = []
    private var bodiesReady = false
    private var pending: Pending?
    private var resurfacing: Resurfacing?
    private var animating = false

    /// Simulated seconds shown per real second: slower than life so a fall on a small scoop reads.
    static let playbackRate: Float = 0.6
    static let dropHeight: Float = 0.014
    static let dropSpeed: Float = 0.35
    /// Spots tried, the roomiest first, before a piece that finds no room on the ice cream is left off.
    static let attempts = 7
    /// A piece with no room on the ice cream may rest on one lying piece, never on a heap.
    static let perchHeight: Float = 0.010
    /// Cosine of the steepest slope pieces are aimed at; steeper spots can't hold them.
    static let steepestAim: Float = 0.6
    static let popGrow = 0.08
    static let popShrink = 0.13
    static let returnDuration = 0.42
    enum Serving {
        /// Fewer pieces on a small top or one shared with other candy, so they lie in one loose layer.
        case fitToRoom
        /// Always the kind's whole count; pieces with no room on the ice cream rest on one lying piece, never in a heap.
        case full
    }

    static let serving = Serving.fitToRoom
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
        let made = kind.makePieces(rng: &rng)
        let specs = Array(made.prefix(portion(made, on: surface)))
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
                              arcHeight: radius * Float.random(in: 0.5...1.0, using: &rng),
                              hand: Self.randomUnit(&rng) * radius * Float.random(in: 0...0.5, using: &rng),
                              lean: Float.random(in: 0.15...0.55, using: &rng),
                              tumbleAxis: Self.randomUnit(&rng), tumble: Float.random(in: 2...5, using: &rng) * .pi,
                              removeDelay: along * (specs.count > 20 ? 0.35 : 0.2), jitter: Double.random(in: 0...1, using: &rng))
            if animated { piece.motion = .arrive(start: now) }
            pieces.append(piece)
        }
        bodies = []
        bodiesReady = false
        pending = pieces.isEmpty ? nil : Pending(surface: surface, settle: ScatterSettle(surface: surface, floor: surface.floor),
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

    /// The tallest a piece stands lying flat, for headroom above the surface.
    var pieceHeight: Float {
        pieces.map { 2 * $0.shape.half.min() }.max() ?? 0
    }

    /// The top of the pieces settled so far, without settling the rest.
    var restingTop: Float? {
        resting.map { f in
            let up = f.rotation.inverse.act([0, 1, 0])
            return f.position.y + simd_dot(simd_abs(up), f.shape.half)
        }.max()
    }

    /// How many pieces to use: the kind's full serving where there's room for it in one loose layer, fewer on a small
    /// top or one shared with other candy, so pieces don't heap.
    private func portion(_ made: [ScatterPiece], on surface: ToppingSurface) -> Int {
        if Self.serving == .full { return made.count }
        guard let half = made.first?.halfExtents else { return 0 }
        let sorted = [half.x, half.y, half.z].sorted()
        let pieceArea = Float.pi * sorted[1] * sorted[2]
        let step: Float = 0.002
        var usable: Float = 0
        for i in -20...20 {
            for j in -20...20 {
                let x = surface.apex.x + Float(i) * step, z = surface.apex.z + Float(j) * step
                guard let s = surface.sample(x: x, z: z), s.height > surface.floor, s.normal.y > Self.steepestAim else { continue }
                usable += step * step
            }
        }
        let fits = Int(0.8 * usable / Float(max(crowd, 1)) / pieceArea)
        return min(made.count, max(fits, Self.leastPortion(made.count)))
    }

    private static func leastPortion(_ serving: Int) -> Int {
        min(serving, max(3, serving / 3))
    }

    /// Simulates every piece not yet settled. Animated applies settle each piece just before it's tossed.
    func finishSettling() {
        while pending != nil { settleNext(now: nil, force: true) }
        while resurfacing != nil { resurfaceNext(force: true) }
    }

    /// The pieces of the layers beneath once they're at rest; nil while they're still settling, unless forced.
    private func restingBeneath(force: Bool) -> [ScatterFootprint]? {
        if beneath.contains(where: \.isSettling) {
            guard force else { return nil }
            for layer in beneath { layer.finishSettling() }
        }
        return beneath.flatMap(\.resting)
    }

    /// A piece settled after its planned toss time is tossed `now` instead. False while waiting for the layers beneath.
    @discardableResult
    private func settleNext(now: Double?, force: Bool) -> Bool {
        guard var job = pending else { return false }
        if !bodiesReady {
            guard let below = restingBeneath(force: force) else { return false }
            bodies = below
            bodiesReady = true
        }
        let index = job.next
        let surface = job.surface
        var piece = pieces[index]
        let toss = tosses[index]
        let radius = max(surface.radius, 1e-3)
        let apexXZ = SIMD2(surface.apex.x, surface.apex.z)
        if job.spots.isEmpty {
            let firstAngle = atan2(toss.candidates[0].y, toss.candidates[0].x)
            let ring = (0..<12).map { k in
                let angle = firstAngle + Float(k) * 2.4
                return SIMD2(cos(angle), sin(angle)) * [0.3, 0.55, 0.8][k % 3]
            }
            job.spots = (toss.candidates + ring).map { offset -> (spot: SIMD2<Float>, score: Float) in
                let candidate = apexXZ + offset * radius
                var score = radius
                for other in bodies {
                    let gap = simd_distance(candidate, SIMD2(other.position.x, other.position.z))
                    score = min(score, gap - other.shape.bound - piece.shape.bound)
                }
                score -= 0.1 * simd_length(offset) * radius
                if (surface.sample(x: candidate.x, z: candidate.y)?.normal.y ?? 0) < Self.steepestAim { score -= radius }
                return (candidate, score)
            }.sorted { $0.score > $1.score }.prefix(Self.attempts).map(\.spot)
        }
        let attempt = job.attempt
        let spot = job.spots[attempt]
        let ground = surface.sample(x: spot.x, z: spot.y)?.height ?? surface.apex.y
        let start = ScatterPose(position: [spot.x, ground + Self.dropHeight + piece.shape.bound, spot.y], rotation: toss.orientation)
        let result = job.settle.run(piece.shape, from: start, velocity: [toss.push.x, -Self.dropSpeed, toss.push.z],
                                    spin: attempt == 0 ? toss.spin : .zero, among: bodies)
        var landed: ScatterSettle.Outcome?
        switch judge(result, shape: piece.shape, on: surface) {
        case .lies: landed = result
        case .perches: if job.perched == nil { job.perched = result }
        case .wedges: if job.awkward == nil { job.awkward = result }
        case .rejected: break
        }
        if landed == nil, attempt + 1 < job.spots.count {
            job.attempt = attempt + 1
            pending = job
            return true
        }
        if landed == nil { landed = job.perched ?? job.awkward }
        if let landed {
            piece.rest = landed.rest
            piece.track = landed.track
            let cream = surface.sample(x: piece.rest.position.x, z: piece.rest.position.z)?.height ?? surface.apex.y
            let footprint = ScatterFootprint(shape: piece.shape, position: piece.rest.position, rotation: piece.rest.rotation,
                                             raised: Self.isRaised(piece.shape, piece.rest, cream: cream))
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
        return true
    }

    private enum Judgement { case lies, perches, wedges, rejected }

    /// Lying on the ice cream is best; resting on one lying piece, or wedged on edge low down, will do if nothing
    /// better turns up; standing on end, falling off, or leaning on a piece that's already up on others never will.
    private func judge(_ result: ScatterSettle.Outcome, shape: ScatterShape, on surface: ToppingSurface) -> Judgement {
        let rest = result.rest
        let up: SIMD3<Float> = [0, 1, 0]
        guard !result.fell, !Self.restsOnRaised(shape, rest, among: bodies) else { return .rejected }
        guard let ground = surface.sample(x: rest.position.x, z: rest.position.z) else { return .rejected }
        if result.onPieces {
            let low = rest.position.y - ground.height < Self.perchHeight + shape.half.min()
            return low && !Self.standsOnEnd(shape, rest, ground: up) && !Self.onEdge(shape, rest, ground: up) ? .perches : .rejected
        }
        if Self.standsOnEnd(shape, rest, ground: ground.normal) || Self.standsOnEnd(shape, rest, ground: up, upright: 0.9) {
            return .rejected
        }
        if Self.onEdge(shape, rest, ground: ground.normal) || Self.onEdge(shape, rest, ground: up) {
            let low = rest.position.y - ground.height < 1.1 * shape.half.max()
            return low && !Self.standsOnEnd(shape, rest, ground: up) ? .wedges : .rejected
        }
        return .lies
    }

    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        finishSettling()
        guard !pieces.isEmpty else { return }
        let order = pieces.indices.sorted { pieces[$0].rest.position.y < pieces[$1].rest.position.y }
        resurfacing = Resurfacing(surface: surface, settle: ScatterSettle(surface: surface, floor: surface.floor), order: order,
                                  next: 0, settled: nil, restingAfter: Array(repeating: nil, count: pieces.count),
                                  duration: duration, start: now)
        if duration <= 0 {
            finishSettling()
        } else {
            animating = true
        }
    }

    /// Settles the next piece of a resurface; the lowest go first, so the ones above land on them.
    @discardableResult
    private func resurfaceNext(force: Bool) -> Bool {
        guard var job = resurfacing else { return false }
        if job.settled == nil {
            guard let below = restingBeneath(force: force) else { return false }
            job.settled = below
        }
        let index = job.order[job.next]
        job.next += 1
        var piece = pieces[index]
        var skip = piece.lost
        if case .leave = piece.motion { skip = true }
        if !skip {
            let surface = job.surface
            let apexXZ = SIMD2(surface.apex.x, surface.apex.z)
            var start = piece.rest
            var outcome: ScatterSettle.Outcome?
            var rising = false
            for attempt in 0..<4 {
                let lift = Self.clearance(piece.shape, at: start, on: surface)
                if lift > 0 {
                    start.position.y += lift + 0.0004
                    rising = true
                }
                let result = job.settle.run(piece.shape, from: start, velocity: .zero, spin: .zero, among: job.settled ?? [])
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
            let cream = job.surface.sample(x: piece.rest.position.x, z: piece.rest.position.z)?.height ?? job.surface.apex.y
            let footprint = ScatterFootprint(shape: piece.shape, position: piece.rest.position, rotation: piece.rest.rotation,
                                             raised: Self.isRaised(piece.shape, piece.rest, cream: cream))
            job.settled?.append(footprint)
            job.restingAfter[index] = footprint
            let duration = job.duration
            if duration <= 0 {
                piece.shown = piece.rest
                piece.motion = .none
                piece.model.isEnabled = true
                piece.scale = 1
                place(piece)
            } else {
                let delay = rising ? 0 : duration * (0.2 + 0.15 * piece.jitter)
                piece.motion = .settle(from: piece.shown, start: job.start + delay, lift: rising ? duration : min(0.12, duration))
            }
            pieces[index] = piece
        }
        if job.next < job.order.count {
            resurfacing = job
        } else {
            resting = job.restingAfter.compactMap { $0 }
            resurfacing = nil
        }
        return true
    }

    func remove(now: Double) {
        guard !pieces.isEmpty else {
            isFinished = true
            return
        }
        pending = nil
        resurfacing = nil
        for index in pieces.indices {
            pieces[index].motion = .leave(from: pieces[index].shown, start: now + pieces[index].removeDelay)
        }
        resting = []
        animating = true
    }

    /// Moves every piece to where `heave` shows it and clears it, so a following `resurface` starts from there.
    func bakeHeave() {
        guard let heave else { return }
        func lifted(_ pose: ScatterPose) -> ScatterPose {
            var pose = pose
            pose.position.y += heave(pose.position.x, pose.position.z)
            return pose
        }
        for index in pieces.indices {
            pieces[index].shown = lifted(pieces[index].shown)
            pieces[index].rest = lifted(pieces[index].rest)
            pieces[index].track = pieces[index].track.map(lifted)
            switch pieces[index].motion {
            case let .settle(from, start, lift): pieces[index].motion = .settle(from: lifted(from), start: start, lift: lift)
            case let .leave(from, start): pieces[index].motion = .leave(from: lifted(from), start: start)
            case .none, .arrive: break
            }
        }
        resting = resting.map { footprint in
            var footprint = footprint
            footprint.position.y += heave(footprint.position.x, footprint.position.z)
            return footprint
        }
        self.heave = nil
    }

    func update(now: Double) {
        let heaving = heave != nil || reheave
        reheave = false
        guard animating || heaving else { return }
        if pending != nil {
            let started = CACurrentMediaTime()
            while pending != nil, CACurrentMediaTime() - started < Self.settleBudget, settleNext(now: now, force: false) {}
        }
        if resurfacing != nil {
            let started = CACurrentMediaTime()
            while resurfacing != nil, CACurrentMediaTime() - started < Self.settleBudget, resurfaceNext(force: false) {}
        }
        var active = resurfacing != nil
        var leaving = false
        let launch = launchPoint?()
        let ceiling = self.ceiling?() ?? .infinity
        for index in pieces.indices {
            switch pieces[index].motion {
            case .none:
                if heaving, !pieces[index].lost { place(pieces[index]) }
                continue
            case .arrive(let start):
                if pieces[index].lost { continue }
                active = stepArrive(index, t: now - start - pieces[index].delay, launch: launch, ceiling: ceiling) || active
            case let .settle(from, start, lift):
                active = stepSettle(index, from: from, t: now - start, lift: lift) || active
            case let .leave(from, start):
                leaving = true
                active = stepLeave(index, from: from, t: now - start, launch: launch, ceiling: ceiling) || active
            }
            place(pieces[index])
        }
        if !active {
            animating = false
            if leaving { isFinished = true }
        }
    }

    // MARK: Motion

    /// The recorded fall starts a drop height above the landing spot, which on a tall item can reach the title, so a
    /// tossed piece is held under `ceiling` and only then follows the fall.
    private func stepArrive(_ index: Int, t: Double, launch: SIMD3<Float>?, ceiling: Float) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else {
            piece.model.isEnabled = false
            return true
        }
        guard !piece.track.isEmpty else { return true }
        piece.model.isEnabled = true
        let top = max(ceiling - piece.shape.bound, piece.rest.position.y)
        var first = piece.track[0]
        first.position.y = min(first.position.y, top)
        let running: Bool
        if let launch, t < piece.flight {
            let s = Float(t / piece.flight)
            let start = launch + piece.hand
            let arc = max(min(piece.arcHeight, (top - first.position.y) / 1.3), 0)
            let peak = first.position.y + arc
            let entry = Self.entryVelocity(piece.track)
            let ahead = simd_mix(start, first.position, SIMD3(repeating: piece.lean))
            let rise = SIMD3(ahead.x, peak + 0.3 * arc, ahead.z)
            var fall = first.position - entry * Float(piece.flight) / 3
            fall.y = min(max(fall.y, peak), top)
            let position = cubicBezier(start, rise, fall, first.position, s)
            let spin = simd_quatf(angle: piece.tumble * (1 - s), axis: piece.tumbleAxis)
            piece.shown = ScatterPose(position: position, rotation: first.rotation * spin)
            piece.scale = 0.45 + 0.55 * Ease.outCubic(min(s * 2.5, 1))
            running = true
        } else if launch != nil {
            piece.scale = 1
            running = playTrack(&piece, t: t - piece.flight)
        } else {
            piece.scale = Ease.outCubic(Float(min(t / 0.08, 1)))
            running = playTrack(&piece, t: t)
        }
        piece.shown.position.y = min(piece.shown.position.y, top)
        return running
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

    private func stepLeave(_ index: Int, from: ScatterPose, t: Double, launch: SIMD3<Float>?, ceiling: Float) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        guard t >= 0 else { return true }
        if let launch {
            let s = Float(min(t / Self.returnDuration, 1))
            let e = Ease.inOutSine(s)
            var lifted = (from.position + launch) / 2 + SIMD3(0, piece.arcHeight * 0.8, 0)
            lifted.y = min(lifted.y, max(ceiling - piece.shape.bound, from.position.y))
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
        var position = piece.shown.position
        if let heave { position.y += heave(position.x, position.z) }
        piece.model.transform = Transform(scale: SIMD3(repeating: scale), rotation: rotation,
                                          translation: position - rotation.act(piece.meshCenter * scale))
    }

    private static func isRaised(_ shape: ScatterShape, _ pose: ScatterPose, cream: Float) -> Bool {
        pose.position.y - cream > 1.6 * shape.half.min() + 0.0005
    }

    /// Whether a piece would lean on one that's already up on other pieces: that's how heaps start.
    private static func restsOnRaised(_ shape: ScatterShape, _ pose: ScatterPose, among bodies: [ScatterFootprint]) -> Bool {
        bodies.contains { other in
            other.raised && other.position.y < pose.position.y
                && simd_distance(other.position, pose.position) < other.shape.bound + shape.bound
        }
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
    private static func onEdge(_ shape: ScatterShape, _ pose: ScatterPose, ground: SIMD3<Float>) -> Bool {
        let half = shape.half
        let thin = half.x < half.y ? (half.x < half.z ? 0 : 2) : (half.y < half.z ? 1 : 2)
        guard half[thin] < 0.7 * ((0..<3).filter { $0 != thin }.map { half[$0] }.min() ?? 0) else { return false }
        var axis = SIMD3<Float>.zero
        axis[thin] = 1
        return abs(simd_dot(pose.rotation.act(axis), ground)) < 0.5
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
