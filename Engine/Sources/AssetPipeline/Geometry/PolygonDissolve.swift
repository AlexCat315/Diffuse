import SIMDCompat

extension PolygonMesh {
    /// Merges connected coplanar face regions across selected interior edges.
    /// Regions with holes, material boundaries or incompatible UVs are rejected.
    /// Returns the merged face indices; failures leave the mesh unchanged.
    @discardableResult
    public mutating func dissolve(edges selection: Set<PolygonMeshEdge>,
                                  limits: GeometryLimits = .init()) throws -> Set<Int> {
        try validate(limits: limits)
        let uses = try edgeUses()
        guard !selection.isEmpty, selection.allSatisfy({ uses[$0]?.count == 2 }) else {
            throw GeometryError.invalidParameter("dissolve requires interior edges")
        }
        var parents = Array(faces.indices)
        func root(_ index: Int) -> Int {
            var cursor = index
            while parents[cursor] != cursor {
                parents[cursor] = parents[parents[cursor]]
                cursor = parents[cursor]
            }
            return cursor
        }
        for edge in selection.sorted() {
            let adjacent = uses[edge]!
            let a = root(adjacent[0].face), b = root(adjacent[1].face)
            parents[max(a,b)] = min(a,b)
        }
        var groups: [Int: [Int]] = [:]
        for i in faces.indices { groups[root(i),default: []].append(i) }
        var result = PolygonMesh(positions: positions,faces: []), merged = Set<Int>()
        for group in groups.values.sorted(by: { $0[0] < $1[0] }) {
            if group.count == 1 { result.faces.append(faces[group[0]]); continue }
            merged.insert(result.faces.count)
            result.faces.append(try dissolvedFace(group,uses: uses))
        }
        result = result.compacted()
        try result.validate(limits: limits)
        _ = try result.edgeUses()
        for face in result.faces { _ = try triangulate(face,positions: result.positions) }
        self = result
        return merged
    }

    private func dissolvedFace(_ indices: [Int],uses: [PolygonMeshEdge: [PolygonEdgeUse]]) throws -> PolygonFace {
        let region = Set(indices)
        let uvs = try dissolveAttributes(indices)
        var next: [Int: Int] = [:], incoming = Set<Int>()
        for index in indices {
            let vertices = faces[index].vertices
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i+1)%vertices.count]
                if uses[.init(a,b)]!.allSatisfy({ region.contains($0.face) }), uses[.init(a,b)]!.count == 2 { continue }
                guard next.updateValue(b,forKey: a) == nil, incoming.insert(b).inserted else {
                    throw GeometryError.invalidMesh("dissolve region has a branching boundary")
                }
            }
        }
        guard (3...256).contains(next.count), let start = next.keys.min() else {
            throw GeometryError.invalidMesh("dissolve region has no supported polygon boundary")
        }
        var boundary: [Int] = [], visited = Set<Int>(), cursor = start
        while visited.insert(cursor).inserted {
            boundary.append(cursor)
            guard let successor = next[cursor] else { throw GeometryError.invalidMesh("open dissolve boundary") }
            cursor = successor
        }
        guard cursor == start, visited.count == next.count else {
            throw GeometryError.invalidMesh("dissolve region contains a hole or disconnected boundary")
        }
        return PolygonFace(boundary,uvs: uvs.map { values in boundary.map { values[$0]! } },materialIndex: faces[indices[0]].materialIndex)
    }
}
