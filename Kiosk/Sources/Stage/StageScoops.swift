import RealityKit
import SwiftUI

/// Hermite spline through waypoints, parameterized by chord length, with explicit end tangents so a
/// flight can leave its icon upward and arrive along the slot's settle direction.
struct FlightPath {
    var points: [SIMD3<Float>]
    var startTangent: SIMD3<Float>
    var endTangent: SIMD3<Float>
    private(set) var stops: [Float] = []

    init(points: [SIMD3<Float>], startDirection: SIMD3<Float>, endDirection: SIMD3<Float>) {
        self.points = points
        self.startTangent = .zero
        self.endTangent = .zero
        var cumulative: [Float] = [0]
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + max(simd_length(points[i] - points[i - 1]), 1e-4))
        }
        let total = cumulative.last ?? 1
        stops = cumulative.map { $0 / total }
        let first = simd_length(points[1] - points[0])
        let last = simd_length(points[points.count - 1] - points[points.count - 2])
        startTangent = simd_normalize(startDirection) * first
        endTangent = simd_normalize(endDirection) * last
    }

    var length: Float {
        var total: Float = 0
        for i in 1..<points.count { total += simd_length(points[i] - points[i - 1]) }
        return total
    }

    /// Per-axis monotone tangents: zero at a local extremum and never more than 3× the neighboring
    /// step, so the curve can't bulge past a waypoint (e.g. up behind the header).
    private func tangent(at i: Int) -> SIMD3<Float> {
        let last = points.count - 1
        var m: SIMD3<Float>
        if i == 0 {
            m = startTangent
        } else if i == last {
            m = endTangent
        } else {
            let d0 = points[i] - points[i - 1], d1 = points[i + 1] - points[i]
            m = .zero
            for axis in 0..<3 where d0[axis] * d1[axis] > 0 {
                m[axis] = 2 * d0[axis] * d1[axis] / (d0[axis] + d1[axis])
            }
            return m
        }
        let d = i == 0 ? points[1] - points[0] : points[last] - points[last - 1]
        for axis in 0..<3 {
            let limit = 3 * abs(d[axis])
            m[axis] = d[axis] * m[axis] < 0 ? 0 : min(max(m[axis], -limit), limit)
        }
        return m
    }

    func position(_ s: Float) -> SIMD3<Float> {
        let s = Ease.clamp01(s)
        var i = 0
        while i < stops.count - 2, s > stops[i + 1] { i += 1 }
        let t = (s - stops[i]) / max(stops[i + 1] - stops[i], 1e-5)
        let p0 = points[i], p1 = points[i + 1]
        let m0 = tangent(at: i)
        let m1 = tangent(at: i + 1)
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
    }
}

/// A flight that only meets a vessel from above its rim: it rises beside the vessel (going around it from a card
/// beneath), crosses over the rim, then comes straight down the axis to the approach point. Everything after the rise
/// is placed relative to the live approach point, so it follows the item while it spins and reframes; sizes are in
/// the vessel's units and scale with it. Played backwards (from the column out to a point) it is the way out.
struct ColumnFlight {
    enum Lead {
        /// Up beside the vessel to `lateral` off the axis on `side`, then over the rim.
        case around(rise: SIMD3<Float>, side: SIMD3<Float>, lateral: Float)
        /// Straight to the top of the column (the start is already above the rim or inside the opening), leaving
        /// along `heading`.
        case direct(heading: SIMD3<Float>)
    }

    var lead: Lead
    /// Height above the approach point, along the axis, where the descent begins: the scoop clears the rim there.
    var height: Float
    /// How far above `height` the crossing bulges, so the scoop comes over the rim rather than sliding onto it.
    var hump: Float
    var riseEnd: Float = 0
    var dropStart: Float = 0
    /// Speed along the axis at the approach point, in world units per unit of progress.
    var endSpeed: Float

    init(lead: Lead, from p0: SIMD3<Float>, approach pa: SIMD3<Float>, up: SIMD3<Float>, scale: Float,
         height: Float, hump: Float, endSpeed: Float) {
        self.lead = lead
        self.height = height
        self.hump = hump
        self.endSpeed = endSpeed
        let top = pa + up * height * scale
        let drop = height * scale
        switch lead {
        case .around(_, let side, let lateral):
            let beside = top + side * lateral * scale
            let rise = simd_length(beside - p0)
            let over = lateral * scale * 1.1 + hump * scale
            let total = rise + over + drop
            riseEnd = rise / total
            dropStart = (rise + over) / total
        case .direct:
            let over = simd_length(top - p0) + hump * scale
            dropStart = over / (over + drop)
        }
    }

    func position(_ u: Float, from p0: SIMD3<Float>, approach pa: SIMD3<Float>, up: SIMD3<Float>, scale: Float) -> SIMD3<Float> {
        let top = pa + up * height * scale
        let crest = top + up * hump * scale
        if u < dropStart {
            switch lead {
            case .around(let rise, let side, let lateral):
                let beside = top + side * lateral * scale
                let inward = lateral * scale * 0.55
                if u < riseEnd {
                    let outward = inward * riseEnd / max(dropStart - riseEnd, 1e-4)
                    return cubicBezier(p0, p0 + rise, beside + side * outward, beside, u / max(riseEnd, 1e-4))
                }
                return cubicBezier(beside, beside - side * inward, crest, top, (u - riseEnd) / max(dropStart - riseEnd, 1e-4))
            case .direct(let heading):
                return cubicBezier(p0, p0 + heading, crest, top, u / max(dropStart, 1e-4))
            }
        }
        let span = max(1 - dropStart, 1e-4)
        let t = (u - dropStart) / span
        let segment = max(dropStart - riseEnd, 1e-4)
        let lambda = height * scale
        let m0 = -min(3 * hump * scale * span / segment, 3 * lambda)
        let m1 = -min(endSpeed * span, 3 * lambda)
        let t2 = t * t, t3 = t2 * t
        let h = (2 * t3 - 3 * t2 + 1) * lambda + (t3 - 2 * t2 + t) * m0 + (t3 - t2) * m1
        return pa + up * h
    }
}

extension Stage {
    enum ScoopRoute {
        case fromIcon(side: Float)
        case restack
    }

    static let approachClearance: Float = 0.004
    /// How far a new scoop has already squashed toward its placed shape when it reaches the point above its slot.
    /// The press bound lets it wait correspondingly lower, which keeps the top scoop's arrival under the title.
    static let preSquish: Float = 0.5
    static let minimumLift: Float = 0.004
    static let pressDuration: Double = 0.4
    /// Settling curve for the press; starts at 1.2× linear speed so the flight can hand over without a kink.
    static let pressCurve = TimingCurve(0.3, 0.36, 0.42, 1)
    static let pressStartSlope: Float = 1.2
    /// Screen y (points) below the builder title; a flying scoop's top must stay under it.
    static let flightCeilingY: CGFloat = 244

