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

    static let approachClearance: Float = 0.008
    static let minimumLift: Float = 0.004
    static let pressDuration: Double = 0.4
    /// Settling curve for the press; starts at 1.2× linear speed so the flight can hand over without a kink.
    static let pressCurve = TimingCurve(0.3, 0.36, 0.42, 1)
    static let pressStartSlope: Float = 1.2
    static let maxArrivalSlope: Float = 2.2
    /// Screen y (points) below the builder header; a flying scoop's top must stay under it.
    static let flightCeilingY: CGFloat = 288

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

    func approachTransform(_ actor: ScoopActor, on rig: ItemRig) -> Transform {
        let key = liveKey(actor, on: rig)
        return slotWorld(rig, key: key, height: liftHeight(rig.vessel, key: key) + Self.approachClearance)
    }

    func detachToWorld(_ actor: ScoopActor) {
        let matrix = actor.root.transformMatrix(relativeTo: nil)
        root.addChild(actor.root)
        actor.root.transform = Transform(matrix: matrix)
    }

    func after(_ delay: Double, _ action: @escaping () -> Void) -> Tween {
        animate(delay: delay, duration: 0.0001, phase: .attachments, onStart: action) { _ in }
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
        for scoop in rig.scoops where scoop !== actor && scoop.root.parent === rig.body {
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
        let start = flavorIconModelTransform(flavor, slot: slot)
        let appear = flavorIcons[flavor]?.appear ?? 1
        actor.root.transform = Transform(scale: start.scale * appear, rotation: start.rotation, translation: start.translation)
        root.addChild(actor.root)
        scoops.append(actor)
        hero.scoops.append(actor)
        actor.rig = hero

        setFlavorIconAppear(flavor, to: 0, duration: 0, shadowDuration: 0.12)
        setFlavorIconAppear(flavor, to: 1, duration: 0.34, delay: 0.5)
        relayoutFirstScoop(on: hero, delay: 0)

        let side: Float = Layout.flavorCardCenter(flavor).x < Layout.midX ? -1 : 1
        flyToSlot(actor, rig: hero, route: .fromIcon(side: side))
    }

    func removeScoop(at index: Int) {
        guard index < scoops.count, let hero = heroes[selectedVessel] else { return }
        let actor = scoops.remove(at: index)
        hero.scoops.removeAll { $0 === actor }
        let above = Array(scoops[index...])
        returnToIcon(actor, delay: above.isEmpty ? 0 : 0.06, sideways: !above.isEmpty)
        for (offset, upper) in above.enumerated() {
            restack(upper, on: hero, delay: Double(offset) * 0.05)
        }
        relayoutFirstScoop(on: hero, delay: 0.42)
    }

    /// Lifts the scoops off as balls into a row above the center, holds them there while the new vessel
    /// flies in beneath, then drops them onto it bottom-up.
    func transferScoops(to rig: ItemRig, landingIn delay: Double) {
        for actor in scoops {
            actor.rig?.scoops.removeAll { $0 === actor }
        }
        rig.scoops = scoops
        guard let assets, !scoops.isEmpty else { return }
        let center = centerPose(rig.vessel, yaw: 0)
        let scale = Self.mainScale(rig.vessel)
        let top = center.position.y + (assets.vesselTop(rig.vessel) - rig.pivot.y) * scale
        let width: Float = 0.048 * scale
        let descentStart = now + delay - 0.05
        let count = Float(scoops.count)
        for (index, actor) in scoops.enumerated() {
            actor.cancelMotions()
            let hoverPoint = SIMD3<Float>(center.position.x + (Float(index) - (count - 1) / 2) * width, top + 0.06, 0.06)
            let land = { [unowned self] in
                actor.motion = after(max(0, descentStart + Double(index) * 0.3 - now)) { [unowned self] in
                    flyToSlot(actor, rig: rig, route: .restack)
                }
            }
            let rise = { [unowned self] in hover(actor, to: hoverPoint, scale: scale, duration: 0.42, then: land) }
            if actor.root.parent !== root, actor.state != .flying {
                unpress(actor, then: rise)
            } else {
                rise()
            }
        }
    }

    private func hover(_ actor: ScoopActor, to point: SIMD3<Float>, scale: Float, duration: Double, then next: @escaping () -> Void) {
        var start = Transform()
        var toBall = false
        actor.motion = animate(duration: duration, phase: .attachments, onStart: { [unowned self] in
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.state = .flying
            start = actor.root.transform
            toBall = actor.staticPose != "ball" || actor.morpher != nil
            if toBall { beginMorph(actor, to: "ball") }
        }) { [unowned self] p in
            let e = TimingCurve.standard(p)
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            actor.root.transform = Transform(scale: .init(repeating: lerp(s0, scale, e)), rotation: start.rotation,
                                             translation: simd_mix(start.translation, point, .init(repeating: e)))
            if toBall { setMorphWeight(actor, e) }
        } completion: { [weak self] in
            if toBall { self?.endMorph(actor) }
            actor.motion = nil
            next()
        }
    }

    private func restack(_ actor: ScoopActor, on rig: ItemRig, delay: Double) {
        actor.cancelMotions()
        if actor.root.parent !== root, actor.state != .flying {
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
        guard let rig = actor.rig, actor.root.parent === rig.body else {
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
        guard let rig = actor.rig, actor.root.parent === rig.body else {
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
        let dip: Bool
        let spin: Float
        let duration: Double
        switch route {
        case .fromIcon:
            dip = true; spin = 1; duration = 0.62
        case .restack:
            dip = false; spin = 0; duration = 0.42
        }

        actor.motion = animate(delay: delay, duration: duration, phase: .attachments, onStart: { [unowned self] in
            if actor.root.parent !== root { detachToWorld(actor) }
            actor.rig = rig
            actor.state = .flying
            start = actor.root.transform
            morphToBall = actor.staticPose != "ball" || actor.morpher != nil
            if morphToBall { beginMorph(actor, to: "ball") }

            let goal = approachTransform(actor, on: rig)
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
            let goal = approachTransform(actor, on: rig)
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
                reslot(actor, to: targetSlot, duration: duration * 0.22)
            }
        } completion: { [weak self] in
            guard let self else { return }
            if actor.morpher != nil, actor.morphTo == "ball" { endMorph(actor) }
            let targetSlot = (rig.scoops.firstIndex { $0 === actor } ?? 0) + 1
            if actor.slot != targetSlot { reslot(actor, to: targetSlot, duration: 0) }
            press(actor, onto: rig)
        }
    }

    /// Settles along the slot's up axis while the ball morphs into the placed pose on the same curve, so
    /// shape and height arrive together. The morph is never behind `1 − h / contact`: that bound keeps every
    /// vertex on or above the straight line from "ball touching" to "placed", so nothing passes through the
    /// vessel or the scoops below. (With a shared curve it holds automatically; the `max` guards tuning.)
    private func press(_ actor: ScoopActor, onto rig: ItemRig) {
        let vessel = rig.vessel
        let key = liveKey(actor, on: rig)
        let pose = finalPoseName(vessel, key: key)
        let contact = liftHeight(vessel, key: key)
        let startHeight = contact + Self.approachClearance
        rig.body.addChild(actor.root)
        actor.root.transform = slotLocal(vessel, key: key, height: startHeight)
        actor.placementKey = key
        actor.pressHeight = startHeight
        actor.state = .pressing
        beginMorph(actor, to: pose)
        actor.motion = animate(duration: Self.pressDuration, phase: .attachments) { [unowned self] p in
            let c = Self.pressCurve(p)
            let h = startHeight * (1 - c)
            actor.pressHeight = h
            actor.root.transform = slotLocal(vessel, key: key, height: h)
            setMorphWeight(actor, max(c, Ease.clamp01(1 - h / contact)))
        } completion: { [weak self] in
            guard let self else { return }
            setMorphWeight(actor, 1)
            endMorph(actor)
            actor.pressHeight = 0
            actor.root.transform = slotLocal(vessel, key: key, height: 0)
            actor.state = .landed
            actor.motion = nil
        }
    }

    func returnToIcon(_ actor: ScoopActor, delay: Double = 0, sideways: Bool = false) {
        let flavor = actor.flavor
        actor.cancelMotions()
        setFlavorIconAppear(flavor, to: 0, duration: 0.2, curve: .swiftUIEaseIn)
        let fly = { [unowned self] in flyHome(actor, delay: delay, sideways: sideways) }
        if actor.root.parent !== root, actor.state != .flying {
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
        let fromRig = actor.rig
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
                reslot(actor, to: 1, duration: duration * 0.25)
            }
            if p >= 0.55 {
                if !toIcon, actor.ghost == nil {
                    toIcon = true
                    beginMorph(actor, to: "icon")
                }
                if toIcon { setMorphWeight(actor, Ease.inOutSine(Ease.segment(p, 0.55, 0.95))) }
            }
        } completion: { [weak self] in
            guard let self else { return }
            flavorIcons[flavor]?.appearTween?.cancel()
            flavorIcons[flavor]?.appear = 1
            flavorIcons[flavor]?.shadowAmount = 1
            updateIcons()
            discard(actor)
        }
    }

    func relayoutFirstScoop(on rig: ItemRig, delay: Double) {
        guard rig.vessel == .cup, let first = rig.scoops.first, first.isLanded, first.slot == 1 else { return }
        let key = placementKey(index: 0, count: rig.scoops.count, vessel: .cup)
        guard key != first.placementKey else { return }
        first.relayout?.cancel()
        let fromKey = first.placementKey
        first.placementKey = key
        var from = Transform()
        first.relayout = animate(delay: delay, duration: 0.32, phase: .attachments, onStart: { [unowned self] in
            guard first.isLanded, first.root.parent === rig.body else { return }
            from = first.root.transform
            if from.translation == .zero { from = slotLocal(.cup, key: fromKey, height: 0) }
            beginMorph(first, to: finalPoseName(.cup, key: key))
        }) { [unowned self] p in
            guard first.isLanded, first.morpher != nil else { return }
            let e = Ease.inOutCubic(p)
            let to = slotLocal(.cup, key: key, height: 0)
            first.root.transform = Transform(scale: .one, rotation: simd_slerp(from.rotation, to.rotation, e),
                                             translation: simd_mix(from.translation, to.translation, .init(repeating: e)))
            setMorphWeight(first, e)
        } completion: { [weak self] in
            if first.morpher != nil { self?.endMorph(first) }
            first.relayout = nil
        }
    }

    /// Swaps the scoop to another slot's mesh and textures by dissolving a copy in over it.
    func reslot(_ actor: ScoopActor, to slot: Int, duration: Double) {
        guard actor.slot != slot else { return }
        if actor.morpher != nil { endMorph(actor) }
        finishCrossfade(actor)
        let incoming = makeScoopModel(slot: slot, flavor: actor.flavor, pose: actor.staticPose)
        let outgoingSlot = actor.slot
        actor.slot = slot
        let outgoing = actor.model
        actor.model = incoming
        actor.staticPose = assets!.scoopSet(slot).resolve(actor.staticPose)
        actor.root.addChild(incoming)
        guard duration > 0 else {
            recycleScoopModel(outgoing, slot: outgoingSlot, flavor: actor.flavor)
            return
        }
        // Plain blending on purpose: the opaque incoming copy underneath already hides the outgoing
        // copy's back faces, and a depth pre-pass here would hide the incoming copy instead.
        actor.ghost = outgoing
        actor.ghostSlot = outgoingSlot
        incoming.scale = .init(repeating: 0.996)
        actor.crossfade = animate(duration: duration, phase: .late) { p in
            outgoing.components.set(OpacityComponent(opacity: max(0.001, 1 - Ease.inOutSine(p))))
        } completion: { [weak self] in
            self?.finishCrossfade(actor)
        }
    }

    private func finishCrossfade(_ actor: ScoopActor) {
        actor.crossfade?.cancel()
        actor.crossfade = nil
        if let ghost = actor.ghost {
            recycleScoopModel(ghost, slot: actor.ghostSlot, flavor: actor.flavor)
            actor.ghost = nil
        }
        actor.model.scale = .one
    }

    func discard(_ scoop: ScoopActor) {
        scoop.cancelMotions()
        finishCrossfade(scoop)
        if let morpher = scoop.morpher {
            assets?.scoopSet(scoop.slot).release(morpher)
            scoop.morpher = nil
        }
        morphing.removeAll { $0 === scoop }
        recycleScoopModel(scoop.model, slot: scoop.slot, flavor: scoop.flavor)
        scoop.root.removeFromParent()
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
