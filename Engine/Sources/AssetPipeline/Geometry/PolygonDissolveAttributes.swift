import SIMDCompat

extension PolygonMesh {
    /// A merged polygon can store only one material and one UV per boundary
    /// corner. Prove that removing its interior does not discard a seam or
    /// change a piecewise UV mapping into a different interpolation.
    func dissolveAttributes(_ indices: [Int]) throws -> [Int: SIMD2<Float>]? {
        let first = faces[indices[0]], vertices = Set(indices.flatMap { faces[$0].vertices }).sorted()
        guard indices.allSatisfy({ faces[$0].materialIndex == first.materialIndex }) else {
            throw GeometryError.invalidMesh("dissolve crosses a material boundary")
        }
        let origin = positions[vertices[0]], normal = geometryUnit(geometryNormal(first,positions: positions))
        let extent = vertices.reduce(Float(0)) { max($0,simd_length(positions[$1]-origin)) }
        guard vertices.allSatisfy({ abs(simd_dot(positions[$0]-origin,normal)) <= max(1e-6,extent*1e-5) }) else {
            throw GeometryError.invalidMesh("dissolve requires coplanar faces")
        }
        var values: [Int: SIMD2<Float>] = [:]
        for index in indices {
            let face = faces[index]
            guard (face.uvs == nil) == (first.uvs == nil) else { throw GeometryError.invalidMesh("dissolve crosses a UV boundary") }
            guard let uvs = face.uvs else { continue }
            for (corner,vertex) in face.vertices.enumerated() {
                if let previous = values[vertex], simd_distance(previous,uvs[corner]) > 1e-5 {
                    throw GeometryError.invalidMesh("dissolve crosses a UV seam")
                }
                values[vertex] = uvs[corner]
            }
        }
        if first.uvs == nil { return nil }
        _ = try PolygonUVProjection(positions: vertices.map { positions[$0] },uvs: vertices.map { values[$0]! })
        return values
    }
}
