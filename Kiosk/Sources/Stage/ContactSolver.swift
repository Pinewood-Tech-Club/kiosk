import simd

/// Finds how far above its final placement a scoop in its `ball` pose first touches what is beneath it
/// (the vessel and the scoops already placed), by dropping the ball along the slot's up axis over a
/// heightfield of the obstacle vertices.
enum ContactSolver {
    struct Problem: Sendable {
        let key: String
        let rotation: simd_quatf
        let translation: SIMD3<Float>
        let ball: [SIMD3<Float>]
        let obstacles: [SIMD3<Float>]
    }

    private static let cell: Float = 0.0008
    private static let halfExtent: Float = 0.046

    nonisolated static func solve(_ problems: [Problem]) -> [String: Float] {
        var result: [String: Float] = [:]
        for problem in problems {
            result[problem.key] = lift(problem)
        }
        return result
    }

    nonisolated private static func lift(_ problem: Problem) -> Float {
        let n = Int((2 * halfExtent / cell).rounded(.up))
        var floor = [Float](repeating: -.infinity, count: n * n)
        let inverse = problem.rotation.inverse

        func index(_ x: Float, _ z: Float) -> Int? {
            let ix = Int(((x + halfExtent) / cell).rounded(.down))
            let iz = Int(((z + halfExtent) / cell).rounded(.down))
            guard ix >= 0, iz >= 0, ix < n, iz < n else { return nil }
            return iz * n + ix
        }

        for point in problem.obstacles {
            let local = inverse.act(point - problem.translation)
            guard local.y < 0.08, let i = index(local.x, local.z) else { continue }
            if local.y > floor[i] { floor[i] = local.y }
        }

        var dilated = floor
        for z in 0..<n {
            for x in 0..<n {
                var best = floor[z * n + x]
                for dz in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, zz = z + dz
                        guard xx >= 0, zz >= 0, xx < n, zz < n else { continue }
                        best = max(best, floor[zz * n + xx])
                    }
                }
                dilated[z * n + x] = best
            }
        }

        var required: Float = 0
        for vertex in problem.ball {
            guard let i = index(vertex.x, vertex.z) else { continue }
            let obstacle = dilated[i]
            if obstacle > -.infinity {
                required = max(required, obstacle - vertex.y)
            }
        }
        return required + 0.0005
    }
}
