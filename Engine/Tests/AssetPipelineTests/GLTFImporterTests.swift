// Fixtures are generated with CoreGraphics/ImageIO (Apple-only). Guarded until
// image decoding is portable (stb_image); see ImageAssetDecoder.
#if canImport(CoreGraphics)
import AssetPipeline
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import SIMDCompat

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
        append([Float(1), 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                2, 0, 0, 1], to: &buffer)
        append([UInt16(0), 1, 2], to: &buffer)
        try buffer.write(to: bufferURL)

        let json = #"""
        {
          "asset": { "version": "2.0" },
          "buffers": [
            { "uri": "character-triangle.bin", "byteLength": 350 }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 72, "byteLength": 24 },
            { "buffer": 0, "byteOffset": 96, "byteLength": 48 },
            { "buffer": 0, "byteOffset": 144, "byteLength": 24 },
            { "buffer": 0, "byteOffset": 168, "byteLength": 48 },
            { "buffer": 0, "byteOffset": 216, "byteLength": 128 },
            { "buffer": 0, "byteOffset": 344, "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2" },
            { "bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC4" },
            { "bufferView": 4, "componentType": 5123, "count": 3, "type": "VEC4" },
            { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC4" },
            { "bufferView": 6, "componentType": 5126, "count": 2, "type": "MAT4" },
            { "bufferView": 7, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "images": [
            { "uri": "hero_base.png", "mimeType": "image/png" },
            { "uri": "hero_normal.png", "mimeType": "image/png" }
          ],
          "textures": [
            { "source": 0 },
            { "source": 1 }
          ],
          "materials": [
            {
              "name": "unused",
              "pbrMetallicRoughness": {
                "baseColorFactor": [1, 1, 1, 1]
              }
            },
            {
              "name": "ink hero",
              "pbrMetallicRoughness": {
                "baseColorFactor": [0.8, 0.7, 0.6, 1],
                "baseColorTexture": { "index": 0 },
                "metallicFactor": 0,
                "roughnessFactor": 0.95
              },
              "normalTexture": { "index": 1 }
            }
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
                  "indices": 7,
                  "material": 1
                }
              ]
            }
          ],
          "nodes": [
            { "name": "hero", "mesh": 0, "skin": 0 },
            { "name": "root" },
            { "name": "weapon" }
          ],
          "skins": [
            {
              "name": "hero rig",
              "joints": [1, 2],
              "inverseBindMatrices": 6
            }
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
        #expect(mesh.vertices[MeshAsset.materialIndexFloatOffset] == 1)
        #expect(mesh.vertices[MeshAsset.jointsFloatOffset] == 0)
        #expect(mesh.vertices[MeshAsset.jointsFloatOffset + 3] == 3)
        #expect(mesh.vertices[MeshAsset.weightsFloatOffset] == 0.4)
        #expect(mesh.vertices[MeshAsset.weightsFloatOffset + 3] == 0.1)
        #expect(mesh.textures.map(\.sourceURI) == ["hero_base.png", "hero_normal.png"])
        #expect(mesh.materials.count == 2)
        #expect(mesh.materials[1].name == "ink hero")
        #expect(mesh.materials[1].baseColorFactor == SIMD4<Float>(0.8, 0.7, 0.6, 1))
        #expect(mesh.materials[1].baseColorTextureIndex == 0)
        #expect(mesh.materials[1].normalTextureIndex == 1)
        #expect(mesh.materials[1].metallicFactor == 0)
        #expect(mesh.materials[1].roughnessFactor == 0.95)
        #expect(mesh.skins.count == 1)
        #expect(mesh.skins[0].name == "hero rig")
        #expect(mesh.skins[0].jointNodeIndices == [1, 2])
        #expect(mesh.skins[0].inverseBindMatrices.count == 2)
        #expect(mesh.skins[0].inverseBindMatrices[1].columns.3.x == 2)
    }

    @Test("loads gltf animation channels and sampler keyframes")
    func loadsAnimationChannels() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bufferURL = tempRoot.appendingPathComponent("animated-triangle.bin")
        let gltfURL = tempRoot.appendingPathComponent("animated-triangle.gltf")

        var buffer = Data()
        append([Float(0), 0, 0,
                1, 0, 0,
                0, 1, 0], to: &buffer)
        append([Float(0), 0, 1,
                0, 0, 1,
                0, 0, 1], to: &buffer)
        append([Float(0), 1], to: &buffer)
        append([Float(0), 0, 0,
                1, 2, 3], to: &buffer)
        append([UInt16(0), 1, 2], to: &buffer)
        try buffer.write(to: bufferURL)

        let json = #"""
        {
          "asset": { "version": "2.0" },
          "buffers": [
            { "uri": "animated-triangle.bin", "byteLength": 110 }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 72, "byteLength": 8 },
            { "buffer": 0, "byteOffset": 80, "byteLength": 24 },
            { "buffer": 0, "byteOffset": 104, "byteLength": 6 }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5126, "count": 2, "type": "SCALAR" },
            { "bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC3" },
            { "bufferView": 4, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "meshes": [
            {
              "primitives": [
                {
                  "attributes": { "POSITION": 0, "NORMAL": 1 },
                  "indices": 4
                }
              ]
            }
          ],
          "nodes": [
            { "name": "animated", "mesh": 0 }
          ],
          "animations": [
            {
              "name": "idle",
              "samplers": [
                { "input": 2, "output": 3, "interpolation": "STEP" }
              ],
              "channels": [
                { "sampler": 0, "target": { "node": 0, "path": "translation" } }
              ]
            }
          ],
          "scenes": [
            { "nodes": [0] }
          ],
          "scene": 0
        }
        """#
        try Data(json.utf8).write(to: gltfURL)

        let mesh = try GLTFImporter.load(path: gltfURL.path)

        #expect(mesh.animations.count == 1)
        #expect(mesh.animations[0].name == "idle")
        #expect(mesh.animations[0].samplers[0].inputTimes == [0, 1])
        #expect(mesh.animations[0].samplers[0].outputValues[1] == SIMD4<Float>(1, 2, 3, 0))
        #expect(mesh.animations[0].samplers[0].interpolation == .step)
        #expect(mesh.animations[0].channels[0].targetNodeIndex == 0)
        #expect(mesh.animations[0].channels[0].path == .translation)
    }

    @Test("loads gltf buffer-view image data into mesh textures")
    func loadsBufferViewImageTexture() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bufferURL = tempRoot.appendingPathComponent("buffer-image.bin")
        let gltfURL = tempRoot.appendingPathComponent("buffer-image.gltf")

        var buffer = Data()
        append([Float(0), 0, 0,
                1, 0, 0,
                0, 1, 0], to: &buffer)
        append([Float(0), 0, 1,
                0, 0, 1,
                0, 0, 1], to: &buffer)
        append([UInt16(0), 1, 2], to: &buffer)
        let imageOffset = buffer.count
        let imageData = try makePNGData(pixels: [44, 55, 66, 255], width: 1, height: 1)
        buffer.append(imageData)
        try buffer.write(to: bufferURL)

        let json = #"""
        {
          "asset": { "version": "2.0" },
          "buffers": [
            { "uri": "buffer-image.bin", "byteLength": \#(buffer.count) }
          ],
          "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
            { "buffer": 0, "byteOffset": 72, "byteLength": 6 },
            { "buffer": 0, "byteOffset": \#(imageOffset), "byteLength": \#(imageData.count) }
          ],
          "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
            { "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }
          ],
          "images": [
            { "bufferView": 3, "mimeType": "image/png", "name": "embedded" }
          ],
          "textures": [
            { "source": 0 }
          ],
          "materials": [
            { "pbrMetallicRoughness": { "baseColorTexture": { "index": 0 } } }
          ],
          "meshes": [
            { "primitives": [ { "attributes": { "POSITION": 0, "NORMAL": 1 }, "indices": 2, "material": 0 } ] }
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
        let resolved = try MeshTextureResolver.decode(mesh.textures[0], sourceDirectory: nil)

        #expect(mesh.textures[0].name == "embedded")
        #expect(mesh.textures[0].data == imageData)
        #expect(resolved.texture.pixels == [44, 55, 66, 255])
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

    private func makePNGData(pixels: [UInt8], width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output,
                                                                 UTType.png.identifier as CFString,
                                                                 1,
                                                                 nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
        return output as Data
    }
}
#endif
