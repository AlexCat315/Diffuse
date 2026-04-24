import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Step 7 — declarative `.animation(_:value:)` modifier. Asserts that:
/// - First materialisation snaps (no implicit animation on initial render).
/// - Subsequent recomposes that change `value` wrap descendant
///   `animatableSet` writes in the supplied `Animation`.
/// - `nil` animation suppresses the implicit wrap.
@Suite("Phase 8 / .animation(_:value:)")
struct AnimationValueModifierTests {

    struct ImplicitOpacityHarness: View {
        @State var alpha: Float = 0.0
        var body: some View {
            _DebugNode(label: "x")
                .opacity(alpha)
                .animation(Animation(duration: 1.0, curve: .linear), value: alpha)
        }
    }

    struct NilOptOutHarness: View {
        @State var alpha: Float = 0.0
        var body: some View {
            _DebugNode(label: "x")
                .opacity(alpha)
                .animation(nil, value: alpha)
        }
    }

    struct ImplicitFrameHarness: View {
        @State var width: Float = 40
        var body: some View {
            _DebugNode(label: "x")
                .frame(width: width)
                .animation(Animation(duration: 1.0, curve: .linear), value: width)
        }
    }

    struct ImplicitMaxFrameHarness: View {
        @State var maxWidth: Float? = 120
        var body: some View {
            _DebugNode(label: "x")
                .frame(maxWidth: maxWidth)
                .animation(Animation(duration: 1.0, curve: .linear), value: maxWidth)
        }
    }

    /// The animation modifier wraps content via a synthetic anchor — find the
    /// inner _DebugNode by descending past the anchor.
    private func findLeaf(_ tree: NodeTree) -> Node? {
        guard let root = tree.root else { return nil }
        var cur: Node? = root.children.first
        while let n = cur, !n.isHitTestable, let next = n.children.first {
            cur = next
            if n.children.count > 1 { break }
        }
        // Final descent into the _DebugNode leaf if still wrapping anchors.
        while let n = cur, n.children.count == 1 {
            cur = n.children.first
        }
        return cur
    }

    @Test("Initial render snaps even when animation is supplied")
    func initialRenderSnaps() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            graph.install(root: ImplicitOpacityHarness())

            let leaf = findLeaf(tree)
            #expect(leaf?.opacity == 0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Subsequent value change animates implicitly")
    func valueChangeAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = ImplicitOpacityHarness()
            graph.install(root: h)

            let leaf = findLeaf(tree)
            h.$alpha.wrappedValue = 1.0
            recomp.commitAll()

            #expect(leaf?.opacity == 0)
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(leaf?.opacity == 0.5)

            scheduler.tick(deltaTime: 0.5)
            #expect(leaf?.opacity == 1.0)
        }
    }

    @Test("animation(nil, value:) writes instantly even on change")
    func nilOptsOut() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = NilOptOutHarness()
            graph.install(root: h)

            let leaf = findLeaf(tree)
            h.$alpha.wrappedValue = 1.0
            recomp.commitAll()

            #expect(leaf?.opacity == 1.0)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("frame(width:) animates implicitly on value change")
    func implicitFrameAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = ImplicitFrameHarness()
            graph.install(root: h)

            let leaf = findLeaf(tree)
            let layout = leaf?.layoutNode

            h.$width.wrappedValue = 80
            recomp.commitAll()

            #expect(layout?.width == 40)
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(layout?.width == 60)

            scheduler.tick(deltaTime: 0.5)
            #expect(layout?.width == 80)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("frame(maxWidth:) animates implicitly on value change")
    func implicitMaxFrameAnimates() {
        let scheduler = AnimatorScheduler()
        AnimatorScheduler.$current.withValue(scheduler) {
            let tree = NodeTree()
            let recomp = Recomposer()
            let graph = ViewGraph(tree: tree, recomposer: recomp)
            let h = ImplicitMaxFrameHarness()
            graph.install(root: h)

            let leaf = findLeaf(tree)
            let layout = leaf?.layoutNode

            h.$maxWidth.wrappedValue = 200
            recomp.commitAll()

            #expect(layout?.maxWidth == 120)
            #expect(scheduler.activeCount == 1)

            scheduler.tick(deltaTime: 0.5)
            #expect(layout?.maxWidth == 160)

            scheduler.tick(deltaTime: 0.5)
            #expect(layout?.maxWidth == 200)
            #expect(scheduler.activeCount == 0)
        }
    }
}
