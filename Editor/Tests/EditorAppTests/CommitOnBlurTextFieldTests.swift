@testable import EditorApp
import EngineKernel
import GuavaUICompose
import GuavaUIRuntime
import Testing

@Suite("CommitOnBlurTextField", .serialized)
struct CommitOnBlurTextFieldTests {
    private final class Model {
        var value = "Cube"
        var writes = 0
    }

    private struct Rig {
        let registry: InteractionRegistry
        let node: Node
        let focusHandler: TextInputFocusChangeHandler
    }

    private func makeBinding(_ model: Model) -> Binding<String> {
        Binding(
            get: { model.value },
            set: { next in
                model.writes += 1
                // Model-side invariant, e.g. entity names can't be empty.
                model.value = next.isEmpty ? "Entity 1" : next
            }
        )
    }

    private func install(_ model: Model) -> Rig? {
        let registry = InteractionRegistry()
        let focus = FocusChain()
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: CommitOnBlurTextField(identity: "e1/name", text: makeBinding(model)))

        guard let node = firstNode(in: tree.root, where: { $0.attachments["__textfield_state"] != nil }),
              let focusHandler = node.attachments[TextInputAttachmentKey.focusChangeHandler]
                  as? TextInputFocusChangeHandler
        else { return nil }
        return Rig(registry: registry, node: node, focusHandler: focusHandler)
    }

    private func tearDownHolders() {
        InteractionRegistryHolder.current = nil
        FocusChainHolder.current = nil
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

    @Test("Clearing the text mid-edit keeps the draft empty; fallback applies once on blur")
    func emptyDraftCommitsOnBlur() {
        defer { tearDownHolders() }
        let model = Model()
        guard let rig = install(model) else {
            Issue.record("no text field node")
            return
        }
        let h = rig.registry.handlers(for: rig.node)

        rig.focusHandler(true)
        let cmdA = KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false)
        _ = h.key!(cmdA, .target)
        let backspace = KeyEvent(scancode: 42, keycode: 0, modifiers: [], isRepeat: false)
        _ = h.key!(backspace, .target)

        // Mid-edit: nothing written through, no fallback generated under the caret.
        #expect(model.writes == 0)
        #expect(model.value == "Cube")

        rig.focusHandler(false)
        // Blur commits exactly once; the model's empty-name fallback applies now.
        #expect(model.writes == 1)
        #expect(model.value == "Entity 1")
    }

    @Test("Return commits the draft once and keeps the value editable")
    func returnCommits() {
        defer { tearDownHolders() }
        let model = Model()
        guard let rig = install(model) else {
            Issue.record("no text field node")
            return
        }
        let h = rig.registry.handlers(for: rig.node)

        rig.focusHandler(true)
        let cmdA = KeyEvent(scancode: Scancode.a, keycode: 0, modifiers: [.lgui], isRepeat: false)
        _ = h.key!(cmdA, .target)
        _ = h.text!("Box", .target)
        #expect(model.writes == 0)

        let returnKey = KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false)
        _ = h.key!(returnKey, .target)
        #expect(model.writes == 1)
        #expect(model.value == "Box")

        // Typing again after a Return-commit re-enters draft mode.
        _ = h.text!("y", .target)
        #expect(model.writes == 1)
        rig.focusHandler(false)
        #expect(model.writes == 2)
        #expect(model.value == "Boxy")
    }
}
