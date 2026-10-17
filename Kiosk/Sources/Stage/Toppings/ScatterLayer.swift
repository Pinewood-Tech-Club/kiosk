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
/// New pieces then collide with theirs as well as with the surface. Animated settles run on a background task
/// (`ScatterPlanner`) that waits for the layers beneath to finish theirs; meanwhile tossed pieces fly toward a guess
/// and blend into their recorded falls as soon as those are known. When an earlier scatter layer is removed, give the
/// later ones their new `beneath` and `resurface` them onto the same surface, so pieces that were resting on the
/// removed ones drop.
@MainActor
final class ScatterLayer: ToppingLayer {
    let kind: ScatterKind
    let entity = Entity()
    var beneath: [ScatterLayer] = []
    /// How many scattered toppings share the item; each gets its part of the room on the ice cream.
    var crowd = 1
    private(set) var isFinished = false
    var isSettling: Bool { !jobs.isEmpty }
    /// Where the topping's card icon is, in the layer's parent space; read every frame. When set,
    /// animated pieces are tossed from it and removed pieces fly back into it.
    var launchPoint: (() -> SIMD3<Float>)?
    /// Height in the layer's parent space that tossed and returning pieces stay under; read every frame.
    var ceiling: (() -> Float)?
    /// The card icon that removed pieces fly back into and become; set before `remove`.
    var home: ToppingCardIcon?

    private enum Motion {
        case none
        case arrive(start: Double)
        /// From where it's shown to its next rest, aimed at `guess` until that rest is worked out.
        case glide(from: ScatterPose, guess: ScatterPose, start: Double, duration: Double)
        case leave(from: ScatterPose, start: Double)
        /// `stays` pieces become icon piece `slot`; the others shrink away into it.
        case home(from: Transform, start: Double, slot: Int, stays: Bool)
    }

    private enum Homing {
        case moving, parked, gone
    }

    private struct Piece {
        let model: ModelEntity
        let shape: ScatterShape
        let look: ScatterLook
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
        /// Where its toss starts the fall, until the settle says where it really does.
        var guess: ScatterPose
        var landing: ScatterLanding?
        /// A settle that will move it is still running.
        var awaiting = false
        var knownAt = -Double.infinity
        /// Simulated seconds of its recorded fall played per real second, once it's known.
        var rate: Float = 0
        var shown = ScatterPose(position: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        var scale: Float = 1
        var motion = Motion.none

        var rest: ScatterPose { landing?.rest ?? guess }
        /// Found nowhere on the item to rest, so it isn't shown.
        var lost: Bool { landing?.lost ?? false }
    }

    private struct Work: Sendable {
        enum Kind: Sendable {
            case toss([ScatterToss], full: Bool)
            case resurface(from: (any ToppingSurface)?)
        }

        let kind: Kind
        let shapes: [ScatterShape]
        let surface: any ToppingSurface

        func run(below: [ScatterFootprint], prior: [ScatterLanding], landed: (ScatterLanding) -> Void = { _ in }) -> ScatterPlan {
            switch kind {
            case let .toss(tosses, full):
                ScatterPlanner.toss(shapes, tosses, onto: surface, among: below, full: full, landed: landed)
            case let .resurface(previous):
                ScatterPlanner.resurface(shapes, prior, from: previous, onto: surface, among: below)
            }
        }
    }

    private final class PlanBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ScatterPlan?
        private var early: [ScatterLanding] = []

        var plan: ScatterPlan? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        func landed(_ landing: ScatterLanding) {
            lock.withLock { early.append(landing) }
        }

        func landings(from start: Int) -> ArraySlice<ScatterLanding> {
            lock.withLock { start < early.count ? early[start...] : [] }
        }
    }

    private struct Job {
        let work: Work
        let box: PlanBox
        let task: Task<ScatterPlan, Never>
    }

