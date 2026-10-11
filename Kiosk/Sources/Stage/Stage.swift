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
    var morphing: [ScoopActor] = []
    var contactLift: [String: Float] = [:]
    var scoopModelPool: [ScoopModelKey: [ModelEntity]] = [:]

    var vesselIcons: [Vessel: ItemRig] = [:]
    var vesselIconAppear: [Vessel: Float] = [.cup: 1, .cone: 1]
    var vesselIconAppearTweens: [Vessel: Tween] = [:]
    /// Step visibility of the card icons, as a scale: models are never faded.
    var iconShown: [CardKey: Float] = [:]
    var iconShownTweens: [CardKey: Tween] = [:]
    var iconShownTargets: [CardKey: Float] = [:]
    var flavorIcons: [Flavor: FlavorIcon] = [:]
    var pressSprings = [Spring1D](repeating: Spring1D(value: 0, response: Stage.pressResponse, dampingRatio: Stage.pressDamping), count: 5)
    var vesselIconTarget: [Vessel: Float] = [.cup: 0, .cone: 0]
    var heroes: [Vessel: ItemRig] = [:]
    var scoops: [ScoopActor] = []
    /// Every scoop that hasn't been discarded, wherever it is.
    var liveScoops: [ObjectIdentifier: ScoopActor] = [:]
    /// Projected extents of each vessel with 0–3 scoops, for framing the item at the center.
    var contentExtents: [String: ContentExtents] = [:]
    var tray: [TrayEntry] = []
    let trayTiles = TrayTileModel()
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
        measureContent()

        configureScene(root: root, camera: camera, ibl: iblEntity)

        for vessel in Vessel.allCases {
            let rig = makeRig(vessel)
            rig.pose = iconPose(vessel)
            rig.apply()
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
        log(framingReport())
        log(approachReport())
    }

    private func configureScene(root: Entity, camera: Entity, ibl: Entity) {
        camera.components.set(PerspectiveCameraComponent(near: 0.5, far: 12, fieldOfViewInDegrees: Self.fieldOfView,
                                                         fieldOfViewOrientation: .vertical))
        camera.position = [0, 0, cameraDistance]
        root.addChild(camera)
        if let environment = assets?.environment {
            var component = ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.35)
            component.inheritsRotation = true
            ibl.components.set(component)
            ibl.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        }
        root.addChild(ibl)
        for (intensity, position) in [(Float(2400), SIMD3<Float>(-1.3, 1.6, 2.2)),
                                      (700, [1.9, 0.35, 1.4]),
                                      (1500, [0.35, 1.5, -2.2])] {
            let light = Entity()
            light.components.set(DirectionalLightComponent(color: .white, intensity: intensity))
            light.look(at: .zero, from: position, relativeTo: nil)
            root.addChild(light)
        }
    }

    func applyLighting(_ entity: Entity, ibl: Entity? = nil) {
        if assets?.environment != nil {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl ?? iblEntity))
        }
        for child in entity.children { applyLighting(child, ibl: ibl) }
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
                    let entity = ModelEntity(mesh: mesh, materials: [assets.material(slot: slot, flavor: flavor)])
                    applyLighting(entity)
                    entity.position = [x, 0.1, 0]
                    group.addChild(entity)
                }
                x += 0.09
            }
        }
        for vessel in Vessel.allCases {
            let rig = makeRig(vessel)
            rig.pose = RigPose(position: [vessel == .cup ? -0.2 : 0.2, 0.3, 0], scale: 1,
                               pitch: 0.3, roll: vessel == .cone ? -0.6 : 0, yaw: 0)
            rig.apply()
            group.addChild(rig.root)
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

    static func maxHeroScale(_ vessel: Vessel) -> Float { vessel == .cup ? 3.8 : 2.9 }
    static func iconScale(_ vessel: Vessel) -> Float { vessel == .cup ? 1.5 : 1.02 }
    static let flavorIconScale: Float = 1.82

    func centerPose(_ rig: ItemRig, yaw: Float) -> RigPose {
        let framing = rig.framing ?? heroFraming(rig.vessel, count: rig.scoops.count)
        return RigPose(position: framing.position, scale: framing.scale, pitch: Self.preferredPitch, yaw: yaw)
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

    func makeRig(_ vessel: Vessel, ibl: Entity? = nil) -> ItemRig {
        let assets = assets!
        let model = assets.vessels[vessel]!.clone(recursive: true)
        applyLighting(model, ibl: ibl)
        return ItemRig(vessel: vessel, model: model, pivot: assets.vesselPivot(vessel),
                       pose: RigPose(position: .zero, scale: 1, pitch: Self.preferredPitch, yaw: 0))
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
        let key = ScoopModelKey(slot: slot, flavor: flavor)
        guard scoopModelPool[key]?.contains(where: { $0 === entity }) != true else { return }
        entity.removeFromParent()
        entity.setOpacity(1)
        entity.components.remove(ModelSortGroupComponent.self)
        scoopModelPool[key, default: []].append(entity)
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
        model.position = -iconCenter(slot: 1)
        let icon = FlavorIcon(flavor: flavor, model: model)
        icon.baseScale = Self.flavorIconScale
        icon.restPosition = world(Layout.flavorIconCenter(flavor))
        icon.restOrientation = simd_quatf(angle: 0.36, axis: [1, 0, 0]) * simd_quatf(angle: -0.25, axis: [0, 1, 0])
        return icon
    }

    /// Screen y of the top of a ball waiting above each slot, which must stay below the header.
    func approachReport() -> String {
        guard let assets else { return "" }
        var parts: [String] = []
        for vessel in Vessel.allCases {
            let pivot = assets.vesselPivot(vessel)
            for slot in 1...3 {
                let framing = heroFraming(vessel, count: slot)
                let center = RigPose(position: framing.position, scale: framing.scale, pitch: Self.preferredPitch, yaw: 0)
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
                markers.append(DebugMarker(id: "hero-\(vessel.rawValue)", expected: screen(centerPose(hero, yaw: 0).position),
                                           actual: screen(hero.root.position(relativeTo: nil))))
            }
        }
        for (flavor, icon) in flavorIcons {
            markers.append(DebugMarker(id: "flavor-\(flavor.rawValue)", expected: Layout.flavorIconCenter(flavor),
                                       actual: screen(icon.holder.position(relativeTo: nil))))
        }
        return markers
    }

    struct ContentExtents {
        var yMin: Float
        var yMax: Float
        var xHalf: Float
        /// Top of the newest scoop's ball while it waits above its slot to settle.
        var yApproach: Float = -.infinity
    }

    /// Measures the vessel plus its placed scoops, as seen at the hero's pitch from any yaw, relative to the pivot.
    private func measureContent() {
        guard let assets else { return }
        let yaws = (0..<12).map { Float($0) / 12 * 2 * .pi }
        let pitch = Self.preferredPitch
        for vessel in Vessel.allCases {
            let pivot = assets.vesselPivot(vessel)
            var points = assets.vesselSamplePoints(vessel, limit: 6000)
            for count in 0...3 {
                if count > 0 {
                    points = assets.vesselSamplePoints(vessel, limit: 6000)
                    for index in 0..<count {
                        let key = placementKey(index: index, count: count, vessel: vessel)
                        let placement = assets.placements.placement(vessel, key: key)
                        let pose = finalPoseName(vessel, key: key)
                        points += assets.scoopSet(index + 1).data.positions(assets.scoopSet(index + 1).resolve(pose), stride: 8)
                            .map { placement.rotation.act($0) + placement.translation }
                    }
                }
                var ball: [SIMD3<Float>] = []
                if count > 0 {
                    let key = placementKey(index: count - 1, count: count, vessel: vessel)
                    let w = Self.preSquish
                    let slot = slotLocal(vessel, key: key, height: liftHeight(vessel, key: key) * (1 - w) + Self.approachClearance)
                    let set = assets.scoopSet(count)
                    let round = set.data.positions("ball", stride: 8)
                    let placed = set.data.positions(set.resolve(finalPoseName(vessel, key: key)), stride: 8)
                    ball = zip(round, placed).map { slot.rotation.act($0 * (1 - w) + $1 * w) + slot.translation }
                }
                var extents = ContentExtents(yMin: .infinity, yMax: -.infinity, xHalf: 0)
                for yaw in yaws {
                    let c = cos(yaw), s = sin(yaw)
                    func project(_ p: SIMD3<Float>) -> (x: Float, y: Float) {
                        let z = -s * p.x + c * p.z
                        return (c * p.x + s * p.z, (p.y - pivot.y) * cos(pitch) - z * sin(pitch))
                    }
                    for p in points {
                        let (x, y) = project(p)
                        extents.yMin = min(extents.yMin, y)
                        extents.yMax = max(extents.yMax, y)
                        extents.xHalf = max(extents.xHalf, abs(x))
                    }
                    for p in ball { extents.yApproach = max(extents.yApproach, project(p).y) }
                }
                contentExtents["\(vessel.rawValue)\(count)"] = extents
            }
        }
    }

    /// Fits the item into the band between the title and the cards, centered, never larger than the vessel's
    /// hero scale. While a new scoop is arriving, the band also has to hold the ball waiting above its slot, so
    /// the item eases back a little and settles in again once the scoop has landed.
    func heroFraming(_ vessel: Vessel, count: Int, arriving: Bool = false) -> Framing {
        let band = Layout.heroBand
        guard let e = contentExtents["\(vessel.rawValue)\(min(count, 3))"] else {
            return Framing(position: world(CGPoint(x: band.midX, y: band.midY)), scale: Self.maxHeroScale(vessel))
        }
        let tightScale = min(Self.maxHeroScale(vessel), Float(band.height) * 0.001 / (e.yMax - e.yMin),
                             Float(band.width) * 0.001 / (2 * e.xHalf))
        var position = world(CGPoint(x: band.midX, y: band.midY))
        position.y -= (e.yMin + e.yMax) / 2 * tightScale
        guard arriving, e.yApproach > e.yMax else { return Framing(position: position, scale: tightScale) }
        // Keep the vessel's base where it is when there's room; only pull back as far as the ball needs.
        let bottom = world(CGPoint(x: band.midX, y: band.maxY)).y
        let top = world(CGPoint(x: band.midX, y: Self.flightCeilingY)).y
        let base = position.y + e.yMin * tightScale
        let scale = min(tightScale, (top - base) / (e.yApproach - e.yMin), (top - bottom) / (e.yApproach - e.yMin))
        let lowest = max(bottom, base)
        return Framing(position: [position.x, lowest - e.yMin * scale, position.z], scale: scale)
    }

    /// Eases the hero to the framing for its current scoop count.
    func reframe(_ rig: ItemRig, animated: Bool = true) {
        let target = heroFraming(rig.vessel, count: rig.scoops.count, arriving: rig.scoops.contains { $0.isArriving })
        guard target != rig.framingTarget || rig.framing == nil else { return }
        rig.framingTarget = target
        rig.framingTween?.cancel()
        rig.framingTween = nil
        guard animated, let from = rig.framing else {
            rig.framing = target
            return
        }
        rig.framingTween = animate(duration: 0.6) { p in
            let e = TimingCurve.swiftUIEaseInOut(p)
            rig.framing = Framing(position: simd_mix(from.position, target.position, .init(repeating: e)),
                                  scale: lerp(from.scale, target.scale, e))
        } completion: {
            rig.framingTween = nil
        }
    }

    func framingReport() -> String {
        var parts: [String] = []
        for vessel in Vessel.allCases {
            for count in 0...3 {
                let f = heroFraming(vessel, count: count)
                let a = heroFraming(vessel, count: count, arriving: true)
                guard let e = contentExtents["\(vessel.rawValue)\(count)"] else { continue }
                let top = screen(f.position + [0, e.yMax * f.scale, 0]).y
                let bottom = screen(f.position + [0, e.yMin * f.scale, 0]).y
                let ball = count > 0 ? screen(a.position + [0, e.yApproach * a.scale, 0]).y : 0
                parts.append(String(format: "%@%d scale %.2f y %.0f-%.0f (arriving %.2f, ball top %.0f)",
                                    vessel.rawValue, count, f.scale, top, bottom, a.scale, ball))
            }
        }
        return "Hero framing: " + parts.joined(separator: ", ")
    }
}
