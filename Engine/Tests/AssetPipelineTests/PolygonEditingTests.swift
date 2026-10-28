import AssetPipeline
import Foundation
import SIMDCompat
import Testing

@Suite("Polygon editing")
struct PolygonEditingTests {
    @Test("face subdivision preserves shape, shared edges and independent corner UV seams")
    func subdivideFaces() throws {
        var mesh = try GeometryPrimitives.box()
        let source = mesh
        let selected = try mesh.subdivide(faces: [1])
        #expect(selected.count == 4)
        #expect(mesh.faces.count == 9 && mesh.positions.count == 13)
        #expect(Array(mesh.positions.prefix(8)) == source.positions)
        #expect(mesh.faces.filter { $0.vertices.count == 5 }.count == 4)
        #expect(selected.allSatisfy { mesh.faces[$0].vertices.count == 4 && mesh.faces[$0].uvs?.count == 4 })
        // Every inserted midpoint participates in both neighboring surfaces.
        var uses: [PolygonMeshEdge: Int] = [:]
        for face in mesh.faces {
            for i in face.vertices.indices { uses[.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count]),default: 0] += 1 }
        }
        #expect(uses.values.allSatisfy { $0 == 2 })
        _ = try mesh.bake(name: "subdivided")
        var full = source
        try full.subdivide(faces: Set(full.faces.indices))
        #expect(full.positions.count == 26 && full.faces.count == 24)
        #expect(full.positions.allSatisfy { max(abs($0.x),max(abs($0.y),abs($0.z))) == 0.5 })
        let before = full
        #expect(throws: GeometryError.self) { try full.subdivide(faces: [-1]) }
        #expect(throws: GeometryError.budgetExceeded) { try full.subdivide(faces: [0],limits: .init(maxVertices: 26)) }
        #expect(full == before)
        var concave = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(3,0,0),SIMD3(3,3,0),SIMD3(2,3,0),
            SIMD3(2,1,0),SIMD3(1,1,0),SIMD3(1,3,0),SIMD3(0,3,0)],faces: [.init(Array(0..<8))])
        let concaveSource = concave
        #expect(throws: GeometryError.self) { try concave.subdivide(faces: [0]) }
        #expect(concave == concaveSource)
        let triangles = try concave.triangulateFaces([0])
        try concave.subdivide(faces: triangles)
        _ = try concave.bake(name: "concave subdivided after triangulation")
    }

    @Test("explicit triangulation preserves the rendered surface and corner attributes")
    func triangulateFaces() throws {
        var mesh = try GeometryPrimitives.box()
        let source = mesh
        let before = try mesh.bake(name: "before")
        let selected = try mesh.triangulateFaces([0,1])
        #expect(mesh.faces.count == 8 && selected.count == 4)
        #expect(mesh.positions == source.positions)
        #expect(selected.allSatisfy { mesh.faces[$0].vertices.count == 3 && mesh.faces[$0].uvs?.count == 3 })
        #expect(try mesh.bake(name: "after").mesh.triangleCount == before.mesh.triangleCount)
        let triangulated = mesh
        #expect(throws: GeometryError.budgetExceeded) { try mesh.triangulateFaces([2],limits: .init(maxFaceCorners: 1)) }
        #expect(mesh == triangulated)
    }

    @Test("adjacent faces extrude as a region without an internal wall")
    func adjacentRegion() throws {
        let source = try GeometryPrimitives.grid(size: SIMD2(2,1),segments: SIMD2(2,1))
        var mesh = source
        try mesh.extrude(faces: [0,1],by: SIMD3(0,1,0))
        #expect(mesh.positions.count == 12)
        #expect(mesh.faces.count == 8) // two caps plus six boundary walls
        #expect(mesh.faces[0].uvs == source.faces[0].uvs)
        #expect(mesh.faces[1].uvs == source.faces[1].uvs)
        #expect(mesh.positions.allSatisfy { $0.y == 0 || $0.y == 1 })
        _ = try mesh.bake(name: "region")
        #expect(source.positions.count == 6 && source.faces.count == 2)
    }

    @Test("extrusion removes unused interior base vertices and preserves closed topology")
    func topology() throws {
        var grid = try GeometryPrimitives.grid(size: SIMD2(2,2),segments: SIMD2(4,4))
        try grid.extrude(faces: Set(grid.faces.indices),by: SIMD3(0,1,0))
        #expect(grid.positions.count == 41) // sixteen boundary bases plus twenty-five cap vertices
        #expect(grid.faces.count == 32)
        #expect(Set(grid.faces.flatMap(\.vertices)).count == grid.positions.count)
        var box = try GeometryPrimitives.box()
        try box.extrude(faces: [1,3],by: SIMD3(0,0.5,0.5))
        #expect(box.faces.count == 12)
        var uses: [PolygonMeshEdge: Int] = [:]
        for face in box.faces {
            for i in face.vertices.indices { uses[.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count]),default: 0] += 1 }
        }
        #expect(uses.values.allSatisfy { $0 == 2 })
        _ = try box.bake(name: "closed")
    }

    @Test("bad selections and geometric degeneracy fail without changing the mesh")
    func transactionalFailures() throws {
        var grid = try GeometryPrimitives.grid(size: SIMD2(2,2),segments: SIMD2(2,2))
        let original = grid
        #expect(throws: GeometryError.self) { try grid.extrude(faces: [0,3],by: SIMD3(0,1,0)) }
        #expect(grid == original)
        #expect(throws: GeometryError.self) { try grid.extrude(faces: [99],by: SIMD3(0,1,0)) }
        #expect(throws: GeometryError.budgetExceeded) {
            try grid.extrude(faces: [0],by: SIMD3(0,1,0),limits: .init(maxVertices: 9))
        }
        #expect(grid == original)
        var invalid = matrix_identity_float4x4; invalid.columns.0.x = .nan
        #expect(throws: GeometryError.self) { try grid.transform(vertices: [0],by: invalid) }
        #expect(grid == original)
        var collapse = matrix_identity_float4x4; collapse.columns.0.x = 0
        #expect(throws: GeometryError.self) { try grid.transform(vertices: Set(grid.positions.indices),by: collapse) }
        #expect(grid == original)
    }

    @Test("affine vertex transformations preserve unselected vertices and corner attributes")
    func affineTransform() throws {
        var mesh = try GeometryPrimitives.box()
        let before = mesh
        var transform = matrix_identity_float4x4; transform.columns.3.x = 0.1
        try mesh.transform(vertices: [0,1],by: transform)
        #expect(mesh.positions[0] == before.positions[0]+SIMD3(0.1,0,0))
        #expect(mesh.positions[1] == before.positions[1]+SIMD3(0.1,0,0))
        #expect(mesh.positions[2] == before.positions[2])
        #expect(mesh.faces == before.faces)
        #expect(mesh.edges == before.edges)
    }

    @Test("preview overlays preserve the authored catalog and survive reload until removed")
    func previewOverlay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("asset.dmesh")
        var document = GeometryDocument(name: "authored",source: .box(size: .one))
        try document.save(to: url)
        let registry = AssetRegistry()
        let entry = try #require(registry.loadProject(at: root.path).first)
        let preview = try GeometryDocument(name: "preview",source: .box(size: SIMD3(repeating: 3))).evaluate()
        registry.registerTransientMesh(preview.mesh,at: entry.meshIndex,assetID: entry.id,topologySlices: [preview.topologySlice])
        #expect(registry.meshAsset(for: entry.meshIndex)?.localBounds.max.x == 1.5)
        document.source = .box(size: SIMD3(repeating: 2)); try document.save(to: url)
        _ = try registry.loadProject(at: root.path)
        #expect(registry.meshAsset(for: entry.meshIndex)?.name == "preview")
        registry.unregisterTransientMesh(at: entry.meshIndex)
        #expect(registry.meshAsset(for: entry.meshIndex)?.localBounds.max.x == 1)
        #expect(try GeometryDocument.load(from: url) == document)
    }
}
