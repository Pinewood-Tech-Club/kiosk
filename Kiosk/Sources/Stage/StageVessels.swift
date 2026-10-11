import QuartzCore
import RealityKit
import SwiftUI

extension Stage {
    func updateHeroSpin(_ dt: Float) {
        guard let hero = heroes[selectedVessel], hero.motion == nil else { return }
        if let framing = hero.framing {
            hero.pose.position = framing.position
            hero.pose.scale = framing.scale
        }
        if isDragging {
            hero.apply()
            return
        }
        let idle = now - releaseTime
        if idle < 0.9 {
            yawVelocity *= exp(-dt / 0.35)
        } else {
            yawVelocity += (Self.baseSpin - yawVelocity) * (1 - exp(-dt / 0.7))
        }
        hero.pose.yaw += yawVelocity * dt
        if hero.pose.yaw > 200 { hero.pose.yaw -= 2 * .pi * 30 }
        if hero.pose.yaw < -200 { hero.pose.yaw += 2 * .pi * 30 }
        if pitchReturnDuration > 0 {
            let t = Float((idle - 0.6) / pitchReturnDuration)
            hero.pose.pitch = lerp(pitchReturnFrom, Self.preferredPitch, Ease.inOutSine(Ease.clamp01(t)))
            if t >= 1 { pitchReturnDuration = 0 }
        }
        hero.apply()
    }

    func dragChanged(translation: CGSize) {
        guard let hero = heroes[selectedVessel], hero.motion == nil else { return }
        let time = CACurrentMediaTime()
        if !isDragging {
            isDragging = true
            dragStartYaw = hero.pose.yaw - Float(translation.width) * 0.0085
            dragStartPitch = hero.pose.pitch - Float(translation.height) * 0.005
            lastDragSample = (time, hero.pose.yaw)
            pitchReturnDuration = 0
            yawVelocity = 0
        }
        hero.pose.yaw = dragStartYaw + Float(translation.width) * 0.0085
        hero.pose.pitch = min(max(dragStartPitch + Float(translation.height) * 0.005, -0.35), 1.15)
        let elapsed = time - lastDragSample.time
        if elapsed > 0.004 {
            let instantaneous = (hero.pose.yaw - lastDragSample.yaw) / Float(elapsed)
            yawVelocity = lerp(yawVelocity, instantaneous, 0.55)
            lastDragSample = (time, hero.pose.yaw)
        }
    }

    func dragEnded() {
        guard isDragging else { return }
        isDragging = false
        releaseTime = now
        if CACurrentMediaTime() - lastDragSample.time > 0.08 { yawVelocity = 0 }
        yawVelocity = min(max(yawVelocity, -9), 9)
        guard let hero = heroes[selectedVessel] else { return }
        pitchReturnFrom = hero.pose.pitch
        let delta = abs(hero.pose.pitch - Self.preferredPitch)
        pitchReturnDuration = delta < 0.001 ? 0 : Double(0.35 + 3.2 * min(1, delta / 0.8))
    }

    func resumeSpin() {
        yawVelocity = 0
        releaseTime = now - 0.75
        pitchReturnDuration = 0
    }

