import AssetPipeline
import Foundation
import Testing

@Suite("Native geometry assets")
struct GeometryAssetTests {
    @Test("checked-in geometry examples load through the production registry")
    func examples() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../examples/GeometryAuthoring/Assets").standardizedFileURL
        let registry = AssetRegistry()
        let entries = try registry.loadProject(at: directory.path)
        #expect(entries.map(\.name).sorted() == ["BezierPipe", "RoundedArray", "Shell"])
        #expect(registry.registeredMeshes().count == 3)
        for entry in entries {
            let mesh = try #require(registry.meshAsset(for: entry.meshIndex))
            #expect(mesh.triangleCount > 10)
        }
    }

    @Test("project scans evaluate native assets, retain scene units and reload changed sources")
    func projectLoading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("row.dmesh")
        var document = GeometryDocument(name: "Row", source: .box(size: SIMD3(2,2,2)), modifiers: [
            .init(.array(count: 3, offset: SIMD3(4,0,0)))])
        try document.save(to: url)
        let registry = AssetRegistry()
        let first = try #require(registry.loadProject(at: root.path).first)
        #expect(first.kind == .dmesh && first.kind.isMesh && !first.kind.isTexture)
        let mesh = try #require(registry.meshAsset(for: first.meshIndex))
        #expect(mesh.localBounds.min == SIMD3(-1,-1,-1))
        #expect(mesh.localBounds.max == SIMD3(9,1,1))
        let snapshot = try #require(registry.meshCatalog(since: nil))
        let slice = try #require(snapshot.meshes.first?.topologySlices?.first)
        #expect(slice.positions.count == 24)
        let remap = try #require(slice.indexRemap)
        for i in slice.triangleIndices.indices {
            #expect(slice.positions[Int(remap[Int(slice.triangleIndices[i])])] == mesh.position(at: Int(mesh.indices[i])))
        }
        document.modifiers = [.init(.array(count: 2, offset: SIMD3(3,0,0)))]
        try document.save(to: url)
        let second = try #require(registry.loadProject(at: root.path).first)
        #expect(first.meshIndex == second.meshIndex)
        #expect(registry.meshAsset(for: second.meshIndex)?.localBounds.max.x == 4)
        #expect(registry.meshCatalog(since: snapshot.revision) != nil)
    }

    @Test("failed evaluation leaves an existing saved asset unchanged")
    func atomicSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-\(UUID().uuidString).dmesh")
        defer { try? FileManager.default.removeItem(at: url) }
        var document = GeometryDocument(name: "Original", source: .box(size: .one))
        try document.save(to: url)
        let originalData = try Data(contentsOf: url)
        document.modifiers = [.init(.subdivision(levels: 99))]
        #expect(throws: GeometryError.self) { try document.save(to: url) }
        #expect(try Data(contentsOf: url) == originalData)
        #expect(try GeometryDocument.load(from: url).name == "Original")
    }

    @Test("minimal JSON documents supply authoring defaults")
    func minimalDocument() throws {
        let json = #"{"version":1,"name":"Cube","source":{"box":{"size":[2,3,4]}}}"#
        let document = try JSONDecoder().decode(GeometryDocument.self, from: Data(json.utf8))
        #expect(document.modifiers.isEmpty && document.shading == .flat)
        #expect(try document.evaluate().mesh.localBounds.max == SIMD3(1,1.5,2))
        let future = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        #expect(throws: GeometryError.unsupportedVersion(2)) {
            try JSONDecoder().decode(GeometryDocument.self, from: Data(future.utf8))
        }
    }

    @Test("invalid native files do not enter the render catalog")
    func invalidAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"version":1,"name":"Bad","source":{"box":{"size":[0,0,0]}}}"#.utf8)
            .write(to: root.appendingPathComponent("bad.dmesh"))
        let registry = AssetRegistry()
        #expect(try registry.loadProject(at: root.path).isEmpty)
        #expect(registry.registeredMeshes().isEmpty)
    }
}
