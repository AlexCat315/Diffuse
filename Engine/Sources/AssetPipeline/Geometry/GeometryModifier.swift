import Foundation
import SIMDCompat

public enum GeometryAxis: String, Codable, Sendable { case x, y, z
    var index: Int { switch self { case .x: 0; case .y: 1; case .z: 2 } }
}

public enum GeometryModifier: Codable, Equatable, Sendable {
    /// Reflection about a local-space plane. Only vertices on the seam weld.
    case mirror(axis: GeometryAxis, offset: Float, weldDistance: Float)
    /// Includes the original; offset is an absolute local-space displacement.
    case array(count: Int, offset: SIMD3<Float>)
    case subdivision(levels: Int)
    /// Symmetric shell, with side walls along open boundary edges.
    case solidify(thickness: Float)

    public func apply(to source: PolygonMesh, limits: GeometryLimits = .init()) throws -> PolygonMesh {
        try source.validate(limits: limits)
        let result: PolygonMesh
        switch self {
        case let .mirror(axis, offset, weldDistance):
            result = try source.mirrored(axis: axis.index, offset: offset, weldDistance: weldDistance, limits: limits)
        case let .array(count, offset):
            result = try source.repeated(count: count, offset: offset, limits: limits)
        case let .subdivision(levels):
            guard (0...6).contains(levels) else { throw GeometryError.invalidParameter("subdivision levels (0...6)") }
            var mesh = source
            for _ in 0..<levels { mesh = try mesh.subdivided(limits: limits) }
            result = mesh
        case let .solidify(thickness):
            result = try source.solidified(thickness: thickness, limits: limits)
        }
        try result.validate(limits: limits)
        return result
    }
}

public struct GeometryModifierEntry: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var operation: GeometryModifier

    public init(_ operation: GeometryModifier, enabled: Bool = true, id: String = UUID().uuidString) {
        self.id = id; self.operation = operation; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, operation }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older native assets did not store identity; derive it from the stack
        // position until the next save persists an explicit identifier.
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? "legacy-\(decoder.codingPath.last?.intValue ?? 0)"
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        operation = try values.decode(GeometryModifier.self, forKey: .operation)
    }
}

private extension PolygonMesh {
    var cornerCount: Int { faces.reduce(0) { $0 + $1.vertices.count } }

    func repeated(count: Int, offset: SIMD3<Float>, limits: GeometryLimits) throws -> PolygonMesh {
        guard count > 0, geometryFinite(offset) else { throw GeometryError.invalidParameter("array count/offset") }
        guard count <= limits.maxVertices / positions.count,
              count <= limits.maxFaceCorners / cornerCount else { throw GeometryError.budgetExceeded }
        var points: [SIMD3<Float>] = [], polygons: [PolygonFace] = []
        for copy in 0..<count {
            let base = points.count
            points += positions.map { $0 + offset * Float(copy) }
            polygons += faces.map { PolygonFace($0.vertices.map { $0 + base }, uvs: $0.uvs, materialIndex: $0.materialIndex) }
        }
        return PolygonMesh(positions: points, faces: polygons)
    }

    func mirrored(axis: Int, offset: Float, weldDistance: Float, limits: GeometryLimits) throws -> PolygonMesh {
        guard offset.isFinite, weldDistance.isFinite, weldDistance >= 0 else {
            throw GeometryError.invalidParameter("mirror plane/weld distance")
        }
        guard positions.count <= limits.maxVertices / 2, cornerCount <= limits.maxFaceCorners / 2 else {
            throw GeometryError.budgetExceeded
        }
        var result = self
        var remap: [Int] = []
        for i in positions.indices {
            var point = positions[i]
            if abs(point[axis] - offset) <= weldDistance {
                result.positions[i][axis] = offset
                remap.append(i)
            } else {
                point[axis] = offset + (offset - point[axis])
                remap.append(result.positions.count)
                result.positions.append(point)
            }
        }
        for face in faces {
            // A polygon already on the reflection plane is retained once.
            if face.vertices.allSatisfy({ remap[$0] == $0 }) { continue }
            result.faces.append(PolygonFace(face.vertices.reversed().map { remap[$0] },
                uvs: face.uvs.map { Array($0.reversed()) }, materialIndex: face.materialIndex))
        }
        return result
    }

