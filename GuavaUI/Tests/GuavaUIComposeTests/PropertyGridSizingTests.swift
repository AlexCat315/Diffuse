import Foundation
import Testing
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

@Suite("Property grid sizing", .serialized)
struct PropertyGridSizingTests {
    private struct Harness: View {
        @State var isExpanded = false
        var body: some View {
            PropertyGrid([
                PropertyGridSection(id: "component", title: "Component", rows: [
                    PropertyGridRow(id: "editor", label: "Shapes", layout: .fullWidth, sizing: .intrinsic) {
                        Box { EmptyView() }
                            .frame(height: isExpanded ? 180 : 24)
                            .debugName("intrinsic-value")
                    },
                    PropertyGridRow(id: "next", label: "Enabled") {
                        Box { EmptyView() }.frame(height: 24).debugName("next-value")
                    },
                ])
            ], labelWidth: 72, minValueWidth: 80, scrollAxes: .vertical)
        }
    }

    private struct ControlledHarness: View {
        @State var collapsedIDs: Set<String> = []
        var body: some View {
            PropertyGrid([PropertyGridSection(id: "component", title: "Component", rows: [
                PropertyGridRow(id: "row", label: "Value") {
                    Text("Editable").debugName("controlled-grid-value")
                }
            ], isCollapsible: true)], scrollAxes: .vertical,
                         collapsedSectionIDs: collapsedIDs,
                         onSectionCollapseChanged: { id, collapsed in
                if collapsed { collapsedIDs.insert(id) } else { collapsedIDs.remove(id) }
            })
        }
    }

    @Test("controlled section collapse follows toolbar commands after a local toggle")
    func controlledCollapse() throws { try GlobalTestLock.locked {
        let previous = InteractionRegistryHolder.current
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        defer { InteractionRegistryHolder.current = previous }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let harness = ControlledHarness()
        graph.install(root: harness)
        let header = try #require(firstNode(tree.root) { registry.handlers(for: $0).key != nil })
        _ = registry.handlers(for: header).key?(KeyEvent(scancode: 40, keycode: 0,
                                                       modifiers: [], isRepeat: false), .target)
        graph.recomposer.commitAll()
        #expect(harness.collapsedIDs == ["component"])
        AnimatorScheduler.current.tick(deltaTime: 1)
        graph.recomposer.commitAll()
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "controlled-grid-value" })
        harness.$collapsedIDs.wrappedValue = []
        graph.recomposer.commitAll()
        #expect(graph.layoutSnapshot().contains { $0.debugName == "controlled-grid-value" })
    } }

    private func firstNode(_ node: Node?, matching predicate: (Node) -> Bool) -> Node? {
        guard let node else { return nil }
        if predicate(node) { return node }
        for child in node.children {
            if let match = firstNode(child, matching: predicate) { return match }
        }
        return nil
    }

    @Test("disclosure content grows and shrinks without overlapping following rows",
          arguments: [Float(200), Float(320)])
    func intrinsicRowsReflow(width: Float) throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
        defer { TextEnvironmentHolder.current = previous }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        let harness = Harness()
        graph.install(root: harness)
        for expanded in [false, true, false] {
            harness.$isExpanded.wrappedValue = expanded
            graph.recomposer.commitAll()
            graph.computeLayout(width: width, height: 480)
            let frames = graph.layoutSnapshot()
            let value = try #require(frames.first { $0.debugName == "intrinsic-value" }?.absoluteFrame)
            let next = try #require(frames.first { $0.debugName == "next-value" }?.absoluteFrame)
            #expect(value.height == (expanded ? 180 : 24))
            #expect(next.minY >= value.maxY)
            #expect(value.maxX <= CGFloat(width))
            #expect(next.maxX <= CGFloat(width))
        }
    } }
}