    func liftHeight(_ vessel: Vessel, key: String) -> Float {
        max(contactLift["\(vessel.rawValue):\(key)"] ?? 0.02, Self.minimumLift)
    }

    func placementKey(index: Int, count: Int, vessel: Vessel) -> String {
        if vessel == .cup, index == 0, count == 1 { return "solo" }
        return Self.slotKeys[min(index, 2)]
    }

    func finalPoseName(_ vessel: Vessel, key: String) -> String {
        vessel == .cone ? "cone" : (key == "solo" ? "cup_solo" : "cup")
    }

    func slotLocal(_ vessel: Vessel, key: String, height: Float) -> Transform {
        let placement = assets!.placements.placement(vessel, key: key)
        return Transform(scale: .one, rotation: placement.rotation,
                         translation: placement.translation + placement.rotation.act([0, height, 0]))
    }

    func slotWorld(_ rig: ItemRig, key: String, height: Float) -> Transform {
        Transform(matrix: rig.body.transformMatrix(relativeTo: nil) * slotLocal(rig.vessel, key: key, height: height).matrix)
    }

    func liveKey(_ actor: ScoopActor, on rig: ItemRig) -> String {
        let index = rig.scoops.firstIndex { $0 === actor } ?? 0
        return placementKey(index: index, count: rig.scoops.count, vessel: rig.vessel)
    }

    /// How far the scoop beneath this one is still above its own slot. Placements are defined against the
    /// landed scoops below, so while the one beneath settles, this one rides on it instead of sinking into it.
    func stackLift(below actor: ScoopActor, on rig: ItemRig) -> Float {
        guard let index = rig.scoops.firstIndex(where: { $0 === actor }), index > 0 else { return 0 }
        let lower = rig.scoops[index - 1]
        return lower.state == .pressing && lower.mount === rig ? lower.pressHeight : 0
    }

    func approachHeight(_ actor: ScoopActor, on rig: ItemRig, squish: Float = 0) -> Float {
        liftHeight(rig.vessel, key: liveKey(actor, on: rig)) * (1 - squish) + Self.approachClearance + stackLift(below: actor, on: rig)
    }

    func approachTransform(_ actor: ScoopActor, on rig: ItemRig, squish: Float = 0) -> Transform {
        slotWorld(rig, key: liveKey(actor, on: rig), height: approachHeight(actor, on: rig, squish: squish))
    }

    func detachToWorld(_ actor: ScoopActor) {
        let matrix = actor.root.transformMatrix(relativeTo: nil)
        root.addChild(actor.root)
        actor.root.transform = Transform(matrix: matrix)
        actor.mount = nil
    }

    /// Makes `rig` the only owner of `actors`, in that order. Ownership changes immediately; where each scoop
    /// is attached (`mount`) only changes when its motion gets there.
    func setOwner(_ actors: [ScoopActor], _ rig: ItemRig) {
        for actor in actors {
            if let previous = actor.rig, previous !== rig { previous.scoops.removeAll { $0 === actor } }
            for other in heroes.values where other !== rig { other.scoops.removeAll { $0 === actor } }
            actor.rig = rig
        }
        rig.scoops = actors
    }

    static let rimMargin: Float = 0.002
    static let restackHover: Float = 0.03
    /// Even a slot above the rim is reached by coming over the top and down its axis, not from the side.
    static let minimumCrossing: Float = 0.004

    /// Height above a slot's origin, along its axis, at which the scoop's lowest point (in any pose it travels in)
    /// clears the vessel's highest rim point. Below it a scoop may only move along the axis.
    func rimClearHeight(_ vessel: Vessel, key: String) -> Float {
        guard let assets else { return 0 }
        let placement = assets.placements.placement(vessel, key: key)
        let set = assets.scoopSet(key == "solo" ? 1 : Int(key) ?? 1)
        var lowest: Float = 0
        for pose in ["ball", finalPoseName(.cup, key: key), "cone"] {
            let b = set.poseBounds(pose)
            for corner in 0..<8 {
                let p = SIMD3<Float>(corner & 1 == 0 ? b.min.x : b.max.x, corner & 2 == 0 ? b.min.y : b.max.y,
                                     corner & 4 == 0 ? b.min.z : b.max.z)
                lowest = min(lowest, placement.rotation.act(p).y)
            }
        }
        let up = max(placement.rotation.act([0, 1, 0]).y, 0.5)
        return max(0, (assets.vesselTop(vessel) + Self.rimMargin - placement.translation.y - lowest) / up)
    }

    /// Distance from a slot's axis, in the vessel's units, at which a ball passes the vessel without touching it.
    func besideDistance(_ vessel: Vessel, key: String) -> Float {
        guard let assets else { return 0.1 }
        let placement = assets.placements.placement(vessel, key: key)
        let ball = assets.scoopSet(key == "solo" ? 1 : Int(key) ?? 1).poseBounds("ball")
        let radius = max(-ball.min.x, ball.max.x, -ball.min.z, ball.max.z)
        return assets.vesselHalfWidth(vessel) + radius + simd_length(SIMD2(placement.translation.x, placement.translation.z)) + 0.003
    }

    /// Where a scoop's base is in a vessel's frame, if it is down inside that vessel's opening.
    func insidePoint(_ actor: ScoopActor, of rig: ItemRig) -> SIMD3<Float>? {
        guard let assets, rig.root.parent != nil else { return nil }
        let w = actor.root.transformMatrix(relativeTo: nil).columns.3
        let l = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * w
        let inside = l.y > 0 && l.y < assets.vesselTop(rig.vessel) + Self.rimMargin
            && simd_length(SIMD2(l.x, l.z)) < assets.vesselRadius(rig.vessel, atHeight: l.y)
        return inside ? SIMD3(l.x, l.y, l.z) : nil
    }

