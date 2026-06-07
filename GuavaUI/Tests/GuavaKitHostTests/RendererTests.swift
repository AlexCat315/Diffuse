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
}
