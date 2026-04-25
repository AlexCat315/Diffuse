import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("ShortcutHost", .serialized)
struct ShortcutHostTests: GuavaUIComposeSerializedSuite {
    private func findShortcutNode(in node: Node, registry: InteractionRegistry) -> Node? {
        if registry.handlers(for: node).keyRoute == .shortcut {
            return node
        }
        for child in node.children {
            if let match = findShortcutNode(in: child, registry: registry) {
                return match
            }
        }
        return nil
    }

    @Test("ShortcutHost registers a system shortcut route")
    func registersShortcutRoute() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: ShortcutHost { _ in true })

        let node = findShortcutNode(in: tree.root!, registry: registry)!
        let handlers = registry.handlers(for: node)
        #expect(node.isHitTestable == false)
        #expect(node.isFocusable == false)
        #expect(handlers.keyRoute == .shortcut)
        #expect(handlers.key != nil)
    } }

    @Test("ShortcutHost maps Bool results to EventResult")
    func mapsBoolResult() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: ShortcutHost { key in
            key.keycode == 0x31
        })

        let node = findShortcutNode(in: tree.root!, registry: registry)!
        let handler = registry.handlers(for: node).key!
        #expect(handler(KeyEvent(scancode: 0,
                                 keycode: 0x31,
                                 modifiers: .gui,
                                 isRepeat: false), .capture) == .handled)
        #expect(handler(KeyEvent(scancode: 0,
                                 keycode: 0x32,
                                 modifiers: .gui,
                                 isRepeat: false), .capture) == .ignored)
    } }
}
