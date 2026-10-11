import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import UIKit

struct SlotPlacement {
    let translation: SIMD3<Float>
    let rotation: simd_quatf

    var transform: Transform { Transform(scale: .one, rotation: rotation, translation: translation) }
}

struct Placements {
    var cup: [String: SlotPlacement]
    var cone: [String: SlotPlacement]

    func placement(_ vessel: Vessel, key: String) -> SlotPlacement {
        let table = vessel == .cup ? cup : cone
        return table[key] ?? table["1"] ?? SlotPlacement(translation: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    }

    static let fallback = Placements(
        cup: [
            "solo": SlotPlacement(translation: [0.0025, 0.0077, 0], rotation: simd_quatf(angle: 2.0, axis: [0, 1, 0])),
            "1": SlotPlacement(translation: [-0.0015, 0.0036, 0], rotation: simd_quatf(angle: 1.0, axis: [0, 1, 0])),
            "2": SlotPlacement(translation: [0.0067, 0.022, 0], rotation: simd_quatf(angle: 3.0, axis: [0, 1, 0])),
            "3": SlotPlacement(translation: [-0.003, 0.0393, -0.0026], rotation: simd_quatf(angle: -1.2, axis: [0, 1, 0])),
        ],
        cone: [
            "1": SlotPlacement(translation: [0, 0.1183, -0.0054], rotation: simd_quatf(angle: 3.0, axis: [0, 1, 0])),
            "2": SlotPlacement(translation: [0, 0.1367, 0.0026], rotation: simd_quatf(angle: 1.3, axis: [0, 1, 0])),
            "3": SlotPlacement(translation: [-0.0049, 0.154, -0.0033], rotation: simd_quatf(angle: -3.0, axis: [0, 1, 0])),
        ]
    )

    static func parse(_ data: Data) -> Placements? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func table(_ key: String) -> [String: SlotPlacement] {
            var out: [String: SlotPlacement] = [:]
            for (name, value) in json[key] as? [String: Any] ?? [:] {
                guard let entry = value as? [String: Any],
                      let t = entry["translation"] as? [Double], t.count == 3,
                      let r = entry["rotation"] as? [Double], r.count == 4
                else { continue }
                out[name] = SlotPlacement(
                    translation: [Float(t[0]), Float(t[1]), Float(t[2])],
                    rotation: simd_normalize(simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3])))
                )
            }
            return out
        }
        let cup = table("cup"), cone = table("cone")
        guard !cup.isEmpty, !cone.isEmpty else { return nil }
        return Placements(cup: cup, cone: cone)
    }
}

@MainActor
final class AssetLibrary {
    let engine: MorphEngine
    private(set) var vessels: [Vessel: Entity] = [:]
    private(set) var vesselBounds: [Vessel: BoundingBox] = [:]
    private(set) var scoopSets: [ScoopMeshSet] = []
    private(set) var placements = Placements.fallback
    private(set) var scoopMaterials: [[Flavor: PhysicallyBasedMaterial]] = []
    private(set) var environment: EnvironmentResource?
    private(set) var candy: CandyLibrary?
    private(set) var report: [String] = []
    private(set) var contactLift: [String: Float] = [:]
    /// Height of the bottom of each vessel's opening (the cup's floor; below it the cone is solid waffle).
    private(set) var cavityFloor: [Vessel: Float] = [:]
    private var vesselPoints: [Vessel: [SIMD3<Float>]] = [:]
    private var vesselGeometry: [Vessel: ContactSolver.VesselGeometry] = [:]

    private static let directory = Bundle.main.resourceURL!.appending(path: "3D")

    private init(engine: MorphEngine) {
        self.engine = engine
    }

    static func load(log: (String) -> Void) async -> AssetLibrary? {
        guard let engine = MorphEngine() else {
            log("Metal unavailable; cannot build the 3D stage")
            return nil
        }
        let library = AssetLibrary(engine: engine)
        let started = CACurrentMediaTime()
        await library.loadEverything()
        let elapsed = CACurrentMediaTime() - started
        library.report.append(String(format: "Loaded in %.2f s", elapsed))
        library.report.forEach(log)
        return library
    }

