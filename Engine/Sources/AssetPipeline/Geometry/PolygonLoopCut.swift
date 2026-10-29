import SIMDCompat

extension PolygonMesh {
    /// Cuts the opposite-edge ring through convex planar quads. Non-quads stop
    /// propagation and receive shared edge vertices, preserving a connected surface.
    /// Slide shifts an evenly spaced bundle by one interval, without collapsing endpoints.
    @discardableResult
    public mutating func loopCut(startingAt seed: PolygonMeshEdge,cuts: Int = 1,slide: Float = 0,
                                 limits: GeometryLimits = .init()) throws -> Set<PolygonMeshEdge> {
        try validate(limits: limits)
        guard (1...64).contains(cuts),slide.isFinite,abs(slide) < 1 else { throw GeometryError.invalidParameter("loop cut count/slide") }
        let plan = try PolygonLoopCutPlan(mesh: self,seed: seed)
        let terminalCorners = faces.enumerated().filter { plan.faces[$0.offset] == nil }.reduce(0) { sum,item in
            let v = item.element.vertices
            return sum+v.indices.filter { plan.starts[.init(v[$0],v[($0+1)%v.count])] != nil }.count*cuts
        }
        let corners = faces.reduce(0) { $0+$1.vertices.count }
        try limits.check(vertices: positions.count+plan.starts.count*cuts,
                         corners: corners+plan.faces.count*cuts*4+terminalCorners)
        let fractions = (0..<cuts).map { (Float($0+1)+slide)/Float(cuts+1) }
        var result = self, cutVertices: [PolygonMeshEdge: [Int]] = [:]
        for edge in plan.starts.keys.sorted() {
            let start = plan.starts[edge]!, end = start == edge.a ? edge.b : edge.a
            cutVertices[edge] = fractions.map { t in
                let index = result.positions.count
                result.positions.append(positions[start]+(positions[end]-positions[start])*t)
                return index
            }
        }
        func boundary(_ face: PolygonFace,_ a: Int,_ b: Int) -> (vertices: [Int],uvs: [SIMD2<Float>]?) {
            let start = face.vertices[a], end = face.vertices[b], edge = PolygonMeshEdge(start,end)
            let forward = plan.starts[edge] == start
            let ids = forward ? cutVertices[edge]! : Array(cutVertices[edge]!.reversed())
            let amounts = forward ? fractions : fractions.reversed().map { 1-$0 }
            let uv = face.uvs.map { values in amounts.map { values[a]+(values[b]-values[a])*$0 } }
            return ([start]+ids+[end],uv.map { [face.uvs![a]]+$0+[face.uvs![b]] })
        }
        var selected = Set<PolygonMeshEdge>()
        for (index,face) in faces.enumerated() {
            if let k = plan.faces[index] {
                let a = boundary(face,k,(k+1)%4), b = boundary(face,(k+3)%4,(k+2)%4)
                for i in 0...cuts {
                    let uv = face.uvs.map { _ in [a.uvs![i],a.uvs![i+1],b.uvs![i+1],b.uvs![i]] }
                    let band = PolygonFace([a.vertices[i],a.vertices[i+1],b.vertices[i+1],b.vertices[i]],uvs: uv,materialIndex: face.materialIndex)
                    if i == 0 { result.faces[index] = band } else { result.faces.append(band) }
                    if i < cuts { selected.insert(.init(a.vertices[i+1],b.vertices[i+1])) }
                }
            } else {
                var ids: [Int] = [], uvs: [SIMD2<Float>]? = face.uvs == nil ? nil : []
                for i in face.vertices.indices {
                    let j = (i+1)%face.vertices.count, edge = PolygonMeshEdge(face.vertices[i],face.vertices[j])
                    if cutVertices[edge] != nil {
                        let chain = boundary(face,i,j)
                        ids += chain.vertices.dropLast()
                        if let uv = chain.uvs { uvs? += uv.dropLast() }
                    } else { ids.append(face.vertices[i]); if let uv = face.uvs { uvs?.append(uv[i]) } }
                }
                result.faces[index] = .init(ids,uvs: uvs,materialIndex: face.materialIndex)
            }
        }
        try result.validate(limits: limits)
        _ = try result.edgeUses()
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
        return selected
    }
}
