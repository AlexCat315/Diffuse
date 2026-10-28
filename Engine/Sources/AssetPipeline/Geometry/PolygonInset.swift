import SIMDCompat

extension PolygonMesh {
    public func suggestedInsetDistance(faces selection: Set<Int>,preferred: Float = 0.1,
                                       limits: GeometryLimits = .init()) throws -> Float {
        try validate(limits: limits)
        guard !selection.isEmpty,selection.allSatisfy({ faces.indices.contains($0) }),preferred.isFinite,preferred > 0 else {
            throw GeometryError.invalidParameter("inset selection/width")
        }
        var distance = preferred
        for index in selection.sorted() { distance = min(distance,try PolygonInsetFace(face: faces[index],positions: positions).safeDistance) }
        return distance
    }

    /// Insets each selected convex planar face independently. Cap face indices
    /// stay stable; all original boundary vertices, materials and UV seams remain.
    public mutating func inset(faces selection: Set<Int>,by distance: Float,
                               limits: GeometryLimits = .init()) throws {
        try validate(limits: limits)
        guard !selection.isEmpty,selection.allSatisfy({ faces.indices.contains($0) }),distance.isFinite,distance > 0 else {
            throw GeometryError.invalidParameter("inset selection/width")
        }
        _ = try edgeUses()
        let corners = faces.reduce(0) { $0+$1.vertices.count }, selectedCorners = selection.reduce(0) { $0+faces[$1].vertices.count }
        guard selectedCorners <= (limits.maxFaceCorners-corners)/4 else { throw GeometryError.budgetExceeded }
        try limits.check(vertices: positions.count+selectedCorners,corners: corners+selectedCorners*4)
        var result = self
        for index in selection.sorted() {
            let face = faces[index], plan = try PolygonInsetFace(face: face,positions: positions)
            let points = try plan.inset(by: distance), base = result.positions.count
            result.positions += points
            let capUVs = plan.uv.map { projection in points.map(projection.project) }
            result.faces[index] = PolygonFace(Array(base..<base+points.count),uvs: capUVs,materialIndex: face.materialIndex)
            for i in face.vertices.indices {
                let j = (i+1)%face.vertices.count
                let uvs = face.uvs.map { [$0[i],$0[j],capUVs![j],capUVs![i]] }
                result.faces.append(PolygonFace([face.vertices[i],face.vertices[j],base+j,base+i],uvs: uvs,materialIndex: face.materialIndex))
            }
        }
        try result.validate(limits: limits)
        _ = try result.edgeUses()
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
    }
}
