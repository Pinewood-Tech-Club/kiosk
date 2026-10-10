import simd

/// Finds how far above its final placement a scoop in its `ball` pose first touches what is beneath it
/// (the vessel and the scoops already placed), by dropping the ball along the slot's up axis over a
/// heightfield of the obstacles. Vessel triangles are densified first so thin rims can't fall between vertices.
enum ContactSolver {
    struct Problem: Sendable {
        let key: String
        let rotation: simd_quatf
        let translation: SIMD3<Float>
        let ball: [SIMD3<Float>]
        let placed: [SIMD3<Float>]
        let vessel: [SIMD3<Float>]
        let scoopsBelow: [SIMD3<Float>]
        /// Triangles (3 points each) of the scoops beneath, for the exact inside test.
        let trianglesBelow: [SIMD3<Float>]
    }

    struct VesselGeometry: Sendable {
        let points: [SIMD3<Float>]
        let triangles: [SIMD3<Float>]
    }

    nonisolated static func problems(meshes: [ScoopMeshData], placements: Placements,
                                     vessels: [Vessel: VesselGeometry], withTriangles: Bool) -> [Problem] {
        var problems: [Problem] = []
        for vessel in Vessel.allCases {
            guard let geometry = vessels[vessel] else { continue }
            let surface = densify(points: geometry.points, triangles: geometry.triangles)
            let pose = vessel == .cone ? "cone" : "cup"
            for key in vessel == .cup ? ["solo", "1", "2", "3"] : ["1", "2", "3"] {
                let slot = key == "solo" ? 1 : Int(key)!
                var below: [SIMD3<Float>] = []
                var belowTriangles: [SIMD3<Float>] = []
                for lower in stride(from: 1, to: slot, by: 1) {
                    let placement = placements.placement(vessel, key: String(lower))
                    below += meshes[lower - 1].positions(pose, stride: 2).map { placement.rotation.act($0) + placement.translation }
                    if withTriangles {
                        belowTriangles += meshes[lower - 1].triangles(pose).map { placement.rotation.act($0) + placement.translation }
                    }
                }
                let placement = placements.placement(vessel, key: key)
                let placedPose = vessel == .cone ? "cone" : (key == "solo" ? "cup_solo" : "cup")
                problems.append(Problem(key: "\(vessel.rawValue):\(key)", rotation: placement.rotation,
                                        translation: placement.translation,
                                        ball: meshes[slot - 1].positions("ball", stride: 2),
                                        placed: meshes[slot - 1].positions(placedPose, stride: 3),
                                        vessel: surface, scoopsBelow: below, trianglesBelow: belowTriangles))
            }
        }
        return problems
    }

    nonisolated static func lifts(_ problems: [Problem]) async -> [String: Float] {
        await withTaskGroup(of: (String, Float).self) { group in
            for problem in problems {
                group.addTask {
                    (problem.key, lift(problem.ball, over: heightfield(problem.vessel + problem.scoopsBelow, problem)) + 0.0005)
                }
            }
            var result: [String: Float] = [:]
            for await (key, value) in group { result[key] = value }
            return result
        }
    }

    /// Regression check for the assets: how far each placed pose sits inside the scoops beneath it.
    nonisolated static func penetrations(_ problems: [Problem]) async -> [String: (depth: Float, vertices: Int)] {
        await withTaskGroup(of: (String, (depth: Float, vertices: Int)).self) { group in
            for problem in problems where !problem.trianglesBelow.isEmpty {
                group.addTask { (problem.key, penetration(problem)) }
            }
            var result: [String: (depth: Float, vertices: Int)] = [:]
            for await (key, value) in group { result[key] = value }
            return result
        }
    }

    private static let cell: Float = 0.0008
    private static let halfExtent: Float = 0.046

    /// Vessel vertices plus extra samples on any triangle wider than `spacing`.
    nonisolated static func densify(points: [SIMD3<Float>], triangles: [SIMD3<Float>], spacing: Float = 0.0006) -> [SIMD3<Float>] {
        var out = points
        var t = 0
        while t + 2 < triangles.count {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            t += 3
            let longest = max(simd_length(b - a), simd_length(c - b), simd_length(a - c))
            guard longest > spacing else { continue }
            let steps = Int((longest / spacing).rounded(.up))
            for i in 0...steps {
                for j in 0...(steps - i) {
                    let u = Float(i) / Float(steps), v = Float(j) / Float(steps)
                    out.append(a + (b - a) * u + (c - a) * v)
                }
            }
        }
        return out
    }

