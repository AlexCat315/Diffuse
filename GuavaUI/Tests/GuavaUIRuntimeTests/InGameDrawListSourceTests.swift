import Testing
@testable import GuavaUIRuntime

@Suite("In-game atlas delivery")
struct InGameDrawListSourceTests {
    private func frame(_ dirty: DrawListAtlasDirty? = nil, width: UInt32 = 640) -> DrawListSnapshot {
        DrawListSnapshot(vertices: [], indices: [], batches: [], viewportWidth: width,
                         viewportHeight: 480, logicalWidth: Float(width), logicalHeight: 480,
                         atlasDirty: dirty)
    }

    private func patch(_ value: UInt8, x: UInt32, texture: TextureID = 1) -> DrawListAtlasDirty {
        DrawListAtlasDirty(pixels: [value], regionX: x, regionY: 0, regionWidth: 1,
                          regionHeight: 1, textureWidth: 2, textureHeight: 2, textureID: texture)
    }

    @Test("skipped frames retain all glyph patches while geometry uses the newest frame")
    func skippedFrames() throws {
        let source = InGameDrawListSource()
        source.publish(frame(patch(100, x: 0)))
        source.publish(frame(patch(200, x: 1)))
        source.publish(frame(width: 800))
        let consumed = try #require(source.consume())
        #expect(consumed.viewportWidth == 800)
        #expect(consumed.atlasDirty?.pixels == [100, 200, 0, 0])
        #expect(consumed.atlasDirty?.regionWidth == 2)
        #expect(source.consume()?.atlasDirty == nil)
        source.publish(frame(patch(150, x: 0)))
        #expect(source.consume()?.atlasDirty?.pixels == [150, 200, 0, 0])
    }

    @Test("a replacement atlas clears pixels from the previous texture")
    func replacement() {
        let source = InGameDrawListSource()
        source.publish(frame(patch(100, x: 0)))
        source.publish(frame(patch(200, x: 1, texture: 2)))
        #expect(source.consume()?.atlasDirty?.pixels == [0, 200, 0, 0])
        source.publish(frame(patch(5, x: UInt32.max)))
        #expect(source.consume()?.atlasDirty == nil)
    }
}
