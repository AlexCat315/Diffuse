import Testing
import GuavaUIRuntime
import PlatformShell
@testable import GuavaUICompose

@Suite("Cursor pipeline")
struct CursorPipelineTests {

    @Test("Button writes pointer cursor onto its node when enabled")
    func enabledButtonHasPointerCursor() {
        GlobalTestLock.locked {
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Button("Tap") {})

            // Button → _StatefulButton → ButtonHost (the actual primitive).
            // Walk to the first hit-testable descendant.
            let buttonNode = firstHitTestable(in: tree.root)
            #expect(buttonNode?.cursor == .pointer)
        }
    }

    @Test("Disabled button uses notAllowed cursor")
    func disabledButtonHasNotAllowedCursor() {
        GlobalTestLock.locked {
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            graph.install(root: Button("Off", isEnabled: false) {})
            let buttonNode = firstHitTestable(in: tree.root)
            #expect(buttonNode?.cursor == .notAllowed)
        }
    }

    @Test("TextField sets ibeam cursor")
    func textFieldHasIbeamCursor() {
        GlobalTestLock.locked {
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = nil }

            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            var text: String = ""
            let binding = Binding<String>(get: { text }, set: { text = $0 })
            graph.install(root: TextField("placeholder", text: binding, onSubmit: {}))

            let fieldNode = firstHitTestable(in: tree.root)
            #expect(fieldNode?.cursor == .ibeam)
        }
    }

    @Test(".cursor(_:) modifier overrides the underlying primitive")
    func cursorModifierOverrides() {
        GlobalTestLock.locked {
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            // .cursor(.crosshair) wraps the Button — modifier runs after the
            // primitive's _updateNode and therefore wins.
            graph.install(root: Button("Tap") {}.cursor(.crosshair))
            let buttonNode = firstHitTestable(in: tree.root)
            #expect(buttonNode?.cursor == .crosshair)
        }
    }

    private func firstHitTestable(in root: Node?) -> Node? {
        guard let root else { return nil }
        // Prefer a deeper hit-testable. Root itself has the default
        // `isHitTestable = true` (Node default) but is just an anchor — the
        // real Button/TextField primitive sits as a descendant.
        for c in root.children {
            if let deeper = firstHitTestable(in: c) { return deeper }
        }
        return root.isHitTestable && root.parent != nil ? root : nil
    }
}
