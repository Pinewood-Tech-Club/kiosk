import Foundation
import Metal
import RealityKit

struct ScoopMeshData: Sendable {
    static let floatsPerPoseVertex = 10
    static let poseVertexStride = floatsPerPoseVertex * MemoryLayout<Float>.size
    static let meshVertexStride = 12 * MemoryLayout<Float>.size

    struct Bounds: Sendable {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    let vertexCount: Int
    let indexCount: Int
    let poseNames: [String]
    let uvs: [Float]
    let indices: [UInt32]
    let poseVertices: [Float]
    let poseBounds: [Bounds]

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ data: Data) throws -> ScoopMeshData {
        var offset = 0
        func readU32() throws -> Int {
            guard offset + 4 <= data.count else { throw ParseError(message: "Truncated header") }
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
            offset += 4
            return Int(UInt32(littleEndian: value))
        }
        func readFloats(_ count: Int) throws -> [Float] {
            let byteCount = count * 4
            guard offset + byteCount <= data.count else { throw ParseError(message: "Truncated float block") }
            var out = [Float](repeating: 0, count: count)
            _ = out.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<(offset + byteCount)) }
            offset += byteCount
            return out
        }

        guard data.count >= 20, data.prefix(4) == Data("SCMP".utf8) else {
            throw ParseError(message: "Bad magic")
        }
        offset = 4
        let version = try readU32()
        guard version == 1 else { throw ParseError(message: "Unsupported version \(version)") }
        let vertexCount = try readU32()
        let indexCount = try readU32()
        let poseCount = try readU32()
        guard indexCount % 3 == 0, vertexCount > 0, poseCount > 0 else {
            throw ParseError(message: "Bad counts")
        }

        var names: [String] = []
        for _ in 0..<poseCount {
            let length = try readU32()
            guard offset + length <= data.count else { throw ParseError(message: "Truncated pose name") }
            names.append(String(decoding: data[offset..<(offset + length)], as: UTF8.self))
            offset += length
        }

        let uvs = try readFloats(vertexCount * 2)
        let indexBytes = indexCount * 4
        guard offset + indexBytes <= data.count else { throw ParseError(message: "Truncated indices") }
        var indices = [UInt32](repeating: 0, count: indexCount)
        _ = indices.withUnsafeMutableBytes { data.copyBytes(to: $0, from: offset..<(offset + indexBytes)) }
        offset += indexBytes

        var interleaved = [Float](repeating: 0, count: poseCount * vertexCount * floatsPerPoseVertex)
        var bounds: [Bounds] = []
        for pose in 0..<poseCount {
            let positions = try readFloats(vertexCount * 3)
            let normals = try readFloats(vertexCount * 3)
            let tangents = try readFloats(vertexCount * 4)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            interleaved.withUnsafeMutableBufferPointer { out in
                let base = pose * vertexCount * floatsPerPoseVertex
                for v in 0..<vertexCount {
                    let o = base + v * floatsPerPoseVertex
                    let p = SIMD3<Float>(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2])
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                    out[o] = p.x; out[o + 1] = p.y; out[o + 2] = p.z
                    out[o + 3] = normals[v * 3]; out[o + 4] = normals[v * 3 + 1]; out[o + 5] = normals[v * 3 + 2]
                    out[o + 6] = tangents[v * 4]; out[o + 7] = tangents[v * 4 + 1]
                    out[o + 8] = tangents[v * 4 + 2]; out[o + 9] = tangents[v * 4 + 3]
                }
            }
            bounds.append(Bounds(min: lo, max: hi))
        }

        weldSeams(&interleaved, vertexCount: vertexCount, poseCount: poseCount)
        return ScoopMeshData(vertexCount: vertexCount, indexCount: indexCount, poseNames: names,
                             uvs: uvs, indices: indices, poseVertices: interleaved, poseBounds: bounds)
    }

    /// UV-seam vertices are duplicated; they coincide in the authored rest pose, but a pose can pull the
    /// copies apart and open a crack. Give every copy of a seam vertex the same position and normal in every pose.
    private static func weldSeams(_ vertices: inout [Float], vertexCount: Int, poseCount: Int) {
        var groups: [SIMD3<Int32>: [Int]] = [:]
        for v in 0..<vertexCount {
            let o = v * floatsPerPoseVertex
            let key = SIMD3<Int32>(Int32((vertices[o] * 1e6).rounded()),
                                   Int32((vertices[o + 1] * 1e6).rounded()),
                                   Int32((vertices[o + 2] * 1e6).rounded()))
            groups[key, default: []].append(v)
        }
        let seams = groups.values.filter { $0.count > 1 }
        guard !seams.isEmpty else { return }
        for pose in 0..<poseCount {
            let base = pose * vertexCount * floatsPerPoseVertex
            for members in seams {
                var position = SIMD3<Float>.zero
                var normal = SIMD3<Float>.zero
                for v in members {
                    let o = base + v * floatsPerPoseVertex
                    position += SIMD3(vertices[o], vertices[o + 1], vertices[o + 2])
                    normal += SIMD3(vertices[o + 3], vertices[o + 4], vertices[o + 5])
                }
                position /= Float(members.count)
                normal = simd_length(normal) > 1e-6 ? simd_normalize(normal) : SIMD3(0, 1, 0)
                for v in members {
                    let o = base + v * floatsPerPoseVertex
                    vertices[o] = position.x; vertices[o + 1] = position.y; vertices[o + 2] = position.z
                    vertices[o + 3] = normal.x; vertices[o + 4] = normal.y; vertices[o + 5] = normal.z
                }
            }
        }
    }

    /// Sphere-based stand-in with the same pose structure, used only if a .scoopmesh file is missing.
    static func placeholder(slot: Int) -> ScoopMeshData {
        let rings = 40, segments = 64
        let names = slot == 1 ? ["icon", "ball", "cup", "cup_solo", "cone"] : ["icon", "ball", "cup", "cone"]
        var uvs: [Float] = []
        var indices: [UInt32] = []
        for ring in 0...rings {
            for segment in 0...segments {
                uvs += [Float(segment) / Float(segments), 1 - Float(ring) / Float(rings)]
            }
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt32(ring * (segments + 1) + segment)
                let b = a + UInt32(segments + 1)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        let vertexCount = (rings + 1) * (segments + 1)
        var interleaved: [Float] = []
        var bounds: [Bounds] = []
        for name in names {
            let radius: Float = 0.022
            let flatten: Float = name == "ball" ? 1 : 0.62
            let widen: Float = name == "ball" ? 1 : (name == "cone" ? 1.2 : 1.45)
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for ring in 0...rings {
                let phi = Float.pi * Float(ring) / Float(rings)
                for segment in 0...segments {
                    let theta = 2 * Float.pi * Float(segment) / Float(segments)
                    let n = SIMD3<Float>(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
                    let p = SIMD3<Float>(n.x * radius * widen, (n.y + 1) * radius * flatten, n.z * radius * widen)
                    let normal = simd_normalize(SIMD3<Float>(n.x / widen, n.y / flatten, n.z / widen))
                    let tangent = SIMD3<Float>(cos(theta), 0, -sin(theta))
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                    interleaved += [p.x, p.y, p.z, normal.x, normal.y, normal.z, tangent.x, tangent.y, tangent.z, 1]
                }
            }
            bounds.append(Bounds(min: lo, max: hi))
        }
        return ScoopMeshData(vertexCount: vertexCount, indexCount: indices.count, poseNames: names,
                             uvs: uvs, indices: indices, poseVertices: interleaved, poseBounds: bounds)
    }
}

extension ScoopMeshData {
    func poseIndex(_ name: String) -> Int {
        if let index = poseNames.firstIndex(of: name) { return index }
        if name == "cup_solo", let index = poseNames.firstIndex(of: "cup") { return index }
        return 0
    }

    func positions(_ name: String, stride step: Int = 1) -> [SIMD3<Float>] {
        let base = poseIndex(name) * vertexCount * Self.floatsPerPoseVertex
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(vertexCount / step + 1)
        poseVertices.withUnsafeBufferPointer { v in
            var i = 0
            while i < vertexCount {
                let o = base + i * Self.floatsPerPoseVertex
                out.append([v[o], v[o + 1], v[o + 2]])
                i += step
            }
        }
        return out
    }

    func triangles(_ name: String) -> [SIMD3<Float>] {
        let base = poseIndex(name) * vertexCount * Self.floatsPerPoseVertex
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(indices.count)
        poseVertices.withUnsafeBufferPointer { v in
            for index in indices {
                let o = base + Int(index) * Self.floatsPerPoseVertex
                out.append([v[o], v[o + 1], v[o + 2]])
            }
        }
        return out
    }
}

struct PoseRef {
    let buffer: MTLBuffer
    let offset: Int
}

@MainActor
final class MorphEngine {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let morphPipeline: MTLComputePipelineState
    private let blendPipeline: MTLComputePipelineState
    private var pending: MTLCommandBuffer?
    private(set) var dispatchesThisFrame = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.kernelSource, options: nil),
              let morph = library.makeFunction(name: "morphScoopMesh"),
              let blend = library.makeFunction(name: "blendScoopPoses"),
              let morphPipeline = try? device.makeComputePipelineState(function: morph),
              let blendPipeline = try? device.makeComputePipelineState(function: blend)
        else { return nil }
        self.device = device
        self.queue = queue
        self.morphPipeline = morphPipeline
        self.blendPipeline = blendPipeline
    }

    private var commandBuffer: MTLCommandBuffer? {
        if let pending { return pending }
        pending = queue.makeCommandBuffer()
        return pending
    }

    func writeMesh(_ mesh: LowLevelMesh, from a: PoseRef, to b: PoseRef, weight: Float, vertexCount: Int) {
        guard let commandBuffer else { return }
        let output = mesh.replace(bufferIndex: 0, using: commandBuffer)
        encode(morphPipeline, a: a, b: b, output: output, outputOffset: 0, weight: weight, count: vertexCount, in: commandBuffer)
    }

    func blendPoses(into output: MTLBuffer, from a: PoseRef, to b: PoseRef, weight: Float, vertexCount: Int) {
        guard let commandBuffer else { return }
        encode(blendPipeline, a: a, b: b, output: output, outputOffset: 0, weight: weight, count: vertexCount, in: commandBuffer)
    }

    private func encode(_ pipeline: MTLComputePipelineState, a: PoseRef, b: PoseRef, output: MTLBuffer,
                        outputOffset: Int, weight: Float, count: Int, in commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var weight = weight
        var count32 = UInt32(count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(a.buffer, offset: a.offset, index: 0)
        encoder.setBuffer(b.buffer, offset: b.offset, index: 1)
        encoder.setBuffer(output, offset: outputOffset, index: 2)
        encoder.setBytes(&weight, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&count32, length: MemoryLayout<UInt32>.size, index: 4)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        dispatchesThisFrame += 1
    }

    func flush() {
        pending?.commit()
        pending = nil
        dispatchesThisFrame = 0
    }
}

