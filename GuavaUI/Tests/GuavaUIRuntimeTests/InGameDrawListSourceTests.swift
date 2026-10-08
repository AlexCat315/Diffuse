import Testing
@testable import GuavaUIRuntime

@Suite("In-game atlas delivery")
struct InGameDrawListSourceTests {
    private final class Lease: Sendable {}

    @Test("latest frame and consumed snapshots own resources independently")
    func snapshotOwnership() throws {
        let source = InGameDrawListSource()
        let list = DrawList()
        var owner: Lease? = Lease()
        weak let observed = owner
        list.retainResource(owner!)
        var published = frame()
        published.resources = list.resources
        source.publish(published)
        owner = nil; list.reset(); published.resources.reset()
        var consumed = try #require(source.consume())
        source.publish(frame())
        #expect(observed != nil)
        let restored = DrawList()
        restored.load(vertices: consumed.vertices, indices: consumed.indices, batches: consumed.batches, resources: consumed.resources)
        consumed.resources.reset()
        #expect(observed != nil)
        restored.reset()
        #expect(observed == nil)
    }

    private func frame(_ dirty: DrawListAtlasDirty? = nil, width: UInt32 = 640) -> DrawListSnapshot {
        DrawListSnapshot(vertices: [], indices: [], batches: [], viewportWidth: width,
                         viewportHeight: 480, logicalWidth: Float(width), logicalHeight: 480,
                         atlasUpdates: dirty.map { [$0] } ?? [])
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
        #expect(consumed.atlasUpdates.first?.pixels == [100, 200, 0, 0])
        #expect(consumed.atlasUpdates.first?.regionWidth == 2)
        #expect(source.consume()?.atlasUpdates.isEmpty == true)
        source.publish(frame(patch(150, x: 0)))
        #expect(source.consume()?.atlasUpdates.first?.pixels == [150, 200, 0, 0])
    }

    @Test("a replacement atlas clears pixels from the previous texture")
    func replacement() {
        let source = InGameDrawListSource()
        source.publish(frame(patch(100, x: 0)))
        source.publish(frame(patch(200, x: 1, texture: 2)))
        #expect(source.consume()?.atlasUpdates.first?.pixels == [0, 200, 0, 0])
        source.publish(frame(patch(5, x: UInt32.max)))
        #expect(source.consume()?.atlasUpdates.isEmpty == true)
    }

    private func colorPatch(_ value: UInt8, x: UInt32) -> DrawListAtlasDirty {
        DrawListAtlasDirty(pixels: [value, 20, 30, 255], regionX: x, regionY: 0,
            regionWidth: 1, regionHeight: 1, textureWidth: 2, textureHeight: 2,
            textureID: TextureID(1).colorGlyphAtlasID, format: .color)
    }

    @Test("alpha and RGBA planes accumulate independently across skipped frames")
    func pairedPlanes() throws {
        let source = InGameDrawListSource()
        source.publish(frame(patch(100, x: 0)))
        source.publish(frame(colorPatch(50, x: 0)))
        source.publish(frame(colorPatch(80, x: 1)))
        source.publish(frame(width: 900))
        let snapshot = try #require(source.consume())
        #expect(snapshot.viewportWidth == 900)
        #expect(snapshot.atlasUpdates.map(\.format) == [.alpha, .color])
        #expect(snapshot.atlasUpdates[0].pixels == [100, 0, 0, 0])
        #expect(snapshot.atlasUpdates[1].pixels == [50, 20, 30, 255, 80, 20, 30, 255, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(source.consume()?.atlasUpdates.isEmpty == true)
        source.publish(frame(patch(5, x: 1, texture: 2)))
        #expect(source.consume()?.atlasUpdates.first?.pixels == [0, 5, 0, 0])
        source.publish(frame(colorPatch(70, x: 1)))
        #expect(source.consume()?.atlasUpdates.first?.pixels.prefix(8) == [50, 20, 30, 255, 70, 20, 30, 255])
    }

    @Test("malformed RGBA patches and oversized allocations preserve the retained plane")
    func invalidColorPatch() {
        let source = InGameDrawListSource()
        source.publish(frame(colorPatch(50, x: 0)))
        var invalid = colorPatch(80, x: 1)
        invalid.pixels.removeLast()
        source.publish(frame(invalid))
        #expect(source.consume()?.atlasUpdates.first?.pixels.prefix(8) == [50, 20, 30, 255, 0, 0, 0, 0])
        invalid = colorPatch(80, x: 1)
        invalid.textureWidth = UInt32.max
        invalid.textureHeight = UInt32.max
        source.publish(frame(invalid))
        #expect(source.consume()?.atlasUpdates.isEmpty == true)
    }
}
