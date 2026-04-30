import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("JsonField", .serialized)
struct JsonFieldTests: GuavaUIComposeSerializedSuite {
    final class Store {
        var value = "{}"
    }

    @Test("empty input saves as an empty JSON object")
    func emptyNormalizesToObject() {
        #expect(JsonField.normalizedCommitText("  \n ") == "{}")
        #expect(JsonField.validate("  \n ") == .empty)
    }

    @Test("valid and invalid JSON are distinguished")
    func validatesJson() {
        #expect(JsonField.validate("{\"speed\": 3}").isAcceptable == true)
        #expect(JsonField.validate("{ speed: 3 }").isAcceptable == false)
    }

    @Test("pretty printer sorts keys for stable diffs")
    func prettyPrinterSortsKeys() {
        let pretty = JsonField.prettyPrinted("{\"z\":1,\"a\":2}")
        #expect(pretty == "{\n  \"a\" : 2,\n  \"z\" : 1\n}")
    }

    @Test("Primary-Return commits only valid JSON through the field")
    func commitsValidJson() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = nil

        let store = Store()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        var commits: [String] = []
        graph.install(root:
            JsonField(text: Binding(get: { store.value }, set: { store.value = $0 }),
                      onCommit: { commits.append($0) })
        )

        let node = fieldNode(in: tree.root)
        focus.focus(node)
        graph.recomposer.commitAll()

        let handlers = registry.handlers(for: node)
        _ = handlers.key!(key(4, primary: true), .target)
        _ = handlers.text!("{\"speed\":4}", .target)
        _ = handlers.key!(key(40, primary: true), .target)

        #expect(store.value == "{\"speed\":4}")
        #expect(commits == ["{\"speed\":4}"])
    } }

    @Test("invalid JSON does not commit over the bound value")
    func rejectsInvalidJson() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        TextEnvironmentHolder.current = nil

        let store = Store()
        store.value = "{\"ok\":true}"
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            JsonField(text: Binding(get: { store.value }, set: { store.value = $0 }))
        )

        let node = fieldNode(in: tree.root)
        focus.focus(node)
        graph.recomposer.commitAll()

        let handlers = registry.handlers(for: node)
        _ = handlers.key!(key(4, primary: true), .target)
        _ = handlers.text!("{ nope }", .target)
        _ = handlers.key!(key(40, primary: true), .target)

        #expect(store.value == "{\"ok\":true}")
    } }

    private func fieldNode(in root: Node?) -> Node {
        guard let node = firstNode(in: root, where: { $0.attachments[TextField.surfaceMarkerKey] != nil }) else {
            fatalError("no JsonField text surface found")
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

    private func key(_ scancode: UInt32, primary: Bool = false) -> KeyEvent {
        var mods = KeyModifiers()
        if primary { mods.insert(.lgui) }
        return KeyEvent(scancode: scancode, keycode: 0, modifiers: mods, isRepeat: false)
    }
}
