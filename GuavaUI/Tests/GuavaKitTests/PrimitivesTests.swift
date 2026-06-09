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

    @Test("flex modifier sets flexGrow and flexShrink on layout")
    func flexModifier() {
        struct App: View {
            var body: some View { Element().flex(2, shrink: 0) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.layoutStyle.flexGrow == 2)
        #expect(node.layoutStyle.flexShrink == 0)
    }

    @Test("border modifier sets border on paint")
    func borderModifier() {
        struct App: View {
            var body: some View { Element().border(Color(r: 0, g: 0, b: 1), width: 2) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.paint.border?.color == Color(r: 0, g: 0, b: 1))
        #expect(node.paint.border?.width == 2)
    }

    @Test("EdgeInsets padding applies correctly")
    func edgeInsetsPadding() {
        struct App: View {
            var body: some View {
                Element().padding(EdgeInsets(top: 1, left: 2, bottom: 3, right: 4))
            }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.layoutStyle.padding.top == 1)
        #expect(node.layoutStyle.padding.left == 2)
        #expect(node.layoutStyle.padding.bottom == 3)
        #expect(node.layoutStyle.padding.right == 4)
    }

    @Test("EdgeInsets padding(horizontal:vertical:) applies symmetrically")
    func edgeInsetsPaddingHorizontalVertical() {
        struct App: View {
            var body: some View { Element().padding(horizontal: 6, vertical: 4) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.layoutStyle.padding.top == 4)
        #expect(node.layoutStyle.padding.left == 6)
        #expect(node.layoutStyle.padding.bottom == 4)
        #expect(node.layoutStyle.padding.right == 6)
    }

    @Test("Unlimited lineLimit (nil) leaves node unchanged")
    func lineLimitNil() {
        struct App: View {
            var body: some View { Text("hi").lineLimit(nil) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.textLineLimit == nil)
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
        #expect(list.commands.contains { if case .text("hi", _, _, _, _) = $0 { return true }; return false })
    }

    @Test("Text with lineLimit stores it on the node and forwards to display list")
    func textLineLimit() {
        struct TextLimitApp: View {
            var body: some View { Text("hello world", lineLimit: 1).frame(width: 100, height: 20) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: TextLimitApp())
        let node = graph.root.children[0]
        #expect(node.textLineLimit == 1)

        let list = Painter().paint(root: graph.root)
        // The text command carries lineLimit.
        let found = list.commands.contains {
            if case .text(_, _, _, _, let ll) = $0, ll == 1 { return true }
            return false
        }
        #expect(found)
    }

    @Test(".lineLimit modifier sets textLineLimit on the node")
    func lineLimitModifier() {
        struct App: View {
            var body: some View { Text("hi").lineLimit(2) }
        }
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App())
        let node = graph.root.children[0]
        #expect(node.textLineLimit == 2)
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

    @Test("Button fires when its label (the laid-out hit target) is clicked")
    func buttonFiresThroughLabel() {
        struct App: View {
            let onTap: () -> Void
            var body: some View {
                Button(action: onTap) { Text("Click").padding(8) }
            }
        }
        var fired = 0
        let ctx = UIContext(); let graph = ViewGraph(context: ctx)
        graph.install(root: App(onTap: { fired += 1 }))
        ctx.layoutIfNeeded(engine: StackLayoutEngine(), available: Size(width: 200, height: 80))

        // Click the centre of the laid-out button — i.e. over the Text label,
        // which (being hit-testable) is the deepest hit, not the Button node.
        let button = graph.root.children[0]
        let f = button.geometry.frame
        let p = Point(x: f.minX + f.size.width / 2, y: f.minY + f.size.height / 2)
        let disp = EventDispatcher(context: ctx)
        disp.pointerDown(PointerEvent(position: p, action: .down))
        disp.pointerUp(PointerEvent(position: p, action: .up))
        #expect(fired == 1)
    }
}
