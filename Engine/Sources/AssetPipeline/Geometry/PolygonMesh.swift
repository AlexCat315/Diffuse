import Foundation
import SIMDCompat

public enum GeometryError: Error, Equatable, CustomStringConvertible {
    case invalidMesh(String)
    case invalidParameter(String)
    case budgetExceeded
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case let .invalidMesh(reason): return "Invalid geometry: \(reason)"
        case let .invalidParameter(name): return "Invalid geometry parameter: \(name)"
        case .budgetExceeded: return "Geometry evaluation exceeded its vertex/corner budget"
        case let .unsupportedVersion(version): return "Unsupported geometry document version: \(version)"
        }
    }
}

/// Bounds both control topology and the expanded GPU stream before allocation.
public struct GeometryLimits: Sendable {
    public var maxVertices: Int
    public var maxFaceCorners: Int

    public init(maxVertices: Int = 250_000, maxFaceCorners: Int = 1_000_000) {
        self.maxVertices = maxVertices
        self.maxFaceCorners = maxFaceCorners
    }

    func check(vertices: Int, corners: Int) throws {
        guard vertices >= 0, corners >= 0, vertices <= maxVertices, corners <= maxFaceCorners else {
            throw GeometryError.budgetExceeded
        }
    }
}

public struct PolygonFace: Codable, Equatable, Sendable {
    public var vertices: [Int]
    /// Per-corner UVs allow seams without splitting the editable control mesh.
    public var uvs: [SIMD2<Float>]?
    public var materialIndex: Int

    public init(_ vertices: [Int], uvs: [SIMD2<Float>]? = nil, materialIndex: Int = 0) {
        self.vertices = vertices
        self.uvs = uvs
        self.materialIndex = materialIndex
    }
}

/// Authored polygon topology, independent of the triangulated render stream.
public struct PolygonMesh: Codable, Equatable, Sendable {
    public var positions: [SIMD3<Float>]
    public var faces: [PolygonFace]

    public init(positions: [SIMD3<Float>], faces: [PolygonFace]) {
        self.positions = positions
        self.faces = faces
    }

    public func validate(limits: GeometryLimits = .init()) throws {
        try limits.check(vertices: positions.count, corners: 0)
        guard !positions.isEmpty, !faces.isEmpty else { throw GeometryError.invalidMesh("empty mesh") }
        guard positions.allSatisfy(geometryFinite) else { throw GeometryError.invalidMesh("non-finite position") }
        var corners = 0
        for face in faces {
            guard (3...256).contains(face.vertices.count),
                  Set(face.vertices).count == face.vertices.count,
                  face.vertices.allSatisfy({ positions.indices.contains($0) }),
                  face.materialIndex >= 0 else { throw GeometryError.invalidMesh("invalid polygon indices/material") }
            guard face.vertices.count <= limits.maxFaceCorners - corners else { throw GeometryError.budgetExceeded }
            corners += face.vertices.count
            if let uvs = face.uvs {
                guard uvs.count == face.vertices.count, uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                    throw GeometryError.invalidMesh("invalid corner UVs")
                }
            }
        }
    }

    /// Edits commit only after validation; a failed edit leaves the mesh intact.
    public mutating func translate(vertices selection: Set<Int>, by offset: SIMD3<Float>,
                                   limits: GeometryLimits = .init()) throws {
        guard geometryFinite(offset), selection.allSatisfy({ positions.indices.contains($0) }) else {
            throw GeometryError.invalidParameter("vertex selection/offset")
        }
        var result = self
        for index in selection { result.positions[index] += offset }
        try result.validate(limits: limits)
        self = result
    }

    /// Extrudes one polygon, replacing it with a cap and connecting side quads.
    public mutating func extrude(face index: Int, by offset: SIMD3<Float>,
                                 limits: GeometryLimits = .init()) throws {
        try validate(limits: limits)
        guard faces.indices.contains(index), geometryFinite(offset), simd_length_squared(offset) > 0 else {
            throw GeometryError.invalidParameter("extrusion face/offset")
        }
        let face = faces[index]
        let corners = faces.reduce(0) { $0 + $1.vertices.count }
        try limits.check(vertices: positions.count + face.vertices.count, corners: corners + face.vertices.count * 4)
        var result = self
        let start = result.positions.count
        result.positions += face.vertices.map { positions[$0] + offset }
        result.faces[index] = PolygonFace(Array(start..<(start + face.vertices.count)),
                                          uvs: face.uvs, materialIndex: face.materialIndex)
        for i in face.vertices.indices {
            let j = (i + 1) % face.vertices.count
            result.faces.append(PolygonFace([face.vertices[i], face.vertices[j], start + j, start + i],
                uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], materialIndex: face.materialIndex))
        }
        try result.validate(limits: limits)
        self = result
    }

    /// Triangulated control topology, without the renderer's split corners.
    public func topologySlice() throws -> MeshTopologySlice {
        try validate()
        var triangles: [UInt32] = []
        for face in faces {
            triangles += try triangulate(face, positions: positions).map { UInt32(face.vertices[$0]) }
        }
        return MeshTopologySlice(positions: positions, triangleIndices: triangles)
    }
}

