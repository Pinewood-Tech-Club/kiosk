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
    func setOpacity(_ value: Float) {
        if value >= 0.999 {
            components.remove(OpacityComponent.self)
        } else {
            components.set(OpacityComponent(opacity: max(value, 0)))
        }
        isEnabled = value > 0.002
    }

    /// Fades render as a flat layer instead of revealing the model's own back faces.
    func useDepthPrePass() {
        let group = ModelSortGroup(depthPass: .prePass)
        func visit(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                entity.components.set(ModelSortGroupComponent(group: group, order: 0))
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
    var pose: RigPose
    var scaleMultiplier: Float = 1
    var scoops: [ScoopActor] = []
    var motion: Tween?
    var appearTween: Tween?
    var opacityTween: Tween?
    private(set) var opacity: Float = 1
    private var shownShadowOpacity: Float = -1

    init(vessel: Vessel, model: Entity, baseShadow: ModelEntity?, floorShadow: ModelEntity?, floorShadowFullRoll: Float,
         pivot: SIMD3<Float>, pose: RigPose) {
        self.vessel = vessel
        self.pivot = pivot
        self.pose = pose
        self.floorShadow = floorShadow
        self.floorShadowFullRoll = floorShadowFullRoll
        root.name = "rig-\(vessel.rawValue)"
        root.addChild(floor)
        floor.addChild(rolled)
        if let floorShadow { floor.addChild(floorShadow) }
        rolled.addChild(spun)
        spun.addChild(body)
        body.position = -pivot
        body.addChild(model)
        if let baseShadow { body.addChild(baseShadow) }
        apply()
    }

    func apply() {
        root.position = pose.position
        root.scale = .init(repeating: max(pose.scale * scaleMultiplier, 1e-5))
        floor.orientation = simd_quatf(angle: pose.pitch, axis: [1, 0, 0])
        rolled.orientation = simd_quatf(angle: pose.roll, axis: [0, 0, 1])
        spun.orientation = simd_quatf(angle: pose.yaw, axis: [0, 1, 0])
        if let floorShadow, floorShadowFullRoll != 0 {
            let amount = Ease.clamp01(abs(pose.roll) / abs(floorShadowFullRoll))
            if abs(amount - shownShadowOpacity) > 0.004 {
                shownShadowOpacity = amount
                floorShadow.setOpacity(amount)
            }
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

/// One scoop. Flights move `root`; `model` (and `ghost` during a slot cross-dissolve) are its children.
@MainActor
final class ScoopActor {
    enum State { case flying, pressing, landed, leaving }

    let flavor: Flavor
    var slot: Int
    let root = Entity()
    var model: ModelEntity
    var ghost: ModelEntity?
    var crossfade: Tween?
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

@MainActor
final class FlavorIcon {
    let flavor: Flavor
    let holder = Entity()
    let model: ModelEntity
    var restPosition: SIMD3<Float> = .zero
    var restOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var baseScale: Float = 1
    var appear: Float = 1
    var appearTween: Tween?
    var opacityTween: Tween?
    var baseVisible = false
    private(set) var opacity: Float = 1

    init(flavor: Flavor, model: ModelEntity, shadow: ModelEntity) {
        self.flavor = flavor
        self.model = model
        holder.name = "flavor-\(flavor.rawValue)"
        holder.addChild(model)
        holder.addChild(shadow)
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        holder.setOpacity(value)
    }
}

@MainActor
final class TrayEntry {
    enum Mode { case tray, summary, flying, editing, removing }

    var item: IceCreamItem
    var rig: ItemRig?
    var index: Float
    var indexTween: Tween?
    var mode: Mode = .flying
    var contentCenterY: Float
    var lastOpacity: Float = -1
    var spinYaw: Float = -0.55
    var spinVelocity: Float = 0

    init(item: IceCreamItem, rig: ItemRig?, index: Float, contentCenterY: Float) {
        self.item = item
        self.rig = rig
        self.index = index
        self.contentCenterY = contentCenterY
    }

    var id: UUID { item.id }
}
