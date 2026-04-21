import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Drives real `Button` instances through `InteractionRegistry` pointer
/// events so the press transition exercises the full production path:
/// pointer handler → `_StatefulButton.@State` write → `Recomposer.invalidate`
/// → recompose → `ButtonStyle.makeBody` → `.animation(.buttonInteraction,
/// value: configuration.interactionKey)` registers a controller against the
/// active `AnimatorScheduler`.
@Suite("Phase 8 / ButtonStyle implicit transitions", .serialized)
struct ButtonStyleAnimationTests: GuavaUIComposeSerializedSuite {

    private func findFilled(_ root: Node) -> Node? {
        if let bg = root.backgroundColor, bg.a > 0 { return root }
        for c in root.children {
            if let n = findFilled(c) { return n }
        }
        return nil
    }

    private func findHitTestable(_ root: Node) -> Node? {
        // Children-first so we land on the inner ButtonHost, not on the
        // graph root anchor (which install marks hit-testable for the
        // root-level pointer dispatcher).
        for c in root.children {
            if let n = findHitTestable(c) { return n }
        }
        if root.isHitTestable { return root }
        return nil
    }

    private func install<V: View>(_ view: V) -> (NodeTree, Recomposer, InteractionRegistry, ViewGraph) {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: view)
        return (tree, recomp, registry, graph)
    }

    @Test("PrimaryButtonStyle animates background on real pointer-down")
    func primaryAnimatesOnPress() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.accent
            let pressed = theme.colors.accentPressed

            let (tree, recomp, registry, graph) = install(
                Button(action: {}) { Text("Hi") }
            )
            _ = graph

            #expect(findFilled(tree.root!)?.backgroundColor == resting)
            #expect(scheduler.activeCount == 0)

            let host = findHitTestable(tree.root!)!
            let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
            _ = registry.handlers(for: host).pointer!(evt, .down, .target)
            recomp.commitAll()

            #expect(scheduler.activeCount >= 1)
            #expect(findFilled(tree.root!)?.backgroundColor == resting)

            scheduler.tick(deltaTime: 0.06)
            let mid = findFilled(tree.root!)?.backgroundColor?.r ?? -1
            #expect(mid >= pressed.r && mid <= resting.r)

            scheduler.tick(deltaTime: 0.10)
            #expect(findFilled(tree.root!)?.backgroundColor == pressed)
            #expect(scheduler.activeCount == 0)
        }
    } }

    @Test("DestructiveButtonStyle animates background on real pointer-down")
    func destructiveAnimatesOnPress() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let theme = Theme.defaultDark
            let resting = theme.colors.error
            let pressed = theme.colors.error.composited(over: theme.colors.stateLayerPressed)

            let (tree, recomp, registry, graph) = install(
                Button(action: {}) { Text("X") }
                    .buttonStyle(DestructiveButtonStyle())
            )
            _ = graph

            #expect(findFilled(tree.root!)?.backgroundColor == resting)

            let host = findHitTestable(tree.root!)!
            let evt = MouseButtonEvent(button: .left, x: 0, y: 0, clicks: 1)
            _ = registry.handlers(for: host).pointer!(evt, .down, .target)
            recomp.commitAll()

            #expect(scheduler.activeCount >= 1)
            scheduler.tick(deltaTime: 0.12)
            #expect(findFilled(tree.root!)?.backgroundColor == pressed)
        }
    } }

    @Test("First render snaps - no controllers active")
    func firstRenderSnaps() { GlobalTestLock.locked {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let (_, _, _, graph) = install(Button(action: {}) { Text("Hi") })
            _ = graph
            #expect(scheduler.activeCount == 0)
        }
    } }
}