    private var pieces: [Piece] = []
    private var surface: (any ToppingSurface)?
    private var resting: [ScatterFootprint] = []
    /// Settles still running, oldest first; each starts from the result of the one before.
    private var jobs: [Job] = []
    private var animating = false
    private var tossed: (real: Double, settle: Double, held: Bool)?
    private var isHoming = false
    private var homeLostAt: Double?

    /// Simulated seconds shown per real second: slower than life so a fall on a small scoop reads.
    static let playbackRate: Float = 0.6
    /// The longest a recorded fall plays; longer ones play faster, so a handful lands as one toss.
    static let longestFall: Float = 0.4
    /// Until its settle is known, a tossed piece's flight goes no further than this share of the way.
    static let heldFlight = 0.7
    /// A piece aimed at a guess moves onto its worked-out pose over this long once that's known.
    static let retarget: Float = 0.25
    static let popGrow = 0.08
    static let popShrink = 0.13
    static let returnDuration = 0.42
    /// As long as a scoop's flight back to its flavor card.
    static let homeDuration = 0.78
    static let homeLostFade = 0.2
    enum Serving {
        /// Fewer pieces on a small top or one shared with other candy, so they lie in one loose layer.
        case fitToRoom
        /// Always the kind's whole count: pieces with no room on the ice cream are laid on the scoops' shoulders or rest on
        /// lying pieces, never up a heap.
        case full
    }

    static let serving = Serving.full

