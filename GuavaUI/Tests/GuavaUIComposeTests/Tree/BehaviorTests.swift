import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Tree branching and navigation", .serialized)
struct TreeBehaviorTests: GuavaUIComposeSerializedSuite {
    private struct Item: Identifiable {
        let id: Int
        var isBranch: Bool { id == 0 || id == 1 }
    }
    private final class Reads {
        var ids: [Int] = []
        func children(_ item: Item) -> [Item] {
            ids.append(item.id)
            switch item.id {
            case 0: return [Item(id: 1), Item(id: 2)]
            case 1: return [Item(id: 3)]
            default: return []
            }
        }
    }
    private final class Harness: View {
        @State var expanded: Set<Int> = []
        @State var selection: Int? = 0
        @State var enabled = true
        @State var query = ""
        let reads = Reads()
        var body: some View {
            Tree([Item(id: 0)], id: \.id, children: reads.children, hasChildren: \.isBranch, configure: {
                $0.isEnabled = enabled
                $0.selection.primary = $selection
                $0.selection.expanded = $expanded
                $0.search.query = query
                $0.search.text = { "Node \($0.id)" }
                $0.layout.rowSpacing = 3
            }) { item, selected, expanded, _ in
                Text("Node \(item.id) \(selected ? "selected" : "idle") \(expanded ? "open" : "closed")")
            }.frame(height: 180)
        }
    }
    private func scene(_ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler()
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer()), harness = Harness()
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: harness)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                settle(graph)
                try work(harness, graph, context, input)
            } }
        }
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 440, height: 240) }
    }
    private func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
    private func key(_ code: UInt32, modifiers: KeyModifiers = [], input: EventDispatcher, graph: ViewGraph) {
        input.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
        settle(graph)
    }

    @Test("Lazy branches resolve only when expanded; shortcuts, Home/End and search preserve selection")
    func lazyNavigation() throws {
        try scene { harness, graph, context, input in
            #expect(harness.reads.ids.isEmpty)
            let keyboard = try #require(all(graph.tree.root!).first { $0.accessibility?.role == .tree })
            context.focusChain.focus(keyboard)
            key(Scancode.arrowRight, input: input, graph: graph)
            #expect(harness.expanded == [0])
            #expect(!harness.reads.ids.isEmpty && harness.reads.ids.allSatisfy { $0 == 0 })
            key(Scancode.arrowRight, modifiers: .lalt, input: input, graph: graph)
            #expect(harness.expanded == [0, 1])
            key(Scancode.end, input: input, graph: graph)
            #expect(harness.selection == 2)
            key(Scancode.home, input: input, graph: graph)
            #expect(harness.selection == 0)
            key(Scancode.arrowLeft, modifiers: .ralt, input: input, graph: graph)
            #expect(harness.expanded.isEmpty)
            harness.reads.ids = []
            harness.query = "Node 3"; settle(graph)
            #expect(harness.expanded.isEmpty)
            #expect(!harness.reads.ids.contains(2) && !harness.reads.ids.contains(3))
            #expect(all(graph.tree.root!).contains { $0.layoutNode?.textInputs?.text == "Node 3 idle closed" })
            harness.query = ""; settle(graph)
            #expect(!all(graph.tree.root!).contains { $0.layoutNode?.textInputs?.text.hasPrefix("Node 3") == true })
        }
    }

    @Test("Disabling a tree releases focus and blocks pointer, keyboard and accessible activation")
    func disabledInput() throws {
        try scene { harness, graph, context, input in
            harness.expanded = [0]; settle(graph)
            let keyboard = try #require(all(graph.tree.root!).first { $0.accessibility?.role == .tree })
            context.focusChain.focus(keyboard)
            harness.enabled = false; settle(graph)
            #expect(context.focusChain.focused == nil)
            let row = try #require(all(graph.tree.root!).first { $0.accessibility?.role == .treeItem && $0.accessibility?.state.isSelected == false })
            #expect(row.accessibility?.state.isEnabled == false && row.accessibilityActions.activate == nil)
            let frame = row.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event)); settle(graph)
            key(Scancode.end, input: input, graph: graph)
            #expect(harness.selection == 0 && harness.expanded == [0])
            harness.enabled = true; settle(graph)
            context.focusChain.focus(keyboard)
            key(Scancode.end, input: input, graph: graph)
            #expect(harness.selection == 2)
            #expect(all(graph.tree.root!).contains { $0.layoutNode?.textInputs?.text == "Node 2 selected closed" })
        }
    }
}
