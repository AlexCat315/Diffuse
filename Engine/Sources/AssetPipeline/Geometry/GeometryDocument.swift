import Foundation
import SIMDCompat

public enum GeometrySource: Codable, Equatable, Sendable {
    case polygon(mesh: PolygonMesh)
    case box(size: SIMD3<Float>)
    case grid(size: SIMD2<Float>, segments: SIMD2<Int>)
    case tube(spline: BezierSpline, radius: Float, radialSegments: Int, samplesPerSegment: Int, capped: Bool)

    public func evaluate(limits: GeometryLimits = .init()) throws -> PolygonMesh {
        let mesh: PolygonMesh
        switch self {
        case let .polygon(polygon): mesh = polygon
        case let .box(size): mesh = try GeometryPrimitives.box(size: size)
        case let .grid(size, segments): mesh = try GeometryPrimitives.grid(size: size, segments: segments, limits: limits)
        case let .tube(spline, radius, radialSegments, samplesPerSegment, capped):
            mesh = try spline.tube(radius: radius, radialSegments: radialSegments,
                samplesPerSegment: samplesPerSegment, capped: capped, limits: limits)
        }
        try mesh.validate(limits: limits)
        return mesh
    }
}

public struct GeometryMaterial: Codable, Equatable, Sendable {
    public var name: String
    public var baseColor: SIMD4<Float>
    public var metallic: Float
    public var roughness: Float

    public init(name: String = "Material", baseColor: SIMD4<Float> = SIMD4(repeating: 1),
                metallic: Float = 0, roughness: Float = 0.5) {
        self.name = name; self.baseColor = baseColor; self.metallic = metallic; self.roughness = roughness
    }

    func bake() throws -> MeshMaterial {
        guard (0..<4).allSatisfy({ baseColor[$0].isFinite && (0...1).contains(baseColor[$0]) }),
              metallic.isFinite, roughness.isFinite, (0...1).contains(metallic), (0...1).contains(roughness) else {
            throw GeometryError.invalidParameter("material color/metallic/roughness")
        }
        return MeshMaterial(name: name, baseColorFactor: baseColor, metallicFactor: metallic, roughnessFactor: roughness)
    }
}

/// Native `.dmesh` assets retain their source and ordered, reversible operations.
/// The asset registry evaluates them into the same mesh catalog used by glTF/OBJ.
public struct GeometryDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "dmesh"
    public var version: Int
    public var name: String
    public var source: GeometrySource
    public var modifiers: [GeometryModifierEntry]
    public var shading: GeometryShading
    public var materials: [GeometryMaterial]

    public init(name: String, source: GeometrySource, modifiers: [GeometryModifierEntry] = [],
                shading: GeometryShading = .flat, materials: [GeometryMaterial] = [.init()]) {
        self.version = Self.currentVersion; self.name = name; self.source = source
        self.modifiers = modifiers; self.shading = shading; self.materials = materials
    }

    private enum CodingKeys: String, CodingKey { case version, name, source, modifiers, shading, materials }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else { throw GeometryError.unsupportedVersion(version) }
        name = try values.decode(String.self, forKey: .name)
        source = try values.decode(GeometrySource.self, forKey: .source)
        modifiers = try values.decodeIfPresent([GeometryModifierEntry].self, forKey: .modifiers) ?? []
        shading = try values.decodeIfPresent(GeometryShading.self, forKey: .shading) ?? .flat
        materials = try values.decodeIfPresent([GeometryMaterial].self, forKey: .materials) ?? [.init()]
    }

    public func evaluate(limits: GeometryLimits = .init()) throws -> GeometryEvaluation {
        guard version == Self.currentVersion else { throw GeometryError.unsupportedVersion(version) }
        guard modifiers.count <= 256, materials.count <= 256 else { throw GeometryError.budgetExceeded }
        let bakedMaterials = try materials.map { try $0.bake() }
        var mesh = try source.evaluate(limits: limits)
        for entry in modifiers where entry.enabled { mesh = try entry.operation.apply(to: mesh, limits: limits) }
        return try mesh.bake(name: name, shading: shading, materials: bakedMaterials, limits: limits)
    }

    public static func load(from url: URL) throws -> GeometryDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw GeometryError.budgetExceeded }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Validation precedes the atomic write, preserving the previous asset on failure.
    public func save(to url: URL, limits: GeometryLimits = .init()) throws {
        _ = try evaluate(limits: limits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw GeometryError.budgetExceeded }
        try data.write(to: url, options: .atomic)
    }
}
