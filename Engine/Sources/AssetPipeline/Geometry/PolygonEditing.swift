import Foundation
import SIMDCompat

extension PolygonMesh {
    public var edges: [PolygonMeshEdge] {
        var result = Set<PolygonMeshEdge>()
        for face in faces {
            for i in face.vertices.indices { result.insert(.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count])) }
        }
        return result.sorted()
    }

    /// Applies an affine transform to a vertex selection in control space.
    public mutating func transform(vertices selection: Set<Int>, by matrix: simd_float4x4,
                                   limits: GeometryLimits = .init()) throws {
        try validate(limits: limits)
        guard selection.allSatisfy({ positions.indices.contains($0) }),
              (0..<4).allSatisfy({ column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }),
              abs(matrix.columns.0.w) < 1e-6, abs(matrix.columns.1.w) < 1e-6,
              abs(matrix.columns.2.w) < 1e-6, abs(matrix.columns.3.w-1) < 1e-6 else {
            throw GeometryError.invalidParameter("vertex selection/affine transform")
        }
        var result = self
        for index in selection {
            let p = matrix * SIMD4(positions[index],1)
            result.positions[index] = SIMD3(p.x,p.y,p.z)
        }
        try result.validate(limits: limits)
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
    }

    /// Extrudes connected face regions without generating internal side walls.
    /// Cap face indices are preserved. Unused interior base vertices are removed.
    public mutating func extrude(faces selection: Set<Int>, by offset: SIMD3<Float>,
                                 limits: GeometryLimits = .init()) throws {
        try validate(limits: limits)
        guard !selection.isEmpty, selection.allSatisfy({ faces.indices.contains($0) }),
              geometryFinite(offset), simd_length_squared(offset) > 0 else {
            throw GeometryError.invalidParameter("extrusion region/offset")
        }
        let uses = try edgeUses()
        let boundary = uses.keys.sorted().compactMap { edge -> PolygonEdgeUse? in
            let selected = uses[edge]!.filter { selection.contains($0.face) }
            return selected.count == 1 ? selected[0] : nil
        }
        let selectedVertices = Set(selection.flatMap { faces[$0].vertices }).sorted()
        var retained = Set(faces.enumerated().filter { !selection.contains($0.offset) }.flatMap { $0.element.vertices })
        for edge in boundary { retained.insert(edge.start); retained.insert(edge.end) }
        let baseVertices = retained.sorted()
        let corners = faces.reduce(0) { $0 + $1.vertices.count }
        guard boundary.count <= (limits.maxFaceCorners-corners)/4 else { throw GeometryError.budgetExceeded }
        try limits.check(vertices: baseVertices.count+selectedVertices.count,corners: corners+boundary.count*4)
        let base = Dictionary(uniqueKeysWithValues: baseVertices.enumerated().map { ($0.element,$0.offset) })
        let cap = Dictionary(uniqueKeysWithValues: selectedVertices.enumerated().map { ($0.element,baseVertices.count+$0.offset) })
        var result = PolygonMesh(positions: baseVertices.map { positions[$0] } + selectedVertices.map { positions[$0]+offset },faces: [])
        result.faces = faces.enumerated().map { index,face in
            let remap = selection.contains(index) ? cap : base
            return PolygonFace(face.vertices.map { remap[$0]! },uvs: face.uvs,materialIndex: face.materialIndex)
        }
        for edge in boundary {
            result.faces.append(PolygonFace([base[edge.start]!,base[edge.end]!,cap[edge.end]!,cap[edge.start]!],
                uvs: [SIMD2(0,0),SIMD2(1,0),SIMD2(1,1),SIMD2(0,1)],materialIndex: faces[edge.face].materialIndex))
        }
        try result.validate(limits: limits)
        _ = try result.edgeUses()
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
    }
}
