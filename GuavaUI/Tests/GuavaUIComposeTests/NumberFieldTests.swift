import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 8 NumberField", .serialized)
struct NumberFieldTests: GuavaUIComposeSerializedSuite {

    private func makeRig() -> (
        registry: InteractionRegistry,
        focus: FocusChain,
        tree: NodeTree,
        graph: ViewGraph,
        store: FloatStore
    ) {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = nil

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        return (registry, focus, tree, graph, FloatStore())
    }

    final class FloatStore {
        var value: Float = 0
    }

    private func makeBinding(_ store: FloatStore) -> Binding<Float> {
        Binding(get: { store.value }, set: { store.value = $0 })
    }

    private func fieldNode(in root: Node?) -> Node {
        guard let node = firstNode(in: root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil }) else {
            fatalError("no NumberField surface found")
        }
        return node
    }

    private func firstNode(in root: Node?, where predicate: (Node) -> Bool) -> Node? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    private func key(_ scancode: UInt32, cmd: Bool = false) -> KeyEvent {
        var mods = KeyModifiers()
        if cmd { mods.insert(.lgui) }
        return KeyEvent(scancode: scancode, keycode: 0, modifiers: mods, isRepeat: false)
    }

    @Test("Return commits the parsed float value")
    func returnCommitsParsedFloat() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = 1
        rig.graph.install(root: NumberField(value: makeBinding(rig.store), size: .small))

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)
        rig.graph.recomposer.commitAll()

        let handlers = rig.registry.handlers(for: node)
        _ = handlers.key!(key(4, cmd: true), .target)
        _ = handlers.text!("12.5", .target)
        _ = handlers.key!(key(40), .target)

        #expect(abs(rig.store.value - 12.5) < 0.0001)
    } }

    @Test("Blur commits the parsed float value")
    func blurCommitsParsedFloat() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = 3
        rig.graph.install(root: NumberField(value: makeBinding(rig.store), size: .small))

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)
        rig.graph.recomposer.commitAll()

        let handlers = rig.registry.handlers(for: node)
        _ = handlers.key!(key(4, cmd: true), .target)
        _ = handlers.text!("7.25", .target)
        rig.focus.clear()
        rig.graph.recomposer.commitAll()

        #expect(abs(rig.store.value - 7.25) < 0.0001)
    } }

    @Test("Invalid blur keeps the previous numeric value")
    func invalidBlurRestoresValue() { GlobalTestLock.locked {
        let rig = makeRig()
        rig.store.value = 4.5
        rig.graph.install(root: NumberField(value: makeBinding(rig.store), size: .small))

        let node = fieldNode(in: rig.tree.root)
        rig.focus.focus(node)
        rig.graph.recomposer.commitAll()

        let handlers = rig.registry.handlers(for: node)
        _ = handlers.key!(key(4, cmd: true), .target)
        _ = handlers.text!("abc", .target)
        rig.focus.clear()
        rig.graph.recomposer.commitAll()

        #expect(abs(rig.store.value - 4.5) < 0.0001)
    } }
}
