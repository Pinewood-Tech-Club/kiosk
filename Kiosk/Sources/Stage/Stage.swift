import QuartzCore
import RealityKit
import SwiftUI

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

struct ScoopModelKey: Hashable {
    let slot: Int
    let flavor: Flavor
}

enum CardKey: Hashable {
    case vessel(Vessel)
    case flavor(Flavor)
}

/// Owns every 3D entity (main item, selector icons, flying entities, tray and summary minis) and drives
/// them from a deterministic per-frame timeline. Not observable: SwiftUI never re-renders because of it.
@MainActor
final class Stage {
    static let preferredPitch: Float = 0.30
    static let baseSpin: Float = 0.42
    static let fieldOfView: Float = 24
    static let pressScale: Float = 0.94
    static let pressDepth: Float = 3
    static let pressResponse: Float = 0.32
    static let pressDamping: Float = 0.72
    static let tweenPhases: [Tween.Phase] = [.rigs, .attachments, .late]
    static let slotKeys = ["1", "2", "3"]
    static let coneIconRoll: Float = -1.368

    let root = Entity()
    let stats = FrameStats()
    var timeScale: Double = 1
    var log: (String) -> Void = { _ in }
    var logsHitches = false
    var onLayoutChange: () -> Void = {}

    var assets: AssetLibrary?
    var isBuilt = false
    var now: Double = 0
    var selectedVessel: Vessel = .cup

    let camera = Entity()
    let iblEntity = Entity()
    var subscription: EventSubscription?
    /// The RealityView renders the full portrait screen; GeometryReader reports a slightly different
    /// frame for it (offset by the hidden status bar area), which doesn't match the drawable.
    let viewFrame = CGRect(origin: .zero, size: Layout.screen)
    var tweens: [Tween] = []
    var shadowMesh: MeshResource?
    var morphing: [ScoopActor] = []
    var contactLift: [String: Float] = [:]
    var scoopModelPool: [ScoopModelKey: [ModelEntity]] = [:]

    var vesselIcons: [Vessel: ItemRig] = [:]
    var vesselIconAppear: [Vessel: Float] = [.cup: 1, .cone: 1]
    var vesselIconAppearTweens: [Vessel: Tween] = [:]
    var flavorIcons: [Flavor: FlavorIcon] = [:]
    var pressSprings = [Spring1D](repeating: Spring1D(value: 0, response: Stage.pressResponse, dampingRatio: Stage.pressDamping), count: 5)
    var vesselIconTarget: [Vessel: Float] = [.cup: 0, .cone: 0]
    var heroes: [Vessel: ItemRig] = [:]
    var scoops: [ScoopActor] = []
    var tray: [TrayEntry] = []
    var step: BuilderStep = .vessel
    var controlsVisible = true

    var warmup: Entity?
    var warmupFrames = 0

    var yawVelocity: Float = 0
    var isDragging = false
    var releaseTime: Double = -10
    var dragStartYaw: Float = 0
    var dragStartPitch: Float = 0
    var lastDragSample: (time: Double, yaw: Float) = (0, 0)
    var pitchReturnFrom: Float = preferredPitch
    var pitchReturnDuration: Double = 0

    var trayScroll: CGFloat = 0
    var trayScrollTween: Tween?
    var trayDragStart: CGFloat?
    var summaryActive = false
    var summaryScroll: CGFloat = 0
    /// Interactive pull-down offset of the order sheet, as a spring matching the SwiftUI one.
    var summaryDrag = Spring1D(value: 0, response: 0.36, dampingRatio: 0.86)
    /// Screen frames of the confirmation receipt's 3D cells, and the visible part of the receipt's list.
    var receiptFrames: [UUID: CGRect] = [:]
    var receiptClip: CGRect = .zero

    func attach(to content: inout RealityViewCameraContent) {
        content.add(root)
        subscription = content.subscribe(to: SceneEvents.Update.self, on: nil, componentType: nil) { [weak self] event in
            self?.tick(realDelta: event.deltaTime)
        }
    }