public struct PolygonMeshEdge: Hashable, Comparable, Sendable {
    public let a: Int
    public let b: Int
    public init(_ a: Int, _ b: Int) { self.a = min(a, b); self.b = max(a, b) }
    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.a, lhs.b) < (rhs.a, rhs.b) }
}

typealias PolygonEdge = PolygonMeshEdge

struct PolygonEdgeUse {
    var face: Int
    var corner: Int
    var start: Int
    var end: Int
}

extension PolygonMesh {
    func edgeUses() throws -> [PolygonEdge: [PolygonEdgeUse]] {
        var result: [PolygonEdge: [PolygonEdgeUse]] = [:]
        for (index, face) in faces.enumerated() {
            for i in face.vertices.indices {
                let a = face.vertices[i], b = face.vertices[(i + 1) % face.vertices.count]
                let edge = PolygonEdge(a, b)
                result[edge, default: []].append(.init(face: index, corner: i, start: a, end: b))
                let uses = result[edge]!
                guard uses.count <= 2, uses.count == 1 || uses[0].start != a else {
                    throw GeometryError.invalidMesh("non-manifold or inconsistently wound edge")
                }
            }
        }
        // Edges alone cannot detect two disconnected surface fans that share
        // one vertex. Union face corners through each shared edge to reject it.
        var starts: [Int] = [], cornerVertices: [Int] = []
        for face in faces {
            starts.append(cornerVertices.count)
            cornerVertices += face.vertices
        }
        var parents = Array(cornerVertices.indices)
        func root(_ index: Int) -> Int {
            var cursor = index
            while parents[cursor] != cursor {
                parents[cursor] = parents[parents[cursor]]
                cursor = parents[cursor]
            }
            return cursor
        }
        for uses in result.values where uses.count == 2 {
            let a = uses[0], b = uses[1]
            let aStart = starts[a.face] + a.corner
            let aEnd = starts[a.face] + (a.corner + 1) % faces[a.face].vertices.count
            let bStart = starts[b.face] + b.corner
            let bEnd = starts[b.face] + (b.corner + 1) % faces[b.face].vertices.count
            parents[root(aStart)] = root(bEnd)
            parents[root(aEnd)] = root(bStart)
        }
        var fans: [Int: Int] = [:]
        for i in cornerVertices.indices {
            let vertex = cornerVertices[i], fan = root(i)
            if let existing = fans[vertex], existing != fan {
                throw GeometryError.invalidMesh("disconnected surface fans at vertex")
            }
            fans[vertex] = fan
        }
        return result
    }
}

func geometryFinite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }

func geometryNormal(_ face: PolygonFace, positions: [SIMD3<Float>]) -> SIMD3<Float> {
    // Newell's method uses the entire polygon, including concave faces.
    var normal = SIMD3<Float>.zero
    let origin = positions[face.vertices[0]]
    for i in face.vertices.indices {
        let a = positions[face.vertices[i]] - origin
        let b = positions[face.vertices[(i + 1) % face.vertices.count]] - origin
        normal += simd_cross(a, b)
    }
    return normal
}

func geometryUnit(_ value: SIMD3<Float>, fallback: SIMD3<Float> = SIMD3(0, 1, 0)) -> SIMD3<Float> {
    let length = simd_length(value)
    return length.isFinite && length > 1e-12 ? value / length : fallback
}