    init(kind: ScatterKind) {
        self.kind = kind
        entity.name = "scatter"
    }

    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface { below }

    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double) {
        for piece in pieces { piece.model.removeFromParent() }
        pieces = []
        resting = []
        jobs = []
        isFinished = false
        self.surface = surface
        var rng = ToppingRandom(seed: seed)
        let made = kind.makePieces(rng: &rng)
        let specs = Array(made.prefix(portion(made, on: surface)))
        let radius = max(surface.radius, 1e-3)
        let apexXZ = SIMD2(surface.apex.x, surface.apex.z)
        let pinches = specs.count > 20 ? 3 : specs.count > 4 ? 2 : 1
        var tosses: [ScatterToss] = []
        for (index, spec) in specs.enumerated() {
            let candidates = (0..<5).map { _ in
                let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
                return SIMD2(cos(angle), sin(angle)) * 0.85 * pow(Float.random(in: 0...1, using: &rng), 0.6)
            }
            let orientation = simd_quatf(angle: Float.random(in: 0..<(2 * .pi), using: &rng), axis: [0, 1, 0])
                * simd_quatf(angle: Float.random(in: 0...1.2, using: &rng), axis: Self.randomUnit(&rng))
            let push = Self.randomUnit(&rng) * Float.random(in: 0...0.04, using: &rng)
            let spin = Self.randomUnit(&rng) * Float.random(in: 1...5, using: &rng)
            tosses.append(ScatterToss(candidates: candidates, orientation: orientation, push: push, spin: spin))
            let along = specs.count > 1 ? Double(index) / Double(specs.count - 1) : 0
            let pinch = min(Int(along * Double(pinches)), pinches - 1)
            let model = ModelEntity(mesh: spec.mesh, materials: spec.materials)
            model.isEnabled = false
            entity.addChild(model)
            let shape = ScatterShape(half: spec.halfExtents)
            let aim = apexXZ + candidates[0] * radius
            let ground = surface.sample(x: aim.x, z: aim.y)?.height ?? surface.apex.y
            let guess = ScatterPose(position: [aim.x, ground + ScatterPlanner.dropHeight + shape.bound, aim.y], rotation: orientation)
            var piece = Piece(model: model, shape: shape, look: spec.look, meshCenter: spec.mesh.bounds.center,
                              delay: Double(pinch) * 0.1 + Double.random(in: 0...0.08, using: &rng),
                              flight: Double.random(in: 0.36...0.48, using: &rng),
                              arcHeight: radius * Float.random(in: 0.5...1.0, using: &rng),
                              hand: Self.randomUnit(&rng) * radius * Float.random(in: 0...0.5, using: &rng),
                              lean: Float.random(in: 0.15...0.55, using: &rng),
                              tumbleAxis: Self.randomUnit(&rng), tumble: Float.random(in: 2...5, using: &rng) * .pi,
                              removeDelay: along * (specs.count > 20 ? 0.35 : 0.2), guess: guess)
            if animated { piece.motion = .arrive(start: now) }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { return }
        let work = Work(kind: .toss(tosses, full: Self.serving == .full), shapes: pieces.map(\.shape), surface: surface)
        if animated {
            tossed = (CACurrentMediaTime(), 0, false)
            enqueue(work)
            animating = true
            update(now: now)
        } else {
            finish(work.run(below: settledBeneath(), prior: []), of: work, final: true, now: now)
            showAtRest()
        }
    }

    /// The tallest a piece stands lying flat, for headroom above the surface.
    var pieceHeight: Float {
        pieces.map { 2 * $0.shape.half.min() }.max() ?? 0
    }

    /// The top of the pieces as last settled.
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
                guard let s = surface.sample(x: x, z: z), s.height > surface.floor,
                      s.normal.y > ScatterPlanner.steepestAim else { continue }
                usable += step * step
            }
        }
        let fits = Int(0.8 * usable / Float(max(crowd, 1)) / pieceArea)
        return min(made.count, max(fits, Self.leastPortion(made.count)))
    }

    private static func leastPortion(_ serving: Int) -> Int {
        min(serving, max(3, serving / 3))
    }

    // MARK: Settling

    private var landings: [ScatterLanding] {
        pieces.map { $0.landing ?? ScatterLanding(rest: $0.guess, track: [], lost: true) }
    }

    /// Starts `work` on a background task once the layers beneath and this layer's earlier settles are done.
    private func enqueue(_ work: Work) {
        let below = beneath.map { ($0.jobs.last?.task, $0.resting) }
        let prior = (jobs.last?.task, landings)
        let box = PlanBox()
        let task = Task.detached(priority: .userInitiated) {
            var footprints: [ScatterFootprint] = []
            for (pending, now) in below {
                if let pending { footprints += await pending.value.resting } else { footprints += now }
            }
            let previous: [ScatterLanding]
            if let pending = prior.0 { previous = await pending.value.landings } else { previous = prior.1 }
            let plan = work.run(below: footprints, prior: previous, landed: box.landed)
            box.plan = plan
            return plan
        }
        jobs.append(Job(work: work, box: box, task: task))
        for index in pieces.indices { pieces[index].awaiting = true }
    }

    /// Settles everything still running right away, on this thread; results match what the background would give.
    func finishSettling() {
        while let job = jobs.first {
            let plan = job.box.plan ?? job.work.run(below: settledBeneath(), prior: landings)
            jobs.removeFirst()
            finish(plan, of: job.work, final: jobs.isEmpty, now: nil)
        }
    }

    private func settledBeneath() -> [ScatterFootprint] {
        for layer in beneath { layer.finishSettling() }
        return beneath.flatMap(\.resting)
    }

    private func collect(now: Double) {
        while let job = jobs.first, let plan = job.box.plan {
            jobs.removeFirst()
            finish(plan, of: job.work, final: jobs.isEmpty, now: now)
        }
        guard jobs.count == 1, let job = jobs.first, case .toss = job.work.kind else { return }
        let known = pieces.prefix { !$0.awaiting }.count
        for (index, landing) in zip(known..., job.box.landings(from: known)) where index < pieces.count {
            land(index, landing, now: now)
        }
    }

    private func land(_ index: Int, _ landing: ScatterLanding, now: Double?) {
        var piece = pieces[index]
        piece.landing = landing
        let span = Float(max(landing.track.count - 1, 0)) * ScatterSettle.recordInterval
        piece.rate = max(Self.playbackRate, span / Self.longestFall)
        piece.awaiting = false
        piece.knownAt = now ?? -.infinity
        if landing.lost {
            piece.motion = .none
            piece.model.isEnabled = false
        }
        pieces[index] = piece
    }

    private func finish(_ plan: ScatterPlan, of work: Work, final: Bool, now: Double?) {
        let tossing: Bool
        if case .toss = work.kind { tossing = true } else { tossing = false }
        for index in pieces.indices where index < plan.landings.count {
            if final {
                let pending = pieces[index].awaiting || pieces[index].landing == nil
                if pending, tossing || !pieces[index].lost { land(index, plan.landings[index], now: now) }
            } else if tossing || !pieces[index].lost {
                pieces[index].landing = plan.landings[index]
            }
        }
        resting = plan.resting
        if tossing {
            tossed?.settle = plan.seconds
            reportTally(plan)
        }
    }

    private func showAtRest() {
        for index in pieces.indices where !pieces[index].lost {
            pieces[index].shown = pieces[index].rest
            pieces[index].motion = .none
            pieces[index].scale = 1
            pieces[index].model.isEnabled = true
            place(pieces[index])
        }
    }

    private func reportTally(_ plan: ScatterPlan) {
        let lost = plan.tally["lost", default: 0]
        let detail = ["lies", "laid", "perches", "wedges", "pressed", "lost"].map { "\($0) \(plan.tally[$0, default: 0])" }
            .joined(separator: ", ")
        SquareService.appendToLogFile(String(format: "Scatter: %@ placed %d/%d (%@) in %.0f ms", "\(type(of: kind))",
                                             pieces.count - lost, pieces.count, detail, plan.seconds * 1000))
    }

    /// Moves the pieces onto a new surface beneath, keeping their places on it: each glides from where it's shown to
    /// where it settles there, over `duration`, with the same easing as the layers that changed beneath it.
    func resurface(to surface: ToppingSurface, duration: Double, now: Double) {
        let previous = self.surface
        self.surface = surface
        guard !pieces.isEmpty else { return }
        let work = Work(kind: .resurface(from: previous), shapes: pieces.map(\.shape), surface: surface)
        guard duration > 0 else {
            finishSettling()
            finish(work.run(below: settledBeneath(), prior: landings), of: work, final: true, now: now)
            for index in pieces.indices {
                switch pieces[index].motion {
                case .leave, .home: continue
                case .arrive where !pieces[index].model.isEnabled: continue
                default: break
                }
                pieces[index].shown = pieces[index].rest
                pieces[index].motion = .none
                pieces[index].scale = 1
                if !pieces[index].lost { place(pieces[index]) }
            }
            return
        }
        enqueue(work)
        for index in pieces.indices {
            var piece = pieces[index]
            switch piece.motion {
            case .leave, .home: continue
            case .arrive where !piece.model.isEnabled: continue
            default: break
            }
            var guess = piece.rest
            if let then = previous?.sample(x: guess.position.x, z: guess.position.z),
               let next = surface.sample(x: guess.position.x, z: guess.position.z) {
                guess.position.y += next.height - then.height
            }
            piece.scale = 1
            piece.motion = .glide(from: piece.shown, guess: guess, start: now, duration: duration)
            pieces[index] = piece
        }
        animating = true
    }

    func remove(now: Double) {
        guard !pieces.isEmpty else {
            isFinished = true
            return
        }
        jobs = []
        tossed = nil
        if let home, !home.slots.isEmpty {
            sendHome(to: home, now: now)
        } else {
            for index in pieces.indices {
                pieces[index].motion = .leave(from: pieces[index].shown, start: now + pieces[index].removeDelay)
            }
        }
        resting = []
        animating = true
    }

    /// Every piece in sight gets one of the icon's pieces to land on, the closest look first; spares follow the icon
    /// piece most like them and shrink into it. Icon pieces nothing lands on grow back after the handoff.
    private func sendHome(to icon: ToppingCardIcon, now: Double) {
        icon.beginReturn(self) { [weak self] in self?.entity.scene != nil }
        isHoming = true
        homeLostAt = nil
        var free: [Int] = []
        for index in pieces.indices {
            if pieces[index].model.isEnabled, !pieces[index].lost {
                free.append(index)
            } else {
                pieces[index].motion = .none
                pieces[index].model.isEnabled = false
            }
        }
        var slotOf: [Int: Int] = [:]
        for slot in icon.slotLooks.indices {
            guard let best = free.indices.max(by: {
                icon.slotLooks[slot].likeness(to: pieces[free[$0]].look) < icon.slotLooks[slot].likeness(to: pieces[free[$1]].look)
            }) else { break }
            slotOf[free.remove(at: best)] = slot
        }
        var spares = [Int](repeating: 0, count: icon.slotLooks.count)
        for index in free {
            let look = pieces[index].look
            let slot = icon.slotLooks.indices.max {
                (icon.slotLooks[$0].likeness(to: look), -spares[$0]) < (icon.slotLooks[$1].likeness(to: look), -spares[$1])
            } ?? 0
            spares[slot] += 1
            pieces[index].motion = .home(from: pieces[index].model.transform, start: now + pieces[index].removeDelay,
                                         slot: slot, stays: false)
        }
        for (index, slot) in slotOf {
            pieces[index].motion = .home(from: pieces[index].model.transform, start: now + pieces[index].removeDelay,
                                         slot: slot, stays: true)
        }
    }

    func update(now: Double) {
        guard animating || !jobs.isEmpty else { return }
        if let home, isHoming {
            updateHome(home, now: now)
            return
        }
        collect(now: now)
        var active = false
        var leaving = false
        let launch = launchPoint?()
        let ceiling = self.ceiling?() ?? .infinity
        for index in pieces.indices {
            switch pieces[index].motion {
            case .none:
                continue
            case .arrive(let start):
                if pieces[index].lost { continue }
                active = stepArrive(index, start: start, now: now, launch: launch, ceiling: ceiling) || active
            case let .glide(from, guess, start, duration):
                active = stepGlide(index, from: from, guess: guess, start: start, duration: duration, now: now) || active
            case let .leave(from, start):
                leaving = true
                active = stepLeave(index, from: from, t: now - start, launch: launch, ceiling: ceiling) || active
            case .home:
                continue
            }
            place(pieces[index])
        }
        if let tossed, jobs.isEmpty, !pieces.contains(where: { if case .arrive = $0.motion { !$0.lost } else { false } }) {
            let launched = pieces.filter { !$0.lost }.map(\.delay).max() ?? 0
            SquareService.appendToLogFile(String(format: "Scatter: %@ landed %.0f ms after the tap (last launch %.0f ms, settle %.0f ms%@)",
                                                 "\(type(of: kind))", (CACurrentMediaTime() - tossed.real) * 1000,
                                                 launched * 1000, tossed.settle * 1000, tossed.held ? ", held in flight" : ""))
            self.tossed = nil
        }
        if !active, jobs.isEmpty {
            animating = false
            if leaving { isFinished = true }
        }
    }

    // MARK: Motion

    /// Tossed from the card on an arc into the start of the recorded fall, then the fall itself. Until the settle is
    /// known the arc ends at the piece's guess, and it eases onto the real start once it is; a piece still waiting
    /// most of the way there holds its place in the air. The fall starts a drop height above the landing spot, which on
    /// a tall item can reach the title, so a tossed piece is held under `ceiling`.
    private func stepArrive(_ index: Int, start: Double, now: Double, launch: SIMD3<Float>?, ceiling: Float) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        let known = piece.awaiting ? nil : piece.landing
        let held = launch != nil ? Self.heldFlight * piece.flight : 0
        if known == nil, now - start - piece.delay > held {
            piece.delay = now - start - held
            tossed?.held = true
        }
        let t = now - start - piece.delay
        guard t >= 0, known != nil || launch != nil else {
            piece.model.isEnabled = false
            return true
        }
        piece.model.isEnabled = true
        var first = piece.guess
        if let known, let actual = known.track.first {
            first = piece.guess.mixed(actual, settling(piece, since: start + piece.delay, now: now))
        }
        let top = max(ceiling - piece.shape.bound, piece.rest.position.y)
        first.position.y = min(first.position.y, top)
        let running: Bool
        if let launch, t < piece.flight || known == nil {
            let s = Float(min(t / piece.flight, 1))
            let from = launch + piece.hand
            let arc = max(min(piece.arcHeight, (top - first.position.y) / 1.3), 0)
            let peak = first.position.y + arc
            let entry = known.map { Self.entryVelocity($0.track, rate: piece.rate) } ?? [0, -ScatterPlanner.dropSpeed * Self.playbackRate, 0]
            let ahead = simd_mix(from, first.position, SIMD3(repeating: piece.lean))
            let rise = SIMD3(ahead.x, peak + 0.3 * arc, ahead.z)
            var fall = first.position - entry * Float(piece.flight) / 3
            fall.y = min(max(fall.y, peak), top)
            let position = cubicBezier(from, rise, fall, first.position, s)
            let spin = simd_quatf(angle: piece.tumble * (1 - s), axis: piece.tumbleAxis)
            piece.shown = ScatterPose(position: position, rotation: first.rotation * spin)
            piece.scale = 0.45 + 0.55 * Ease.outCubic(min(s * 2.5, 1))
            running = true
        } else if let known {
            piece.scale = launch != nil ? 1 : Ease.outCubic(Float(min(t / 0.08, 1)))
            running = playTrack(&piece, known.track, t: launch != nil ? t - piece.flight : t)
        } else {
            running = true
        }
        piece.shown.position.y = min(piece.shown.position.y, top)
        return running
    }

    private func stepGlide(_ index: Int, from: ScatterPose, guess: ScatterPose, start: Double, duration: Double, now: Double) -> Bool {
        var piece = pieces[index]
        defer { pieces[index] = piece }
        piece.model.isEnabled = true
        piece.scale = 1
        let s = duration > 0 ? Ease.inOutSine(Ease.clamp01(Float((now - start) / duration))) : 1
        var target = guess
        var settled = false
        if !piece.awaiting, piece.landing != nil {
            let w = settling(piece, since: start, now: now)
            target = guess.mixed(piece.rest, w)
            settled = w >= 1
        }
        piece.shown = from.mixed(target, s)
        guard s >= 1, settled else { return true }
        piece.shown = piece.rest
        piece.motion = .none
        return false
    }

    /// How far a piece aimed at its guess has moved onto its worked-out pose: all the way if that was known before it
    /// set off.
    private func settling(_ piece: Piece, since start: Double, now: Double) -> Float {
        guard piece.knownAt > start else { return 1 }
        let t = Ease.clamp01(Float(now - piece.knownAt) / Self.retarget)
        return t * t * (3 - 2 * t)
    }

    private func playTrack(_ piece: inout Piece, _ track: [ScatterPose], t: Double) -> Bool {
        let frame = max(Float(t) * piece.rate / ScatterSettle.recordInterval, 0)
        let last = track.count - 1
        guard last > 0, frame < Float(last) else {
            piece.shown = piece.rest
            piece.motion = .none
            return false
        }
        let index = Int(frame)
        piece.shown = track[index].mixed(track[index + 1], frame - Float(index))
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

    /// Landed pieces keep following their icon piece until the last one is in, then the icon takes their place in the
    /// same frame. If another return took the icon over, or it was reset, they shrink away instead.
    private func updateHome(_ icon: ToppingCardIcon, now: Double) {
        let toLayer = entity.transformMatrix(relativeTo: nil).inverse
        let slots = icon.slotMatrices().map { Transform(matrix: toLayer * $0) }
        let ceiling = self.ceiling?() ?? .infinity
        let owned = icon.isReturning(self)
        if !owned, homeLostAt == nil { homeLostAt = now }
        let fade = homeLostAt.map { 1 - Ease.inQuad(Ease.clamp01(Float((now - $0) / Self.homeLostFade))) } ?? 1
        var landed: [Int: ModelComponent] = [:]
        var waiting = false
        for index in pieces.indices {
            guard case let .home(from, start, slot, stays) = pieces[index].motion, slot < slots.count else { continue }
            switch stepHome(index, from: from, t: now - start, to: slots[slot], stays: stays, fade: fade, ceiling: ceiling) {
            case .moving: waiting = true
            case .parked: if let model = pieces[index].model.model { landed[slot] = model }
            case .gone: break
            }
        }
        guard !waiting, owned || landed.isEmpty || fade <= 0 else { return }
        if owned { icon.completeReturn(self, models: landed) }
        for index in pieces.indices {
            pieces[index].motion = .none
            pieces[index].model.isEnabled = false
        }
        isHoming = false
        animating = false
        isFinished = true
    }

    /// Timed like a scoop flying home to its flavor card. The tumble is whole turns so the piece ends on the icon
    /// piece's exact orientation.
    private func stepHome(_ index: Int, from: Transform, t: Double, to target: Transform, stays: Bool, fade: Float,
                          ceiling: Float) -> Homing {
        let piece = pieces[index]
        guard t >= 0 else {
            if fade < 1 {
                piece.model.transform.scale = from.scale * max(fade, 1e-4)
                if fade <= 0 { return gone(index) }
            }
            return .moving
        }
        let p = Float(min(t / Self.homeDuration, 1))
        let e = TimingCurve.flight(p)
        var lifted = (from.translation + target.translation) / 2 + SIMD3(0, piece.arcHeight * 0.8, 0)
        lifted.y = min(lifted.y, max(ceiling - piece.shape.bound, from.translation.y, target.translation.y))
        let u = 1 - e
        let position = u * u * from.translation + 2 * u * e * lifted + e * e * target.translation
        let turns = max((piece.tumble / (2 * .pi)).rounded(), 1) * 2 * .pi
        let rotation = simd_slerp(from.rotation, target.rotation, e) * simd_quatf(angle: turns * e, axis: piece.tumbleAxis)
        var shrink = fade
        if !stays {
            let s = Ease.clamp01((p - 0.35) / 0.55)
            shrink *= 1 - s * s * (3 - 2 * s)
        }
        let scale = simd_mix(from.scale, target.scale, SIMD3(repeating: TimingCurve.standard(p))) * shrink
        piece.model.transform = Transform(scale: simd_max(scale, SIMD3(repeating: 1e-6)), rotation: rotation, translation: position)
        piece.model.isEnabled = shrink > 0.001
        if shrink <= 0.001, !stays || fade <= 0.001 { return gone(index) }
        return stays && p >= 1 ? .parked : .moving
    }

    private func gone(_ index: Int) -> Homing {
        pieces[index].motion = .none
        pieces[index].model.isEnabled = false
        return .gone
    }

    private func place(_ piece: Piece) {
        let scale = max(piece.scale, 1e-4)
        let rotation = piece.shown.rotation
        piece.model.transform = Transform(scale: SIMD3(repeating: scale), rotation: rotation,
                                          translation: piece.shown.position - rotation.act(piece.meshCenter * scale))
    }

    /// Real-time velocity at the start of a recorded track, so a toss flows into the fall.
    private static func entryVelocity(_ track: [ScatterPose], rate: Float) -> SIMD3<Float> {
        guard track.count > 1 else { return [0, -ScatterPlanner.dropSpeed * rate, 0] }
        return (track[1].position - track[0].position) / ScatterSettle.recordInterval * rate
    }

    private static func randomUnit(_ rng: inout ToppingRandom) -> SIMD3<Float> {
        let y = Float.random(in: -1...1, using: &rng)
        let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
        let r = (1 - y * y).squareRoot()
        return [r * cos(angle), y, r * sin(angle)]
    }
}
