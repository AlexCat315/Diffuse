import Testing
import GuavaKit
import GuavaUIRuntime
@testable import GuavaKitHost

@Suite("GuavaKitHost renderer bridge")
struct RendererTests {

    private func displayList(_ configure: (UINode) -> Void) -> GuavaKit.DisplayList {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 50, height: 50)))
        configure(root)
        return Painter().paint(root: root)
    }

    private func makeFontBridge(size: Float = 16) throws -> FontBridge {
        let bridge = FontBridge()
        // macOS system font guaranteed to be available on all test hosts.
        let ok = bridge.loadFont(path: "/System/Library/Fonts/Supplemental/Arial.ttf",
                                 size: size)
        #expect(ok, "Arial.ttf must load on macOS")
        try #require(ok)
        return bridge
    }

    @Test("A filled rect becomes one quad in the DrawList")
    func fillRect() {
        let dl = displayList { $0.setPaint(Paint(background: GuavaKit.Color(r: 1, g: 0, b: 0))) }
        let draw = DrawList()
        DisplayListRenderer().render(dl, into: draw)
        #expect(draw.vertices.count == 4)   // one quad
        #expect(draw.indices.count == 6)    // two triangles
    }

    @Test("A border becomes four edge quads")
    func border() {
        let dl = displayList {
            $0.setPaint(Paint(border: GuavaKit.Border(color: GuavaKit.Color(r: 0, g: 0, b: 0), width: 2)))
        }
        let draw = DrawList()
        DisplayListRenderer().render(dl, into: draw)
        #expect(draw.vertices.count == 16) // 4 edges × 4 verts
    }

    @Test("Clipped content renders within a scissor (push/pop handled)")
    func clip() {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 50, height: 50),
                                             clipsToBounds: true))
        root.setPaint(Paint(background: GuavaKit.Color(r: 1, g: 1, b: 1)))
        let dl = Painter().paint(root: root)
        let draw = DrawList()
        DisplayListRenderer().render(dl, into: draw)
        #expect(draw.vertices.count == 4)
        // The clip was popped, so the stack is balanced afterwards.
        #expect(draw.currentClip == nil)
    }

    // MARK: - Text rendering

    @Test("DisplayListRenderer without font bridge skips text commands")
    func textIsSkippedWithoutBridge() {
        let dl = displayList { $0.setText("Hello", color: GuavaKit.Color(r: 0, g: 0, b: 0), size: 16) }
        let draw = DrawList()
        DisplayListRenderer().render(dl, into: draw)
        // No vertices at all — text was skipped (no bridge).
        #expect(draw.vertices.isEmpty)
    }

    @Test("DisplayListRenderer with font bridge emits glyph quads for text")
    func textEmitsQuads() throws {
        let bridge = try makeFontBridge()
        let renderer = DisplayListRenderer(fontBridge: bridge, atlasTextureID: .none)

        let dl = displayList { $0.setText("ABC", color: GuavaKit.Color(r: 0, g: 0, b: 0), size: 16) }
        let draw = DrawList()
        renderer.render(dl, into: draw)

        // "ABC" produces at least 3 glyphs, each a quad = 12+ vertices.
        #expect(draw.vertices.count >= 12)
    }

    @Test("FontBridge layout produces lines for simple text")
    func fontBridgeLayout() throws {
        let bridge = try makeFontBridge()
        let result = bridge.layout(text: "Hello", maxWidth: 400)
        #expect(!result.lines.isEmpty)
        #expect(result.totalWidth > 0)
        #expect(result.totalHeight > 0)
    }

    @Test("FontBridgeMeasurer returns non-zero size for text")
    func fontBridgeMeasurer() throws {
        let bridge = try makeFontBridge()
        let measurer = FontBridgeMeasurer(bridge: bridge)
        let size = measurer.measure("Hello", fontSize: 16)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    @Test("FontBridgeMeasurer falls back for empty bridge")
    func fontBridgeMeasurerFallback() {
        let bridge = FontBridge() // no font loaded
        let measurer = FontBridgeMeasurer(bridge: bridge)
        let size = measurer.measure("Hello", fontSize: 14)
        #expect(size.width > 0)
        #expect(size.height > 0)
    }
}
