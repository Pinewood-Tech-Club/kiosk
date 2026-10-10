import RealityKit
import SwiftUI

extension Stage {
    static func pressIndex(_ card: CardKey) -> Int {
        switch card {
        case .vessel(.cup): 0
        case .vessel(.cone): 1
        case .flavor(.vanilla): 2
        case .flavor(.chocolate): 3
        case .flavor(.cookies): 4
        }
    }

    func setPressed(_ card: CardKey, _ pressed: Bool) {
        pressSprings[Self.pressIndex(card)].target = pressed ? 1 : 0
    }

    func stepPresses(_ dt: Float) {
        for index in pressSprings.indices {
            pressSprings[index].step(dt)
        }
    }

    func updateIcons() {
        guard isBuilt else { return }
        for vessel in Vessel.allCases {
            guard let rig = vesselIcons[vessel] else { continue }
            rig.pose = iconPose(vessel)
            rig.scaleMultiplier = iconShown[.vessel(vessel)] ?? 0
            rig.root.isEnabled = rig.scaleMultiplier > 0.001
            rig.modelScale = vesselIconAppear[vessel] ?? 1
            rig.grounded = vesselIconShadow[vessel] ?? 1
            rig.apply()
        }
        for flavor in Flavor.allCases {
            guard let icon = flavorIcons[flavor] else { continue }
            let (position, scale) = pressed(icon.restPosition, card: .flavor(flavor), center: Layout.flavorCardCenter(flavor))
            icon.holder.position = position
            icon.holder.orientation = icon.restOrientation
            let shown = iconShown[.flavor(flavor)] ?? 0
            icon.holder.scale = .init(repeating: max(icon.baseScale * scale * shown, 1e-5))
            icon.holder.isEnabled = shown > 0.001
            icon.scaler.scale = .init(repeating: max(icon.appear, 1e-5))
            icon.applyShadow()
        }
    }

    /// World transform of the flavor icon's scoop as it sits in the card (ignoring hide/grow), where
    /// launched scoops start and returning scoops land.
    /// `slot` picks whose icon pose to center, so a scoop using another slot's mesh sits where the icon sits.
    func flavorIconModelTransform(_ flavor: Flavor, slot: Int = 1) -> Transform {
        guard let icon = flavorIcons[flavor] else { return Transform() }
        let (position, scale) = pressed(icon.restPosition, card: .flavor(flavor), center: Layout.flavorCardCenter(flavor))
        let holder = Transform(scale: .init(repeating: icon.baseScale * scale), rotation: icon.restOrientation, translation: position)
        return Transform(matrix: holder.matrix * Transform(translation: -iconCenter(slot: slot)).matrix)
    }

    func setStep(_ newStep: BuilderStep, animated: Bool) {
        step = newStep
        refreshIconVisibility(animated: animated)
    }

    func setControlsVisible(_ visible: Bool, animated: Bool) {
        controlsVisible = visible
        refreshIconVisibility(animated: animated)
    }

    /// Icons scale out and back in on the cards' fade curves (`.easeIn(0.18)` out, `.easeOut(0.26)` in
    /// after 0.16 s), shrinking toward their card's centre.
    private func refreshIconVisibility(animated: Bool) {
        for vessel in Vessel.allCases {
            let visible = controlsVisible && step == .vessel
            vesselIconTarget[vessel] = visible ? 1 : 0
            setIconShown(.vessel(vessel), visible, animated: animated)
        }
        for flavor in Flavor.allCases {
            setIconShown(.flavor(flavor), controlsVisible && step == .flavors, animated: animated)
        }
    }

    private func setIconShown(_ card: CardKey, _ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        guard iconShownTargets[card] != target || !animated else { return }
        iconShownTargets[card] = target
        iconShownTweens[card]?.cancel()
        iconShownTweens[card] = nil
        guard animated else {
            iconShown[card] = target
            return
        }
        var from: Float = 0
        iconShownTweens[card] = animate(delay: visible ? 0.16 : 0, duration: visible ? 0.26 : 0.18,
                                        onStart: { [unowned self] in from = iconShown[card] ?? 0 }) { [unowned self] p in
            iconShown[card] = lerp(from, target, visible ? TimingCurve.swiftUIEaseOut(p) : TimingCurve.swiftUIEaseIn(p))
        }
    }

    func setVesselIconShadow(_ vessel: Vessel, to target: Float, duration: Double, delay: Double = 0) {
        // A delayed change takes over when it starts, so a fade already running finishes first.
        if delay <= 0 {
            vesselIconShadowTweens[vessel]?.cancel()
            vesselIconShadowTweens[vessel] = nil
        }
        if duration <= 0, delay <= 0 {
            vesselIconShadow[vessel] = target
            return
        }
        var from: Float = 0
        vesselIconShadowTweens[vessel] = animate(delay: delay, duration: duration,
                                                 onStart: { [unowned self] in from = vesselIconShadow[vessel] ?? 1 }) { [unowned self] p in
            vesselIconShadow[vessel] = lerp(from, target, TimingCurve.swiftUIEaseInOut(p))
        }
    }

    func setVesselIconAppear(_ vessel: Vessel, to target: Float, duration: Double, delay: Double = 0,
                             curve: TimingCurve = .swiftUIEaseOut) {
        vesselIconAppearTweens[vessel]?.cancel()
        vesselIconAppearTweens[vessel] = nil
        if duration <= 0, delay <= 0 {
            vesselIconAppear[vessel] = target
            return
        }
        var from: Float = 0
        vesselIconAppearTweens[vessel] = animate(delay: delay, duration: max(duration, 0.0001),
                                                 onStart: { [unowned self] in from = vesselIconAppear[vessel] ?? 1 }) { [unowned self] p in
            vesselIconAppear[vessel] = lerp(from, target, curve(p))
        }
    }

    /// `shadowDuration` lets the contact shadow fade out after the scoop has already lifted off.
    func setFlavorIconAppear(_ flavor: Flavor, to target: Float, duration: Double, delay: Double = 0,
                             curve: TimingCurve = .swiftUIEaseOut, shadowDuration: Double? = nil) {
        guard let icon = flavorIcons[flavor] else { return }
        icon.appearTween?.cancel()
        icon.appearTween = nil
        let shadowTime = shadowDuration ?? duration
        if shadowTime <= 0, delay <= 0 {
            icon.shadowTween?.cancel()
            icon.shadowTween = nil
            icon.shadowAmount = target
        } else {
            // A delayed fade takes over when it starts, so a fade already running finishes first.
            if delay <= 0 { icon.shadowTween?.cancel() }
            var from: Float = 0
            icon.shadowTween = animate(delay: delay, duration: max(shadowTime, 0.0001), onStart: { [weak icon] in
                guard let icon else { return }
                from = icon.shadowAmount
            }) { [weak icon] p in
                icon?.shadowAmount = lerp(from, target, TimingCurve.swiftUIEaseInOut(p))
            }
        }
        if duration <= 0, delay <= 0 {
            icon.appear = target
            return
        }
        var from: Float = 0
        icon.appearTween = animate(delay: delay, duration: max(duration, 0.0001), onStart: { from = icon.appear }) { p in
            icon.appear = lerp(from, target, curve(p))
        }
    }
}
