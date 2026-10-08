import EngineKernel
import GuavaUIRuntime
import GuavaUICompose
import Testing

@Suite("Script HUD canvas", .serialized)
@MainActor
struct ScriptCanvasTests: GuavaUIComposeSerializedSuite {
    @Test("script-only HUD publishes text and progress without a custom root view")
    func publishesCanvas() throws { try GlobalTestLock.locked {
        let source = InGameDrawListSource()
        let bridge = InGameViewGraphBridge(source: source)
        var canvas = InGameCanvas()
        canvas.rect(x: 10, y: 10, w: 200, h: 90, color: .blue, cornerRadius: 8)
        canvas.label("Score: 8", x: 20, y: 20, fontSize: 24)
        canvas.progressBar(x: 20, y: 60, w: 150, h: 10, value: 0.5)
        bridge.tick(width: 640, height: 480, contentScale: 2, canvas: canvas)
        let frame = try #require(source.consume())
        #expect(!frame.isEmpty)
        #expect(!frame.vertices.isEmpty)
        #expect(!frame.atlasUpdates.isEmpty)
        #expect(frame.logicalWidth == 640)
        bridge.tick(width: 640, height: 480, contentScale: 2)
        #expect(source.consume()?.isEmpty == true)
    } }

    @Test("script canvas coexists with a declarative HUD root")
    func combinesRoot() throws { try GlobalTestLock.locked {
        let source = InGameDrawListSource()
        let bridge = InGameViewGraphBridge(source: source)
        bridge.setRootView(Text("Declarative HUD"))
        bridge.tick(width: 640, height: 480)
        let base = try #require(source.consume()).vertices.count
        var canvas = InGameCanvas()
        canvas.rect(x: 100, y: 100, w: 200, h: 80, color: .green)
        bridge.tick(width: 640, height: 480, canvas: canvas)
        #expect(try #require(source.consume()).vertices.count > base)
    } }

    #if canImport(CoreText)
    @Test("script HUD delivers both atlas planes and keeps emoji after skipped frames")
    func publishesColorGlyphs() throws { try GlobalTestLock.locked {
        let source = InGameDrawListSource()
        let bridge = InGameViewGraphBridge(source: source)
        var canvas = InGameCanvas()
        canvas.label("Score 🙂", x: 20, y: 20, fontSize: 24)
        bridge.tick(width: 640, height: 480, contentScale: 2, canvas: canvas)
        bridge.tick(width: 640, height: 480, contentScale: 2, canvas: canvas)
        let frame = try #require(source.consume())
        #expect(frame.atlasUpdates.map(\.format) == [.alpha, .color])
        #expect(frame.batches.contains { $0.textureID == TextureID(1).colorGlyphAtlasID })
        #expect(frame.atlasUpdates[1].pixels.contains { $0 != 0 })
        #expect(source.consume()?.atlasUpdates.isEmpty == true)
    } }
    #endif
}