    func scoopSet(_ slot: Int) -> ScoopMeshSet { scoopSets[slot - 1] }

    func material(slot: Int, flavor: Flavor) -> PhysicallyBasedMaterial {
        scoopMaterials[slot - 1][flavor]!
    }

    func vesselPivot(_ vessel: Vessel) -> SIMD3<Float> {
        guard let bounds = vesselBounds[vessel] else { return [0, vessel == .cup ? 0.023 : 0.068, 0] }
        return [0, bounds.center.y, 0]
    }

    func vesselRadius(_ vessel: Vessel, atHeight y: Float) -> Float {
        var radius: Float = 0
        for p in vesselPoints[vessel] ?? [] where abs(p.y - y) < 0.002 {
            radius = max(radius, simd_length(SIMD2<Float>(p.x, p.z)))
        }
        return radius > 0 ? radius : (vessel == .cone ? 0.014 : 0.04)
    }

    func vesselHalfWidth(_ vessel: Vessel) -> Float {
        guard let b = vesselBounds[vessel] else { return vessel == .cup ? 0.044 : 0.028 }
        return max(abs(b.min.x), abs(b.max.x), abs(b.min.z), abs(b.max.z))
    }

    func vesselSamplePoints(_ vessel: Vessel, limit: Int) -> [SIMD3<Float>] {
        let points = vesselPoints[vessel] ?? []
        let step = max(1, points.count / max(limit, 1))
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    func vesselSurface(_ vessel: Vessel) -> ContactSolver.VesselGeometry? { vesselGeometry[vessel] }

    func vesselTop(_ vessel: Vessel) -> Float {
        vesselBounds[vessel]?.max.y ?? (vessel == .cup ? 0.0463 : 0.136)
    }

    private func url(_ name: String) -> URL? {
        let url = Self.directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadEverything() async {
        async let meshData = Self.parseScoopMeshes(directory: Self.directory)
        async let images = Self.decodeScoopTextures(directory: Self.directory)
        async let environmentImage = Self.decodeEnvironment(url(named: "studio.exr"))

        for vessel in Vessel.allCases {
            let name = vessel == .cup ? "Cup.usdz" : "Cone.usdz"
            if let url = url(name), let entity = try? await Entity(contentsOf: url) {
                vessels[vessel] = entity
                report.append("\(name): loaded")
            } else {
                vessels[vessel] = Self.placeholderVessel(vessel)
                report.append("\(name): MISSING, using placeholder")
            }
            vesselBounds[vessel] = vessels[vessel]!.visualBounds(relativeTo: nil)
        }

        for vessel in Vessel.allCases {
            let geometry = Self.geometry(of: vessels[vessel]!)
            vesselPoints[vessel] = geometry.points
            vesselGeometry[vessel] = ContactSolver.VesselGeometry(points: geometry.points, triangles: geometry.triangles)
            cavityFloor[vessel] = Self.floorHeight(geometry.triangles, top: vesselTop(vessel), radius: vesselHalfWidth(vessel))
        }

        let (candy, candyReport) = await CandyLibrary.load(gummyBearURL: url("GummyBear.usdz"))
        self.candy = candy
        report += candyReport

        if let url = url("placements.json"), let data = try? Data(contentsOf: url), let parsed = Placements.parse(data) {
            placements = parsed
            report.append("placements.json: loaded")
        } else {
            report.append("placements.json: MISSING, using fallback")
        }

        let parsed = await meshData
        for slot in 1...3 {
            let entry = parsed[slot - 1]
            let data = entry.data ?? ScoopMeshData.placeholder(slot: slot)
            report.append("Scoop\(slot).scoopmesh: " + (entry.data != nil
                ? "\(data.vertexCount) verts, poses \(data.poseNames.joined(separator: "/"))"
                : "MISSING (\(entry.error ?? "?")), using placeholder"))
            let set = try! ScoopMeshSet(slot: slot, data: data, engine: engine)
            set.preloadStaticMeshes()
            set.preloadMorphers(3)
            scoopSets.append(set)
        }
        engine.flush()

        let meshes = scoopSets.map(\.data)
        let placementsCopy = placements
        let geometry = vesselGeometry
        let liftTask = Task.detached(priority: .userInitiated) {
            await ContactSolver.lifts(ContactSolver.problems(meshes: meshes, placements: placementsCopy,
                                                             vessels: geometry, withTriangles: false))
        }

        let decoded = await images
        var missing = 0
        for slot in 1...3 {
            var row: [Flavor: PhysicallyBasedMaterial] = [:]
            for flavor in Flavor.allCases {
                var material = PhysicallyBasedMaterial()
                material.metallic = .init(floatLiteral: 0)
                material.specular = .init(floatLiteral: 0.45)
                let key = "Scoop\(slot)_\(flavor.rawValue)"
                if let image = decoded[key + "_basecolor"],
                   let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) {
                    material.baseColor = .init(tint: .white, texture: .init(texture))
                } else {
                    missing += 1
                    material.baseColor = .init(tint: Self.fallbackColor(flavor))
                }
                if let image = decoded[key + "_normal"],
                   let texture = try? await TextureResource(image: image, options: .init(semantic: .normal)) {
                    material.normal = .init(texture: .init(texture))
                } else {
                    missing += 1
                }
                if let image = decoded[key + "_roughness"],
                   let texture = try? await TextureResource(image: image, options: .init(semantic: .raw)) {
                    material.roughness = .init(scale: 1, texture: .init(texture))
                } else {
                    missing += 1
                    material.roughness = .init(floatLiteral: 0.75)
                }
                row[flavor] = material
            }
            scoopMaterials.append(row)
        }
        report.append(missing == 0 ? "Scoop textures: 27 loaded" : "Scoop textures: \(missing) of 27 MISSING")

        if let image = await environmentImage, let env = try? await EnvironmentResource(equirectangular: image) {
            environment = env
            report.append("studio.exr: loaded \(image.width)×\(image.height)")
        } else {
            report.append("studio.exr: MISSING, using default lighting")
        }

        contactLift = await liftTask.value
    }

    private func url(named name: String) -> URL? { url(name) }

    /// Highest flat, near-axis surface in the vessel's lower half: the floor its opening ends on.
    private static func floorHeight(_ triangles: [SIMD3<Float>], top: Float, radius: Float) -> Float {
        var floor: Float = 0
        var t = 0
        while t + 2 < triangles.count {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            t += 3
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let centroid = (a + b + c) / 3
            guard length > 1e-12, abs(cross.y / length) > 0.7, centroid.y < top / 2,
                  simd_length(SIMD2(centroid.x, centroid.z)) < 0.3 * radius else { continue }
            floor = max(floor, centroid.y)
        }
        return floor
    }

    private static func geometry(of entity: Entity) -> (points: [SIMD3<Float>], triangles: [SIMD3<Float>]) {
        var points: [SIMD3<Float>] = []
        var triangles: [SIMD3<Float>] = []
        func visit(_ node: Entity) {
            if let model = node.components[ModelComponent.self] {
                let toRoot = node.transformMatrix(relativeTo: entity)
                let contents = model.mesh.contents
                for instance in contents.instances {
                    guard let meshModel = contents.models[instance.model] else { continue }
                    let matrix = toRoot * instance.transform
                    for part in meshModel.parts {
                        let local = part.positions.elements.map { p -> SIMD3<Float> in
                            let w = matrix * SIMD4<Float>(p, 1)
                            return [w.x, w.y, w.z]
                        }
                        points += local
                        if let indices = part.triangleIndices?.elements {
                            for index in indices where Int(index) < local.count {
                                triangles.append(local[Int(index)])
                            }
                        }
                    }
                }
            }
            for child in node.children { visit(child) }
        }
        visit(entity)
        return (points, triangles)
    }

    /// Logs any placed scoop pose that sits inside the scoops beneath it, so an asset regression shows up
    /// in the log. Runs in the background after launch.
    func checkContacts(log: @escaping @MainActor (String) -> Void) {
        let meshes = scoopSets.map(\.data)
        let placementsCopy = placements
        let geometry = vesselGeometry
        Task.detached(priority: .background) {
            let problems = ContactSolver.problems(meshes: meshes, placements: placementsCopy, vessels: geometry, withTriangles: true)
            let results = await ContactSolver.penetrations(problems)
            let lines = results.sorted { $0.key < $1.key }.map { key, value in
                value.vertices == 0
                    ? "\(key) clear"
                    : String(format: "%@ %.1f mm inside (%d vertices)", key, value.depth * 1000, value.vertices)
            }
            await log("Contact check (placed pose vs scoops beneath): " + lines.joined(separator: ", "))
        }
    }

    private struct ParsedMesh: Sendable {
        var data: ScoopMeshData?
        var error: String?
    }

    nonisolated private static func parseScoopMeshes(directory: URL) async -> [ParsedMesh] {
        await withTaskGroup(of: (Int, ParsedMesh).self) { group in
            for slot in 1...3 {
                group.addTask {
                    let url = directory.appending(path: "Scoop\(slot).scoopmesh")
                    do {
                        let data = try Data(contentsOf: url, options: .alwaysMapped)
                        return (slot, ParsedMesh(data: try ScoopMeshData.parse(data)))
                    } catch {
                        return (slot, ParsedMesh(error: error.localizedDescription))
                    }
                }
            }
            var results = [ParsedMesh](repeating: ParsedMesh(), count: 3)
            for await (slot, result) in group { results[slot - 1] = result }
            return results
        }
    }

    nonisolated private static func decodeScoopTextures(directory: URL) async -> [String: CGImage] {
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for slot in 1...3 {
                for flavor in Flavor.allCases {
                    for map in ["basecolor", "normal", "roughness"] {
                        let key = "Scoop\(slot)_\(flavor.rawValue)_\(map)"
                        group.addTask {
                            let url = directory.appending(path: key + ".png")
                            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (key, nil) }
                            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                            return (key, CGImageSourceCreateImageAtIndex(source, 0, options))
                        }
                    }
                }
            }
            var images: [String: CGImage] = [:]
            for await (key, image) in group {
                if let image { images[key] = image }
            }
            return images
        }
    }

    nonisolated private static func decodeEnvironment(_ url: URL?) async -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private static func fallbackColor(_ flavor: Flavor) -> UIColor {
        switch flavor {
        case .vanilla: UIColor(red: 0.96, green: 0.86, blue: 0.62, alpha: 1)
        case .chocolate: UIColor(red: 0.36, green: 0.2, blue: 0.12, alpha: 1)
        case .cookies: UIColor(red: 0.88, green: 0.87, blue: 0.84, alpha: 1)
        }
    }

    private static func placeholderVessel(_ vessel: Vessel) -> Entity {
        switch vessel {
        case .cup:
            let model = ModelEntity(mesh: .generateCylinder(height: 0.046, radius: 0.042),
                                    materials: [SimpleMaterial(color: .white, roughness: 0.5, isMetallic: false)])
            model.position.y = 0.023
            let root = Entity()
            root.addChild(model)
            return root
        case .cone:
            let model = ModelEntity(mesh: .generateCone(height: 0.136, radius: 0.028),
                                    materials: [SimpleMaterial(color: UIColor(red: 0.8, green: 0.55, blue: 0.3, alpha: 1), roughness: 0.7, isMetallic: false)])
            model.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
            model.position.y = 0.068
            let root = Entity()
            root.addChild(model)
            return root
        }
    }
}
