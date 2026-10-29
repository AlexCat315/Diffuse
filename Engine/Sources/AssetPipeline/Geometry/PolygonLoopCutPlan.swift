import SIMDCompat

struct PolygonLoopCutPlan {
    /// Start vertex gives a consistent slide direction across the edge ring.
    var starts: [PolygonMeshEdge: Int] = [:]
    var faces: [Int: Int] = [:]

    init(mesh: PolygonMesh,seed: PolygonMeshEdge) throws {
        let uses = try mesh.edgeUses()
        guard uses[.init(seed.a,seed.b)] != nil else { throw GeometryError.invalidParameter("loop cut seed edge") }
        starts[seed] = seed.a
        var pending = [seed], cursor = 0
        while cursor < pending.count {
            let edge = pending[cursor]; cursor += 1
            for use in uses[.init(edge.a,edge.b)] ?? [] {
                let face = mesh.faces[use.face]
                guard face.vertices.count == 4 else { continue }
                let k = face.vertices.indices.first { PolygonMeshEdge(face.vertices[$0],face.vertices[($0+1)%4]) == edge }!
                if let previous = faces[use.face] {
                    guard k == previous || k == (previous+2)%4 else { throw GeometryError.invalidMesh("loop cut crosses itself") }
                } else {
                    _ = try PolygonInsetFace(face: face,positions: mesh.positions)
                    faces[use.face] = k
                }
                let a = face.vertices[(k+3)%4], b = face.vertices[(k+2)%4], opposite = PolygonMeshEdge(a,b)
                let start = starts[edge] == face.vertices[k] ? a : b
                if let previous = starts[opposite] {
                    guard previous == start else { throw GeometryError.invalidMesh("loop cut ring is twisted") }
                } else { starts[opposite] = start; pending.append(opposite) }
            }
        }
        guard !faces.isEmpty else { throw GeometryError.invalidMesh("loop cut requires a quad strip") }
        for (index,face) in mesh.faces.enumerated() where faces[index] == nil {
            guard face.vertices.indices.contains(where: { starts[.init(face.vertices[$0],face.vertices[($0+1)%face.vertices.count])] != nil }) else { continue }
            _ = try triangulate(face,positions: mesh.positions)
            let vertices = face.vertices.map { mesh.positions[$0] }, origin = vertices[0]
            let normal = geometryUnit(geometryNormal(face,positions: mesh.positions))
            let extent = vertices.reduce(Float(0)) { max($0,simd_length($1-origin)) }
            guard vertices.allSatisfy({ abs(simd_dot($0-origin,normal)) <= max(1e-6,extent*1e-5) }) else {
                throw GeometryError.invalidMesh("loop cut requires planar terminal faces")
            }
            if let uv = face.uvs { _ = try PolygonUVProjection(positions: vertices,uvs: uv) }
        }
    }
}
