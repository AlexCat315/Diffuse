import AssetPipeline
import Foundation
import Testing

@Suite("AssetRegistry")
struct AssetRegistryTests {
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

        try writeTriangleGLTF(into: meshesDir)
        try "# ignore".write(to: meshesDir.appendingPathComponent("notes.txt"),
                              atomically: true,
                              encoding: .utf8)

        let entries = try registry.loadProject(at: tempRoot.path)

        #expect(entries.count == 1)
        #expect(entries[0].kind == .gltf)
        #expect(entries[0].meshIndex == AssetRegistry.importedMeshStartIndex)
        #expect(entries[0].relativePath == "Assets/Meshes/triangle.gltf")
        #expect(registry.entry(for: entries[0].id) == entries[0])
        #expect(registry.meshAsset(for: entries[0].meshIndex)?.name == "triangle.gltf")
        #expect(registry.registeredMeshes().map(\ .meshIndex) == [AssetRegistry.importedMeshStartIndex])
        #expect(registry.registeredMeshes().first?.sourceDirectory == meshesDir.path)
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