    /// Keeps a flying scoop off vessels where its own motion doesn't: over the opening of a vessel it is neither
    /// entering nor leaving it stays above the rim, and beside any vessel it stays outside the wall. Only bites when
    /// two motions cross (a swap, removal or add interrupting another); the planned paths keep clear on their own.
    func avoidVessels(_ position: SIMD3<Float>, scale: Float, slot: Int, excluding: [ItemRig]) -> SIMD3<Float> {
        guard let assets else { return position }
        let set = assets.scoopSet(slot)
        let ball = set.poseBounds("ball")
        let lowest = min(0, ball.min.y, set.poseBounds("cup").min.y, set.poseBounds("cone").min.y)
        let widest = set.poseBounds("icon")
        var position = position
        for rig in Array(heroes.values) + leavingRigs where rig.root.parent != nil && rig.rolled.isEnabled {
            let body = rig.body.transformMatrix(relativeTo: nil)
            let rigScale = simd_length(SIMD3(body.columns.0.x, body.columns.0.y, body.columns.0.z))
            guard rigScale > 1e-3 else { continue }
            let k = scale / rigScale
            let l4 = simd_inverse(body) * SIMD4<Float>(position, 1)
            var local = SIMD3(l4.x, l4.y, l4.z)
            let radius = max(-ball.min.x, ball.max.x, -ball.min.z, ball.max.z) * k
            let width = max(-widest.min.x, widest.max.x, -widest.min.z, widest.max.z, radius / k) * k
            let rim = assets.vesselTop(rig.vessel)
            let r = simd_length(SIMD2(local.x, local.z))
            let bottom = local.y + lowest * k
            let top = local.y + ball.max.y * k
            guard top > 0, bottom < rim else { continue }
            let center = local.y + radius
            let wall = assets.vesselRadius(rig.vessel, atHeight: min(max(center, 0), rim))
            let overOpening = r < wall * 0.8
            if overOpening, excluding.contains(where: { $0 === rig }) { continue }
            if overOpening, local.y > assets.cavityFloor[rig.vessel] ?? 0 {
                let floor = rim + Self.rimMargin - lowest * k
                guard local.y > floor - 2 * radius else { continue }
                local.y = floor
            } else {
                let reach = wall + width + Self.rimMargin
                guard r < reach else { continue }
                let below = -ball.max.y * k - Self.rimMargin
                if local.y < 0, local.y - below < reach - r {
                    local.y = below
                } else {
                    let direction = r > 1e-5 ? SIMD2(local.x, local.z) / r : SIMD2<Float>(1, 0)
                    local.x = direction.x * reach
                    local.z = direction.y * reach
                }
            }
            let w = body * SIMD4<Float>(local, 1)
            position = SIMD3(w.x, w.y, w.z)
        }
        return position
    }

    func holdsScoop(_ rig: ItemRig) -> Bool {
        liveScoops.values.contains { insidePoint($0, of: rig) != nil }
    }

    /// The vessel a scoop is inside right now: the one it is attached to, or one it is still on its way out of.
    func holder(of actor: ScoopActor, excluding rig: ItemRig? = nil) -> ItemRig? {
        if let mount = actor.mount, mount !== rig, actor.root.parent === mount.body { return mount }
        return (Array(heroes.values) + leavingRigs).first { $0 !== rig && insidePoint(actor, of: $0) != nil }
    }

    /// The first part of a column flight from below or beside the vessel: up beside it, or out to the side first
    /// when starting right beneath it.
    func aroundLead(from p0: SIMD3<Float>, approach pa: SIMD3<Float>, top: SIMD3<Float>, scale: Float, beside: Float,
                    preferredSide: Float) -> ColumnFlight.Lead {
        let dx = p0.x - pa.x
        let under = abs(dx) < beside * scale * 0.6
        let side: Float = under ? preferredSide : (dx < 0 ? -1 : 1)
        let lateral = under ? beside : max(beside, min(abs(dx) / scale, beside * 1.2))
        let q1 = under
            ? SIMD3<Float>(pa.x + side * lateral * scale * 1.3, lerp(p0.y, top.y, 0.2), p0.z + 0.06)
            : SIMD3<Float>(pa.x + side * max(abs(dx), lateral * scale), lerp(p0.y, top.y, 0.6), p0.z + 0.04)
        return .around(rise: q1 - p0, side: [side, 0, 0], lateral: lateral)
    }

    func ballHeight(slot: Int) -> Float {
        guard let assets else { return 0.045 }
        let ball = assets.scoopSet(slot).poseBounds("ball")
        return ball.max.y - ball.min.y
    }

    /// Height of the hump over the rim for a column flight that has to rise `height` (vessel units) above the approach point.
    static func humpHeight(_ height: Float) -> Float { min(0.25 * height, 0.008) }

    /// Highest point above a slot's origin that a new scoop's base reaches on its way in (where it crosses the rim),
    /// for a stack whose scoops beneath have landed.
    func approachCrest(_ vessel: Vessel, key: String) -> Float {
        let approach = liftHeight(vessel, key: key) * (1 - Self.preSquish) + Self.approachClearance
        let height = max(rimClearHeight(vessel, key: key) - approach, Self.minimumCrossing)
        return approach + height + Self.humpHeight(height) * 4 / 9
    }

    func addScoop(_ flavor: Flavor) {
        guard let hero = heroes[selectedVessel], scoops.count < Pricing.maxScoopsPerItem,
              flavorIcons[flavor] != nil else { return }
        let slot = scoops.count + 1
        let actor = ScoopActor(flavor: flavor, slot: slot, model: makeScoopModel(slot: slot, flavor: flavor, pose: "icon"), pose: "icon")
        liveScoops[ObjectIdentifier(actor)] = actor
        let start = flavorIconModelTransform(flavor, slot: slot)
        let appear = flavorIcons[flavor]?.appear ?? 1
        actor.root.transform = Transform(scale: start.scale * appear, rotation: start.rotation, translation: start.translation)
        root.addChild(actor.root)
        scoops.append(actor)
        hero.scoops.append(actor)
        actor.rig = hero
        actor.isArriving = true
        reframe(hero)

        setFlavorIconAppear(flavor, to: 0, duration: 0)
        setFlavorIconAppear(flavor, to: 1, duration: 0.34, delay: 0.5)
        relayoutFirstScoop(on: hero, delay: 0)

        let side: Float = Layout.flavorCardCenter(flavor).x < Layout.midX ? -1 : 1
        flyToSlot(actor, rig: hero, route: .fromIcon(side: side))
    }

    func removeScoop(at index: Int) {
        guard index < scoops.count, let hero = heroes[selectedVessel] else { return }
        let actor = scoops.remove(at: index)
        hero.scoops.removeAll { $0 === actor }
        actor.rig = nil
        let above = Array(scoops[index...])
        if let upper = above.first, exitBlocked(actor, under: upper, on: hero) {
            shrinkAway(actor)
        } else {
            returnToIcon(actor, delay: above.isEmpty ? 0 : 0.06, sideways: !above.isEmpty)
        }
        for (offset, upper) in above.enumerated() {
            restack(upper, on: hero, delay: Double(offset) * 0.05)
        }
        reframe(hero)
        relayoutFirstScoop(on: hero, delay: 0.42)
    }

    /// Hands the scoops to the incoming vessel as one stack: it lifts a little while the old vessel drops
    /// away beneath it, reshapes for the new vessel in the air, and settles onto it as it rises into place.
    /// A scoop still on its way in (in neither vessel yet) flies to its slot on the new one instead.
    func transferScoops(to rig: ItemRig, arrival: Double) {
        setOwner(scoops, rig)
        for actor in scoops {
            actor.isArriving = false
            if actor.mount == nil, holder(of: actor, excluding: rig) == nil {
                actor.cancelMotions()
                flyToSlot(actor, rig: rig, route: .restack)
            } else {
                transfer(actor, to: rig, duration: arrival)
            }
        }
    }