    var cameraDistance: Float {
        Float(viewFrame.height) * 0.001 / 2 / tan(Self.fieldOfView * .pi / 360)
    }

    func world(_ point: CGPoint, z: Float = 0) -> SIMD3<Float> {
        let depthScale = (cameraDistance - z) / cameraDistance
        return [Float(point.x - viewFrame.midX) * 0.001 * depthScale,
                Float(viewFrame.midY - point.y) * 0.001 * depthScale,
                z]
    }

    func screen(_ position: SIMD3<Float>) -> CGPoint {
        let depthScale = (cameraDistance - position.z) / cameraDistance
        return CGPoint(x: CGFloat(position.x / depthScale / 0.001) + viewFrame.midX,
                       y: viewFrame.midY - CGFloat(position.y / depthScale / 0.001))
    }

    func build(with assets: AssetLibrary) {
        guard !isBuilt else { return }
        self.assets = assets
        contactLift = assets.contactLift
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
            root.addChild(rig.root)
        }
        for flavor in Flavor.allCases {
            let icon = makeFlavorIcon(flavor)
            flavorIcons[flavor] = icon
            root.addChild(icon.holder)
        }
        fillScoopModelPool()
        buildWarmup()
        isBuilt = true
        setStep(.vessel, animated: false)
        updateIcons()
        log("Contact lifts (mm): " + contactLift.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(String(format: "%.1f", $0.value * 1000))" }.joined(separator: " "))
        log(approachReport())
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

    func applyLighting(_ entity: Entity) {
        if assets?.environment != nil {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
        }
        for child in entity.children { applyLighting(child) }
    }

    /// Renders every material, mesh and blend mode once behind the opaque launch screens, so shader
    /// compilation and first-use uploads never land on a customer's first tap.
    private func buildWarmup() {
        guard let assets else { return }
        let group = Entity()
        var x: Float = -0.4
        for slot in 1...3 {
            for flavor in Flavor.allCases {
                let meshes = [assets.scoopSet(slot).staticMesh("ball")] + assets.scoopSet(slot).allMorpherResources.prefix(1)
                for mesh in meshes {
                    for translucent in [false, true] {
                        let entity = ModelEntity(mesh: mesh, materials: [assets.material(slot: slot, flavor: flavor)])
                        applyLighting(entity)
                        entity.position = [x, translucent ? -0.1 : 0.1, 0]
                        if translucent { entity.setOpacity(0.5) }
                        group.addChild(entity)
                    }
                }
                x += 0.09
            }
        }
        for vessel in Vessel.allCases {
            for translucent in [false, true] {
                let rig = makeRig(vessel)
                rig.pose = RigPose(position: [vessel == .cup ? -0.2 : 0.2, translucent ? -0.3 : 0.3, 0], scale: 1,
                                   pitch: 0.3, roll: vessel == .cone ? -0.6 : 0, yaw: 0)
                rig.apply()
                if translucent { rig.setOpacity(0.5) }
                group.addChild(rig.root)
            }
        }
        // Tiny and tucked under the debug-bar corner: it only has to be drawn, not seen.
        group.scale = .init(repeating: 0.04)
        group.position = world(CGPoint(x: 1010, y: 12))
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

        stepPresses(Float(min(realDelta, 0.1)))
        updateHeroSpin(Float(dt))
        for phase in Self.tweenPhases {
            for tween in tweens where tween.phase == phase {
                tween.step(now: now)
            }
        }
        tweens.removeAll { $0.isFinished }
        updateIcons()
        updateTray(dt: Float(dt))
        flushMorphs()

        stats.record(frame: realDelta, cpu: CACurrentMediaTime() - started)
        if logsHitches, realDelta > 0.05, realDelta < 0.9 {
            log(String(format: "Frame hitch %.0f ms (tweens %d, morphing %d)", realDelta * 1000, tweens.count, morphing.count))
        }
    }

    @discardableResult
    func animate(delay: Double = 0, duration: Double, phase: Tween.Phase = .rigs,
                 onStart: (() -> Void)? = nil,
                 _ update: @escaping (Float) -> Void,
                 completion: (() -> Void)? = nil) -> Tween {
        let tween = Tween(start: now + delay, duration: duration, phase: phase, onStart: onStart, update: update, completion: completion)
        tweens.append(tween)
        return tween
    }

    var activeAnimationCount: Int { tweens.count }
    var morphingCount: Int { morphing.count }

    static func mainScale(_ vessel: Vessel) -> Float { vessel == .cup ? 3.9 : 2.35 }
    static func iconScale(_ vessel: Vessel) -> Float { vessel == .cup ? 1.75 : 1.18 }
    static let flavorIconScale: Float = 2.1

    func centerPose(_ vessel: Vessel, yaw: Float) -> RigPose {
        RigPose(position: world(Layout.mainPivot(vessel)), scale: Self.mainScale(vessel), pitch: Self.preferredPitch, yaw: yaw)
    }

    func iconRestPose(_ vessel: Vessel) -> RigPose {
        switch vessel {
        case .cup:
            RigPose(position: world(Layout.vesselIconCenter(vessel)), scale: Self.iconScale(vessel), pitch: 0.34, yaw: 0.6)
        case .cone:
            RigPose(position: world(Layout.vesselIconCenter(vessel)), scale: Self.iconScale(vessel), pitch: 0.42,
                    roll: Self.coneIconRoll, yaw: 0.35)
        }
    }

    /// The icon's pose including the card's current press, i.e. where a flight must start or land.
    func iconPose(_ vessel: Vessel) -> RigPose {
        var pose = iconRestPose(vessel)
        let (position, scale) = pressed(pose.position, card: .vessel(vessel), center: Layout.vesselCardCenter(vessel))
        pose.position = position
        pose.scale *= scale
        return pose
    }

    func pressed(_ position: SIMD3<Float>, card: CardKey, center: CGPoint) -> (SIMD3<Float>, Float) {
        let amount = pressSprings[Self.pressIndex(card)].value
        let scale = 1 - (1 - Self.pressScale) * amount
        let c = world(center)
        var p = c + (position - c) * scale
        p.y -= Self.pressDepth * 0.001 * amount
        return (p, scale)
    }

    func makeShadow(width: Float, depth: Float, y: Float) -> ModelEntity? {
        guard let assets, let shadowMesh else { return nil }
        let shadow = ModelEntity(mesh: shadowMesh, materials: [assets.shadowMaterial])
        shadow.scale = [width, 1, depth]
        shadow.position.y = y
        shadow.components.set(DynamicLightShadowComponent(castsShadow: false))
        return shadow
    }

    func makeRig(_ vessel: Vessel) -> ItemRig {
        let assets = assets!
        let model = assets.vessels[vessel]!.clone(recursive: true)
        applyLighting(model)
        let pivot = assets.vesselPivot(vessel)
        let rig: ItemRig
        switch vessel {
        case .cup:
            rig = ItemRig(vessel: vessel, model: model, baseShadow: makeShadow(width: 0.15, depth: 0.15, y: -0.0012),
                          floorShadow: nil, floorShadowFullRoll: 0, pivot: pivot,
                          pose: RigPose(position: .zero, scale: 1, pitch: Self.preferredPitch, yaw: 0))
        case .cone:
            let radius = assets.vesselRadius(vessel, atHeight: pivot.y)
            rig = ItemRig(vessel: vessel, model: model, baseShadow: nil,
                          floorShadow: makeShadow(width: 0.17, depth: 0.06, y: -radius - 0.0015),
                          floorShadowFullRoll: Self.coneIconRoll, pivot: pivot,
                          pose: RigPose(position: .zero, scale: 1, pitch: Self.preferredPitch, yaw: 0))
        }
        return rig
    }

    /// Scoop models come from a pool filled at launch, so a tap never allocates entities or components.
    func makeScoopModel(slot: Int, flavor: Flavor, pose: String) -> ModelEntity {
        let assets = assets!
        let key = ScoopModelKey(slot: slot, flavor: flavor)
        let mesh = assets.scoopSet(slot).staticMesh(pose)
        if let entity = scoopModelPool[key]?.popLast() {
            entity.model?.mesh = mesh
            entity.transform = Transform()
            entity.setOpacity(1)
            return entity
        }
        let entity = ModelEntity(mesh: mesh, materials: [assets.material(slot: slot, flavor: flavor)])
        applyLighting(entity)
        return entity
    }

    func recycleScoopModel(_ entity: ModelEntity, slot: Int, flavor: Flavor) {
        entity.removeFromParent()
        entity.setOpacity(1)
        entity.components.remove(ModelSortGroupComponent.self)
        scoopModelPool[ScoopModelKey(slot: slot, flavor: flavor), default: []].append(entity)
    }

    func fillScoopModelPool() {
        guard let assets else { return }
        for slot in 1...3 {
            for flavor in Flavor.allCases {
                var entities: [ModelEntity] = []
                for _ in 0..<4 {
                    let entity = ModelEntity(mesh: assets.scoopSet(slot).staticMesh("icon"),
                                             materials: [assets.material(slot: slot, flavor: flavor)])
                    applyLighting(entity)
                    entities.append(entity)
                }
                scoopModelPool[ScoopModelKey(slot: slot, flavor: flavor)] = entities
            }
        }
    }

    func iconCenter(slot: Int) -> SIMD3<Float> {
        let bounds = assets!.scoopSet(slot).poseBounds("icon")
        return (bounds.min + bounds.max) / 2
    }

    private func makeFlavorIcon(_ flavor: Flavor) -> FlavorIcon {
        let model = makeScoopModel(slot: 1, flavor: flavor, pose: "icon")
        let center = iconCenter(slot: 1)
        model.position = -center
        let shadow = makeShadow(width: 0.1, depth: 0.1, y: -center.y - 0.0008) ?? ModelEntity()
        let icon = FlavorIcon(flavor: flavor, model: model, shadow: shadow)
        icon.baseScale = Self.flavorIconScale
        icon.restPosition = world(Layout.flavorIconCenter(flavor))
        icon.restOrientation = simd_quatf(angle: 0.36, axis: [1, 0, 0]) * simd_quatf(angle: -0.25, axis: [0, 1, 0])
        icon.setOpacity(0)
        return icon
    }

    /// Screen y of the top of a ball waiting above each slot, which must stay below the header.
    func approachReport() -> String {
        guard let assets else { return "" }
        var parts: [String] = []
        for vessel in Vessel.allCases {
            let center = centerPose(vessel, yaw: 0)
            let pivot = assets.vesselPivot(vessel)
            for slot in 1...3 {
                let key = placementKey(index: slot - 1, count: slot, vessel: vessel)
                let base = assets.placements.placement(vessel, key: key).translation.y + liftHeight(vessel, key: key) + Self.approachClearance
                let top = base + 0.0438
                let tilt = cos(center.pitch)
                let y = center.position.y + (top - pivot.y) * center.scale * tilt
                let topY = Int(screen([0, y, 0]).y)
                let speed = Self.pressStartSlope * (liftHeight(vessel, key: key) + Self.approachClearance) / Float(Self.pressDuration) * center.scale
                let needed = Int(speed * 0.62 / (3 * Self.maxArrivalSlope) * 1000)
                parts.append("\(vessel.rawValue)\(slot)=\(topY) (room \(topY - Int(Self.flightCeilingY)), wants \(needed))")
            }
        }
        return "Approach ball tops (screen y, header ends at \(Int(Self.flightCeilingY))): " + parts.joined(separator: " ")
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
