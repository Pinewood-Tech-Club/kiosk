import RealityKit
import UIKit

struct RigPose {
    var position: SIMD3<Float>
    var scale: Float
    var pitch: Float
    var roll: Float = 0
    var yaw: Float
}

extension Entity {
    /// While translucent, the subtree gets a depth pre-pass so a fade reads as a flat layer instead of
    /// revealing the model's own back faces. The pre-pass costs an extra geometry pass, so it is only
    /// present during fades.
    func setOpacity(_ value: Float) {
        let wasTranslucent = components.has(OpacityComponent.self)
        if value >= 0.999 {
            components.remove(OpacityComponent.self)
            if wasTranslucent { setDepthPrePass(false) }
        } else {
            components.set(OpacityComponent(opacity: max(value, 0)))
            if !wasTranslucent { setDepthPrePass(true) }
        }
        isEnabled = value > 0.002
    }

    func setDepthPrePass(_ enabled: Bool) {
        let group = ModelSortGroup(depthPass: .prePass)
        func visit(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                if enabled {
                    entity.components.set(ModelSortGroupComponent(group: group, order: 0))
                } else {
                    entity.components.remove(ModelSortGroupComponent.self)
                }
            }
            for child in entity.children { visit(child) }
        }
        visit(self)
    }
}

/// A vessel with its scoops.
/// root (position, scale) → floor (pitch) → rolled (roll) → spun (yaw) → body (−pivot).
@MainActor
final class ItemRig {
    let vessel: Vessel
    let root = Entity()
    let floor = Entity()
    let rolled = Entity()
    let spun = Entity()
    let body = Entity()
    let pivot: SIMD3<Float>
    let floorShadow: ModelEntity?
    let floorShadowFullRoll: Float
    private let floorShadowScale: SIMD3<Float>
    var pose: RigPose
    var scaleMultiplier: Float = 1
    var scoops: [ScoopActor] = []
    var motion: Tween?
    var appearTween: Tween?
    var opacityTween: Tween?
    private(set) var opacity: Float = 1
    private var shownShadowOpacity: Float = -1
    private var shownBaseShadow: Float = -1
    let baseShadow: ModelEntity?
    private let baseShadowScale: SIMD3<Float>
    /// 1 while the item rests on a surface, 0 in the air: its contact shadows shrink and grow with it.
    var grounded: Float = 1
    /// Scales the model but not its contact shadows (card icons hide this way while their shadow fades).
    var modelScale: Float = 1

    init(vessel: Vessel, model: Entity, baseShadow: ModelEntity?, floorShadow: ModelEntity?, floorShadowFullRoll: Float,
         pivot: SIMD3<Float>, pose: RigPose) {
        self.vessel = vessel
        self.pivot = pivot
        self.pose = pose
        self.floorShadow = floorShadow
        self.floorShadowScale = floorShadow?.scale ?? .one
        self.baseShadow = baseShadow
        self.baseShadowScale = baseShadow?.scale ?? .one
        self.floorShadowFullRoll = floorShadowFullRoll
        root.name = "rig-\(vessel.rawValue)"
        root.addChild(floor)
        floor.addChild(rolled)
        if let floorShadow { floor.addChild(floorShadow) }
        rolled.addChild(spun)
        spun.addChild(body)
        body.position = -pivot
        body.addChild(model)
        if let baseShadow {
            // Under `floor` rather than the spinning body, so the model can be scaled separately from it.
            baseShadow.position.y -= pivot.y
            floor.addChild(baseShadow)
        }
        apply()
    }

