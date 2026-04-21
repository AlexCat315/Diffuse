import Testing
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Verifies that pointer-driven press transitions on a real `Button`
/// invalidate the owning scope (via `_StatefulButton`'s `@State`) and
/// recompose the styled body. Before this fix, `node.markDirty()` did not
/// re-run `_children(for:)`, so the visual state never changed in
/// production — even though `ButtonStyleAnimationTests` proved the styles
/// themselves transitioned correctly when driven by `@State` directly.
@Suite("Phase 8 / Button press recompose plumbing", .serialized)
struct ButtonPressRecomposeTests: GuavaUIComposeSerializedSuite {

    private func findFilled(_ root: Node) -> Node? {
        if let bg = root.backgroundColor, bg.a > 0 { return root }
        for c in root.children {
            if let n = findFilled(c) { return n }
        }
        return nil
    }

    private func buttonHost(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!.children.first!
    }

    @Test("Pointer down on Button recomposes body with isPressed=true")
    func pointerDownRecomposes() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let pressedColor = theme.colors.accent.darker(0.10)

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: {}) { Text("Tap") }
            )

            // Resting state.
            let filled = findFilled(tree.root!)
            #expect(filled?.backgroundColor == resting)

            // Drive pointer down on the ButtonHost.
            let host = buttonHost(in: tree)
            let handler = registry.handlers(for: host).pointer
            #expect(handler != nil)
            let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
            _ = handler!(evt, .down, .target)

            // The State write enqueues an invalidation; flush it.
            recomp.commitAll()

            // Settle the implicit press animation to its terminal value so we
            // can assert against `pressedColor` deterministically.
            scheduler.tick(deltaTime: 1.0)

            let after = findFilled(tree.root!)
            #expect(after?.backgroundColor == pressedColor)

            // Release.
            _ = handler!(evt, .up, .target)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)

            let released = findFilled(tree.root!)
            #expect(released?.backgroundColor == resting)
        }
    } }

    @Test("Hover enter on Button recomposes body with isHovered=true")
    func hoverEnterRecomposes() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry

        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let hoveredColor = theme.colors.accent.lighter(0.06)

            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root:
                Button(action: {}) { Text("Hover") }
            )

            #expect(findFilled(tree.root!)?.backgroundColor == resting)

            let host = buttonHost(in: tree)
            let hover = registry.handlers(for: host).hover
            #expect(hover != nil)

            hover?(.enter)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == hoveredColor)

            hover?(.leave)
            recomp.commitAll()
            scheduler.tick(deltaTime: 1.0)
            #expect(findFilled(tree.root!)?.backgroundColor == resting)
        }
    } }
}