    /// Interpolates every pose component from the rig's current pose to a live target, so the final
    /// frame equals the target exactly. `liveControl` re-aims the curve at the target every frame, for targets
    /// that travel far during the flight (a row on the rising order sheet).
    /// `axisOut` / `axisIn` make the flight leave or arrive along the vessel's own axis for that distance (world
    /// units), with its pose (pitch, roll, scale) only changing over `attitude`'s part of the flight, so a vessel can
    /// drop out from under, or rise up into, scoops that sit inside its rim.
    func flyRig(_ rig: ItemRig, duration: Double, delay: Double = 0, minSpin: Float, dip: Bool, timing: TimingCurve,
                liveControl: Bool = false, axisOut: Float = 0, axisIn: Float = 0, attitude: ClosedRange<Float> = 0...1,
                control: @escaping (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>,
                target: @escaping () -> RigPose, completion: @escaping () -> Void) {
        rig.motion?.cancel()
        rig.flightGoal = nil
        var start = rig.pose
        var yawDelta: Float = 0
        var controlPoint = SIMD3<Float>.zero
        rig.motion = animate(delay: delay, duration: duration, onStart: {
            start = rig.pose
            let goal = target()
            yawDelta = forwardYawDelta(from: start.yaw, to: goal.yaw, minimum: minSpin)
            controlPoint = control(start.position, goal.position)
            let endYaw = start.yaw + yawDelta
            rig.flightGoal = {
                var pose = target()
                pose.yaw = endYaw
                return pose
            }
        }) { p in
            let goal = target()
            let e = timing(p)
            if liveControl { controlPoint = control(start.position, goal.position) }
            if axisOut > 0 || axisIn > 0 {
                var c1 = start.position + (controlPoint - start.position) * (2 / 3)
                var c2 = goal.position + (controlPoint - goal.position) * (2 / 3)
                if axisOut > 0 { c1 = start.position - Self.axis(of: start) * axisOut }
                if axisIn > 0 { c2 = goal.position - Self.axis(of: goal) * axisIn }
                rig.pose.position = cubicBezier(start.position, c1, c2, goal.position, e)
            } else {
                rig.pose.position = quadraticBezier(start.position, controlPoint, goal.position, e)
            }
            let a = Ease.segment(e, attitude.lowerBound, attitude.upperBound)
            if dip {
                let dipEnd: Float = 0.16
                rig.pose.scale = p < dipEnd
                    ? start.scale * lerp(1, 0.93, Ease.inOutSine(p / dipEnd))
                    : lerp(start.scale * 0.93, goal.scale, TimingCurve.standard(Ease.segment(p, dipEnd, 1)))
            } else if attitude != 0...1 {
                rig.pose.scale = lerp(start.scale, goal.scale, Ease.inOutSine(a))
            } else {
                rig.pose.scale = lerp(start.scale, goal.scale, TimingCurve.standard(p))
            }
            rig.pose.pitch = lerp(start.pitch, goal.pitch, attitude != 0...1 ? Ease.inOutSine(a) : e)
            rig.pose.roll = lerp(start.roll, goal.roll, attitude != 0...1 ? Ease.inOutSine(a) : e)
            rig.pose.yaw = start.yaw + yawDelta * Ease.inOutCubic(p)
            rig.apply()
        } completion: {
            rig.motion = nil
            rig.flightGoal = nil
            completion()
        }
    }

    /// The vessel's up axis in world space at `pose` (yaw doesn't change it).
    static func axis(of pose: RigPose) -> SIMD3<Float> {
        (simd_quatf(angle: pose.pitch, axis: [1, 0, 0]) * simd_quatf(angle: pose.roll, axis: [0, 0, 1])).act([0, 1, 0])
    }

    /// World distance a vessel has to travel along its axis before nothing it holds is below its rim.
    func axialClearance(_ vessel: Vessel, count: Int, scale: Float) -> Float {
        (0..<min(count, 3)).map { rimClearHeight(vessel, key: placementKey(index: $0, count: count, vessel: vessel)) }.max().map { $0 * scale } ?? 0
    }

    /// `underScoops` is the quicker flight used while scoops are handed over: it rises into place from below and
    /// in front, so the rim never sweeps sideways through the stack waiting above, and passes in front of the
    /// outgoing vessel, which drops away behind.
    /// `inFront` keeps the flight in the order sheet's item plane, so an item lifted out of a row stays in front
    /// of the sheet's occluder; the hero spin moves it back to its framing's depth on landing, which looks the same.
    func flyHeroToCenter(_ rig: ItemRig, duration: Double, delay: Double = 0, underScoops: Bool = false, inFront: Bool = false) {
        let vessel = rig.vessel
        let fromIcon = abs(rig.pose.roll - iconRestPose(vessel).roll) < 0.01
            && abs(rig.pose.scale - Self.iconScale(vessel)) < Self.iconScale(vessel) * 0.1
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        let axisIn = underScoops ? 1.6 * axialClearance(vessel, count: rig.scoops.count, scale: centerPose(rig, yaw: 0).scale) : 0
        flyRig(rig, duration: duration, delay: delay, minSpin: fromIcon && !underScoops ? 2 * .pi : .pi,
               dip: fromIcon && !underScoops, timing: .flight, axisIn: axisIn, attitude: underScoops ? 0...0.7 : 0...1,
               control: { p0, p1 in
                   underScoops
                       ? SIMD3<Float>(p1.x, lerp(p0.y, p1.y, 0.35), 0.7)
                       : (p0 + p1) / 2 + SIMD3<Float>(side * 0.2, -0.03, 0.14)
               },
               target: { [unowned self] in
                   let pose = centerPose(rig, yaw: rig.pose.yaw)
                   return inFront ? replaned(pose, z: Self.itemPlaneZ) : pose
               }) { [weak self] in
            guard let self, heroes[selectedVessel] === rig else { return }
            resumeSpin()
        }
    }

    /// Lands exactly on the icon's live pose (press included), then hands over to the icon in the same frame.
    /// `leavingScoops` (how many scoops are being lifted off it) makes it drop down its own axis first, out from
    /// under them, and only then turn and shrink toward its card.
    func flyHeroHome(_ rig: ItemRig, duration: Double, delay: Double = 0, leavingScoops: Int = 0) {
        let vessel = rig.vessel
        let fromUnderScoops = leavingScoops > 0
        setVesselIconAppear(vessel, to: 0, duration: 0.2, delay: delay, curve: .swiftUIEaseIn)
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        let axisOut = 1.6 * axialClearance(vessel, count: leavingScoops, scale: rig.pose.scale * rig.scaleMultiplier)
        flyRig(rig, duration: duration, delay: delay, minSpin: 1.5 * .pi, dip: false, timing: .flight,
               axisOut: axisOut, attitude: fromUnderScoops ? 0.3...1 : 0...1,
               control: { p0, p1 in
                   fromUnderScoops
                       ? SIMD3<Float>(p0.x, lerp(p0.y, p1.y, 0.75), -1.0)
                       : (p0 + p1) / 2 + SIMD3<Float>(side * 0.17, 0.02, -0.1)
               },
               target: { [unowned self] in iconPose(vessel) }) { [weak self] in
            guard let self else { return }
            if heroes[vessel] === rig { heroes[vessel] = nil }
            setVesselIconAppear(vessel, to: 1, duration: 0)
            if (vesselIconTarget[vessel] ?? 0) > 0 {
                updateIcons()
                discard(rig)
            } else {
                dismiss(rig)
            }
        }
    }

    /// Removes a rig and the scoops that belong to it. Scoops merely attached to it on their way elsewhere are
    /// handed to the world so they keep flying.
    func discard(_ rig: ItemRig) {
        leavingRigs.removeAll { $0 === rig }
        rig.cancelMotions()
        rig.framingTween?.cancel()
        rig.framingTween = nil
        for actor in Array(liveScoops.values) where actor.rig === rig || actor.mount === rig {
            if actor.rig === rig {
                discard(actor)
            } else {
                detachToWorld(actor)
            }
        }
        rig.scoops.removeAll()
        forgetToppings(rig)
        rig.root.removeFromParent()
    }

    /// Shrinks a rig away with a quarter turn, then removes it.
    func dismiss(_ rig: ItemRig, duration: Double = 0.3, curve: TimingCurve = .swiftUIEaseIn) {
        rig.cancelMotions()
        let startYaw = rig.pose.yaw
        let startMultiplier = rig.scaleMultiplier
        rig.motion = animate(duration: duration) { p in
            let e = curve(p)
            rig.scaleMultiplier = max(0.0001, startMultiplier * (1 - e))
            rig.pose.yaw = startYaw + 1.6 * e
            rig.apply()
        } completion: { [weak self] in
            self?.discard(rig)
        }
    }

    func dismissCurrentHero() {
        guard let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        for scoop in scoops where scoop.mount !== hero {
            discard(scoop)
        }
        scoops.removeAll()
        isDragging = false
        dismiss(hero)
    }

    func sendCurrentHeroHome() {
        guard let hero = heroes[selectedVessel], scoops.isEmpty else {
            dismissCurrentHero()
            return
        }
        heroes[selectedVessel] = nil
        isDragging = false
        flyHeroHome(hero, duration: 0.8)
    }

    func presentNewItem(vessel: Vessel, delay: Double = 0) {
        selectedVessel = vessel
        let (rig, isNew) = heroRig(vessel)
        reframe(rig, animated: !isNew)
        launch(rig, isNew: isNew, duration: 0.95, delay: delay)
    }

    /// The vessel's hero: the one still on its way home if there is one, otherwise a new rig waiting
    /// (hidden) on the card icon.
    private func heroRig(_ vessel: Vessel) -> (ItemRig, isNew: Bool) {
        if let existing = heroes[vessel] { return (existing, false) }
        let rig = makeRig(vessel)
        rig.pose = iconPose(vessel)
        rig.apply()
        rig.root.isEnabled = false
        heroes[vessel] = rig
        root.addChild(rig.root)
        return (rig, true)
    }

    private func launch(_ rig: ItemRig, isNew: Bool, duration: Double, delay: Double = 0, underScoops: Bool = false) {
        let vessel = rig.vessel
        guard isNew else {
            flyHeroToCenter(rig, duration: duration, delay: delay, underScoops: underScoops)
            setVesselIconAppear(vessel, to: 1, duration: 0.32, delay: delay + duration * 0.55)
            return
        }
        let takeOver = { [unowned self] in
            rig.pose = iconPose(vessel)
            rig.scaleMultiplier = vesselIconAppear[vessel] ?? 1
            rig.root.isEnabled = true
            rig.apply()
            setVesselIconAppear(vessel, to: 0, duration: 0)
            setVesselIconAppear(vessel, to: 1, duration: 0.32, delay: duration * 0.55)
        }
        if delay <= 0 { takeOver() }
        rig.appearTween = animate(delay: delay, duration: 0.2, onStart: delay > 0 ? takeOver : nil) { p in
            rig.scaleMultiplier = lerp(rig.scaleMultiplier, 1, p)
        }
        flyHeroToCenter(rig, duration: duration, delay: delay, underScoops: underScoops)
    }

    static let transferDuration: Double = 0.62

    func swapVessel(to vessel: Vessel) {
        guard vessel != selectedVessel else { return }
        let old = selectedVessel
        selectedVessel = vessel
        isDragging = false
        let carrying = !scoops.isEmpty
        let duration = carrying ? Self.transferDuration : 1.0
        let (incoming, isNew) = heroRig(vessel)
        setOwner(scoops, incoming)
        reframe(incoming, animated: !isNew)
        // Carrying scoops, both vessels pass under the stack; the incoming one starts a beat later, in front, so it
        // never meets the outgoing one dropping away behind.
        launch(incoming, isNew: isNew, duration: carrying ? duration - 0.16 : duration, delay: carrying ? 0.1 : 0,
               underScoops: carrying)
        if let outgoing = heroes[old] {
            moveToppings(from: outgoing, to: incoming)
            flyHeroHome(outgoing, duration: carrying ? 0.75 : 1.0, leavingScoops: scoops.count)
        }
        if carrying { transferScoops(to: incoming, arrival: duration) }
    }
}
