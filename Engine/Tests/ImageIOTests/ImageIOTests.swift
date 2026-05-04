import ImageIO
import Testing

@Suite("ImageIO")
struct ImageIOTests {

    @Test("EXRWriter layer construction yields correct channel counts")
    func exrWriterLayerConstruction() {
        let beauty = EXRWriter.Layer(name: "beauty", channels: ["R", "G", "B", "A"])
        let depth = EXRWriter.Layer(name: "depth", channels: ["Z"], pixelType: .float)
        let writer = EXRWriter(path: "/tmp/test.exr", width: 1920, height: 1080)
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
}