@MainActor
final class ScoopMorpher {
    let mesh: LowLevelMesh
    let resource: MeshResource
    let scratch: MTLBuffer
    var inUse = false

    init(mesh: LowLevelMesh, resource: MeshResource, scratch: MTLBuffer) {
        self.mesh = mesh
        self.resource = resource
        self.scratch = scratch
    }
}

@MainActor
final class ScoopMeshSet {
    let slot: Int
    let vertexCount: Int
    let data: ScoopMeshData
    private let poseBuffer: MTLBuffer
    private let poseIndex: [String: Int]
    private let engine: MorphEngine
    private let bounds: BoundingBox
    private var staticMeshes: [String: MeshResource] = [:]
    private var morphers: [ScoopMorpher] = []

    init(slot: Int, data: ScoopMeshData, engine: MorphEngine) throws {
        self.slot = slot
        self.data = data
        self.vertexCount = data.vertexCount
        self.engine = engine
        guard let buffer = data.poseVertices.withUnsafeBytes({
            engine.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw ScoopMeshData.ParseError(message: "Could not allocate pose buffer") }
        poseBuffer = buffer
        poseIndex = Dictionary(uniqueKeysWithValues: data.poseNames.enumerated().map { ($0.element, $0.offset) })
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for b in data.poseBounds {
            lo = simd_min(lo, b.min)
            hi = simd_max(hi, b.max)
        }
        let pad = SIMD3<Float>(repeating: 0.004)
        bounds = BoundingBox(min: lo - pad, max: hi + pad)
    }

    func resolve(_ name: String) -> String {
        if poseIndex[name] != nil { return name }
        if name == "cup_solo", poseIndex["cup"] != nil { return "cup" }
        return data.poseNames[0]
    }

    func pose(_ name: String) -> PoseRef {
        let index = poseIndex[resolve(name)] ?? 0
        return PoseRef(buffer: poseBuffer, offset: index * vertexCount * ScoopMeshData.poseVertexStride)
    }

    func poseBounds(_ name: String) -> ScoopMeshData.Bounds {
        data.poseBounds[poseIndex[resolve(name)] ?? 0]
    }

    func staticMesh(_ name: String) -> MeshResource {
        let key = resolve(name)
        if let mesh = staticMeshes[key] { return mesh }
        let mesh = try! makeLowLevelMesh()
        let ref = pose(key)
        engine.writeMesh(mesh, from: ref, to: ref, weight: 0, vertexCount: vertexCount)
        let resource = try! MeshResource(from: mesh)
        staticMeshes[key] = resource
        return resource
    }

    func preloadStaticMeshes() {
        for name in data.poseNames {
            _ = staticMesh(name)
        }
    }

    func preloadMorphers(_ count: Int) {
        while morphers.count < count {
            morphers.append(makeMorpher())
        }
    }

    var allMorpherResources: [MeshResource] { morphers.map(\.resource) }

    func acquireMorpher() -> ScoopMorpher {
        if let free = morphers.first(where: { !$0.inUse }) {
            free.inUse = true
            return free
        }
        let morpher = makeMorpher()
        morphers.append(morpher)
        morpher.inUse = true
        return morpher
    }

    func release(_ morpher: ScoopMorpher) {
        morpher.inUse = false
    }

    private func makeMorpher() -> ScoopMorpher {
        let mesh = try! makeLowLevelMesh()
        let first = pose(data.poseNames[0])
        engine.writeMesh(mesh, from: first, to: first, weight: 0, vertexCount: vertexCount)
        let resource = try! MeshResource(from: mesh)
        let scratch = engine.device.makeBuffer(length: vertexCount * ScoopMeshData.poseVertexStride, options: .storageModePrivate)!
        return ScoopMorpher(mesh: mesh, resource: resource, scratch: scratch)
    }

    private func makeLowLevelMesh() throws -> LowLevelMesh {
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: 12),
            .init(semantic: .tangent, format: .float3, layoutIndex: 0, offset: 24),
            .init(semantic: .bitangent, format: .float3, layoutIndex: 0, offset: 36),
            .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: ScoopMeshData.meshVertexStride),
            .init(bufferIndex: 1, bufferStride: 8),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: layouts, indexCapacity: data.indexCount,
                                                 indexType: .uint32)
        let mesh = try LowLevelMesh(descriptor: descriptor)
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            data.uvs.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.withUnsafeMutableIndices { raw in
            data.indices.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: data.indexCount, topology: .triangle, bounds: bounds)])
        return mesh
    }
}