    private struct Field {
        let n: Int
        var heights: [Float]

        func index(_ x: Float, _ z: Float) -> Int? {
            let ix = Int(((x + halfExtent) / cell).rounded(.down))
            let iz = Int(((z + halfExtent) / cell).rounded(.down))
            guard ix >= 0, iz >= 0, ix < n, iz < n else { return nil }
            return iz * n + ix
        }
    }

    nonisolated private static func heightfield(_ points: [SIMD3<Float>], _ problem: Problem) -> Field {
        let n = Int((2 * halfExtent / cell).rounded(.up))
        var field = Field(n: n, heights: [Float](repeating: -.infinity, count: n * n))
        let inverse = problem.rotation.inverse
        for point in points {
            let l = inverse.act(point - problem.translation)
            guard l.y < 0.08, let i = field.index(l.x, l.z) else { continue }
            if l.y > field.heights[i] { field.heights[i] = l.y }
        }

        var dilated = field.heights
        for z in 0..<n {
            for x in 0..<n {
                var best = field.heights[z * n + x]
                for dz in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, zz = z + dz
                        guard xx >= 0, zz >= 0, xx < n, zz < n else { continue }
                        best = max(best, field.heights[zz * n + xx])
                    }
                }
                dilated[z * n + x] = best
            }
        }
        field.heights = dilated
        return field
    }

    nonisolated private static func lift(_ ball: [SIMD3<Float>], over field: Field) -> Float {
        var required: Float = 0
        for vertex in ball {
            guard let i = field.index(vertex.x, vertex.z) else { continue }
            let obstacle = field.heights[i]
            if obstacle > -.infinity {
                required = max(required, obstacle - vertex.y)
            }
        }
        return required
    }

    /// Exact inside test: a vertex of the placed pose is inside the scoops beneath if a vertical ray from it
    /// crosses their closed surface an odd number of times. Depth is the distance up to the nearest crossing.
    nonisolated private static func penetration(_ problem: Problem) -> (depth: Float, vertices: Int) {
        guard !problem.trianglesBelow.isEmpty else { return (0, 0) }
        let inverse = problem.rotation.inverse
        let tris = problem.trianglesBelow.map { inverse.act($0 - problem.translation) }
        let n = Int((2 * halfExtent / 0.001).rounded(.up))
        func cell(_ v: Float) -> Int { min(max(Int(((v + halfExtent) / 0.001).rounded(.down)), 0), n - 1) }
        var grid = [[Int32]](repeating: [], count: n * n)
        var t = 0
        while t + 2 < tris.count {
            let a = tris[t], b = tris[t + 1], c = tris[t + 2]
            for z in cell(min(a.z, b.z, c.z))...cell(max(a.z, b.z, c.z)) {
                for x in cell(min(a.x, b.x, c.x))...cell(max(a.x, b.x, c.x)) {
                    grid[z * n + x].append(Int32(t))
                }
            }
            t += 3
        }
        var deepest: Float = 0
        var count = 0
        for v in problem.placed {
            guard abs(v.x) < halfExtent, abs(v.z) < halfExtent else { continue }
            var crossings = 0
            var nearest = Float.infinity
            for index in grid[cell(v.z) * n + cell(v.x)] {
                let a = tris[Int(index)], b = tris[Int(index) + 1], c = tris[Int(index) + 2]
                let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
                guard abs(d) > 1e-12 else { continue }
                let l1 = ((b.z - c.z) * (v.x - c.x) + (c.x - b.x) * (v.z - c.z)) / d
                let l2 = ((c.z - a.z) * (v.x - c.x) + (a.x - c.x) * (v.z - c.z)) / d
                let l3 = 1 - l1 - l2
                guard l1 >= 0, l2 >= 0, l3 >= 0 else { continue }
                let y = l1 * a.y + l2 * b.y + l3 * c.y
                if y > v.y {
                    crossings += 1
                    nearest = min(nearest, y - v.y)
                }
            }
            if crossings % 2 == 1, nearest > 0.0005 {
                count += 1
                deepest = max(deepest, nearest)
            }
        }
        return (deepest, count)
    }
}
