import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ViewThatFits content trees", .serialized)
struct ViewThatFitsTests: GuavaUIComposeSerializedSuite {
    private struct Counter: View {
        let name: String
        @State private var count = 0
        var body: some View {
            Button(action: { count += 1 }) { Box {}.frame(width: 20, height: 20) }
                .debugName(name).modifier(Value(value: count)).accessibilityLabel(name)
        }
    }
    private struct Value: ViewModifier {
        let value: Int
        func apply(node: Node) { node.attachments["test.counter"] = value }
    }
    private struct Harness: View {
        @State var width: Float = 700
        @State var threshold: Float = 600
        var body: some View {
            ViewThatFits(threshold: CGFloat(threshold)) {
                Counter(name: "wide")
            } compact: {
                Counter(name: "compact")
            }.frame(width: width, height: 100)
        }
    }
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func named(_ name: String, in graph: ViewGraph) -> Node? {
        nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name }
    }
    private func settle(_ graph: ViewGraph, width: Float) {
        for _ in 0..<3 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: width, height: 100)
        }
        #expect(!graph.recomposer.hasPending)
    }

    @Test("only the measured branch lays out and is exposed to input and accessibility")
    func selectionAndVisibility() throws { try GlobalTestLock.locked {
        let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        #expect(named("compact", in: graph) != nil && named("wide", in: graph) == nil)
        settle(graph, width: 700)
        let wide = try #require(named("wide", in: graph)), compact = try #require(named("compact", in: graph))
        #expect(wide.acceptsSubtreeInput && !compact.acceptsSubtreeInput)
        #expect(wide.frame.width > 0 && compact.frame.size == .zero)
        #expect(AccessibilityTree.snapshot(root: graph.tree.root!).map(\.semantics.label) == ["wide"])
        harness.width = 300
        settle(graph, width: 300)
        #expect(!wide.acceptsSubtreeInput && compact.acceptsSubtreeInput)
        #expect(wide.frame.size == .zero && compact.frame.width > 0)
        #expect(AccessibilityTree.snapshot(root: graph.tree.root!).map(\.semantics.label) == ["compact"])
    } }

    @Test("round trips preserve independent local state and node identity, while releasing hidden focus and capture")
    func retainedState() throws { try GlobalTestLock.locked {
        let oldRegistry = InteractionRegistryHolder.current, oldFocus = FocusChainHolder.current
        let oldCapture = PointerCaptureHolder.current
        let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
        InteractionRegistryHolder.current = registry; FocusChainHolder.current = focus; PointerCaptureHolder.current = capture
        defer { InteractionRegistryHolder.current = oldRegistry; FocusChainHolder.current = oldFocus; PointerCaptureHolder.current = oldCapture }
        let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness); settle(graph, width: 700)
        let wide = try #require(named("wide", in: graph))
        wide.accessibilityActions.activate?(); settle(graph, width: 700)
        #expect(wide.attachments["test.counter"] as? Int == 1)
        focus.focus(wide); capture.acquire(wide)
        harness.width = 300; settle(graph, width: 300)
        #expect(focus.focused == nil && capture.target == nil)
        let compact = try #require(named("compact", in: graph))
        #expect(compact.attachments["test.counter"] as? Int == 0)
        compact.accessibilityActions.activate?(); compact.accessibilityActions.activate?()
        settle(graph, width: 300)
        harness.width = 800; settle(graph, width: 800)
        #expect(named("wide", in: graph) === wide && wide.attachments["test.counter"] as? Int == 1)
        harness.width = 320; settle(graph, width: 320)
        #expect(named("compact", in: graph) === compact && compact.attachments["test.counter"] as? Int == 2)
        let id = compact.id
        graph.install(root: EmptyView())
        #expect(nodes(graph.tree.root!).allSatisfy { $0.id != id })
    } }

    @Test("the wide threshold is inclusive and changing it does not require a new measurement")
    func thresholdBoundary() throws { try GlobalTestLock.locked {
        let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness); settle(graph, width: 700)
        harness.width = 600; settle(graph, width: 600)
        let wide = try #require(named("wide", in: graph))
        #expect(wide.acceptsSubtreeInput)
        harness.threshold = 700; settle(graph, width: 600)
        let compact = try #require(named("compact", in: graph))
        #expect(compact.acceptsSubtreeInput)
        #expect(!wide.acceptsSubtreeInput)
    } }
}
