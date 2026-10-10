import QuartzCore
import SwiftUI
import RealityKit
import UIKit

enum BuilderStep: Int, CaseIterable, Sendable {
    case vessel, flavors, toppings

    var title: String {
        switch self {
        case .vessel: "Vessel"
        case .flavors: "Flavors"
        case .toppings: "Toppings"
        }
    }
}

/// Owns every 3D entity (main item, selector icons, flying entities, tray minis) and drives them
/// from a deterministic per-frame timeline. Not observable: SwiftUI never re-renders because of it.
@MainActor
final class Stage {
    static let preferredPitch: Float = 0.30
    static let baseSpin: Float = 0.42
    static let fieldOfView: Float = 24
    private static let tweenPhases: [Tween.Phase] = [.rigs, .attachments, .late]
    private static let slotKeys = ["1", "2", "3"]

    let root = Entity()
    let stats = FrameStats()
    var timeScale: Double = 1
    var log: (String) -> Void = { _ in }
    var logsHitches = false

    private(set) var assets: AssetLibrary?
    private(set) var isBuilt = false
    private(set) var now: Double = 0
    private(set) var selectedVessel: Vessel = .cup

    private let camera = Entity()
    private let iblEntity = Entity()
    private var subscription: EventSubscription?
    private var viewSize = Layout.screen
    private var tweens: [Tween] = []
    private var shadowMesh: MeshResource?
    private var morphing: [ScoopActor] = []

    private var vesselIcons: [Vessel: ItemRig] = [:]
    private var vesselIconVisible: [Vessel: Bool] = [:]
    private var vesselIconSuppressed: [Vessel: Bool] = [:]
    private var flavorIcons: [Flavor: FlavorIcon] = [:]
    private var heroes: [Vessel: ItemRig] = [:]
    private var scoops: [ScoopActor] = []
    private var tray: [TrayEntry] = []
    private var step: BuilderStep = .vessel

    private var warmup: Entity?
    private var warmupFrames = 0

    private var yawVelocity: Float = 0
    private var isDragging = false
    private var releaseTime: Double = -10
    private var dragStartYaw: Float = 0
    private var dragStartPitch: Float = 0
    private var lastDragSample: (time: Double, yaw: Float) = (0, 0)
    private var pitchReturnFrom: Float = preferredPitch
    private var pitchReturnDuration: Double = 0

