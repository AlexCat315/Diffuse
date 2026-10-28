import AssetPipeline
import Foundation
import SIMDCompat
import Testing

@Suite("Polygon deletion and dissolve")
struct PolygonTopologyTests {
    @Test("component deletion removes incident faces, compacts vertices and preserves retained corner data")
    func deletion() throws {
        let source = try GeometryPrimitives.box()
        var vertices = source; try vertices.delete(vertices: [0])
        #expect(vertices.faces.count == 3 && vertices.positions.count == 7)
        #expect(!vertices.positions.contains(source.positions[0]))
        #expect(vertices.faces.map(\.uvs) == [source.faces[1].uvs,source.faces[3].uvs,source.faces[5].uvs])
        var edges = source; try edges.delete(edges: [.init(0,1)])
        #expect(edges.faces.count == 4 && edges.positions.count == 8)
        var faces = source; try faces.delete(faces: [1])
        #expect(faces.faces == source.faces.enumerated().filter { $0.offset != 1 }.map(\.element))
        for mesh in [vertices,edges,faces] {
            #expect(Set(mesh.faces.flatMap(\.vertices)).count == mesh.positions.count)
            _ = try mesh.bake(name: "deleted")
        }
        let before = faces
        #expect(throws: GeometryError.self) { try faces.delete(vertices: [-1]) }
        #expect(throws: GeometryError.self) { try faces.delete(edges: [.init(0,6)]) }
        #expect(throws: GeometryError.self) { try faces.delete(faces: [100]) }
        #expect(faces == before)
    }

    @Test("an empty authored asset survives modifiers, save and catalog reload without losing its identity")
    func emptyAsset() throws {
        var mesh = try GeometryPrimitives.box()
        try mesh.delete(faces: Set(mesh.faces.indices))
        #expect(mesh.positions.isEmpty && mesh.faces.isEmpty)
        let modifiers: [GeometryModifierEntry] = [.init(.array(count: 3,offset: SIMD3(2,0,0))),
            .init(.subdivision(levels: 2)),.init(.mirror(axis: .x,offset: 0,weldDistance: 1e-5)),.init(.solidify(thickness: 0.1))]
        let document = GeometryDocument(name: "empty",source: .polygon(mesh: mesh),modifiers: modifiers)
        let evaluated = try document.evaluate()
        #expect(evaluated.mesh.vertexCount == 0 && evaluated.mesh.triangleCount == 0)
        #expect(evaluated.mesh.localBounds.min == .zero && evaluated.mesh.localBounds.max == .zero)
        #expect(evaluated.topologySlice.positions.isEmpty && evaluated.topologySlice.triangleIndices.isEmpty)
        #expect(throws: GeometryError.self) { try GeometryModifier.array(count: 0,offset: .zero).apply(to: mesh) }
        #expect(throws: GeometryError.self) { try PolygonMesh(positions: [.zero],faces: []).validate() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("surface.dmesh"), registry = AssetRegistry()
        try GeometryDocument(name: "filled",source: .box(size: .one)).save(to: url)
        let before = try #require(registry.loadProject(at: root.path).first)
        try document.save(to: url)
        let after = try #require(registry.loadProject(at: root.path).first)
        #expect(before.id == after.id && before.meshIndex == after.meshIndex)
        #expect(registry.meshAsset(for: after.meshIndex)?.triangleCount == 0)
        #expect(try GeometryDocument.load(from: url) == document)
    }

    @Test("dissolving a triangulation restores the original quad and its corner attributes")
    func triangulatedQuad() throws {
        let source = try GeometryPrimitives.box()
        var mesh = source
        let triangles = try mesh.triangulateFaces([1])
        let common = edges(mesh.faces[triangles.min()!]).intersection(edges(mesh.faces[triangles.max()!]))
        #expect(common.count == 1)
        let merged = try mesh.dissolve(edges: common)
        #expect(merged == [1])
        #expect(mesh == source)
    }

    @Test("connected coplanar regions remove internal vertices and retain concave outlines")
    func regions() throws {
        var grid = try GeometryPrimitives.grid(size: SIMD2(2,2),segments: SIMD2(2,2))
        try grid.dissolve(edges: interiorEdges(grid))
        #expect(grid.faces.count == 1 && grid.positions.count == 8)
        #expect(abs(try area(grid)-4) < 1e-5)
        var concave = try GeometryPrimitives.grid(size: SIMD2(2,2),segments: SIMD2(2,2))
        try concave.delete(faces: [3])
        try concave.dissolve(edges: interiorEdges(concave))
        #expect(concave.faces.count == 1)
        #expect(abs(try area(concave)-3) < 1e-5)
    }

    @Test("UV seams, interpolation, material boundaries, folds, holes and boundary edges cannot be silently dissolved")
    func rejectedRegions() throws {
        let source = try GeometryPrimitives.grid(size: SIMD2(2,1),segments: SIMD2(2,1))
        let selection = interiorEdges(source)
        var variants: [PolygonMesh] = []
        var seam = source; seam.faces[1].uvs = seam.faces[1].uvs?.map { $0+SIMD2(0.25,0) }; variants.append(seam)
        var mapping = source; mapping.faces[1].uvs?[2].y += 0.25; variants.append(mapping)
        var material = source; material.faces[1].materialIndex = 1; variants.append(material)
        var folded = source; folded.positions[2].y = 1; variants.append(folded)
        var mixed = source; mixed.faces[1].uvs = nil; variants.append(mixed)
        for original in variants {
            var mesh = original
            #expect(throws: GeometryError.self) { try mesh.dissolve(edges: selection) }
            #expect(mesh == original)
        }
        var boundary = source
        #expect(throws: GeometryError.self) { try boundary.dissolve(edges: [.init(0,1)]) }
        #expect(boundary == source)
        var ring = try GeometryPrimitives.grid(size: SIMD2(3,3),segments: SIMD2(3,3))
        try ring.delete(faces: [4])
        let originalRing = ring
        #expect(throws: GeometryError.self) { try ring.dissolve(edges: interiorEdges(ring)) }
        #expect(ring == originalRing)
    }

    private func edges(_ face: PolygonFace) -> Set<PolygonMeshEdge> {
        Set(face.vertices.indices.map { .init(face.vertices[$0],face.vertices[($0+1)%face.vertices.count]) })
    }
    private func interiorEdges(_ mesh: PolygonMesh) -> Set<PolygonMeshEdge> {
        var counts: [PolygonMeshEdge: Int] = [:]
        for face in mesh.faces { for edge in edges(face) { counts[edge,default: 0] += 1 } }
        return Set(counts.filter { $0.value == 2 }.keys)
    }
    private func area(_ mesh: PolygonMesh) throws -> Float {
        let baked = try mesh.bake(name: "area").mesh
        return stride(from: 0,to: baked.indices.count,by: 3).reduce(0) { total,i in
            let a = baked.position(at: Int(baked.indices[i]))!, b = baked.position(at: Int(baked.indices[i+1]))!, c = baked.position(at: Int(baked.indices[i+2]))!
            return total+simd_length(simd_cross(b-a,c-a))*0.5
        }
    }
}
