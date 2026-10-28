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
        try validateDissolveUVs(vertices,values: values)
        return values
    }

    private func validateDissolveUVs(_ vertices: [Int],values: [Int: SIMD2<Float>]) throws {
        let a = vertices[0], origin = positions[a]
        let b = vertices.max { simd_length_squared(positions[$0]-origin) < simd_length_squared(positions[$1]-origin) }!
        let e1 = positions[b]-origin
        let c = vertices.max { simd_length_squared(simd_cross(e1,positions[$0]-origin)) < simd_length_squared(simd_cross(e1,positions[$1]-origin)) }!
        let e2 = positions[c]-origin
        let d11 = simd_dot(e1,e1), d12 = simd_dot(e1,e2), d22 = simd_dot(e2,e2), determinant = d11*d22-d12*d12
        guard determinant.isFinite, determinant > max(1e-24,d11*d22*1e-8) else { throw GeometryError.invalidMesh("degenerate dissolve UV frame") }
        let uv = values[a]!, du = values[b]!-uv, dv = values[c]!-uv
        let tolerance = max(1e-5,values.values.reduce(Float(0)) { max($0,simd_length($1-uv)) }*1e-5)
        for vertex in vertices {
            let point = positions[vertex]-origin, u = simd_dot(point,e1), v = simd_dot(point,e2)
            let expected = uv+du*((u*d22-v*d12)/determinant)+dv*((v*d11-u*d12)/determinant)
            guard simd_distance(expected,values[vertex]!) <= tolerance else {
                throw GeometryError.invalidMesh("dissolve would change UV interpolation")
            }
        }
    }
}
