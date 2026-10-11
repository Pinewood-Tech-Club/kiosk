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
