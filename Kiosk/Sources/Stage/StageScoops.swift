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
    static let maxArrivalSlope: Float = 2.2
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

    /// Half-width of the vessel and its scoops on screen plus a ball's radius, so paths can go around it.
    private func clearanceHalfWidth(_ rig: ItemRig) -> Float {
        let scale = rig.pose.scale * rig.scaleMultiplier
        let vesselRadius: Float = rig.vessel == .cup ? 0.0438 : 0.035
        return (vesselRadius + 0.022) * scale + 0.015
    }

    /// World height a ball's base must stay above to clear the vessel's rim and the scoops already placed.
    private func clearTop(_ rig: ItemRig, excluding actor: ScoopActor) -> Float {
        guard let assets else { return 0 }
        var top = assets.vesselTop(rig.vessel)
        for scoop in rig.scoops where scoop !== actor && scoop.mount === rig {
            let bounds = assets.scoopSet(scoop.slot).poseBounds(scoop.staticPose)
            top = max(top, scoop.root.transform.translation.y + bounds.max.y)
        }
        let point = rig.body.transformMatrix(relativeTo: nil) * SIMD4<Float>(0, top, 0, 1)
        return point.y + 0.006 * rig.pose.scale
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
        returnToIcon(actor, delay: above.isEmpty ? 0 : 0.06, sideways: !above.isEmpty)
        for (offset, upper) in above.enumerated() {
            restack(upper, on: hero, delay: Double(offset) * 0.05)
        }
        reframe(hero)
        relayoutFirstScoop(on: hero, delay: 0.42)
    }

    /// Hands the scoops to the incoming vessel as one stack: it lifts a little while the old vessel drops
    /// away beneath it, reshapes for the new vessel in the air, and settles onto it as it rises into place.
    func transferScoops(to rig: ItemRig, arrival: Double) {
        setOwner(scoops, rig)
        for actor in scoops {
            actor.isArriving = false
            transfer(actor, to: rig, duration: arrival)
        }
    }

    private func transfer(_ actor: ScoopActor, to rig: ItemRig, duration: Double) {
        actor.cancelMotions()
        var start = Transform()
        var rise = SIMD3<Float>.zero
        var origin: (rig: ItemRig, slot: Transform)?
        var pose = ""
        var reslotDone = false
        let gap: Float = 0.004
        let landing: Float = 0.012
        actor.motion = animate(duration: duration, phase: .attachments, onStart: { [unowned self] in
            var up: SIMD3<Float> = [0, 1, 0]
            if let mount = actor.mount, actor.root.parent === mount.body {
                origin = (mount, slotLocal(mount.vessel, key: actor.placementKey, height: 0))
                let column = actor.root.transformMatrix(relativeTo: nil).columns.1
                up = simd_normalize(SIMD3(column.x, column.y, column.z))
            }
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.state = .flying
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
            let position = cubicBezier(start.translation, start.translation + rise,
                                       goal.translation + up * landing * goal.scale.x, goal.translation, e)
            let scale = lerp(start.scale.x, goal.scale.x, TimingCurve.standard(p))
            actor.root.transform = Transform(scale: .init(repeating: max(scale, 1e-5)),
                                             rotation: simd_slerp(start.rotation, goal.rotation, e), translation: position)
            if !reslotDone, actor.slot != index + 1, p >= 0.15 {
                reslotDone = true
                reslot(actor, to: index + 1)
                beginMorph(actor, to: pose)
            }
            // Reshapes only while clear of both vessels: no rounder than its height above the old slot allows, and
            // fully in the new shape before it gets within `landing` of the new slot.
            var w = Ease.inOutSine(Ease.segment(p, 0.15, 0.7))
            if let origin, p < 0.5 {
                w = min(w, Ease.clamp01(height(position, above: origin.slot, on: origin.rig) / landing))
            }
            if p > 0.5 {
                w = max(w, 1 - Ease.clamp01(height(position, above: slotLocal(rig.vessel, key: key, height: 0), on: rig) / landing))
            }
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

    private func height(_ position: SIMD3<Float>, above slot: Transform, on rig: ItemRig) -> Float {
        let local = simd_inverse(rig.body.transformMatrix(relativeTo: nil)) * SIMD4<Float>(position, 1)
        return simd_dot(SIMD3(local.x, local.y, local.z) - slot.translation, slot.rotation.act([0, 1, 0]))
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
                hover(actor, rise: 0.03, duration: 0.22) { [unowned self] in
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
        actor.motion = animate(duration: duration, phase: .attachments) { [unowned self] p in
            let h = from + rise * Ease.outCubic(p)
            actor.pressHeight = h
            actor.root.transform = slotLocal(vessel, key: key, height: h)
        } completion: {
            actor.motion = nil
            next()
        }
    }

    /// World-space flight to the point just above the slot, then the press. The path's last waypoint
    /// tracks the (spinning, possibly flying) rig every frame.
    func flyToSlot(_ actor: ScoopActor, rig: ItemRig, route: ScoopRoute, delay: Double = 0) {
        var path = FlightPath(points: [.zero, .one], startDirection: [0, 1, 0], endDirection: [0, -1, 0])
        var arc: (c1: SIMD3<Float>, lift: Float, up: SIMD3<Float>)?
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
            switch route {
            case .fromIcon(let side):
                // One cubic arc. Every control point stays under the header ceiling, so the whole curve does
                // (convex hull). The last control point sits on the slot's up axis, so the scoop arrives along
                // the settle direction at the speed the press starts with.
                let ceiling = world(CGPoint(x: 0, y: Self.flightCeilingY)).y - 0.0438 * rigScale
                let room = max(0, (ceiling - pa.y) / max(up.y, 0.3))
                let lift = min(max(pressSpeed * Float(duration) / (3 * Self.maxArrivalSlope), 0.012), room)
                let endSlope = lift > 1e-4 ? min(pressSpeed * Float(duration) / (3 * lift), Self.maxArrivalSlope) : 0
                let centerCard = abs(p0.x - pa.x) < clearanceHalfWidth(rig)
                let c1x = centerCard ? pa.x + side * 0.24 : p0.x
                let c1y = min(lerp(p0.y, pa.y + up.y * lift, 0.95), ceiling)
                arc = (SIMD3<Float>(c1x, c1y, centerCard ? 0.1 : 0.04), lift, up)
                timing = TimingCurve(0.42, 0, 0.6, 1 - 0.4 * endSlope)
            case .restack:
                let clear = clearTop(rig, excluding: actor)
                let above = pa + up * max(0, (clear - pa.y) / max(up.y, 0.3))
                var points = [p0]
                if simd_length(above - pa) > 0.005 { points.append(above) }
                points.append(pa)
                path = FlightPath(points: points, startDirection: [0, 1, 0.1], endDirection: -up)
                let endSlope = min(pressSpeed * Float(duration) / max(path.length, 0.01), 2)
                timing = TimingCurve(0.42, 0, 0.6, 1 - 0.4 * endSlope)
            }
        }) { [unowned self] p in
            let goal = approachTransform(actor, on: rig, squish: squish)
            let e = timing(p)
            let position: SIMD3<Float>
            if let arc {
                position = cubicBezier(start.translation, arc.c1, goal.translation + arc.up * arc.lift, goal.translation, e)
            } else {
                path.points[path.points.count - 1] = goal.translation
                position = path.position(e)
            }
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            let scale: Float
            if dip {
                scale = p < 0.15
                    ? s0 * lerp(1, 0.9, Ease.inOutSine(p / 0.15))
                    : lerp(s0 * 0.9, s1, TimingCurve.standard(Ease.segment(p, 0.15, 1)))
            } else {
                scale = lerp(s0, s1, TimingCurve.standard(p))
            }
            let turn = simd_quatf(angle: spin * 2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            actor.root.transform = Transform(scale: .init(repeating: max(scale, 1e-5)),
                                             rotation: simd_slerp(start.rotation, goal.rotation, e) * turn,
                                             translation: position)
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
        let duration = 0.78
        let fromRig = actor.mount ?? heroes[selectedVessel]
        actor.motion = animate(delay: delay, duration: duration, phase: .attachments, onStart: { [unowned self] in
            let up = actor.root.transformMatrix(relativeTo: nil).columns.1
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.rig = nil
            actor.state = .flying
            start = actor.root.transform
            toBall = actor.staticPose != "ball" || actor.morpher != nil
            if toBall { beginMorph(actor, to: "ball") }
            let goal = flavorIconModelTransform(flavor).translation
            let p0 = start.translation
            let halfWidth = fromRig.map { clearanceHalfWidth($0) } ?? 0.1
            let sx = p0.x + side * max(halfWidth, abs(goal.x - p0.x))
            let lift = simd_normalize(SIMD3<Float>(up.x, up.y, up.z))
            let exit: SIMD3<Float> = sideways
                ? [p0.x + side * halfWidth * 0.9, p0.y + 0.005, 0.08]
                : [lerp(p0.x, sx, 0.5), p0.y + 0.06, 0.05]
            path = FlightPath(points: [p0, exit, [sx, lerp(p0.y, goal.y, 0.5), 0.05], goal],
                              startDirection: sideways ? SIMD3<Float>(side, 0.1, 0.3) : lift + SIMD3<Float>(side * 0.3, 0, 0),
                              endDirection: [0, -1, -0.1])
        }) { [unowned self] p in
            let goal = flavorIconModelTransform(flavor)
            path.points[path.points.count - 1] = goal.translation
            let e = TimingCurve.flight(p)
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            let turn = simd_quatf(angle: -2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            actor.root.transform = Transform(scale: .init(repeating: lerp(s0, s1, TimingCurve.standard(p))),
                                             rotation: simd_slerp(start.rotation, goal.rotation, e) * turn,
                                             translation: path.position(e))
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
