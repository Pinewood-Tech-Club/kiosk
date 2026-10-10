import RealityKit
import UIKit

struct RigPose {
    var position: SIMD3<Float>
    var scale: Float
    var pitch: Float
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
}

/// A vessel with its scoops. Transform chain: root (position, scale) → orient (pitch · yaw) → body (−pivot).
@MainActor
final class ItemRig {
    let vessel: Vessel
    let root = Entity()
    let orient = Entity()
    let body = Entity()
    let pivot: SIMD3<Float>
    var pose: RigPose
    var scaleMultiplier: Float = 1
    var squashY: Float = 1
    var scoops: [ScoopActor] = []
    var motion: Tween?
    var bounceTween: Tween?
    var opacityTween: Tween?
    var replenishTween: Tween?
    private(set) var opacity: Float = 1

    init(vessel: Vessel, model: Entity, shadow: ModelEntity?, pivot: SIMD3<Float>, pose: RigPose) {
        self.vessel = vessel
        self.pivot = pivot
        self.pose = pose
        root.name = "rig-\(vessel.rawValue)"
        root.addChild(orient)
        orient.addChild(body)
        body.position = -pivot
        body.addChild(model)
        if let shadow { body.addChild(shadow) }
        apply()
    }

    func apply() {
        root.position = pose.position
        let s = pose.scale * scaleMultiplier
        root.scale = [s, s * squashY, s]
        orient.orientation = simd_quatf(angle: pose.pitch, axis: [1, 0, 0]) * simd_quatf(angle: pose.yaw, axis: [0, 1, 0])
    }

    func setOpacity(_ value: Float) {
        opacity = value
        root.setOpacity(value)
    }

    func cancelMotions() {
        motion?.cancel()
        bounceTween?.cancel()
        opacityTween?.cancel()
        replenishTween?.cancel()
    }
}

@MainActor
final class ScoopActor {
    let flavor: Flavor
    let slot: Int
    let entity: ModelEntity
    var staticPose: String
    var morpher: ScoopMorpher?
    var morphFrom: PoseRef?
    var morphTo = ""
    var morphWeight: Float = 0
    var morphDirty = false
    var morphTween: Tween?
    var motion: Tween?
    var squashTween: Tween?
    weak var rig: ItemRig?
    var placementKey = "1"
    var isLanded = false

    init(flavor: Flavor, slot: Int, entity: ModelEntity, pose: String) {
        self.flavor = flavor
        self.slot = slot
        self.entity = entity
        self.staticPose = pose
    }

    func cancelMotions() {
        motion?.cancel()
        squashTween?.cancel()
        morphTween?.cancel()
    }
}

/// A flavor selector icon. Two model entities let the icon cross-fade when it switches to the next slot's mesh.
@MainActor
final class FlavorIcon {
    let flavor: Flavor
    let holder = Entity()
    let models: [ModelEntity]
    var activeModel = 0
    var slot = 1
    var baseVisible = false
    var suppressed = false
    var opacityTween: Tween?
    var replenishTween: Tween?
    var crossfadeTween: Tween?
    var bounceTween: Tween?
    var scaleMultiplier: Float = 1
    var baseScale: Float = 1
    private(set) var opacity: Float = 0

    init(flavor: Flavor, models: [ModelEntity], shadow: ModelEntity) {
        self.flavor = flavor
        self.models = models
        holder.name = "flavor-\(flavor.rawValue)"
        for model in models { holder.addChild(model) }
        holder.addChild(shadow)
        models[1].setOpacity(0)
    }

    var model: ModelEntity { models[activeModel] }

    func setOpacity(_ value: Float) {
        opacity = value
        holder.setOpacity(value)
    }

    func applyScale() {
        holder.scale = .init(repeating: baseScale * scaleMultiplier)
    }
}

@MainActor
final class TrayEntry {
    let item: IceCreamItem
    let rig: ItemRig
    let contentCenterY: Float
    var index: Float
    var indexTween: Tween?
    var isFlying = true
    var isRemoving = false
    var lastOpacity: Float = -1

    init(item: IceCreamItem, rig: ItemRig, index: Float, contentCenterY: Float) {
        self.item = item
        self.rig = rig
        self.index = index
        self.contentCenterY = contentCenterY
    }

    var id: UUID { item.id }
}
