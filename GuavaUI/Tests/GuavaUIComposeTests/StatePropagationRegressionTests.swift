import Testing
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

@Suite("State propagation regressions", .serialized)
struct StatePropagationRegressionTests: GuavaUIComposeSerializedSuite {

    private func maxMarker(in node: Node?) -> Int {
        guard let node else { return 0 }
        return max(Int(node.frame.origin.x), node.children.map { maxMarker(in: $0) }.max() ?? 0)
    }

    private func firstNode(in node: Node?, where predicate: (Node) -> Bool) -> Node? {
        guard let node else { return nil }
        if predicate(node) { return node }
        for child in node.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    struct ButtonHarness: View {
        @State var flag: Bool = false
        @State var count: Int = 0

        var body: some View {
            Column {
                _DebugNode(label: flag ? "yy" : "x")
                Button("Tap") { count = 7 }
                _DebugNode(label: String(repeating: "x", count: count))
            }
        }
    }

    @Test("Button action still updates parent state after parent recompose")
    func buttonActionAfterParentRecompose() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let harness = ButtonHarness()
        graph.install(root: harness)

        #expect(maxMarker(in: tree.root) == 1)

        harness.$flag.wrappedValue = true
        recomp.commitAll()
        #expect(maxMarker(in: tree.root) == 2)

        let host = firstNode(in: tree.root) { registry.handlers(for: $0).pointer != nil }
        #expect(host != nil)

        let pointer = registry.handlers(for: host!).pointer
        #expect(pointer != nil)
        let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
        _ = pointer?(evt, .down, .target)
        _ = pointer?(evt, .up, .target)
        recomp.commitAll()

        #expect(maxMarker(in: tree.root) == 7)
    } }

    struct ButtonTextLabelHarness: View {
        @State var flag: Bool = false

        var body: some View {
            Button(action: {}) {
                _DebugNode(label: flag ? "xxxxxxx" : "x")
            }
        }
    }

    @Test("Button text label reflows after parent recompose")
    func buttonTextLabelReflows() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let harness = ButtonTextLabelHarness()
        graph.install(root: harness)
        #expect(maxMarker(in: tree.root) == 1)

        harness.$flag.wrappedValue = true
        recomp.commitAll()

        #expect(maxMarker(in: tree.root) == 7)
    } }

    struct TextFieldHarness: View {
        @State var flag: Bool = false
        @State var text: String = ""

        var body: some View {
            Column {
                _DebugNode(label: flag ? "yy" : "x")
                TextField(text: $text)
                _DebugNode(label: String(repeating: "x", count: text.count))
            }
        }
    }

    @Test("TextField binding still updates parent state after parent recompose")
    func textFieldBindingAfterParentRecompose() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let harness = TextFieldHarness()
        graph.install(root: harness)

        #expect(maxMarker(in: tree.root) == 1)

        harness.$flag.wrappedValue = true
        recomp.commitAll()
        #expect(maxMarker(in: tree.root) == 2)

        let field = firstNode(in: tree.root) { registry.handlers(for: $0).text != nil }
        #expect(field != nil)
        focus.focus(field)

        let textHandler = registry.handlers(for: field!).text
        #expect(textHandler != nil)
        _ = textHandler?("abc", .target)
        recomp.commitAll()

        #expect(maxMarker(in: tree.root) == 3)
    } }
}