extension MorphEngine {
    // Compiled at preload so the build does not depend on the separately downloaded Metal toolchain.
    nonisolated static let kernelSource = """
#include <metal_stdlib>
using namespace metal;

struct PoseVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float4 tangent;
};

struct MeshVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float3 tangent;
    packed_float3 bitangent;
};

static inline PoseVertex blend(PoseVertex a, PoseVertex b, float w) {
    float3 p = mix(float3(a.position), float3(b.position), w);
    float3 n = mix(float3(a.normal), float3(b.normal), w);
    float nl = length(n);
    n = nl > 1e-6 ? n / nl : float3(0, 1, 0);
    float4 ta = float4(a.tangent);
    float4 tb = float4(b.tangent);
    float3 t = mix(ta.xyz, tb.xyz, w);
    t -= n * dot(n, t);
    float tl = length(t);
    t = tl > 1e-6 ? t / tl : float3(1, 0, 0);
    PoseVertex out;
    out.position = packed_float3(p);
    out.normal = packed_float3(n);
    out.tangent = packed_float4(float4(t, w < 0.5 ? ta.w : tb.w));
    return out;
}

kernel void morphScoopMesh(device const PoseVertex *a [[buffer(0)]],
                           device const PoseVertex *b [[buffer(1)]],
                           device MeshVertex *out [[buffer(2)]],
                           constant float &weight [[buffer(3)]],
                           constant uint &count [[buffer(4)]],
                           uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    PoseVertex v = blend(a[id], b[id], weight);
    float3 n = float3(v.normal);
    float4 t = float4(v.tangent);
    MeshVertex m;
    m.position = v.position;
    m.normal = v.normal;
    m.tangent = packed_float3(t.xyz);
    m.bitangent = packed_float3(cross(n, t.xyz) * t.w);
    out[id] = m;
}

kernel void blendScoopPoses(device const PoseVertex *a [[buffer(0)]],
                            device const PoseVertex *b [[buffer(1)]],
                            device PoseVertex *out [[buffer(2)]],
                            constant float &weight [[buffer(3)]],
                            constant uint &count [[buffer(4)]],
                            uint id [[thread_position_in_grid]]) {
    if (id >= count) { return; }
    out[id] = blend(a[id], b[id], weight);
}
"""
}