    func subdivided(limits: GeometryLimits) throws -> PolygonMesh {
        let uses = try edgeUses()
        let edges = uses.keys.sorted()
        guard cornerCount <= limits.maxFaceCorners / 4 else { throw GeometryError.budgetExceeded }
        try limits.check(vertices: positions.count + edges.count + faces.count, corners: cornerCount * 4)
        var facePoints: [SIMD3<Float>] = []
        var incidentFaces = [[Int]](repeating: [], count: positions.count)
        var incidentEdges = [[PolygonEdge]](repeating: [], count: positions.count)
        for (i, face) in faces.enumerated() {
            facePoints.append(face.vertices.reduce(SIMD3<Float>.zero) { $0 + positions[$1] / Float(face.vertices.count) })
            for vertex in face.vertices { incidentFaces[vertex].append(i) }
        }
        var edgeIndices: [PolygonEdge: Int] = [:]
        var edgePoints: [SIMD3<Float>] = []
        for edge in edges {
            incidentEdges[edge.a].append(edge); incidentEdges[edge.b].append(edge)
            edgeIndices[edge] = positions.count + edgePoints.count
            let adjacent = uses[edge]!
            let midpoint = positions[edge.a] * 0.5 + positions[edge.b] * 0.5
            edgePoints.append(adjacent.count == 2
                ? (midpoint * 0.5 + facePoints[adjacent[0].face] * 0.25 + facePoints[adjacent[1].face] * 0.25) : midpoint)
        }
        var points = positions
        for i in positions.indices {
            let edges = incidentEdges[i], adjacent = incidentFaces[i]
            if edges.isEmpty { continue }
            let boundary = edges.filter { uses[$0]!.count == 1 }
            if !boundary.isEmpty {
                guard boundary.count == 2 else { throw GeometryError.invalidMesh("non-manifold boundary vertex") }
                let neighbors = boundary.map { $0.a == i ? $0.b : $0.a }
                points[i] = positions[i] * 0.75 + positions[neighbors[0]] * 0.125 + positions[neighbors[1]] * 0.125
            } else {
                let n = Float(adjacent.count)
                let f = adjacent.reduce(SIMD3<Float>.zero) { $0 + facePoints[$1] / n }
                let r = edges.reduce(SIMD3<Float>.zero) { $0 + (positions[$1.a] * 0.5 + positions[$1.b] * 0.5) / n }
                points[i] = (f + 2*r + (n-3)*positions[i]) / n
            }
        }
        let centerBase = points.count + edgePoints.count
        points += edgePoints + facePoints
        var polygons: [PolygonFace] = []
        for (index, face) in faces.enumerated() {
            let count = face.vertices.count
            let centerUV = face.uvs.map { $0.reduce(SIMD2<Float>.zero) { $0 + $1 / Float(count) } }
            for i in 0..<count {
                let prev = (i + count - 1) % count, next = (i + 1) % count
                let a = face.vertices[i], b = face.vertices[next], c = face.vertices[prev]
                let uv = face.uvs.map { [$0[i], ($0[i] + $0[next])*0.5, centerUV!, ($0[prev] + $0[i])*0.5] }
                polygons.append(PolygonFace([a, edgeIndices[PolygonEdge(a,b)]!, centerBase + index, edgeIndices[PolygonEdge(c,a)]!],
                    uvs: uv, materialIndex: face.materialIndex))
            }
        }
        return PolygonMesh(positions: points, faces: polygons)
    }

    func solidified(thickness: Float, limits: GeometryLimits) throws -> PolygonMesh {
        guard thickness.isFinite, thickness > 0 else { throw GeometryError.invalidParameter("positive shell thickness") }
        let uses = try edgeUses()
        let boundary = uses.keys.sorted().filter { uses[$0]!.count == 1 }
        guard positions.count <= limits.maxVertices / 2,
              cornerCount <= limits.maxFaceCorners / 2,
              boundary.count <= (limits.maxFaceCorners - cornerCount * 2) / 4 else { throw GeometryError.budgetExceeded }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for face in faces {
            let normal = geometryNormal(face, positions: positions)
            for vertex in face.vertices { normals[vertex] += normal }
        }
        guard normals.allSatisfy({ geometryFinite($0) && simd_length_squared($0) > 1e-20 }) else {
            throw GeometryError.invalidMesh("undefined shell normal at vertex")
        }
        normals = normals.map { geometryUnit($0) }
        let count = positions.count
        let outer = positions.indices.map { positions[$0] + normals[$0] * (thickness * 0.5) }
        let inner = positions.indices.map { positions[$0] - normals[$0] * (thickness * 0.5) }
        var polygons = faces
        polygons += faces.map { PolygonFace($0.vertices.reversed().map { $0 + count },
            uvs: $0.uvs.map { Array($0.reversed()) }, materialIndex: $0.materialIndex) }
        for edge in boundary {
            let use = uses[edge]![0], a = use.start, b = use.end
            polygons.append(PolygonFace([b, a, a + count, b + count],
                uvs: [SIMD2(0,0), SIMD2(1,0), SIMD2(1,1), SIMD2(0,1)], materialIndex: faces[use.face].materialIndex))
        }
        return PolygonMesh(positions: outer + inner, faces: polygons)
    }
}
