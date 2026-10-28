extension PolygonMesh {
    /// Deletes selected components and their incident faces. Unreferenced
    /// vertices are compacted; removing the last face leaves an empty asset.
    public mutating func delete(vertices vertexSelection: Set<Int> = [],
                                edges edgeSelection: Set<PolygonMeshEdge> = [],
                                faces faceSelection: Set<Int> = [],
                                limits: GeometryLimits = .init()) throws {
        try validate(limits: limits)
        guard !vertexSelection.isEmpty || !edgeSelection.isEmpty || !faceSelection.isEmpty,
              vertexSelection.allSatisfy({ positions.indices.contains($0) }),
              faceSelection.allSatisfy({ faces.indices.contains($0) }),
              edgeSelection.isSubset(of: Set(edges)) else {
            throw GeometryError.invalidParameter("delete component selection")
        }
        let retained = faces.enumerated().filter { index, face in
            !faceSelection.contains(index) && !face.vertices.contains(where: vertexSelection.contains) &&
                !face.vertices.indices.contains { corner in
                    edgeSelection.contains(.init(face.vertices[corner],face.vertices[(corner+1)%face.vertices.count]))
                }
        }.map(\.element)
        let result = PolygonMesh(positions: positions,faces: retained).compacted()
        try result.validate(limits: limits)
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
    }

    func compacted() -> PolygonMesh {
        let retained = Set(faces.flatMap(\.vertices)).sorted()
        let indices = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element,$0.offset) })
        return PolygonMesh(positions: retained.map { positions[$0] },faces: faces.map { face in
            PolygonFace(face.vertices.map { indices[$0]! },uvs: face.uvs,materialIndex: face.materialIndex)
        })
    }
}
