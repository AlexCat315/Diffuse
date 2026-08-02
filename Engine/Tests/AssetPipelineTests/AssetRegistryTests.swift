import AssetPipeline
import Foundation
import Testing

@Suite("AssetRegistry")
struct AssetRegistryTests {
    @Test("explicit mesh registration survives project reload and can be removed independently")
    func explicitMeshOverlaySurvivesReload() throws {
        let registry = AssetRegistry()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-registry-overlay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let meshIndex = 77
        registry.registerForTesting(MeshAsset(name: "transient", vertices: [], indices: []),
                                    at: meshIndex)
        _ = try registry.loadProject(at: root.path)

        #expect(registry.meshAsset(for: meshIndex)?.name == "transient")
        #expect(registry.registeredMeshes().contains { $0.meshIndex == meshIndex })
        registry.unregisterTestingMesh(at: meshIndex)
        #expect(registry.meshAsset(for: meshIndex) == nil)
    }

    @Test("scans project directory and registers importable meshes")
    func scansProjectDirectory() throws {
        let registry = AssetRegistry()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let meshesDir = tempRoot.appendingPathComponent("Assets/Meshes", isDirectory: true)
        try FileManager.default.createDirectory(at: meshesDir,
                                                withIntermediateDirectories: true)
        let texturesDir = tempRoot.appendingPathComponent("Assets/Textures", isDirectory: true)
        try FileManager.default.createDirectory(at: texturesDir,
                                                withIntermediateDirectories: true)

        try writeTriangleGLTF(into: meshesDir)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: texturesDir.appendingPathComponent("smoke.png"))
        try "# ignore".write(to: meshesDir.appendingPathComponent("notes.txt"),
                              atomically: true,
                              encoding: .utf8)

        let entries = try registry.loadProject(at: tempRoot.path)

        #expect(entries.count == 2)
        #expect(entries[0].kind == .gltf)
        #expect(entries[0].meshIndex == AssetRegistry.importedMeshStartIndex)
        #expect(entries[0].relativePath == "Assets/Meshes/triangle.gltf")
        #expect(registry.entry(for: entries[0].id) == entries[0])
        #expect(registry.meshAsset(for: entries[0].meshIndex)?.name == "triangle.gltf")
        #expect(registry.registeredMeshes().map(\ .meshIndex) == [AssetRegistry.importedMeshStartIndex])
        #expect(registry.registeredMeshes().first?.sourceDirectory == meshesDir.path)
        #expect(entries[1].kind == .png)
        #expect(entries[1].kind.sceneKindLabel == "Texture")
        #expect(entries[1].kind.isTexture)
        #expect(entries[1].meshIndex == 0)
        #expect(entries[1].relativePath == "Assets/Textures/smoke.png")
        #expect(registry.entry(for: entries[1].id) == entries[1])
    }

    @Test("honors persisted mesh indices from an export bundle")
    func honorsPreferredMeshIndex() throws {
        let registry = AssetRegistry()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let meshesDir = tempRoot.appendingPathComponent("Assets/Meshes", isDirectory: true)
        try FileManager.default.createDirectory(at: meshesDir, withIntermediateDirectories: true)
        try writeTriangleGLTF(into: meshesDir)

        let relativePath = "Assets/Meshes/triangle.gltf"
        let entries = try registry.loadProject(at: tempRoot.path,
                                               preferredMeshIndices: [relativePath: 17])

        #expect(entries.first?.meshIndex == 17)
        #expect(registry.registeredMeshes().map(\.meshIndex) == [17])
    }

    @Test("switching project roots never reuses a mesh from the previous project")
    func isolatesProjectRoots() throws {
        let registry = AssetRegistry()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstMeshes = parent.appendingPathComponent("First/Assets/Meshes", isDirectory: true)
        let secondMeshes = parent.appendingPathComponent("Second/Assets/Meshes", isDirectory: true)
        try FileManager.default.createDirectory(at: firstMeshes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondMeshes, withIntermediateDirectories: true)
        try writeTriangleGLTF(into: firstMeshes)
        try writeTriangleGLTF(into: secondMeshes)

        _ = try registry.loadProject(at: parent.appendingPathComponent("First").path)
        #expect(registry.registeredMeshes().first?.sourceDirectory == firstMeshes.path)

        _ = try registry.loadProject(at: parent.appendingPathComponent("Second").path)
        #expect(registry.registeredMeshes().first?.sourceDirectory == secondMeshes.path)
    }

    @Test("build directory matching is case-insensitive")
    func ignoresBuildDirectoryCaseVariants() throws {
        let registry = AssetRegistry()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        let generated = root.appendingPathComponent("Build", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data([1]).write(to: assets.appendingPathComponent("kept.png"))
        try Data([2]).write(to: generated.appendingPathComponent("ignored.png"))

        let entries = try registry.loadProject(at: root.path)

        #expect(entries.map(\.relativePath) == ["Assets/kept.png"])
    }

    private func writeTriangleGLTF(into directory: URL) throws {
        let bufferURL = directory.appendingPathComponent("triangle.bin")
        let gltfURL = directory.appendingPathComponent("triangle.gltf")

        var buffer = Data()
        append([Float(0), 0, 0,
                1, 0, 0,
                0, 1, 0], to: &buffer)
        append([Float(0), 0, 1,
                0, 0, 1,
                0, 0, 1], to: &buffer)
        append([UInt16(0), 1, 2], to: &buffer)
        try buffer.write(to: bufferURL)

        let json = #"""
        {
          "asset": { "version": "2.0" },
          "buffers": [
            { "uri": "triangle.bin", "byteLength": 78 }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 72, "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "meshes": [
            {
              "primitives": [
                {
                  "attributes": { "POSITION": 0, "NORMAL": 1 },
                  "indices": 2
                }
              ]
            }
          ],
          "nodes": [
            { "mesh": 0 }
          ],
          "scenes": [
            { "nodes": [0] }
          ],
          "scene": 0
        }
        """#
        try Data(json.utf8).write(to: gltfURL)
    }

    private func append(_ values: [Float], to data: inout Data) {
        for value in values {
            var copy = value.bitPattern.littleEndian
            withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
        }
    }

    private func append(_ values: [UInt16], to data: inout Data) {
        for value in values {
            var copy = value.littleEndian
            withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
        }
    }
}
