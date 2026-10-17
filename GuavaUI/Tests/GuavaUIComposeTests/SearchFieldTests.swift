import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Search field", .serialized)
struct SearchFieldTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                TextEnvironmentHolder.current = oldText
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func field(in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
    }

    private func press(_ key: UInt32, on node: Node, registry: InteractionRegistry) {
        _ = registry.handlers(for: node).key?(
            KeyEvent(scancode: key, keycode: 0, modifiers: [], isRepeat: false), .target)
    }

    @Test("Escape clears the query")
    func escapeClears() {
        withScene { graph, registry in
            var buffer = TextBuffer("camera")
            graph.install(root: SearchField(text: Binding(get: { buffer }, set: { buffer = $0 })))
            graph.computeLayout(width: 400, height: 200)
            guard let field = try? field(in: graph) else {
                Issue.record("search field was not mounted")
                return
            }
            press(Scancode.escape, on: field, registry: registry)
            #expect(buffer.stringValue.isEmpty)
        }
    }

    @Test("Arrow keys move the suggestion highlight and Return selects it")
    func suggestionSelection() {
        withScene { graph, registry in
            var buffer = TextBuffer("Ca")
            var selected: String?
            graph.install(root: SearchField(
                text: Binding(get: { buffer }, set: { buffer = $0 }),
                suggestions: ["Camera", "Canvas", "Counter"],
                onSuggestionSelected: { selected = $0 }
            ))
            graph.computeLayout(width: 400, height: 240)
            guard let field = try? field(in: graph) else {
                Issue.record("search field was not mounted")
                return
            }
            press(Scancode.arrowDown, on: field, registry: registry)
            press(Scancode.return, on: field, registry: registry)
            #expect(selected == "Camera")
            #expect(buffer.stringValue == "Camera")
        }
    }

    @Test("Return submits the current query when no suggestion is highlighted")
    func submit() {
        withScene { graph, registry in
            var buffer = TextBuffer("light")
            var submitted = ""
            graph.install(root: SearchField(
                text: Binding(get: { buffer }, set: { buffer = $0 }),
                onSubmit: { submitted = $0 }
            ))
            graph.computeLayout(width: 400, height: 200)
            guard let field = try? field(in: graph) else {
                Issue.record("search field was not mounted")
                return
            }
            press(Scancode.return, on: field, registry: registry)
            #expect(submitted == "light")
        }
    }
}
