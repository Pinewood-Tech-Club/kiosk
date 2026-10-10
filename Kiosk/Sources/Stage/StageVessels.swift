import QuartzCore
import RealityKit
import SwiftUI

extension Stage {
    func updateHeroSpin(_ dt: Float) {
        guard let hero = heroes[selectedVessel], hero.motion == nil else { return }
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
    /// frame equals the target exactly.
    /// The rig's contact shadows shrink away as it lifts off (first ~12% of the flight) and grow back as it
    /// lands (last ~12%), so no shadow ever travels through the air with it.
    func flyRig(_ rig: ItemRig, duration: Double, delay: Double = 0, minSpin: Float, dip: Bool,
                timing: TimingCurve, shadowAtStart: Bool = true, shadowAtEnd: Bool = true,
                control: @escaping (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>,
                target: @escaping () -> RigPose, completion: @escaping () -> Void) {
        rig.motion?.cancel()
        var start = rig.pose
        var yawDelta: Float = 0
        var controlPoint = SIMD3<Float>.zero
        rig.motion = animate(delay: delay, duration: duration, onStart: {
            start = rig.pose
            let goal = target()
            yawDelta = forwardYawDelta(from: start.yaw, to: goal.yaw, minimum: minSpin)
            controlPoint = control(start.position, goal.position)
        }) { p in
            let goal = target()
            let e = timing(p)
            rig.pose.position = quadraticBezier(start.position, controlPoint, goal.position, e)
            if dip {
                let dipEnd: Float = 0.16
                rig.pose.scale = p < dipEnd
                    ? start.scale * lerp(1, 0.93, Ease.inOutSine(p / dipEnd))
                    : lerp(start.scale * 0.93, goal.scale, TimingCurve.standard(Ease.segment(p, dipEnd, 1)))
            } else {
                rig.pose.scale = lerp(start.scale, goal.scale, TimingCurve.standard(p))
            }
            rig.pose.pitch = lerp(start.pitch, goal.pitch, e)
            rig.pose.roll = lerp(start.roll, goal.roll, e)
            rig.pose.yaw = start.yaw + yawDelta * Ease.inOutCubic(p)
            let leaving: Float = shadowAtStart ? 1 - Ease.inOutSine(Ease.segment(p, 0, 0.12)) : 0
            let landing: Float = shadowAtEnd ? Ease.inOutSine(Ease.segment(p, 0.88, 1)) : 0
            rig.grounded = max(leaving, landing)
            rig.apply()
        } completion: {
            rig.grounded = shadowAtEnd ? 1 : 0
            rig.apply()
            rig.motion = nil
            completion()
        }
    }

    func flyHeroToCenter(_ rig: ItemRig, duration: Double, delay: Double = 0) {
        let vessel = rig.vessel
        let fromIcon = abs(rig.pose.roll - iconRestPose(vessel).roll) < 0.01
            && abs(rig.pose.scale - Self.iconScale(vessel)) < Self.iconScale(vessel) * 0.1
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        flyRig(rig, duration: duration, delay: delay, minSpin: fromIcon ? 2 * .pi : .pi, dip: fromIcon,
               timing: .flight, shadowAtStart: !fromIcon,
               control: { p0, p1 in (p0 + p1) / 2 + SIMD3<Float>(side * 0.2, -0.03, 0.14) },
               target: { [unowned self] in centerPose(vessel, yaw: rig.pose.yaw) }) { [weak self] in
            guard let self, heroes[selectedVessel] === rig else { return }
            resumeSpin()
        }
    }

    /// Lands exactly on the icon's live pose (press included), then hands over to the icon in the same frame.
    func flyHeroHome(_ rig: ItemRig, duration: Double, delay: Double = 0) {
        let vessel = rig.vessel
        setVesselIconAppear(vessel, to: 0, duration: 0.2, delay: delay, curve: .swiftUIEaseIn)
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        setVesselIconShadow(vessel, to: 0, duration: 0.2, delay: delay)
        flyRig(rig, duration: duration, delay: delay, minSpin: 1.5 * .pi, dip: false, timing: .flight, shadowAtEnd: false,
               control: { p0, p1 in (p0 + p1) / 2 + SIMD3<Float>(side * 0.17, 0.02, -0.1) },
               target: { [unowned self] in iconPose(vessel) }) { [weak self] in
            guard let self else { return }
            if heroes[vessel] === rig { heroes[vessel] = nil }
            setVesselIconShadow(vessel, to: 1, duration: 0.28)
            if (vesselIconTarget[vessel] ?? 0) > 0 {
                setVesselIconAppear(vessel, to: 1, duration: 0)
                updateIcons()
                discard(rig)
            } else {
                setVesselIconAppear(vessel, to: 1, duration: 0)
                dismiss(rig)
            }
        }
    }

    func discard(_ rig: ItemRig) {
        rig.cancelMotions()
        for scoop in rig.scoops { discard(scoop) }
        rig.scoops.removeAll()
        rig.root.removeFromParent()
    }

    /// Shrinks a rig away with a quarter turn, then removes it.
    func dismiss(_ rig: ItemRig, duration: Double = 0.3) {
        rig.cancelMotions()
        let startYaw = rig.pose.yaw
        let startMultiplier = rig.scaleMultiplier
        rig.motion = animate(duration: duration) { p in
            let e = TimingCurve.swiftUIEaseIn(p)
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
        for scoop in scoops where scoop.root.parent !== hero.body {
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
        launchFromIcon(vessel, duration: 0.95, delay: delay)
    }

    func launchFromIcon(_ vessel: Vessel, duration: Double, delay: Double = 0) {
        if let existing = heroes[vessel] {
            flyHeroToCenter(existing, duration: duration, delay: delay)
            setVesselIconAppear(vessel, to: 1, duration: 0.32, delay: delay + duration * 0.55)
            return
        }
        let rig = makeRig(vessel)
        rig.pose = iconPose(vessel)
        rig.grounded = 0
        rig.apply()
        rig.root.isEnabled = false
        heroes[vessel] = rig
        root.addChild(rig.root)
        let takeOver = { [unowned self] in
            rig.pose = iconPose(vessel)
            rig.scaleMultiplier = vesselIconAppear[vessel] ?? 1
            rig.grounded = 0
            rig.root.isEnabled = true
            rig.apply()
            setVesselIconAppear(vessel, to: 0, duration: 0)
            setVesselIconAppear(vessel, to: 1, duration: 0.32, delay: duration * 0.55)
            setVesselIconShadow(vessel, to: 0, duration: 0.2)
            setVesselIconShadow(vessel, to: 1, duration: 0.32, delay: duration * 0.55)
        }
        if delay <= 0 { takeOver() }
        animate(delay: delay, duration: 0.2, onStart: delay > 0 ? takeOver : nil) { p in
            rig.scaleMultiplier = lerp(rig.scaleMultiplier, 1, p)
        }
        flyHeroToCenter(rig, duration: duration, delay: delay)
    }

    func swapVessel(to vessel: Vessel) {
        guard vessel != selectedVessel else { return }
        let old = selectedVessel
        selectedVessel = vessel
        isDragging = false
        let duration = 1.0
        launchFromIcon(vessel, duration: duration)
        if let outgoing = heroes[old] {
            flyHeroHome(outgoing, duration: duration, delay: scoops.isEmpty ? 0 : 0.3)
        }
        if let incoming = heroes[vessel] {
            transferScoops(to: incoming, landingIn: duration)
        }
    }
}