    private(set) var trayScroll: CGFloat = 0
    private var trayScrollTween: Tween?
    private var trayDragStart: CGFloat?

    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        subscription = content.subscribe(to: SceneEvents.Update.self, on: nil, componentType: nil) { [weak self] event in
            self?.tick(realDelta: event.deltaTime)
        }
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewSize = size
        camera.position = [0, 0, cameraDistance]
    }

    private var cameraDistance: Float {
        Float(viewSize.height) * 0.001 / 2 / tan(Self.fieldOfView * .pi / 360)
    }

    func world(_ point: CGPoint, z: Float = 0) -> SIMD3<Float> {
        let depthScale = (cameraDistance - z) / cameraDistance
        return [Float(point.x - viewSize.width / 2) * 0.001 * depthScale,
                Float(viewSize.height / 2 - point.y) * 0.001 * depthScale,
                z]
    }

    func screen(_ position: SIMD3<Float>) -> CGPoint {
        let depthScale = (cameraDistance - position.z) / cameraDistance
        return CGPoint(x: CGFloat(position.x / depthScale / 0.001) + viewSize.width / 2,
                       y: viewSize.height / 2 - CGFloat(position.y / depthScale / 0.001))
    }

    func build(with assets: AssetLibrary) {
        guard !isBuilt else { return }
        self.assets = assets
        shadowMesh = MeshResource.generatePlane(width: 1, depth: 1)

        camera.components.set(PerspectiveCameraComponent(near: 0.5, far: 12, fieldOfViewInDegrees: Self.fieldOfView,
                                                         fieldOfViewOrientation: .vertical))
        camera.position = [0, 0, cameraDistance]
        root.addChild(camera)

        if let environment = assets.environment {
            var ibl = ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.35)
            ibl.inheritsRotation = true
            iblEntity.components.set(ibl)
            iblEntity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        }
        root.addChild(iblEntity)

        addLight(intensity: 2400, from: [-1.3, 1.6, 2.2], shadow: true)
        addLight(intensity: 700, from: [1.9, 0.35, 1.4], shadow: false)
        addLight(intensity: 1500, from: [0.35, 1.5, -2.2], shadow: false)

        for vessel in Vessel.allCases {
            let rig = makeRig(vessel)
            rig.pose = iconPose(vessel)
            rig.apply()
            rig.setOpacity(0)
            vesselIcons[vessel] = rig
            vesselIconVisible[vessel] = false
            vesselIconSuppressed[vessel] = false
            root.addChild(rig.root)
        }
        for flavor in Flavor.allCases {
            let icon = makeFlavorIcon(flavor)
            flavorIcons[flavor] = icon
            root.addChild(icon.holder)
        }
        buildWarmup()
        isBuilt = true
        setStep(.vessel, animated: false)
    }

    private func addLight(intensity: Float, from position: SIMD3<Float>, shadow: Bool) {
        let light = Entity()
        light.components.set(DirectionalLightComponent(color: .white, intensity: intensity))
        if shadow {
            light.components.set(DirectionalLightComponent.Shadow(maximumDistance: 5, depthBias: 2))
        }
        light.look(at: .zero, from: position, relativeTo: nil)
        root.addChild(light)
    }

    private func applyLighting(_ entity: Entity) {
        if assets?.environment != nil {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
        }
        for child in entity.children { applyLighting(child) }
    }

    /// Renders every material/mesh combination once (behind the opaque attract screen) so shader
    /// compilation and first-use uploads never land on a customer's first tap.
    private func buildWarmup() {
        guard let assets else { return }
        let group = Entity()
        var x: Float = -0.4
        for slot in 1...3 {
            for flavor in Flavor.allCases {
                let meshes = [assets.scoopSet(slot).staticMesh("cup")] + assets.scoopSet(slot).allMorpherResources.prefix(1)
                for mesh in meshes {
                    for translucent in [false, true] {
                        let entity = ModelEntity(mesh: mesh, materials: [assets.material(slot: slot, flavor: flavor)])
                        applyLighting(entity)
                        entity.position = [x, translucent ? -0.1 : 0.1, 0]
                        if translucent { entity.components.set(OpacityComponent(opacity: 0.5)) }
                        group.addChild(entity)
                    }
                }
                x += 0.09
            }
        }
        for vessel in Vessel.allCases {
            for translucent in [false, true] {
                let rig = makeRig(vessel)
                rig.pose = RigPose(position: [vessel == .cup ? -0.2 : 0.2, translucent ? -0.3 : 0.3, 0], scale: 1, pitch: 0.3, yaw: 0)
                rig.apply()
                if translucent { rig.setOpacity(0.5) }
                group.addChild(rig.root)
            }
        }
        warmup = group
        warmupFrames = 0
        root.addChild(group)
    }

    private func tick(realDelta: Double) {
        let started = CACurrentMediaTime()
        let dt = min(realDelta, 0.25) * timeScale
        now += dt

        if let warmup {
            warmupFrames += 1
            if warmupFrames > 12 {
                warmup.removeFromParent()
                self.warmup = nil
            }
        }

        updateHeroSpin(Float(dt))
        for phase in Self.tweenPhases {
            for tween in tweens where tween.phase == phase {
                tween.step(now: now)
            }
        }
        tweens.removeAll { $0.isFinished }
        updateTray()
        flushMorphs()

        stats.record(frame: realDelta, cpu: CACurrentMediaTime() - started)
        if logsHitches, realDelta > 0.05, realDelta < 0.9 {
            log(String(format: "Frame hitch %.0f ms (tweens %d, morphing %d)", realDelta * 1000, tweens.count, morphing.count))
        }
    }

    @discardableResult
    private func animate(delay: Double = 0, duration: Double, phase: Tween.Phase = .rigs,
                         onStart: (() -> Void)? = nil,
                         _ update: @escaping (Float) -> Void,
                         completion: (() -> Void)? = nil) -> Tween {
        let tween = Tween(start: now + delay, duration: duration, phase: phase, onStart: onStart, update: update, completion: completion)
        tweens.append(tween)
        return tween
    }

    var activeAnimationCount: Int { tweens.count }
    var morphingCount: Int { morphing.count }

    static func mainScale(_ vessel: Vessel) -> Float { vessel == .cup ? 4.2 : 2.5 }
    static func iconScale(_ vessel: Vessel) -> Float { vessel == .cup ? 1.75 : 0.92 }
    static func miniScale(_ vessel: Vessel) -> Float { vessel == .cup ? 1.0 : 0.5 }
    static let flavorIconScale: Float = 2.3

    func centerPose(_ vessel: Vessel, yaw: Float) -> RigPose {
        RigPose(position: world(Layout.mainPivot(vessel)), scale: Self.mainScale(vessel), pitch: Self.preferredPitch, yaw: yaw)
    }

    func iconPose(_ vessel: Vessel) -> RigPose {
        RigPose(position: world(Layout.vesselIconCenter(vessel)), scale: Self.iconScale(vessel), pitch: 0.34,
                yaw: vessel == .cup ? 0.6 : 0)
    }

    private func trayPose(_ entry: TrayEntry) -> RigPose {
        let x = Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll
        var position = world(CGPoint(x: x, y: Layout.trayCenterY))
        let scale = Self.miniScale(entry.item.vessel)
        position.y += (entry.rig.pivot.y - entry.contentCenterY) * scale
        return RigPose(position: position, scale: scale, pitch: 0.3, yaw: -0.55)
    }

    private func makeShadow(diameter: Float, y: Float) -> ModelEntity? {
        guard let assets, let shadowMesh else { return nil }
        let shadow = ModelEntity(mesh: shadowMesh, materials: [assets.shadowMaterial])
        shadow.scale = [diameter, 1, diameter]
        shadow.position.y = y
        shadow.components.set(DynamicLightShadowComponent(castsShadow: false))
        return shadow
    }

    private func makeRig(_ vessel: Vessel) -> ItemRig {
        let assets = assets!
        let model = assets.vessels[vessel]!.clone(recursive: true)
        applyLighting(model)
        let shadow = vessel == .cup ? makeShadow(diameter: 0.15, y: -0.0012) : nil
        return ItemRig(vessel: vessel, model: model, shadow: shadow, pivot: assets.vesselPivot(vessel),
                       pose: RigPose(position: .zero, scale: 1, pitch: Self.preferredPitch, yaw: 0))
    }

    private func makeScoopEntity(slot: Int, flavor: Flavor, pose: String) -> ModelEntity {
        let assets = assets!
        let entity = ModelEntity(mesh: assets.scoopSet(slot).staticMesh(pose),
                                 materials: [assets.material(slot: slot, flavor: flavor)])
        applyLighting(entity)
        return entity
    }

    private func iconCenter(slot: Int) -> SIMD3<Float> {
        let bounds = assets!.scoopSet(slot).poseBounds("icon")
        return (bounds.min + bounds.max) / 2
    }

    private func makeFlavorIcon(_ flavor: Flavor) -> FlavorIcon {
        let models = [makeScoopEntity(slot: 1, flavor: flavor, pose: "icon"),
                      makeScoopEntity(slot: 1, flavor: flavor, pose: "icon")]
        let center = iconCenter(slot: 1)
        for model in models { model.position = -center }
        let shadow = makeShadow(diameter: 0.1, y: -center.y - 0.0008) ?? ModelEntity()
        let icon = FlavorIcon(flavor: flavor, models: models, shadow: shadow)
        icon.baseScale = Self.flavorIconScale
        icon.applyScale()
        icon.holder.position = world(Layout.flavorIconCenter(flavor))
        icon.holder.orientation = simd_quatf(angle: 0.36, axis: [1, 0, 0]) * simd_quatf(angle: -0.25, axis: [0, 1, 0])
        icon.setOpacity(0)
        return icon
    }

    private func configureIconModel(_ model: ModelEntity, flavor: Flavor, slot: Int) {
        guard let assets else { return }
        model.model?.mesh = assets.scoopSet(slot).staticMesh("icon")
        model.model?.materials = [assets.material(slot: slot, flavor: flavor)]
        model.position = -iconCenter(slot: slot)
    }

    func setStep(_ newStep: BuilderStep, animated: Bool) {
        step = newStep
        let fadeOut = animated ? 0.18 : 0
        let fadeIn = animated ? 0.26 : 0
        let fadeInDelay = animated ? 0.16 : 0
        for vessel in Vessel.allCases {
            let visible = newStep == .vessel
            guard vesselIconVisible[vessel] != visible || !animated else { continue }
            vesselIconVisible[vessel] = visible
            refreshVesselIcon(vessel, duration: visible ? fadeIn : fadeOut, delay: visible ? fadeInDelay : 0)
        }
        for icon in flavorIcons.values {
            let visible = newStep == .flavors
            guard icon.baseVisible != visible || !animated else { continue }
            icon.baseVisible = visible
            refreshFlavorIcon(icon, duration: visible ? fadeIn : fadeOut, delay: visible ? fadeInDelay : 0)
        }
        for icon in flavorIcons.values {
            setIconSlot(icon, slot: nextSlot, animated: false)
        }
    }

    private var nextSlot: Int { min(scoops.count + 1, Pricing.maxScoopsPerItem) }

    private func vesselIconTarget(_ vessel: Vessel) -> Float {
        (vesselIconVisible[vessel] ?? false) && !(vesselIconSuppressed[vessel] ?? false) ? 1 : 0
    }

    private func refreshVesselIcon(_ vessel: Vessel, duration: Double, delay: Double = 0) {
        guard let rig = vesselIcons[vessel] else { return }
        let target = vesselIconTarget(vessel)
        rig.opacityTween?.cancel()
        if duration <= 0 {
            rig.setOpacity(target)
            return
        }
        var from: Float = 0
        rig.opacityTween = animate(delay: delay, duration: duration, onStart: { from = rig.opacity }) { p in
            rig.setOpacity(lerp(from, target, Ease.inOutSine(p)))
        }
    }

    private func flavorIconTarget(_ icon: FlavorIcon) -> Float {
        icon.baseVisible && !icon.suppressed ? 1 : 0
    }

    private func refreshFlavorIcon(_ icon: FlavorIcon, duration: Double, delay: Double = 0) {
        let target = flavorIconTarget(icon)
        icon.opacityTween?.cancel()
        if duration <= 0 {
            icon.setOpacity(target)
            return
        }
        var from: Float = 0
        icon.opacityTween = animate(delay: delay, duration: duration, onStart: { from = icon.opacity }) { p in
            icon.setOpacity(lerp(from, target, Ease.inOutSine(p)))
        }
    }

    private func suppressVesselIcon(_ vessel: Vessel, fade: Double) {
        guard let rig = vesselIcons[vessel] else { return }
        rig.replenishTween?.cancel()
        vesselIconSuppressed[vessel] = true
        refreshVesselIcon(vessel, duration: fade)
    }

    private func replenishVesselIcon(_ vessel: Vessel, after delay: Double) {
        guard let rig = vesselIcons[vessel] else { return }
        rig.replenishTween?.cancel()
        rig.replenishTween = animate(delay: delay, duration: 0.3, onStart: { [unowned self] in
            vesselIconSuppressed[vessel] = false
            refreshVesselIcon(vessel, duration: 0.22)
        }) { p in
            rig.scaleMultiplier = lerp(0.84, 1, Ease.outBack(p, overshoot: 1.4))
            rig.apply()
        }
    }

    private func suppressFlavorIcon(_ icon: FlavorIcon, fade: Double) {
        icon.replenishTween?.cancel()
        icon.suppressed = true
        refreshFlavorIcon(icon, duration: fade)
    }

    private func replenishFlavorIcon(_ icon: FlavorIcon, after delay: Double) {
        icon.replenishTween?.cancel()
        icon.replenishTween = animate(delay: delay, duration: 0.3, onStart: { [unowned self] in
            icon.suppressed = false
            refreshFlavorIcon(icon, duration: 0.22)
        }) { p in
            icon.scaleMultiplier = lerp(0.84, 1, Ease.outBack(p, overshoot: 1.4))
            icon.applyScale()
        }
    }

    private func setIconSlot(_ icon: FlavorIcon, slot: Int, animated: Bool) {
        guard icon.slot != slot else { return }
        icon.slot = slot
        icon.crossfadeTween?.cancel()
        let previous = icon.activeModel
        let next = 1 - previous
        for (index, model) in icon.models.enumerated() where index != previous {
            model.setOpacity(0)
        }
        if !animated || icon.opacity < 0.01 || icon.suppressed {
            configureIconModel(icon.models[previous], flavor: icon.flavor, slot: slot)
            icon.models[previous].setOpacity(1)
            return
        }
        configureIconModel(icon.models[next], flavor: icon.flavor, slot: slot)
        icon.activeModel = next
        let outgoing = icon.models[previous], incoming = icon.models[next]
        icon.crossfadeTween = animate(duration: 0.22) { p in
            let e = Ease.inOutSine(p)
            incoming.setOpacity(e)
            outgoing.setOpacity(1 - e)
        } completion: {
            outgoing.setOpacity(0)
            incoming.setOpacity(1)
        }
    }

    func bounceVessel(_ vessel: Vessel) {
        guard let rig = vesselIcons[vessel] else { return }
        rig.bounceTween?.cancel()
        let start = rig.scaleMultiplier
        rig.bounceTween = animate(duration: 0.46) { p in
            let s: Float = p < 0.24
                ? lerp(start, 0.9, Ease.outCubic(p / 0.24))
                : lerp(0.9, 1, Ease.outBack((p - 0.24) / 0.76, overshoot: 2.2))
            rig.scaleMultiplier = s
            rig.apply()
        }
    }

    func bounceFlavor(_ flavor: Flavor) {
        guard let icon = flavorIcons[flavor] else { return }
        icon.bounceTween?.cancel()
        let start = icon.scaleMultiplier
        icon.bounceTween = animate(duration: 0.46) { p in
            icon.scaleMultiplier = p < 0.24
                ? lerp(start, 0.9, Ease.outCubic(p / 0.24))
                : lerp(0.9, 1, Ease.outBack((p - 0.24) / 0.76, overshoot: 2.2))
            icon.applyScale()
        }
    }

    private func updateHeroSpin(_ dt: Float) {
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

    private func flyRig(_ rig: ItemRig, duration: Double, delay: Double = 0, minSpin: Float, dip: Bool,
                        timing: TimingCurve, control: @escaping (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>,
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
                if p < dipEnd {
                    rig.pose.scale = start.scale * lerp(1, 0.9, Ease.inOutSine(p / dipEnd))
                } else {
                    let g = TimingCurve.standard(Ease.segment(p, dipEnd, 1))
                    rig.pose.scale = lerp(start.scale * 0.9, goal.scale, g)
                }
            } else {
                rig.pose.scale = lerp(start.scale, goal.scale, TimingCurve.standard(p))
            }
            rig.pose.pitch = lerp(start.pitch, goal.pitch, e)
            rig.pose.yaw = start.yaw + yawDelta * Ease.inOutCubic(p)
            rig.apply()
        } completion: {
            rig.motion = nil
            completion()
        }
    }

    private func flyHeroToCenter(_ rig: ItemRig, duration: Double, delay: Double = 0) {
        let vessel = rig.vessel
        let fromIcon = abs(rig.pose.scale - Self.iconScale(vessel)) < 0.01
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        flyRig(rig, duration: duration, delay: delay, minSpin: fromIcon ? 2 * .pi : .pi, dip: fromIcon,
               timing: .flight,
               control: { p0, p1 in
                   let mid = (p0 + p1) / 2
                   return mid + SIMD3<Float>(side * 0.2, -0.03, 0.14)
               },
               target: { [unowned self] in centerPose(vessel, yaw: rig.pose.yaw) }) { [weak self] in
            guard let self else { return }
            if heroes[selectedVessel] === rig {
                yawVelocity = 0
                releaseTime = now - 0.75
                pitchReturnDuration = 0
            }
        }
    }

    private func flyHeroHome(_ rig: ItemRig, duration: Double, delay: Double = 0) {
        let vessel = rig.vessel
        suppressVesselIcon(vessel, fade: 0.16)
        let side: Float = Layout.vesselIconCenter(vessel).x > Layout.midX ? 1 : -1
        flyRig(rig, duration: duration, delay: delay, minSpin: 1.5 * .pi, dip: false, timing: .flight,
               control: { p0, p1 in
                   let mid = (p0 + p1) / 2
                   return mid + SIMD3<Float>(side * 0.17, 0.02, -0.1)
               },
               target: { [unowned self] in iconPose(vessel) }) { [weak self] in
            guard let self else { return }
            heroes[vessel] = nil
            vesselIconSuppressed[vessel] = false
            vesselIcons[vessel]?.replenishTween?.cancel()
            vesselIcons[vessel]?.scaleMultiplier = 1
            vesselIcons[vessel]?.apply()
            if vesselIconVisible[vessel] == true {
                refreshVesselIcon(vessel, duration: 0)
                discard(rig)
            } else {
                refreshVesselIcon(vessel, duration: 0)
                animate(duration: 0.2) { p in rig.setOpacity(1 - p) } completion: { [weak self] in self?.discard(rig) }
            }
        }
    }

    private func discard(_ rig: ItemRig) {
        rig.cancelMotions()
        for scoop in rig.scoops { discard(scoop) }
        rig.scoops.removeAll()
        rig.root.removeFromParent()
    }

    private func discard(_ scoop: ScoopActor) {
        scoop.cancelMotions()
        if let morpher = scoop.morpher {
            assets?.scoopSet(scoop.slot).release(morpher)
            scoop.morpher = nil
        }
        morphing.removeAll { $0 === scoop }
        scoop.entity.removeFromParent()
    }

    func presentNewItem(vessel: Vessel, delay: Double = 0) {
        selectedVessel = vessel
        launchFromIcon(vessel, duration: 0.95, delay: delay)
    }

    private func launchFromIcon(_ vessel: Vessel, duration: Double, delay: Double = 0) {
        guard let icon = vesselIcons[vessel] else { return }
        if let existing = heroes[vessel] {
            flyHeroToCenter(existing, duration: duration, delay: delay)
            replenishVesselIcon(vessel, after: delay + duration * 0.55)
            return
        }
        let rig = makeRig(vessel)
        rig.pose = iconPose(vessel)
        rig.apply()
        rig.setOpacity(0)
        heroes[vessel] = rig
        root.addChild(rig.root)
        let takeOver = { [unowned self] in
            rig.pose = iconPose(vessel)
            rig.scaleMultiplier = icon.scaleMultiplier
            rig.apply()
            rig.setOpacity(max(icon.opacity, 0.001))
            suppressVesselIcon(vessel, fade: 0)
            replenishVesselIcon(vessel, after: duration * 0.55)
        }
        if delay <= 0 { takeOver() }
        animate(delay: delay, duration: 0.14, onStart: delay > 0 ? takeOver : nil) { p in
            rig.setOpacity(max(rig.opacity, p))
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
            flyHeroHome(outgoing, duration: duration, delay: scoops.isEmpty ? 0 : 0.14)
        }
        guard let incoming = heroes[vessel] else { return }
        for (index, scoop) in scoops.enumerated() {
            flyScoop(scoop, to: incoming, duration: duration + 0.12 + Double(index) * 0.06, dip: false, spinTurns: 0,
                     midPose: "ball", arcLift: 0.16 + Float(index) * 0.03, timing: .transfer,
                     side: 0, liftDepth: 0.04)
        }
    }

    private func placementKey(for scoop: ScoopActor, on rig: ItemRig) -> (key: String, pose: String) {
        switch rig.vessel {
        case .cone:
            return (Self.slotKeys[scoop.slot - 1], "cone")
        case .cup:
            guard scoop.slot == 1 else { return (Self.slotKeys[scoop.slot - 1], "cup") }
            for other in rig.scoops where other !== scoop && other.isLanded {
                return ("1", "cup")
            }
            return ("solo", "cup_solo")
        }
    }

    private func slotWorldTransform(_ scoop: ScoopActor, on rig: ItemRig) -> Transform {
        let key = placementKey(for: scoop, on: rig).key
        let placement = assets!.placements.placement(rig.vessel, key: key)
        return Transform(matrix: rig.body.transformMatrix(relativeTo: nil) * placement.transform.matrix)
    }

    private func detachToWorld(_ scoop: ScoopActor) {
        let matrix = scoop.entity.transformMatrix(relativeTo: nil)
        root.addChild(scoop.entity)
        scoop.entity.transform = Transform(matrix: matrix)
        if let rig = scoop.rig, scoop.isLanded {
            scoop.isLanded = false
            relayoutFirstScoop(on: rig)
        }
        scoop.isLanded = false
    }

    private func flyScoop(_ scoop: ScoopActor, to rig: ItemRig, duration: Double, delay: Double = 0, dip: Bool,
                          spinTurns: Float, midPose: String?, arcLift: Float, timing: TimingCurve,
                          side: Float = 1, liftDepth: Float = 0.3, fadeIn: Bool = false) {
        scoop.cancelMotions()
        if scoop.entity.parent !== root { detachToWorld(scoop) }
        if let previous = scoop.rig, previous !== rig { previous.scoops.removeAll { $0 === scoop } }
        scoop.rig = rig
        if !rig.scoops.contains(where: { $0 === scoop }) { rig.scoops.append(scoop) }

        var start = Transform()
        var lift = SIMD3<Float>.zero
        var startedMorph = false
        scoop.motion = animate(delay: delay, duration: duration, phase: .attachments, onStart: { [unowned self] in
            start = Transform(matrix: scoop.entity.transformMatrix(relativeTo: nil))
            lift = start.translation + SIMD3<Float>(side * 0.15, arcLift, liftDepth)
            if let midPose, scoop.staticPose != midPose || scoop.morpher != nil {
                beginMorph(scoop, to: midPose)
                startedMorph = true
            }
        }) { [unowned self] p in
            let goal = slotWorldTransform(scoop, on: rig)
            let e = timing(p)
            let descent = goal.translation + SIMD3<Float>(side * 0.1, max(arcLift, 0.1) + 0.06, 0.16)
            let position = cubicBezier(start.translation, lift, descent, goal.translation, e)
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            var scale: Float
            if dip {
                let dipEnd: Float = 0.18
                scale = p < dipEnd
                    ? s0 * lerp(1, 0.9, Ease.inOutSine(p / dipEnd))
                    : lerp(s0 * 0.9, s1, TimingCurve.standard(Ease.segment(p, dipEnd, 1)))
            } else {
                scale = lerp(s0, s1, TimingCurve.standard(p))
            }
            scale = max(scale, 0.0001)
            let spin = simd_quatf(angle: spinTurns * 2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            let rotation = simd_slerp(start.rotation, goal.rotation, e) * spin
            scoop.entity.transform = Transform(scale: .init(repeating: scale), rotation: rotation, translation: position)
            if startedMorph {
                setMorphWeight(scoop, Ease.inOutSine(Ease.segment(p, 0.05, 0.5)))
            }
            if fadeIn {
                scoop.entity.setOpacity(Ease.segment(p, 0, 0.12) * 0.999 + 0.001)
            }
        } completion: { [weak self] in
            scoop.motion = nil
            self?.land(scoop, on: rig)
        }
    }

    private func land(_ scoop: ScoopActor, on rig: ItemRig) {
        let spec = placementKey(for: scoop, on: rig)
        rig.body.addChild(scoop.entity)
        scoop.entity.transform = assets!.placements.placement(rig.vessel, key: spec.key).transform
        scoop.entity.setOpacity(1)
        scoop.placementKey = spec.key
        scoop.isLanded = true

        beginMorph(scoop, to: spec.pose)
        scoop.morphTween = animate(duration: 0.18, phase: .late) { [unowned self] p in
            setMorphWeight(scoop, Ease.outCubic(p))
        } completion: { [weak self] in
            self?.endMorph(scoop)
        }
        scoop.squashTween = animate(duration: Double(Squash.duration), phase: .late) { p in
            scoop.entity.scale = Squash.scale(p * Squash.duration)
        } completion: {
            scoop.entity.scale = .one
        }
        animate(duration: 0.34) { p in
            rig.squashY = 1 - 0.028 * sin(.pi * p)
            rig.apply()
        } completion: {
            rig.squashY = 1
            rig.apply()
        }
        relayoutFirstScoop(on: rig)
    }

    private func relayoutFirstScoop(on rig: ItemRig) {
        guard rig.vessel == .cup,
              let first = rig.scoops.first(where: { $0.slot == 1 && $0.isLanded }),
              first.motion == nil
        else { return }
        let spec = placementKey(for: first, on: rig)
        guard spec.key != first.placementKey else { return }
        let from = first.entity.transform
        let to = assets!.placements.placement(rig.vessel, key: spec.key).transform
        first.placementKey = spec.key
        first.motion?.cancel()
        beginMorph(first, to: spec.pose)
        first.morphTween?.cancel()
        first.morphTween = nil
        first.motion = animate(duration: 0.32, phase: .attachments) { [unowned self] p in
            let e = Ease.inOutCubic(p)
            first.entity.transform = Transform(scale: first.entity.scale,
                                               rotation: simd_slerp(from.rotation, to.rotation, e),
                                               translation: simd_mix(from.translation, to.translation, .init(repeating: e)))
            setMorphWeight(first, e)
        } completion: { [weak self] in
            first.motion = nil
            self?.endMorph(first)
        }
    }

    func addScoop(_ flavor: Flavor) {
        guard let hero = heroes[selectedVessel], scoops.count < Pricing.maxScoopsPerItem,
              let icon = flavorIcons[flavor] else { return }
        let slot = scoops.count + 1
        let scoop = ScoopActor(flavor: flavor, slot: slot,
                               entity: makeScoopEntity(slot: slot, flavor: flavor, pose: "icon"), pose: "icon")
        let iconMatrix = icon.model.transformMatrix(relativeTo: nil)
        scoop.entity.transform = Transform(matrix: iconMatrix)
        root.addChild(scoop.entity)
        let startOpacity = icon.opacity
        scoop.entity.setOpacity(max(startOpacity, 0.001))
        scoops.append(scoop)

        suppressFlavorIcon(icon, fade: 0)
        let next = nextSlot
        for other in flavorIcons.values {
            setIconSlot(other, slot: next, animated: other !== icon)
        }
        let duration = 0.92
        replenishFlavorIcon(icon, after: duration * 0.55)
        let side: Float = flavor == .vanilla ? -1 : (flavor == .chocolate ? 1.6 : 1)
        flyScoop(scoop, to: hero, duration: duration, dip: true, spinTurns: 1, midPose: "ball",
                 arcLift: 0.2, timing: .impact, side: side, fadeIn: startOpacity < 0.99)
    }

    func removeTopScoop() {
        guard let scoop = scoops.popLast(), let icon = flavorIcons[scoop.flavor] else { return }
        suppressFlavorIcon(icon, fade: 0.12)
        for other in flavorIcons.values {
            setIconSlot(other, slot: scoop.slot, animated: other !== icon)
        }
        scoop.cancelMotions()
        if scoop.entity.parent !== root { detachToWorld(scoop) }
        scoop.rig?.scoops.removeAll { $0 === scoop }
        if let rig = scoop.rig { relayoutFirstScoop(on: rig) }
        scoop.rig = nil

        var start = Transform()
        var secondMorph = false
        let duration = 0.82
        let side: Float = scoop.flavor == .vanilla ? -1 : 1
        scoop.motion = animate(duration: duration, phase: .attachments, onStart: { [unowned self] in
            start = Transform(matrix: scoop.entity.transformMatrix(relativeTo: nil))
            beginMorph(scoop, to: "ball")
        }) { [unowned self] p in
            let goal = Transform(matrix: icon.model.transformMatrix(relativeTo: nil))
            let e = TimingCurve.flight(p)
            let s0 = (start.scale.x + start.scale.y + start.scale.z) / 3
            let s1 = (goal.scale.x + goal.scale.y + goal.scale.z) / 3
            let spin = simd_quatf(angle: -2 * .pi * Ease.inOutCubic(p), axis: [0, 1, 0])
            scoop.entity.transform = Transform(scale: .init(repeating: lerp(s0, s1, TimingCurve.standard(p))),
                                               rotation: simd_slerp(start.rotation, goal.rotation, e) * spin,
                                               translation: cubicBezier(start.translation,
                                                                        start.translation + SIMD3<Float>(side * 0.08, 0.12, 0.2),
                                                                        goal.translation + SIMD3<Float>(side * 0.14, 0.06, 0.22),
                                                                        goal.translation, e))
            if p < 0.5 {
                setMorphWeight(scoop, Ease.inOutSine(Ease.segment(p, 0, 0.32)))
            } else {
                if !secondMorph {
                    secondMorph = true
                    beginMorph(scoop, to: "icon")
                }
                setMorphWeight(scoop, Ease.inOutSine(Ease.segment(p, 0.5, 0.95)))
            }
        } completion: { [weak self] in
            guard let self else { return }
            icon.replenishTween?.cancel()
            icon.suppressed = false
            icon.scaleMultiplier = 1
            icon.applyScale()
            refreshFlavorIcon(icon, duration: 0)
            discard(scoop)
        }
    }

    private func beginMorph(_ scoop: ScoopActor, to pose: String) {
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
            scoop.entity.model?.mesh = morpher.resource
            morphing.append(scoop)
        }
        scoop.morphTo = pose
        scoop.morphWeight = 0
        scoop.morphDirty = true
    }

    private func setMorphWeight(_ scoop: ScoopActor, _ weight: Float) {
        guard scoop.morpher != nil, abs(scoop.morphWeight - weight) > 1e-5 else { return }
        scoop.morphWeight = weight
        scoop.morphDirty = true
    }

    private func endMorph(_ scoop: ScoopActor) {
        guard let assets, let morpher = scoop.morpher else { return }
        let set = assets.scoopSet(scoop.slot)
        scoop.staticPose = set.resolve(scoop.morphTo)
        scoop.entity.model?.mesh = set.staticMesh(scoop.staticPose)
        set.release(morpher)
        scoop.morpher = nil
        scoop.morphFrom = nil
        scoop.morphDirty = false
        morphing.removeAll { $0 === scoop }
    }

    private func flushMorphs() {
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

    private func contentCenterY(of item: IceCreamItem) -> Float {
        guard let assets else { return 0.05 }
        var top = assets.vesselTop(item.vessel)
        for index in item.flavors.indices {
            let slot = index + 1
            let key: String, pose: String
            if item.vessel == .cup {
                (key, pose) = item.flavors.count == 1 ? ("solo", "cup_solo") : ("\(slot)", "cup")
            } else {
                (key, pose) = ("\(slot)", "cone")
            }
            let y = assets.placements.placement(item.vessel, key: key).translation.y
            top = max(top, y + assets.scoopSet(slot).poseBounds(pose).max.y)
        }
        return top / 2
    }

    private var maxTrayScroll: CGFloat {
        guard !tray.isEmpty else { return 0 }
        let lastCenter = Layout.trayFirstCenterX + CGFloat(tray.count - 1) * Layout.trayPitch
        return max(0, lastCenter + Layout.trayPitch / 2 + 8 - Layout.trayItemsRect.maxX)
    }

    private func animateTrayScroll(to target: CGFloat, duration: Double = 0.5) {
        trayScrollTween?.cancel()
        let from = trayScroll
        guard abs(from - target) > 0.5 else {
            trayScroll = target
            return
        }
        trayScrollTween = animate(duration: duration) { [unowned self] p in
            trayScroll = from + (target - from) * CGFloat(Ease.outCubic(p))
        }
    }

    private func windowOpacity(_ x: CGFloat) -> Float {
        let fade: CGFloat = 46
        let left = (x - (Layout.trayItemsRect.minX + 30)) / fade
        let right = ((Layout.trayItemsRect.maxX - 30) - x) / fade
        return Float(min(max(min(left, right), 0), 1))
    }

    private func updateTray() {
        for entry in tray where !entry.isFlying && !entry.isRemoving {
            entry.rig.pose = trayPose(entry)
            entry.rig.apply()
            let x = Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll
            let opacity = windowOpacity(x)
            if abs(opacity - entry.lastOpacity) > 0.004 {
                entry.lastOpacity = opacity
                entry.rig.setOpacity(opacity)
            }
        }
    }

    func sendCurrentToTray(_ item: IceCreamItem) {
        guard let hero = heroes[selectedVessel] else { return }
        heroes[selectedVessel] = nil
        isDragging = false
        scoops.removeAll()
        let entry = TrayEntry(item: item, rig: hero, index: Float(tray.count), contentCenterY: contentCenterY(of: item))
        tray.append(entry)
        animateTrayScroll(to: maxTrayScroll, duration: 0.7)
        flyRig(hero, duration: 1.05, minSpin: 1.5 * .pi, dip: false, timing: .swoop,
               control: { p0, p1 in
                   SIMD3<Float>(lerp(p0.x, p1.x, 0.15) + 0.2, lerp(p0.y, p1.y, 0.3), 0.18)
               },
               target: { [unowned self] in trayPose(entry) }) {
            entry.isFlying = false
        }
    }

    func removeTrayItem(_ id: UUID) {
        guard let index = tray.firstIndex(where: { $0.id == id }) else { return }
        let entry = tray.remove(at: index)
        entry.isRemoving = true
        entry.rig.motion?.cancel()
        let startYaw = entry.rig.pose.yaw
        animate(duration: 0.3) { p in
            entry.rig.scaleMultiplier = max(0.001, 1 - Ease.inCubic(p))
            entry.rig.pose.yaw = startYaw + 2 * Ease.inCubic(p)
            entry.rig.apply()
        } completion: { [weak self] in
            self?.discard(entry.rig)
        }
        for (newIndex, other) in tray.enumerated() where other.index != Float(newIndex) {
            other.indexTween?.cancel()
            let from = other.index
            let to = Float(newIndex)
            other.indexTween = animate(delay: 0.08, duration: 0.42) { p in
                other.index = lerp(from, to, Ease.inOutCubic(p))
            }
        }
        animateTrayScroll(to: min(trayScroll, maxTrayScroll), duration: 0.45)
    }

    func trayDragChanged(_ dx: CGFloat) {
        if trayDragStart == nil {
            trayDragStart = trayScroll
            trayScrollTween?.cancel()
        }
        let raw = (trayDragStart ?? 0) - dx
        let limit = maxTrayScroll
        if raw < 0 {
            trayScroll = -rubberBand(-raw)
        } else if raw > limit {
            trayScroll = limit + rubberBand(raw - limit)
        } else {
            trayScroll = raw
        }
    }

    func trayDragEnded(predictedDx: CGFloat) {
        let target = min(max((trayDragStart ?? trayScroll) - predictedDx, 0), maxTrayScroll)
        trayDragStart = nil
        animateTrayScroll(to: target, duration: 0.5)
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat { 60 * (1 - 1 / (x / 120 + 1)) }

    func trayItem(at point: CGPoint) -> UUID? {
        guard Layout.trayItemsRect.contains(point) else { return nil }
        for entry in tray where !entry.isRemoving {
            let x = Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll
            if abs(point.x - x) < Layout.trayPitch / 2, windowOpacity(x) > 0.5 { return entry.id }
        }
        return nil
    }

    func trayItemCenter(_ id: UUID) -> CGPoint? {
        guard let entry = tray.first(where: { $0.id == id }) else { return nil }
        return CGPoint(x: Layout.trayFirstCenterX + CGFloat(entry.index) * Layout.trayPitch - trayScroll,
                       y: Layout.trayCenterY)
    }

    func reset() {
        for tween in tweens { tween.cancel() }
        tweens.removeAll()
        for rig in heroes.values { discard(rig) }
        heroes.removeAll()
        for scoop in scoops { discard(scoop) }
        scoops.removeAll()
        for entry in tray { discard(entry.rig) }
        tray.removeAll()
        trayScroll = 0
        trayDragStart = nil
        isDragging = false
        selectedVessel = .cup
        for vessel in Vessel.allCases {
            vesselIconSuppressed[vessel] = false
            vesselIcons[vessel]?.scaleMultiplier = 1
            vesselIcons[vessel]?.apply()
        }
        for icon in flavorIcons.values {
            icon.suppressed = false
            icon.scaleMultiplier = 1
            icon.applyScale()
        }
        setStep(.vessel, animated: false)
    }

    func restore(current: IceCreamItem?, items: [IceCreamItem], step: BuilderStep) {
        reset()
        for item in items {
            let rig = makeItemRig(item)
            let entry = TrayEntry(item: item, rig: rig, index: Float(tray.count), contentCenterY: contentCenterY(of: item))
            entry.isFlying = false
            tray.append(entry)
            root.addChild(rig.root)
        }
        trayScroll = maxTrayScroll
        if let current {
            selectedVessel = current.vessel
            let rig = makeItemRig(current)
            rig.pose = centerPose(current.vessel, yaw: 0.4)
            rig.apply()
            heroes[current.vessel] = rig
            scoops = rig.scoops
            root.addChild(rig.root)
            releaseTime = now - 2
            yawVelocity = Self.baseSpin
        }
        setStep(step, animated: false)
        updateTray()
    }

    private func makeItemRig(_ item: IceCreamItem) -> ItemRig {
        let rig = makeRig(item.vessel)
        for (index, flavor) in item.flavors.enumerated() {
            let slot = index + 1
            let scoop = ScoopActor(flavor: flavor, slot: slot,
                                   entity: makeScoopEntity(slot: slot, flavor: flavor, pose: "icon"), pose: "icon")
            scoop.rig = rig
            rig.scoops.append(scoop)
        }
        for scoop in rig.scoops {
            scoop.isLanded = true
        }
        for scoop in rig.scoops {
            let spec = placementKey(for: scoop, on: rig)
            scoop.placementKey = spec.key
            scoop.staticPose = assets!.scoopSet(scoop.slot).resolve(spec.pose)
            scoop.entity.model?.mesh = assets!.scoopSet(scoop.slot).staticMesh(scoop.staticPose)
            scoop.entity.transform = assets!.placements.placement(item.vessel, key: spec.key).transform
            rig.body.addChild(scoop.entity)
        }
        return rig
    }

    struct DebugMarker: Identifiable {
        let id: String
        let expected: CGPoint
        let actual: CGPoint
    }

    func debugMarkers() -> [DebugMarker] {
        var markers: [DebugMarker] = []
        for vessel in Vessel.allCases {
            if let rig = vesselIcons[vessel] {
                markers.append(DebugMarker(id: "icon-\(vessel.rawValue)", expected: Layout.vesselIconCenter(vessel),
                                           actual: screen(rig.root.position(relativeTo: nil))))
            }
            if let hero = heroes[vessel] {
                markers.append(DebugMarker(id: "hero-\(vessel.rawValue)", expected: Layout.mainPivot(vessel),
                                           actual: screen(hero.root.position(relativeTo: nil))))
            }
        }
        for (flavor, icon) in flavorIcons {
            markers.append(DebugMarker(id: "flavor-\(flavor.rawValue)", expected: Layout.flavorIconCenter(flavor),
                                       actual: screen(icon.holder.position(relativeTo: nil))))
        }
        return markers
    }
}