    func apply() {
        root.position = pose.position
        root.scale = .init(repeating: max(pose.scale * scaleMultiplier, 1e-5))
        floor.orientation = simd_quatf(angle: pose.pitch, axis: [1, 0, 0])
        rolled.orientation = simd_quatf(angle: pose.roll, axis: [0, 0, 1])
        rolled.scale = .init(repeating: max(modelScale, 1e-5))
        rolled.isEnabled = modelScale > 0.001
        spun.orientation = simd_quatf(angle: pose.yaw, axis: [0, 1, 0])
        if let floorShadow, floorShadowFullRoll != 0 {
            let amount = min(Ease.clamp01(abs(pose.roll) / abs(floorShadowFullRoll)), grounded)
            if abs(amount - shownShadowOpacity) > 0.004 {
                shownShadowOpacity = amount
                floorShadow.scale = floorShadowScale * max(amount, 1e-4)
                floorShadow.isEnabled = amount > 0.002
            }
        }
        if let baseShadow, abs(grounded - shownBaseShadow) > 0.004 {
            shownBaseShadow = grounded
            baseShadow.scale = baseShadowScale * max(grounded, 1e-4)
            baseShadow.isEnabled = grounded > 0.002
        }
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        root.setOpacity(value)
    }

    func cancelMotions() {
        motion?.cancel()
        appearTween?.cancel()
        opacityTween?.cancel()
    }
}

/// One scoop. Flights move `root`; `model` is its child.
@MainActor
final class ScoopActor {
    enum State { case flying, pressing, landed, leaving }

    let flavor: Flavor
    var slot: Int
    let root = Entity()
    var model: ModelEntity
    var staticPose: String
    var morpher: ScoopMorpher?
    var morphFrom: PoseRef?
    var morphTo = ""
    var morphWeight: Float = 0
    var morphDirty = false
    var motion: Tween?
    var relayout: Tween?
    weak var rig: ItemRig?
    var placementKey = "1"
    var state: State = .flying
    var pressHeight: Float = 0

    init(flavor: Flavor, slot: Int, model: ModelEntity, pose: String) {
        self.flavor = flavor
        self.slot = slot
        self.model = model
        self.staticPose = pose
        root.addChild(model)
    }

    var isLanded: Bool { state == .landed }

    func cancelMotions() {
        motion?.cancel()
        motion = nil
        relayout?.cancel()
        relayout = nil
    }
}

/// holder (card position, press) → [scaler (hide / grow) → model, shadow]. The shadow fades rather than
/// scales, so it lingers briefly when the scoop leaves and returns with it.
@MainActor
final class FlavorIcon {
    let flavor: Flavor
    let holder = Entity()
    let scaler = Entity()
    let model: ModelEntity
    let shadow: ModelEntity
    private let shadowScale: SIMD3<Float>
    var restPosition: SIMD3<Float> = .zero
    var restOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var baseScale: Float = 1
    var appear: Float = 1
    var shadowAmount: Float = 1
    var appearTween: Tween?
    var shadowTween: Tween?
    private var shownShadow: Float = -1

    init(flavor: Flavor, model: ModelEntity, shadow: ModelEntity) {
        self.flavor = flavor
        self.model = model
        self.shadow = shadow
        self.shadowScale = shadow.scale
        holder.name = "flavor-\(flavor.rawValue)"
        holder.addChild(scaler)
        scaler.addChild(model)
        holder.addChild(shadow)
    }

    func applyShadow() {
        guard abs(shadowAmount - shownShadow) > 0.004 else { return }
        shownShadow = shadowAmount
        shadow.scale = shadowScale * max(shadowAmount, 1e-4)
        shadow.isEnabled = shadowAmount > 0.002
    }
}

@MainActor
final class TrayEntry {
    enum Mode { case tray, summary, receipt, flying, editing, removing }

    var item: IceCreamItem
    var rig: ItemRig?
    var index: Float
    var indexTween: Tween?
    var mode: Mode = .flying
    var contentTop: Float
    var contentRadius: Float
    var lastEdge: Float = -1
    var spinYaw: Float = -0.55
    var spinVelocity: Float = 0
    var appear: Float = 1
    var appearTween: Tween?

    init(item: IceCreamItem, rig: ItemRig?, index: Float, metrics: (top: Float, radius: Float)) {
        self.item = item
        self.rig = rig
        self.index = index
        self.contentTop = metrics.top
        self.contentRadius = metrics.radius
    }

    func setMetrics(_ metrics: (top: Float, radius: Float)) {
        contentTop = metrics.top
        contentRadius = metrics.radius
    }

    var id: UUID { item.id }
}
