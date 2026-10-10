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
            rig.scaleMultiplier = vesselIconAppear[vessel] ?? 1
            rig.apply()
        }
        for flavor in Flavor.allCases {
            guard let icon = flavorIcons[flavor] else { continue }
            let (position, scale) = pressed(icon.restPosition, card: .flavor(flavor), center: Layout.flavorCardCenter(flavor))
            icon.holder.position = position
            icon.holder.orientation = icon.restOrientation
            icon.holder.scale = .init(repeating: icon.baseScale * scale)
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

    /// Mirrors the cards' SwiftUI transition (`.easeIn(0.18)` out, `.easeOut(0.26).delay(0.16)` in).
    private func refreshIconVisibility(animated: Bool) {
        for vessel in Vessel.allCases {
            guard let rig = vesselIcons[vessel] else { continue }
            let target: Float = controlsVisible && step == .vessel ? 1 : 0
            guard vesselIconTarget[vessel] != target || !animated else { continue }
            vesselIconTarget[vessel] = target
            rig.opacityTween?.cancel()
            if !animated {
                rig.setOpacity(target)
                continue
            }
            var from: Float = 0
            let fadingIn = target > 0
            rig.opacityTween = animate(delay: fadingIn ? 0.16 : 0, duration: fadingIn ? 0.26 : 0.18,
                                       onStart: { from = rig.opacity }) { p in
                let e = fadingIn ? TimingCurve.swiftUIEaseOut(p) : TimingCurve.swiftUIEaseIn(p)
                rig.setOpacity(lerp(from, target, e))
            }
        }
        for icon in flavorIcons.values {
            let visible = controlsVisible && step == .flavors
            guard icon.baseVisible != visible || !animated else { continue }
            icon.baseVisible = visible
            let target: Float = visible ? 1 : 0
            icon.opacityTween?.cancel()
            if !animated {
                icon.setOpacity(target)
                continue
            }
            var from: Float = 0
            icon.opacityTween = animate(delay: visible ? 0.16 : 0, duration: visible ? 0.26 : 0.18,
                                        onStart: { from = icon.opacity }) { p in
                let e = visible ? TimingCurve.swiftUIEaseOut(p) : TimingCurve.swiftUIEaseIn(p)
                icon.setOpacity(lerp(from, target, e))
            }
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
