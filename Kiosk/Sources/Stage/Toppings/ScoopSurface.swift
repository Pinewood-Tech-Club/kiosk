import RealityKit
import simd

/// The top of an item's settled scoops in rig `body` space, as a height field rasterized from the scoop meshes
/// in their placed poses (the shapes the landed scoops show), so it depends only on the vessel and scoop count.
struct ScoopSurface: ToppingSurface, Sendable {
    struct Part: Sendable {
        let mesh: ScoopMeshData
        let pose: String
        let placement: SlotPlacement
    }

    static let cell: Float = 0.0006
    /// Toppings only cover the part of the top that faces up at least this much.
    static let minimumUpness: Float = 0.3

    let originX: Float
    let originZ: Float
    let columns: Int
    let rows: Int
    let heights: [Float]
    let normals: [SIMD3<Float>]
    let apex: SIMD3<Float>
    let radius: Float

    func sample(x: Float, z: Float) -> (height: Float, normal: SIMD3<Float>)? {
        let fx = (x - originX) / Self.cell - 0.5
        let fz = (z - originZ) / Self.cell - 0.5
        let i = Int(fx.rounded(.down)), j = Int(fz.rounded(.down))
        let tx = fx - Float(i), tz = fz - Float(j)
        var weight: Float = 0
        var height: Float = 0
        var normal = SIMD3<Float>.zero
        for (di, dj, w) in [(0, 0, (1 - tx) * (1 - tz)), (1, 0, tx * (1 - tz)), (0, 1, (1 - tx) * tz), (1, 1, tx * tz)] {
            let c = i + di, r = j + dj
            guard c >= 0, r >= 0, c < columns, r < rows, w > 0 else { continue }
            let index = r * columns + c
            let h = heights[index]
            guard h.isFinite else { continue }
            weight += w
            height += h * w
            normal += normals[index] * w
        }
        guard weight > 0.5, simd_length(normal) > 1e-6 else { return nil }
        return (height / weight, simd_normalize(normal))
    }

    nonisolated static func build(_ parts: [Part]) -> ScoopSurface {
        var placed: [(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])] = []
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for part in parts {
            let data = part.mesh
            let base = data.poseIndex(part.pose) * data.vertexCount * ScoopMeshData.floatsPerPoseVertex
            var positions = [SIMD3<Float>](repeating: .zero, count: data.vertexCount)
            var normals = [SIMD3<Float>](repeating: .zero, count: data.vertexCount)
            let rotation = part.placement.rotation
            let translation = part.placement.translation
            data.poseVertices.withUnsafeBufferPointer { v in
                for i in 0..<data.vertexCount {
                    let o = base + i * ScoopMeshData.floatsPerPoseVertex
                    let p = rotation.act(SIMD3(v[o], v[o + 1], v[o + 2])) + translation
                    positions[i] = p
                    normals[i] = rotation.act(SIMD3(v[o + 3], v[o + 4], v[o + 5]))
                    lo = simd_min(lo, SIMD2(p.x, p.z))
                    hi = simd_max(hi, SIMD2(p.x, p.z))
                }
            }
            placed.append((positions, normals, data.indices))
        }
        guard lo.x < hi.x else {
            return ScoopSurface(originX: 0, originZ: 0, columns: 0, rows: 0, heights: [], normals: [], apex: .zero, radius: 0)
        }
        let cell = Self.cell
        let originX = lo.x - cell, originZ = lo.y - cell
        let columns = Int(((hi.x - lo.x) / cell).rounded(.up)) + 2
        let rows = Int(((hi.y - lo.y) / cell).rounded(.up)) + 2
        var heights = [Float](repeating: -.infinity, count: columns * rows)
        var normals = [SIMD3<Float>](repeating: [0, 1, 0], count: columns * rows)

        for part in placed {
            part.positions.withUnsafeBufferPointer { positions in
                part.normals.withUnsafeBufferPointer { vertexNormals in
                    part.indices.withUnsafeBufferPointer { indices in
                        var t = 0
                        while t + 2 < indices.count {
                            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
                            t += 3
                            let a = positions[ia], b = positions[ib], c = positions[ic]
                            let area = (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
                            guard abs(area) > 1e-14 else { continue }
                            let minX = min(a.x, b.x, c.x), maxX = max(a.x, b.x, c.x)
                            let minZ = min(a.z, b.z, c.z), maxZ = max(a.z, b.z, c.z)
                            let c0 = max(0, Int(((minX - originX) / cell - 0.5).rounded(.up)))
                            let c1 = min(columns - 1, Int(((maxX - originX) / cell - 0.5).rounded(.down)))
                            let r0 = max(0, Int(((minZ - originZ) / cell - 0.5).rounded(.up)))
                            let r1 = min(rows - 1, Int(((maxZ - originZ) / cell - 0.5).rounded(.down)))
                            guard c0 <= c1, r0 <= r1 else { continue }
                            let inverse = 1 / area
                            for r in r0...r1 {
                                let z = originZ + (Float(r) + 0.5) * cell
                                for col in c0...c1 {
                                    let x = originX + (Float(col) + 0.5) * cell
                                    let wb = ((x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)) * inverse
                                    let wc = ((b.x - a.x) * (z - a.z) - (x - a.x) * (b.z - a.z)) * inverse
                                    let wa = 1 - wb - wc
                                    guard wa >= -1e-5, wb >= -1e-5, wc >= -1e-5 else { continue }
                                    let y = wa * a.y + wb * b.y + wc * c.y
                                    let index = r * columns + col
                                    guard y > heights[index] else { continue }
                                    heights[index] = y
                                    var n = wa * vertexNormals[ia] + wb * vertexNormals[ib] + wc * vertexNormals[ic]
                                    if n.y < 0 { n = -n }
                                    normals[index] = simd_length(n) > 1e-6 ? simd_normalize(n) : [0, 1, 0]
                                }
                            }
                        }
                    }
                }
            }
        }

        var apex = SIMD3<Float>(0, -.infinity, 0)
        for r in 0..<rows {
            for c in 0..<columns where heights[r * columns + c] > apex.y {
                apex = [originX + (Float(c) + 0.5) * cell, heights[r * columns + c], originZ + (Float(r) + 0.5) * cell]
            }
        }
        var surface = ScoopSurface(originX: originX, originZ: originZ, columns: columns, rows: rows,
                                   heights: heights, normals: normals, apex: apex, radius: 0)
        surface = ScoopSurface(originX: originX, originZ: originZ, columns: columns, rows: rows,
                               heights: heights, normals: normals, apex: apex, radius: surface.coverRadius())
        return surface
    }

    /// Distance from the apex's axis to the nearest point, in any direction, where the top stops facing up or
    /// drops off the edge of the top scoop.
    private func coverRadius() -> Float {
        let step = Self.cell * 0.75
        var radius = Float.greatestFiniteMagnitude
        for k in 0..<48 {
            let angle = Float(k) / 48 * 2 * .pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var r: Float = 0
            var previous = apex.y
            while r < 0.08 {
                let next = r + step
                guard let s = sample(x: apex.x + direction.x * next, z: apex.z + direction.y * next),
                      s.normal.y >= Self.minimumUpness, previous - s.height < step * 4 else { break }
                previous = s.height
                r = next
            }
            radius = min(radius, r)
        }
        return max(radius * 0.97, 0.004)
    }
}
