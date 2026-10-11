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

struct Framing: Equatable {
    var position: SIMD3<Float>
    var scale: Float
}

/// A vessel with its scoops.
/// root (position, scale) → floor (pitch) → rolled (roll, modelScale) → spun (yaw) → body (−pivot).
@MainActor
final class ItemRig {
    let vessel: Vessel
    let root = Entity()
    let floor = Entity()
    let rolled = Entity()
    let spun = Entity()
    let body = Entity()
    let pivot: SIMD3<Float>
    var pose: RigPose
    var scaleMultiplier: Float = 1
    /// Scales the model inside the rig (card icons hide this way when their item flies out).
    var modelScale: Float = 1
    var scoops: [ScoopActor] = []
    var motion: Tween?
    var appearTween: Tween?
    var opacityTween: Tween?
    private(set) var opacity: Float = 1
    /// Where the rig sits at the center when it's the item being built; eased when its scoop count changes.
    var framing: Framing?
    var framingTarget: Framing?
    var framingTween: Tween?
    /// The pose the current flight ends on, so scoops can aim at where the rig will be rather than where it is.
    var flightGoal: (() -> RigPose)?

    init(vessel: Vessel, model: Entity, pivot: SIMD3<Float>, pose: RigPose) {
        self.vessel = vessel
        self.pivot = pivot
        self.pose = pose
        root.name = "rig-\(vessel.rawValue)"
        root.addChild(floor)
        floor.addChild(rolled)
        rolled.addChild(spun)
        spun.addChild(body)
        body.position = -pivot
        body.addChild(model)
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
    }

    /// World matrix `body` will have at `pose` once fully shown (same chain as `apply`).
    func bodyMatrix(at pose: RigPose) -> simd_float4x4 {
        let scale = max(pose.scale, 1e-5)
        let rootMatrix = Transform(scale: .init(repeating: scale), rotation: simd_quatf(angle: pose.pitch, axis: [1, 0, 0]),
                                   translation: pose.position).matrix
        let rolledMatrix = Transform(scale: .one, rotation: simd_quatf(angle: pose.roll, axis: [0, 0, 1]), translation: .zero).matrix
        let spunMatrix = Transform(scale: .one, rotation: simd_quatf(angle: pose.yaw, axis: [0, 1, 0]), translation: .zero).matrix
        return rootMatrix * rolledMatrix * spunMatrix * Transform(translation: -pivot).matrix
    }

    func setOpacity(_ value: Float) {
        guard value != opacity else { return }
        opacity = value
        root.setOpacity(value)
    }

    func cancelMotions() {
        motion?.cancel()
        motion = nil
        flightGoal = nil
        appearTween?.cancel()
        opacityTween?.cancel()
    }
}

/// One scoop. Flights move `root`; `model` is its child.
@MainActor
final class ScoopActor {
    enum State { case flying, pressing, landed, leaving }
    static let rootName = "scoop"

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
    /// The rig whose body this scoop is attached to right now, if any. Differs from `rig` while it transfers.
    weak var mount: ItemRig?
    var isDiscarded = false
    /// Flying in from its card as a new scoop: the item is framed with room for it above.
    var isArriving = false
    var placementKey = "1"
    var state: State = .flying
    var pressHeight: Float = 0
    /// Name of the motion it's in, for the clip check's reports.
    var phase = ""

    init(flavor: Flavor, slot: Int, model: ModelEntity, pose: String) {
        self.flavor = flavor
        self.slot = slot
        self.model = model
        self.staticPose = pose
        root.name = Self.rootName
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

/// holder (card position, press) → scaler (hide / grow) → model.
@MainActor
final class FlavorIcon {
    let flavor: Flavor
    let holder = Entity()
    let scaler = Entity()
    let model: ModelEntity
    var restPosition: SIMD3<Float> = .zero
    var restOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var baseScale: Float = 1
    var appear: Float = 1
    var appearTween: Tween?

    init(flavor: Flavor, model: ModelEntity) {
        self.flavor = flavor
        self.model = model
        holder.name = "flavor-\(flavor.rawValue)"
        holder.addChild(scaler)
        scaler.addChild(model)
    }
}

@MainActor
final class TrayEntry {
    /// `docked` rests in its tray slot or its order-sheet row, whichever the sheet's progress says.
    enum Mode { case docked, receipt, flying, editing, removing }

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
    /// Docked yaw is `trayYaw + lerp(spinAnchor, spin, t)`: `spin` turns while the sheet is open and
    /// `spinAnchor`, a whole number of turns, is where it lands back in the tray.
    var spin: Float = 0
    var spinAnchor: Float = 0
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

/// Invisible stand-in for the order sheet at a depth between the builder's models and the sheet's items: it
/// hides the hero, card icons and scoops wherever the sheet covers them (as if drawn on the SwiftUI sheet
/// beneath the stage), while the items riding on the sheet sit in front of it.
/// A rounded rectangle built from two bars and four discs, so it can resize every frame without new meshes.
@MainActor
final class SheetOccluder {
    let root = Entity()
    let bars: [ModelEntity]
    let corners: [ModelEntity]

    init() {
        let material = OcclusionMaterial()
        let plane = MeshResource.generatePlane(width: 1, height: 1)
        let disc = MeshResource.generatePlane(width: 1, height: 1, cornerRadius: 0.5)
        bars = (0..<2).map { _ in ModelEntity(mesh: plane, materials: [material]) }
        corners = (0..<4).map { _ in ModelEntity(mesh: disc, materials: [material]) }
        root.name = "sheet-occluder"
        for part in bars + corners { root.addChild(part) }
        root.isEnabled = false
    }
}
