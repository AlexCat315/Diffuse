import AssetPipeline
import Foundation
import Testing
import simd

@Suite("GLTFImporter")
struct GLTFImporterTests {
    @Test("loads external-buffer gltf mesh and applies node translation")
    func loadsExternalBufferMesh() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bufferURL = tempRoot.appendingPathComponent("triangle.bin")
        let gltfURL = tempRoot.appendingPathComponent("triangle.gltf")

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
            { "mesh": 0, "translation": [1, 2, 3] }
          ],
          "scenes": [
            { "nodes": [0] }
          ],
          "scene": 0
        }
        """#
        try Data(json.utf8).write(to: gltfURL)

        let mesh = try GLTFImporter.load(path: gltfURL.path)

        #expect(mesh.name == "triangle.gltf")
        #expect(mesh.indexCount == 3)
        #expect(mesh.vertices.count == MeshAsset.vertexFloatCount * 3)
        #expect(mesh.localBounds.min == SIMD3<Float>(1, 2, 3))
        #expect(mesh.localBounds.max == SIMD3<Float>(2, 3, 3))
        #expect(mesh.vertices[MeshAsset.uvFloatOffset] == 0)
        #expect(mesh.vertices[MeshAsset.tangentFloatOffset] == 1)
        #expect(mesh.vertices[MeshAsset.materialIndexFloatOffset] == 0)
        #expect(mesh.vertices[MeshAsset.weightsFloatOffset] == 1)
        #expect(Array(mesh.indices) == [0, 1, 2])
    }

    @Test("loads character vertex attributes for stylized mesh pipeline")
    func loadsCharacterVertexAttributes() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bufferURL = tempRoot.appendingPathComponent("character-triangle.bin")
        let gltfURL = tempRoot.appendingPathComponent("character-triangle.gltf")

        var buffer = Data()
        append([Float(0), 0, 0,
                1, 0, 0,
                0, 1, 0], to: &buffer)
        append([Float(0), 0, 1,
                0, 0, 1,
                0, 0, 1], to: &buffer)
        append([Float(0), 0,
                1, 0,
                0, 1], to: &buffer)
        append([Float(1), 0, 0, 1,
                1, 0, 0, 1,
                1, 0, 0, 1], to: &buffer)
        append([UInt16(0), 1, 2, 3,
                4, 5, 6, 7,
                8, 9, 10, 11], to: &buffer)
        append([Float(0.4), 0.3, 0.2, 0.1,
                1, 0, 0, 0,
                0.5, 0.5, 0, 0], to: &buffer)
        append([UInt16(0), 1, 2], to: &buffer)
        try buffer.write(to: bufferURL)

        let json = #"""
        {
          "asset": { "version": "2.0" },
          "buffers": [
            { "uri": "character-triangle.bin", "byteLength": 222 }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 72, "byteLength": 24 },
            { "buffer": 0, "byteOffset": 96, "byteLength": 48 },
            { "buffer": 0, "byteOffset": 144, "byteLength": 24 },
            { "buffer": 0, "byteOffset": 168, "byteLength": 48 },
            { "buffer": 0, "byteOffset": 216, "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2" },
            { "bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC4" },
            { "bufferView": 4, "componentType": 5123, "count": 3, "type": "VEC4" },
            { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC4" },
            { "bufferView": 6, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "meshes": [
            {
              "primitives": [
                {
                  "attributes": {
                    "POSITION": 0,
                    "NORMAL": 1,
                    "TEXCOORD_0": 2,
                    "TANGENT": 3,
                    "JOINTS_0": 4,
                    "WEIGHTS_0": 5
                  },
                  "indices": 6
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

        let mesh = try GLTFImporter.load(path: gltfURL.path)

        #expect(mesh.vertices.count == MeshAsset.vertexFloatCount * 3)
        #expect(mesh.vertices[MeshAsset.uvFloatOffset] == 0)
        #expect(mesh.vertices[MeshAsset.uvFloatOffset + 1] == 0)
        #expect(mesh.vertices[MeshAsset.tangentFloatOffset] == 1)
        #expect(mesh.vertices[MeshAsset.tangentFloatOffset + 3] == 1)
        #expect(mesh.vertices[MeshAsset.jointsFloatOffset] == 0)
        #expect(mesh.vertices[MeshAsset.jointsFloatOffset + 3] == 3)
        #expect(mesh.vertices[MeshAsset.weightsFloatOffset] == 0.4)
        #expect(mesh.vertices[MeshAsset.weightsFloatOffset + 3] == 0.1)
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
