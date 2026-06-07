import Testing
@testable import GuavaKit

@Suite("GuavaKit primitives")
struct PrimitivesTests {
    private final class ActionBox { var fire: () -> Void = {} }

    // MARK: - Modifiers

    private struct ModApp: View {
        var body: some View {
            Element()
                .frame(width: 50, height: 30)
                .background(Color(r: 1, g: 0, b: 0))
                .padding(8)
        }
    }

    @Test("A modifier chain collapses to one node, applied in order")
    func modifierChain() {
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: ModApp())
        // No wrapper nodes: just the single Element node.
        #expect(graph.root.children.count == 1)
        let node = graph.root.children[0]
        #expect(node.layoutStyle.width == .points(50))
        #expect(node.layoutStyle.height == .points(30))
        #expect(node.paint.background == Color(r: 1, g: 0, b: 0))
        #expect(node.layoutStyle.padding == .all(8))
    }

    // MARK: - Text

    private struct TextApp: View {
        var body: some View { Text("hi") }
    }

    @Test("Text measures an intrinsic size and emits a text draw command")
    func text() {
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: TextApp())
        let node = graph.root.children[0]
        #expect(node.textContent?.string == "hi")
        // Default ApproxTextMeasurer: 0.5×1.2 · fontSize(16) → 2 glyphs wide.
        #expect(node.intrinsicSize == Size(width: 16, height: 19.2))

        // Layout gives an auto Text leaf its intrinsic size.
        ctx.layoutIfNeeded(engine: StackLayoutEngine(), available: Size(width: 200, height: 200))
        #expect(node.geometry.frame.size == Size(width: 16, height: 19.2))

        // And paint emits the text command.
        let list = Painter().paint(root: graph.root)
        #expect(list.commands.contains { if case .text("hi", _, _) = $0 { return true }; return false })
    }

    @Test("Text uses the context's injected font measurer")
    func injectedMeasurer() {
        struct Fixed: TextMeasuring {
            func measure(_ string: String, fontSize: Float) -> Size { Size(width: 99, height: 7) }
        }
        let ctx = UIContext()
        ctx.textMeasurer = Fixed()
        let graph = ViewGraph(context: ctx)
        graph.install(root: TextApp())
        #expect(graph.root.children[0].intrinsicSize == Size(width: 99, height: 7))
    }

    // MARK: - Button

    private struct ButtonApp: View {
        let action: PrimitivesTests.ActionBox
        var body: some View {
            Button(action: { action.fire() }) {
                Element(width: 40, height: 20)
            }
        }
    }

    @Test("Button fires its action on press + release")
    func buttonPress() {
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        let box = ActionBox()
        var fired = 0
        box.fire = { fired += 1 }
        graph.install(root: ButtonApp(action: box))

        let button = graph.root.children[0]
        button.setFrame(Rect(x: 0, y: 0, width: 40, height: 20)) // place it for hit-testing

        let disp = EventDispatcher(context: ctx)
        let p = Point(x: 10, y: 10)
        disp.pointerDown(PointerEvent(position: p, action: .down))
        #expect(ctx.pointerCapture.target === button) // captured on press
        disp.pointerUp(PointerEvent(position: p, action: .up))
        #expect(fired == 1)
        #expect(ctx.pointerCapture.target == nil) // released after
    }
}
