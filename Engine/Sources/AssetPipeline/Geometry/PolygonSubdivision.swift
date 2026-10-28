import SIMDCompat

extension PolygonMesh {
    /// Splits selected polygons into quads without smoothing or moving the
    /// existing vertices. Shared midpoints are inserted into adjacent faces.
    @discardableResult
    public mutating func subdivide(faces selection: Set<Int>, limits: GeometryLimits = .init()) throws -> Set<Int> {
        try validate(limits: limits)
        guard !selection.isEmpty, selection.allSatisfy({ faces.indices.contains($0) }) else {
            throw GeometryError.invalidParameter("subdivision face selection")
        }
        _ = try edgeUses()
        for index in selection {
            let face = faces[index], normal = geometryNormal(face,positions: positions)
            let center = face.vertices.reduce(SIMD3<Float>.zero) { $0+positions[$1]/Float(face.vertices.count) }
            let tolerance = simd_length_squared(normal)*1e-6
            guard face.vertices.indices.allSatisfy({ i in
                let a = positions[face.vertices[i]], b = positions[face.vertices[(i+1)%face.vertices.count]]
                return simd_dot(simd_cross(b-a,center-a),normal) >= -tolerance
            }) else { throw GeometryError.invalidMesh("subdivide concave faces after triangulating them") }
        }
        let splitSet = Set(selection.flatMap { index in
            let vertices = faces[index].vertices
            return vertices.indices.map { PolygonMeshEdge(vertices[$0],vertices[($0+1)%vertices.count]) }
        })
        let splitEdges = splitSet.sorted()
        let selectedCorners = selection.reduce(0) { $0+faces[$1].vertices.count }
        let otherCorners = faces.enumerated().filter { !selection.contains($0.offset) }.reduce(0) { total, item in
            let vertices = item.element.vertices
            return total+vertices.count+vertices.indices.filter {
                splitSet.contains(.init(vertices[$0],vertices[($0+1)%vertices.count]))
            }.count
        }
        guard selectedCorners <= (limits.maxFaceCorners-otherCorners)/4 else { throw GeometryError.budgetExceeded }
        try limits.check(vertices: positions.count+splitEdges.count+selection.count,corners: otherCorners+selectedCorners*4)
        var result = PolygonMesh(positions: positions,faces: [])
        var midpoints: [PolygonMeshEdge: Int] = [:]
        for edge in splitEdges {
            midpoints[edge] = result.positions.count
            result.positions.append((positions[edge.a]+positions[edge.b])*0.5)
        }
        var selected = Set<Int>()
        for (index,face) in faces.enumerated() {
            let count = face.vertices.count
            if selection.contains(index) {
                let center = result.positions.count
                result.positions.append(face.vertices.reduce(.zero) { $0+positions[$1]/Float(count) })
                let centerUV = face.uvs.map { $0.reduce(SIMD2<Float>.zero) { $0+$1/Float(count) } }
                for i in face.vertices.indices {
                    let prev = (i+count-1)%count, next = (i+1)%count
                    let uv = face.uvs.map { [$0[i],($0[i]+$0[next])*0.5,centerUV!,($0[prev]+$0[i])*0.5] }
                    selected.insert(result.faces.count)
                    result.faces.append(.init([face.vertices[i],midpoints[.init(face.vertices[i],face.vertices[next])]!,center,
                                               midpoints[.init(face.vertices[prev],face.vertices[i])]!],
                                              uvs: uv,materialIndex: face.materialIndex))
                }
            } else {
                var vertices: [Int] = [], uvs: [SIMD2<Float>]? = face.uvs == nil ? nil : []
                for i in face.vertices.indices {
                    let next = (i+1)%count
                    vertices.append(face.vertices[i])
                    if let uv = face.uvs { uvs?.append(uv[i]) }
                    if let midpoint = midpoints[.init(face.vertices[i],face.vertices[next])] {
                        vertices.append(midpoint)
                        if let uv = face.uvs { uvs?.append((uv[i]+uv[next])*0.5) }
                    }
                }
                result.faces.append(.init(vertices,uvs: uvs,materialIndex: face.materialIndex))
            }
        }
        try result.validate(limits: limits)
        _ = try result.edgeUses()
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
        return selected
    }

    @discardableResult
    public mutating func triangulateFaces(_ selection: Set<Int>, limits: GeometryLimits = .init()) throws -> Set<Int> {
        try validate(limits: limits)
        guard !selection.isEmpty, selection.allSatisfy({ faces.indices.contains($0) }) else {
            throw GeometryError.invalidParameter("triangulation face selection")
        }
        let corners = faces.enumerated().reduce(0) { $0+(selection.contains($1.offset) ? ($1.element.vertices.count-2)*3 : $1.element.vertices.count) }
        try limits.check(vertices: positions.count,corners: corners)
        var result = self, polygons: [PolygonFace] = [], selected = Set<Int>()
        for (index,face) in faces.enumerated() {
            if !selection.contains(index) { polygons.append(face); continue }
            let triangles = try triangulate(face,positions: positions)
            for i in stride(from: 0,to: triangles.count,by: 3) {
                let corners = Array(triangles[i..<i+3])
                selected.insert(polygons.count)
                polygons.append(.init(corners.map { face.vertices[$0] },uvs: face.uvs.map { uv in corners.map { uv[$0] } },materialIndex: face.materialIndex))
            }
        }
        result.faces = polygons
        try result.validate(limits: limits)
        self = result
        return selected
    }
}