    private func transfer(_ actor: ScoopActor, to rig: ItemRig, duration: Double) {
        actor.cancelMotions()
        var start = Transform()
        var rise = SIMD3<Float>.zero
        var origin: (rig: ItemRig, slot: Transform, clear: Float)?
        var pose = ""
        var reslotDone = false
        let gap: Float = 0.004
        let landing: Float = 0.012
        actor.motion = animate(duration: duration, phase: .attachments, onStart: { [unowned self] in
            var up: SIMD3<Float> = [0, 1, 0]
            if let mount = actor.mount, mount !== rig, actor.root.parent === mount.body {
                origin = (mount, slotLocal(mount.vessel, key: actor.placementKey, height: 0),
                          rimClearHeight(mount.vessel, key: actor.placementKey))
                let column = actor.root.transformMatrix(relativeTo: nil).columns.1
                up = simd_normalize(SIMD3(column.x, column.y, column.z))
            } else if let holder = holder(of: actor, excluding: rig), let local = insidePoint(actor, of: holder), let assets {
                let ball = assets.scoopSet(actor.slot).poseBounds("ball")
                origin = (holder, Transform(scale: .one, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), translation: local),
                          assets.vesselTop(holder.vessel) + Self.rimMargin + 0.002 - local.y - min(ball.min.y, 0))
            }
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.state = .flying
            actor.phase = "transfer"
            start = actor.root.transform
            rise = up * 0.016 * start.scale.x
            pose = finalPoseName(rig.vessel, key: liveKey(actor, on: rig))
            beginMorph(actor, to: pose)
        }) { [unowned self] p in
            let index = rig.scoops.firstIndex { $0 === actor } ?? 0
            let key = liveKey(actor, on: rig)
            let goal = transferGoal(actor, on: rig, key: key, height: gap * Float(index) * sin(.pi * p), progress: p)
            let up = goal.rotation.act([0, 1, 0])
            let e = Self.transferCurve(p)
            let slot = slotLocal(rig.vessel, key: key, height: 0)
            let clear = rimClearHeight(rig.vessel, key: key)
            var position = cubicBezier(start.translation, start.translation + rise,
                                       goal.translation + up * max(landing, clear + Self.rimMargin) * goal.scale.x, goal.translation, e)
            if let origin, origin.rig.root.parent != nil {
                position = funnel(position, rig: origin.rig, slot: origin.slot, clear: origin.clear)
            }
            position = funnel(position, rig: rig, slot: slot, clear: clear)
            // Once it is coming down into the new vessel it has that vessel's live size and turn, so it fits the opening.
            let new = opening(position, rig: rig, slot: slot)
            let inside = (1 - Ease.clamp01((new.height - clear) / landing)) * new.over
            let live = Transform(matrix: new.body * slot.matrix)
            let scale = lerp(lerp(start.scale.x, goal.scale.x, TimingCurve.standard(p)), live.scale.x, inside)
            let rotation = simd_slerp(simd_slerp(start.rotation, goal.rotation, e), live.rotation, inside)
            position = avoidVessels(position, scale: scale, slot: actor.slot, excluding: [rig] + (origin.map { [$0.rig] } ?? []))
            actor.root.transform = Transform(scale: .init(repeating: max(scale, 1e-5)), rotation: rotation, translation: position)
            if !reslotDone, actor.slot != index + 1, p >= 0.15 {
                reslotDone = true
                reslot(actor, to: index + 1)
                beginMorph(actor, to: pose)
            }
            // Reshapes only while clear of the old rim. The cone's opening only fits the cone pose, so that is complete
            // before it goes in; into the cup it reshapes in step with its descent, like the press, since a cup pose
            // lowered whole would drag its collar past the cup's rolled rim.
            var w = Ease.inOutSine(Ease.segment(p, 0.15, 0.7))
            if let origin, origin.rig.root.parent != nil {
                let old = opening(position, rig: origin.rig, slot: origin.slot)
                w = min(w, lerp(1, Ease.clamp01((old.height - origin.clear) / landing), old.over))
            }
            w = max(w, rig.vessel == .cone ? inside : max(0, 1 - max(new.height, 0) / max(clear, landing)) * new.over)
            setMorphWeight(actor, w)
        } completion: { [weak self] in
            guard let self else { return }
            let index = rig.scoops.firstIndex { $0 === actor } ?? 0
            if actor.slot != index + 1 { reslot(actor, to: index + 1) }
            let key = liveKey(actor, on: rig)
            if actor.morpher == nil || actor.morphTo != finalPoseName(rig.vessel, key: key) {
                beginMorph(actor, to: finalPoseName(rig.vessel, key: key))
            }
            setMorphWeight(actor, 1)
            endMorph(actor)
            rig.body.addChild(actor.root)
            actor.mount = rig
            actor.placementKey = key
            actor.pressHeight = 0
            actor.state = .pressing
            settle(actor, on: rig, key: key)
        }
    }

    static let transferCurve = TimingCurve(0.45, 0, 0.25, 1)

    /// A point's height above a slot along its axis, its offset from that axis, and how far it is over the vessel's
    /// opening (1 within the rim, easing to 0 just outside it, and 0 for a vessel lying on its side far below).
    /// Only a point over the opening is the funnel's to hold; one beside the vessel is the choreography's to keep clear.
    func opening(_ position: SIMD3<Float>, rig: ItemRig, slot: Transform)
        -> (height: Float, over: Float, lateral: SIMD3<Float>, body: simd_float4x4) {
        let body = rig.body.transformMatrix(relativeTo: nil)
        let l = simd_inverse(body) * SIMD4<Float>(position, 1)
        let up = slot.rotation.act([0, 1, 0])
        let offset = SIMD3(l.x, l.y, l.z) - slot.translation
        let h = simd_dot(offset, up)
        let lateral = offset - up * h
        let rim = assets?.vesselHalfWidth(rig.vessel) ?? 0.044
        let over = h < -rim ? 0 : 1 - Ease.inOutSine(Ease.segment(simd_length(lateral), rim * 0.8, rim * 1.2))
        return (h, over, lateral, body)
    }

    /// Keeps a point that is down inside a vessel's opening on the slot's axis: below `clear` (the rim-clear height
    /// above the slot) its offset from the axis is squeezed to nothing, and the squeeze relaxes smoothly above it.
    /// A smooth squeeze rather than a clamp, so the path never kinks where it takes hold or lets go.
    func funnel(_ position: SIMD3<Float>, rig: ItemRig, slot: Transform, clear: Float) -> SIMD3<Float> {
        let (h, over, lateral, body) = opening(position, rig: rig, slot: slot)
        let up = slot.rotation.act([0, 1, 0])
        let d = simd_length(lateral)
        let open = max(0, h - clear)
        let allowed: Float = 0.0005 + open * open / 0.004
        guard d > 1e-7, d > allowed * 0.02, over > 0 else { return position }
        let squeezed = lerp(d, allowed * tanh(d / allowed), over)
        let out = body * SIMD4<Float>(slot.translation + up * h + lateral * (squeezed / d), 1)
        return SIMD3(out.x, out.y, out.z)
    }

    /// The slot on the rig where it will be when its flight ends, handing over to the live rig by the end so
    /// the scoop lands exactly on it.
    private func transferGoal(_ actor: ScoopActor, on rig: ItemRig, key: String, height: Float, progress p: Float) -> Transform {
        let local = slotLocal(rig.vessel, key: key, height: height)
        let live = Transform(matrix: rig.body.transformMatrix(relativeTo: nil) * local.matrix)
        guard let goalPose = rig.flightGoal?() else { return live }
        let predicted = Transform(matrix: rig.bodyMatrix(at: goalPose) * local.matrix)
        let w = Ease.inOutSine(Ease.segment(p, 0.55, 1))
        return Transform(scale: simd_mix(predicted.scale, live.scale, .init(repeating: w)),
                         rotation: simd_slerp(predicted.rotation, live.rotation, w),
                         translation: simd_mix(predicted.translation, live.translation, .init(repeating: w)))
    }

    private func restack(_ actor: ScoopActor, on rig: ItemRig, delay: Double) {
        actor.cancelMotions()
        if actor.mount != nil, actor.state != .flying {
            unpress(actor) { [unowned self] in
                hover(actor, rise: Self.restackHover, duration: 0.22) { [unowned self] in
                    flyToSlot(actor, rig: rig, route: .restack, delay: delay)
                }
            }
        } else {
            flyToSlot(actor, rig: rig, route: .restack, delay: delay)
        }
    }

    /// Lifts a placed scoop off its slot: the exact reverse of the press, so every vertex retraces its path.
    func unpress(_ actor: ScoopActor, then next: @escaping () -> Void) {
        guard let rig = actor.mount, actor.root.parent === rig.body else {
            next()
            return
        }
        let vessel = rig.vessel
        let key = actor.placementKey
        let contact = liftHeight(vessel, key: key)
        let startHeight = actor.pressHeight
        let needsMorph = actor.staticPose != "ball" || actor.morpher != nil
        if needsMorph { beginMorph(actor, to: "ball") }
        actor.state = .leaving
        actor.phase = "unpress"
        let distance = max(contact - startHeight, 0)
        let duration = max(0.1, 0.2 * Double(contact > 0 ? distance / contact : 1))
        actor.motion = animate(duration: duration, phase: .attachments) { [unowned self] p in
            let e = Ease.inOutSine(p)
            let h = lerp(startHeight, contact, e)
            actor.pressHeight = h
            actor.root.transform = slotLocal(vessel, key: key, height: h)
            if needsMorph { setMorphWeight(actor, e) }
        } completion: { [weak self] in
            if needsMorph { self?.endMorph(actor) }
            actor.motion = nil
            next()
        }
    }

    private func hover(_ actor: ScoopActor, rise: Float, duration: Double, then next: @escaping () -> Void) {
        guard let rig = actor.mount, actor.root.parent === rig.body else {
            next()
            return
        }
        let vessel = rig.vessel
        let key = actor.placementKey
        let from = actor.pressHeight
        actor.phase = "hover"
        actor.motion = animate(duration: duration, phase: .attachments) { [unowned self] p in
            let h = from + rise * Ease.outCubic(p)
            actor.pressHeight = h
            actor.root.transform = slotLocal(vessel, key: key, height: h)
        } completion: {
            actor.motion = nil
            next()
        }
    }

    /// Flight to the point just above the slot (a `ColumnFlight`, so it only ever enters over the rim), then the press.
    /// The column end of the path tracks the (spinning, possibly flying) rig every frame.
    func flyToSlot(_ actor: ScoopActor, rig: ItemRig, route: ScoopRoute, delay: Double = 0) {
        var column: ColumnFlight?
        var start = Transform()
        var timing = TimingCurve.standard
        var morphToBall = false
        var morphDone = false
        var reslotDone = false
        var squishing = false
        let dip: Bool
        let spin: Float
        let duration: Double
        let squish: Float
        switch route {
        case .fromIcon:
            dip = true; spin = 1; duration = 0.62; squish = Self.preSquish
        case .restack:
            dip = false; spin = 0; duration = 0.42; squish = 0
        }

        actor.motion = animate(delay: delay, duration: duration, phase: .attachments, onStart: { [unowned self] in
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.state = .flying
            actor.phase = squish > 0 ? "approach" : "restack"
            start = actor.root.transform
            morphToBall = actor.staticPose != "ball" || actor.morpher != nil
            if morphToBall { beginMorph(actor, to: "ball") }

            let goal = approachTransform(actor, on: rig, squish: squish)
            let up = goal.rotation.act([0, 1, 0])
            let p0 = start.translation
            let pa = goal.translation
            let rigScale = rig.pose.scale * rig.scaleMultiplier
            let pressSpeed = Self.pressStartSlope * (liftHeight(rig.vessel, key: liveKey(actor, on: rig)) + Self.approachClearance)
                / Float(Self.pressDuration) * rigScale
            let key = liveKey(actor, on: rig)
            let height = max(rimClearHeight(rig.vessel, key: key) - approachHeight(actor, on: rig, squish: squish), Self.minimumCrossing)
            let ceiling = world(CGPoint(x: 0, y: Self.flightCeilingY)).y - 0.0438 * rigScale
            let room = (ceiling - pa.y) / max(up.y, 0.3) / rigScale - height
            let hump = min(Self.humpHeight(height), max(room / 0.75, 0.002))
            let top = pa + up * height * rigScale
            let beside = besideDistance(rig.vessel, key: key)
            let local = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * SIMD4<Float>(p0, 1)
            let inOpening = local.y > 0 && simd_length(SIMD2(local.x, local.z)) < (assets?.vesselRadius(rig.vessel, atHeight: local.y) ?? 0.044)
            let overRim = local.y >= (assets?.vesselTop(rig.vessel) ?? 0.05)
            let lead: ColumnFlight.Lead
            if case .fromIcon(let cardSide) = route {
                lead = aroundLead(from: p0, approach: pa, top: top, scale: rigScale, beside: beside, preferredSide: cardSide)
            } else if inOpening || overRim {
                lead = .direct(heading: (top - p0) / 3)
            } else {
                lead = aroundLead(from: p0, approach: pa, top: top, scale: rigScale, beside: beside,
                                  preferredSide: p0.x < pa.x ? -1 : 1)
            }
            column = ColumnFlight(lead: lead, from: p0, approach: pa, up: up, scale: rigScale, height: height, hump: hump,
                                  endSpeed: pressSpeed * Float(duration))
            timing = TimingCurve(0.42, 0, 0.6, 0.6)
        }) { [unowned self] p in
            let goal = approachTransform(actor, on: rig, squish: squish)
            let e = timing(p)
            let position = column?.position(e, from: start.translation, approach: goal.translation, up: goal.rotation.act([0, 1, 0]),
                                            scale: rig.pose.scale * rig.scaleMultiplier) ?? goal.translation
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            var scale: Float
            if dip {
                scale = p < 0.15
                    ? s0 * lerp(1, 0.9, Ease.inOutSine(p / 0.15))
                    : lerp(s0 * 0.9, s1, TimingCurve.standard(Ease.segment(p, 0.15, 1)))
            } else {
                scale = lerp(s0, s1, TimingCurve.standard(p))
            }
            if let column {
                scale = lerp(scale, s1, Ease.inOutSine(Ease.segment(e, column.dropStart - 0.1, column.dropStart)))
            }
            let turn = simd_quatf(angle: spin * 2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            actor.root.transform = Transform(scale: .init(repeating: max(scale, 1e-5)),
                                             rotation: simd_slerp(start.rotation, goal.rotation, e) * turn,
                                             translation: avoidVessels(position, scale: scale, slot: actor.slot, excluding: [rig]))
            if morphToBall, !morphDone {
                let w = Ease.inOutSine(Ease.segment(p, 0.04, 0.48))
                setMorphWeight(actor, w)
                if p >= 0.5 {
                    endMorph(actor)
                    morphDone = true
                }
            }
            let targetSlot = (rig.scoops.firstIndex { $0 === actor } ?? 0) + 1
            if !reslotDone, actor.slot != targetSlot, actor.morpher == nil, p >= 0.5 {
                reslotDone = true
                reslot(actor, to: targetSlot)
            }
            // The final stretch comes straight down the slot's axis; the squash rides on the same progress.
            if squish > 0, p >= 0.72, actor.slot == targetSlot, morphDone || !morphToBall {
                if !squishing {
                    squishing = true
                    if actor.morpher != nil { endMorph(actor) }
                    beginMorph(actor, to: finalPoseName(rig.vessel, key: liveKey(actor, on: rig)))
                }
                setMorphWeight(actor, squish * Ease.inOutSine(Ease.segment(p, 0.72, 1)))
            }
        } completion: { [weak self] in
            guard let self else { return }
            if actor.morpher != nil, actor.morphTo == "ball" { endMorph(actor) }
            let targetSlot = (rig.scoops.firstIndex { $0 === actor } ?? 0) + 1
            if actor.slot != targetSlot { reslot(actor, to: targetSlot) }
            pressWhenClear(actor, onto: rig, squish: squishing ? squish : 0)
        }
    }

    /// Placements assume the scoops beneath have landed; if one is still in the air, wait just above the slot.
    private func pressWhenClear(_ actor: ScoopActor, onto rig: ItemRig, squish: Float) {
        let index = rig.scoops.firstIndex { $0 === actor } ?? 0
        guard rig.scoops.prefix(index).contains(where: { $0.state == .flying || $0.state == .leaving }) else {
            press(actor, onto: rig, squish: squish)
            return
        }
        actor.phase = "wait"
        actor.motion = animate(duration: 1.0 / 60, phase: .attachments) { [unowned self] _ in
            let goal = approachTransform(actor, on: rig, squish: squish)
            actor.root.transform = Transform(scale: goal.scale, rotation: goal.rotation, translation: goal.translation)
        } completion: { [weak self] in
            self?.pressWhenClear(actor, onto: rig, squish: squish)
        }
    }

    /// Settles along the slot's up axis while the ball morphs into the placed pose on the same curve, so
    /// shape and height arrive together. The morph is never behind `1 − h / contact`: that bound keeps every
    /// vertex on or above the straight line from "ball touching" to "placed", so nothing passes through the
    /// vessel or the scoops below. (With a shared curve it holds automatically; the `max` guards tuning.)
    /// Heights are measured from the scoop beneath while it is still settling (`stackLift`).
    /// `squish` is how far the scoop already morphed toward the placed pose on its way in.
    private func press(_ actor: ScoopActor, onto rig: ItemRig, duration: Double = Stage.pressDuration, squish: Float = 0) {
        let vessel = rig.vessel
        let key = liveKey(actor, on: rig)
        let pose = finalPoseName(vessel, key: key)
        let contact = liftHeight(vessel, key: key)
        var base: Float = 0
        if actor.morpher != nil, actor.morphTo == pose {
            base = actor.morphWeight
        } else {
            beginMorph(actor, to: pose)
        }
        let startHeight = contact * (1 - (base > 0 ? squish : 0)) + Self.approachClearance
        rig.body.addChild(actor.root)
        actor.mount = rig
        actor.placementKey = key
        actor.pressHeight = startHeight + stackLift(below: actor, on: rig)
        actor.root.transform = slotLocal(vessel, key: key, height: actor.pressHeight)
        actor.state = .pressing
        actor.phase = "press"
        actor.motion = animate(duration: duration, phase: .attachments) { [unowned self] p in
            let c = Self.pressCurve(p)
            let own = startHeight * (1 - c)
            let h = own + stackLift(below: actor, on: rig)
            actor.pressHeight = h
            actor.root.transform = slotLocal(vessel, key: key, height: h)
            setMorphWeight(actor, max(base + (1 - base) * c, Ease.clamp01(1 - own / contact)))
        } completion: { [weak self] in
            guard let self else { return }
            setMorphWeight(actor, 1)
            endMorph(actor)
            settle(actor, on: rig, key: key)
        }
    }

    /// Lands the pressed scoop, first riding the one beneath down if that one is still settling.
    private func settle(_ actor: ScoopActor, on rig: ItemRig, key: String) {
        let riding = stackLift(below: actor, on: rig)
        if riding > 1e-5 {
            actor.pressHeight = riding
            actor.root.transform = slotLocal(rig.vessel, key: key, height: riding)
            actor.motion = animate(duration: 1.0 / 60, phase: .attachments) { [unowned self] _ in
                actor.pressHeight = stackLift(below: actor, on: rig)
                actor.root.transform = slotLocal(rig.vessel, key: key, height: actor.pressHeight)
            } completion: { [weak self] in
                self?.settle(actor, on: rig, key: key)
            }
            return
        }
        actor.pressHeight = 0
        actor.root.transform = slotLocal(rig.vessel, key: key, height: 0)
        actor.state = .landed
        actor.phase = "landed"
        actor.motion = nil
        relayoutFirstScoop(on: rig, delay: 0)
        if actor.isArriving {
            actor.isArriving = false
            if heroes.values.contains(where: { $0 === rig }) { reframe(rig) }
        }
    }

    func returnToIcon(_ actor: ScoopActor, delay: Double = 0, sideways: Bool = false) {
        let flavor = actor.flavor
        actor.cancelMotions()
        setFlavorIconAppear(flavor, to: 0, duration: 0.2, curve: .swiftUIEaseIn)
        let fly = { [unowned self] in flyHome(actor, delay: delay, sideways: sideways) }
        if actor.mount != nil, actor.state != .flying {
            unpress(actor, then: fly)
        } else {
            fly()
        }
    }

    private func flyHome(_ actor: ScoopActor, delay: Double, sideways: Bool) {
        let flavor = actor.flavor
        let side: Float = Layout.flavorCardCenter(flavor).x < Layout.midX ? -1 : 1
        var path = FlightPath(points: [.zero, .one], startDirection: [0, 1, 0], endDirection: [0, -1, 0])
        var start = Transform()
        var toBall = false
        var ballDone = false
        var toIcon = false
        var reslotDone = false
        var outward: (flight: ColumnFlight, rig: ItemRig, body: simd_float4x4, local: SIMD3<Float>)?
        let duration = 0.78
        var leaving: ItemRig?
        actor.motion = animate(delay: delay, duration: duration, phase: .attachments, onStart: { [unowned self] in
            let fromRig = holder(of: actor) ?? actor.mount ?? heroes[selectedVessel]
            leaving = holder(of: actor)
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.rig = nil
            actor.state = .flying
            actor.phase = "home"
            start = actor.root.transform
            toBall = actor.staticPose != "ball" || actor.morpher != nil
            if toBall { beginMorph(actor, to: "ball") }
            let goal = flavorIconModelTransform(flavor).translation
            let p0 = start.translation
            // Not in or over a vessel (still on its way up from the card): straight back down.
            path = FlightPath(points: [p0, goal], startDirection: goal - p0, endDirection: [0, -1, -0.1])
            if let rig = fromRig, rig.root.parent != nil {
                outward = columnExit(from: p0, slot: actor.slot, rig: rig, to: goal, side: side, sideways: sideways)
            }
        }) { [unowned self] p in
            let goal = flavorIconModelTransform(flavor)
            path.points[path.points.count - 1] = goal.translation
            let e = TimingCurve.flight(p)
            var position = path.position(e)
            if let exit = outward {
                let body = exit.rig.root.parent != nil ? exit.rig.body.transformMatrix(relativeTo: nil) : exit.body
                let pa = body * SIMD4<Float>(exit.local, 1)
                let up = simd_normalize(SIMD3(body.columns.1.x, body.columns.1.y, body.columns.1.z))
                let scale = simd_length(SIMD3(body.columns.0.x, body.columns.0.y, body.columns.0.z))
                position = exit.flight.position(1 - e, from: goal.translation, approach: SIMD3(pa.x, pa.y, pa.z), up: up, scale: scale)
            }
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            let turn = simd_quatf(angle: -2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            let scale = lerp(s0, s1, TimingCurve.standard(p))
            actor.root.transform = Transform(scale: .init(repeating: scale),
                                             rotation: simd_slerp(start.rotation, goal.rotation, e) * turn,
                                             translation: avoidVessels(position, scale: scale, slot: actor.slot,
                                                                       excluding: leaving.map { [$0] } ?? []))
            if toBall, !ballDone {
                setMorphWeight(actor, Ease.inOutSine(Ease.segment(p, 0, 0.14)))
                if p >= 0.15 {
                    endMorph(actor)
                    ballDone = true
                }
            }
            if !reslotDone, actor.slot != 1, actor.morpher == nil, p >= 0.16 {
                reslotDone = true
                reslot(actor, to: 1)
            }
            if p >= 0.55 {
                if !toIcon {
                    toIcon = true
                    beginMorph(actor, to: "icon")
                }
                if toIcon { setMorphWeight(actor, Ease.inOutSine(Ease.segment(p, 0.55, 0.95))) }
            }
        } completion: { [weak self] in
            guard let self else { return }
            flavorIcons[flavor]?.appearTween?.cancel()
            flavorIcons[flavor]?.appearTween = nil
            flavorIcons[flavor]?.appear = 1
            updateIcons()
            discard(actor)
        }
    }

    /// The way out for a scoop inside a vessel's opening below its rim: straight up the axis, over the rim, then down
    /// beside the vessel to `goal`. Nil when the scoop is already clear of the rim.
    private func columnExit(from p0: SIMD3<Float>, slot: Int, rig: ItemRig, to goal: SIMD3<Float>, side cardSide: Float,
                            sideways: Bool) -> (flight: ColumnFlight, rig: ItemRig, body: simd_float4x4, local: SIMD3<Float>)? {
        guard let assets else { return nil }
        let body = rig.body.transformMatrix(relativeTo: nil)
        let l = simd_inverse(body) * SIMD4<Float>(p0, 1)
        let local = SIMD3(l.x, l.y, l.z)
        let offset = simd_length(SIMD2(local.x, local.z))
        let ball = assets.scoopSet(slot).poseBounds("ball")
        let height = max(assets.vesselTop(rig.vessel) + Self.rimMargin + 0.002 - (local.y + min(ball.min.y, 0)), Self.minimumCrossing)
        guard offset < assets.vesselHalfWidth(rig.vessel), local.y > 0 else { return nil }
        let scale = simd_length(SIMD3(body.columns.0.x, body.columns.0.y, body.columns.0.z))
        let up = simd_normalize(SIMD3(body.columns.1.x, body.columns.1.y, body.columns.1.z))
        let radius = max(-ball.min.x, ball.max.x, -ball.min.z, ball.max.z)
        let beside = assets.vesselHalfWidth(rig.vessel) + radius + offset + 0.003
        let top = p0 + up * height * scale
        let lead = aroundLead(from: goal, approach: p0, top: top, scale: scale, beside: beside, preferredSide: cardSide)
        let hump = sideways ? min(Self.humpHeight(height), 0.003) : Self.humpHeight(height)
        let flight = ColumnFlight(lead: lead, from: goal,
                                  approach: p0, up: up, scale: scale, height: height, hump: hump, endSpeed: 0)
        return (flight, rig, body, local)
    }

    /// Whether a scoop with others stacked on it can't get out of its vessel: rising clear of the rim would take it
    /// into the scoop above, even once that one has lifted off to make room.
    private func exitBlocked(_ actor: ScoopActor, under upper: ScoopActor, on rig: ItemRig) -> Bool {
        guard let assets, actor.mount === rig, actor.state != .flying else { return false }
        let clear = rimClearHeight(rig.vessel, key: actor.placementKey)
        guard clear > max(actor.pressHeight, liftHeight(rig.vessel, key: actor.placementKey)) else { return false }
        guard upper.mount === rig, upper.state != .flying else { return true }
        let removedTop = assets.placements.placement(rig.vessel, key: actor.placementKey).translation.y + clear + ballHeight(slot: actor.slot)
        let upperBase = assets.placements.placement(rig.vessel, key: upper.placementKey).translation.y
            + liftHeight(rig.vessel, key: upper.placementKey) + Self.restackHover
        return upperBase < removedTop
    }

    /// Takes a scoop that can't leave its vessel out of the scene where it sits; shrinking toward a point inside the
    /// opening keeps every part of it inside the vessel.
    private func shrinkAway(_ actor: ScoopActor) {
        actor.cancelMotions()
        actor.state = .leaving
        actor.phase = "shrink"
        let from = actor.root.transform
        let bounds = assets?.scoopSet(actor.slot).poseBounds(actor.staticPose)
        let center = bounds.map { ($0.min + $0.max) / 2 } ?? .zero
        actor.motion = animate(duration: 0.3, phase: .attachments) { p in
            let k = max(1 - TimingCurve.swiftUIEaseIn(p), 1e-4)
            actor.root.transform = Transform(scale: from.scale * k, rotation: from.rotation,
                                             translation: from.translation + from.rotation.act(center * (1 - k)))
        } completion: { [weak self] in
            self?.discard(actor)
        }
    }

    /// A lone cup scoop sits in its own `solo` placement; it moves to slot 1's when a second scoop joins and back
    /// when it's alone again. The placement key only changes once the move has finished.
    func relayoutFirstScoop(on rig: ItemRig, delay: Double) {
        guard rig.vessel == .cup, let first = rig.scoops.first else { return }
        let wanted = placementKey(index: 0, count: rig.scoops.count, vessel: .cup)
        guard wanted != first.placementKey || first.relayout != nil else { return }
        first.relayout?.cancel()
        first.relayout = nil
        var from = Transform()
        var key = wanted
        var active = false
        first.relayout = animate(delay: delay, duration: 0.32, phase: .attachments, onStart: { [unowned self] in
            key = placementKey(index: 0, count: rig.scoops.count, vessel: .cup)
            guard rig.scoops.first === first, first.isLanded, first.slot == 1, first.mount === rig, first.motion == nil else { return }
            active = true
            first.phase = "relayout"
            from = first.root.transform
            beginMorph(first, to: finalPoseName(.cup, key: key))
        }) { [unowned self] p in
            guard active else { return }
            let e = Ease.inOutCubic(p)
            let to = slotLocal(.cup, key: key, height: 0)
            first.root.transform = Transform(scale: .one, rotation: simd_slerp(from.rotation, to.rotation, e),
                                             translation: simd_mix(from.translation, to.translation, .init(repeating: e)))
            setMorphWeight(first, e)
        } completion: { [weak self] in
            first.relayout = nil
            guard let self, active else { return }
            first.phase = "landed"
            if first.morpher != nil { endMorph(first) }
            first.placementKey = key
            relayoutFirstScoop(on: rig, delay: 0)
        }
    }

    /// Swaps the scoop to another slot's mesh and textures. Done while it's a small ball in fast motion
    /// (the slots' ball poses differ only in surface lumps); a cross-dissolve would need partial opacity.
    func reslot(_ actor: ScoopActor, to slot: Int) {
        guard actor.slot != slot else { return }
        if actor.morpher != nil { endMorph(actor) }
        let outgoingSlot = actor.slot
        let outgoing = actor.model
        let incoming = makeScoopModel(slot: slot, flavor: actor.flavor, pose: actor.staticPose)
        incoming.transform = outgoing.transform
        actor.slot = slot
        actor.model = incoming
        actor.staticPose = assets!.scoopSet(slot).resolve(actor.staticPose)
        actor.root.addChild(incoming)
        recycleScoopModel(outgoing, slot: outgoingSlot, flavor: actor.flavor)
    }

    func discard(_ scoop: ScoopActor) {
        guard !scoop.isDiscarded else { return }
        scoop.isDiscarded = true
        clipCheck?.forget(scoop)
        liveScoops[ObjectIdentifier(scoop)] = nil
        scoop.cancelMotions()
        if let morpher = scoop.morpher {
            assets?.scoopSet(scoop.slot).release(morpher)
            scoop.morpher = nil
        }
        morphing.removeAll { $0 === scoop }
        recycleScoopModel(scoop.model, slot: scoop.slot, flavor: scoop.flavor)
        scoop.root.removeFromParent()
        scoop.rig?.scoops.removeAll { $0 === scoop }
        scoop.rig = nil
        scoop.mount = nil
    }

    func beginMorph(_ scoop: ScoopActor, to pose: String) {
        guard let assets else { return }
        clipCheck?.willBeginMorph(scoop)
        let set = assets.scoopSet(scoop.slot)
        if let morpher = scoop.morpher, let from = scoop.morphFrom {
            assets.engine.blendPoses(into: morpher.scratch, from: from, to: set.pose(scoop.morphTo),
                                     weight: scoop.morphWeight, vertexCount: set.vertexCount)
            scoop.morphFrom = PoseRef(buffer: morpher.scratch, offset: 0)
        } else {
            let morpher = set.acquireMorpher()
            scoop.morpher = morpher
            scoop.morphFrom = set.pose(scoop.staticPose)
            scoop.model.model?.mesh = morpher.resource
            morphing.append(scoop)
        }
        scoop.morphTo = pose
        scoop.morphWeight = 0
        scoop.morphDirty = true
    }

    func setMorphWeight(_ scoop: ScoopActor, _ weight: Float) {
        guard scoop.morpher != nil, abs(scoop.morphWeight - weight) > 1e-5 else { return }
        scoop.morphWeight = weight
        scoop.morphDirty = true
    }

    func endMorph(_ scoop: ScoopActor) {
        guard let assets, let morpher = scoop.morpher else { return }
        let set = assets.scoopSet(scoop.slot)
        scoop.staticPose = set.resolve(scoop.morphTo)
        scoop.model.model?.mesh = set.staticMesh(scoop.staticPose)
        set.release(morpher)
        scoop.morpher = nil
        scoop.morphFrom = nil
        scoop.morphDirty = false
        morphing.removeAll { $0 === scoop }
    }

    func flushMorphs() {
        guard let assets, !morphing.isEmpty else { return }
        for scoop in morphing where scoop.morphDirty {
            guard let morpher = scoop.morpher, let from = scoop.morphFrom else { continue }
            let set = assets.scoopSet(scoop.slot)
            assets.engine.writeMesh(morpher.mesh, from: from, to: set.pose(scoop.morphTo),
                                    weight: scoop.morphWeight, vertexCount: set.vertexCount)
            scoop.morphDirty = false
        }
        assets.engine.flush()
    }
}
