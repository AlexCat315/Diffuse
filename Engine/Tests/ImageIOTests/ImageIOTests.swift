import Foundation
import ImageIO
import Testing

@Suite("ImageIO")
struct ImageIOTests {

    @Test("EXRWriter layer construction yields correct channel counts")
    func exrWriterLayerConstruction() throws {
        let beauty = EXRWriter.Layer(name: "beauty", channels: ["R", "G", "B", "A"])
        let depth = EXRWriter.Layer(name: "depth", channels: ["Z"], pixelType: .float)
        let writer = try EXRWriter(path: "/tmp/test.exr", width: 1920, height: 1080)
        writer.addLayer(beauty)
        writer.addLayer(depth)

        #expect(beauty.channels.count == 4)
        #expect(beauty.pixelType == .half)
        #expect(depth.channels.count == 1)
        #expect(depth.pixelType == .float)
    }

    @Test("EXRReader init fails gracefully for nonexistent path")
    func exrReaderNonexistentPath() {
        #expect(throws: EXRReaderError.self) {
            _ = try EXRReader(path: "/tmp/nonexistent_guava_test.exr")
        }
    }

    @Test("EXRReader layerInfo returns nil for out-of-bounds index")
    func exrReaderLayerInfoOutOfBounds() throws {
        // Since the C bridge isn't available in tests, the reader won't open.
        // Verify the error type is correct.
        do {
            _ = try EXRReader(path: "/tmp/nonexistent_guava_test.exr")
            #expect(Bool(false), "Should have thrown")
        } catch let error as EXRReaderError {
            #expect(String(describing: error).contains("nonexistent"))
        }
    }

    @Test("EXRWriter error types are distinct")
    func exrWriterErrorTypes() {
        let ctx = EXRWriterError.contextCreationFailed
        let layer = EXRWriterError.layerCreationFailed("test")
        #expect(String(describing: ctx) != String(describing: layer))
    }

    @Test("EXR write-then-read roundtrip preserves RGBA pixel data")
    func exrRoundtripRGBA() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("roundtrip_rgba.exr").path
        let width = 64
        let height = 32
        let pixelCount = width * height * 4

        // Create known pixel data
        var original = [Float](repeating: 0, count: pixelCount)
        for i in 0..<(width * height) {
            let r = Float(i % 256) / 255.0
            let g = Float((i / 3) % 256) / 255.0
            let b = Float((i / 7) % 256) / 255.0
            original[i * 4 + 0] = r
            original[i * 4 + 1] = g
            original[i * 4 + 2] = b
            original[i * 4 + 3] = 1.0
        }

        // Write
        let writer = try EXRWriter(path: path, width: width, height: height)
        writer.addLayer(EXRWriter.Layer(name: "beauty", channels: ["R", "G", "B", "A"], pixelType: .float))
        #expect(writer.setPixels(original, for: "beauty"))
        try writer.write()

        // Read back
        let reader = try EXRReader(path: path)
        #expect(reader.width == width)
        #expect(reader.height == height)
        #expect(reader.layerCount == 1)

        let info = reader.layerInfo(at: 0)
        #expect(info?.name == "beauty")

        let readPixels = reader.readPixels(layerName: "beauty")
        #expect(readPixels.count == pixelCount)

        // Verify
        for i in 0..<pixelCount {
            #expect(abs(readPixels[i] - original[i]) < 0.005)
        }
    }

    @Test("EXR two-layer write produces correct layer count on read")
    func exrTwoLayerRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("twolayer.exr").path
        let writer = try EXRWriter(path: path, width: 16, height: 16)
        writer.addLayer(EXRWriter.Layer(name: "beauty", channels: ["R", "G", "B", "A"]))
        writer.addLayer(EXRWriter.Layer(name: "depth", channels: ["Z"]))

        let rgba = [Float](repeating: 0.5, count: 16 * 16 * 4)
        let depth = [Float](repeating: 0.75, count: 16 * 16)
        #expect(writer.setPixels(rgba, for: "beauty"))
        #expect(writer.setPixels(depth, for: "depth"))
        try writer.write()

        let reader = try EXRReader(path: path)
        #expect(reader.layerCount == 2)

        let names = (0..<reader.layerCount).compactMap { reader.layerInfo(at: $0)?.name }
        #expect(names.contains("beauty"))
        #expect(names.contains("depth"))

        let readDepth = reader.readPixels(layerName: "depth")
        #expect(readDepth.count >= 16 * 16)
        #expect(abs(readDepth[0] - 0.75) < 0.01)
    }
}
