import RealityKit
import simd

/// What a topping layer rests on, in the item rig's `body` space (meters, +Y up, vessel axis along Y).
protocol ToppingSurface {
    /// Straight-down probe at (x, z): the top surface's height and outward normal, or nil off the edge.
    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)?
    /// Highest point of the surface.
    var apex: SIMD3<Float> { get }
    /// Horizontal radius around the apex's axis that toppings may cover.
    var radius: Float { get }
    /// A scattered piece that ends up below this has slid off the part of the item a customer sees.
    var floor: Float { get }
    /// 0 for firm ice cream to 1 for whipped cream, which holds a piece where it lands and lets it sink in a little.
    func softness(x: Float, z: Float) -> Float
}

extension ToppingSurface {
    var floor: Float { apex.y - 2.5 * radius }
    func softness(x: Float, z: Float) -> Float { 0 }
}

/// One layer of toppings on an item. The stack is always scoops, whip, drizzle, scattered,
/// whatever order they were tapped in; `ToppingStack` enforces that by handing each layer
/// the surface of everything beneath it.
@MainActor
protocol ToppingLayer: AnyObject {
    var entity: Entity { get }
    /// Builds onto `surface`; `animated == false` shows the finished state (tray minis, rebuilt items).
    func apply(onto surface: ToppingSurface, seed: UInt64, animated: Bool, now: Double)
    /// Re-conforms to a new surface beneath (whip added or removed under it, scoops changed).
    func resurface(to surface: ToppingSurface, duration: Double, now: Double)
    /// Animates away; the layer is detached once `isFinished` turns true.
    func remove(now: Double)
    /// Called every frame with stage time (already scaled by the debug animation speed).
    func update(now: Double)
    var isFinished: Bool { get }
    /// The surface layers above this one should rest on, given the one beneath it.
    func surfaceAbove(_ below: ToppingSurface) -> ToppingSurface
    /// `surfaceAbove` once the layer has finished growing (or, while it's being removed, without it).
    func settledSurfaceAbove(_ below: ToppingSurface) -> ToppingSurface
    /// The topping card icon's current position in `entity`'s parent space (rig body space); re-evaluate every
    /// frame, the item spins and moves. Set only on layers applied from a tap.
    var launchPoint: (() -> SIMD3<Float>)? { get set }
    /// How long `apply(animated: true)` takes to reach its final shape; layers above resurface over the same time.
    var growDuration: Double { get }
    /// How long `remove` takes; layers above sink back over the same time.
    var removeDuration: Double { get }
    /// The card's icon, set alongside `launchPoint`. A layer that stores it drives the icon itself (`takeOut` when its
    /// pieces leave the card, `putBack` once they're out, `react` for a squish); otherwise the stack drives it on tap.
    var cardIcon: ToppingCardIcon? { get set }
}

extension ToppingLayer {
    func settledSurfaceAbove(_ below: ToppingSurface) -> ToppingSurface { surfaceAbove(below) }
    var growDuration: Double { 0.8 }
    var removeDuration: Double { 0.4 }
    var cardIcon: ToppingCardIcon? {
        get { nil }
        set {}
    }
}

struct ToppingRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct ScatterPiece {
    let mesh: MeshResource
    let materials: [any RealityKit.Material]
    /// Half extents of the local bounding box; lying flat, the piece rests on its local -Y face.
    let halfExtents: SIMD3<Float>
}

/// A kind of scattered topping (gummy bears, M&M's, sprinkles): how many land and what each one looks like.
@MainActor
protocol ScatterKind {
    var count: Int { get }
    func makePieces(rng: inout ToppingRandom) -> [ScatterPiece]
    /// A few pieces composed as the topping card's icon: real size (about 25 mm across), resting on y = 0, centered
    /// on the Y axis, composed to be seen from the front (+Z) and a little above. Needs the stage's lighting applied.
    func makeIconPile(rng: inout ToppingRandom) -> Entity
}
