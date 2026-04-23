import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

// Reuse _DebugNode from ViewBuilderTests.swift via the same test target.

/// A simple modifier that flips `isHitTestable`.
struct DisableHitTestModifier: ViewModifier {
    func apply(node: Node) {
        node.isHitTestable = false
    }
}

/// A modifier that stamps a marker into `frame.origin.y`.
struct MarkerModifier: ViewModifier {
    let value: CGFloat
    func apply(node: Node) {
        node.frame.origin.y = value
    }
}

@Suite("ViewGraph")
struct ViewGraphTests {

    @Test("Install a single primitive view creates one child node")
    func installSingle() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        graph.install(root: _DebugNode(label: "hi"))

        #expect(tree.root != nil)
        // root → DebugNode
        #expect(tree.root?.children.count == 1)
        #expect(tree.root?.children.first?.frame.origin.x == 2)
    }

    @Test("TupleView expands into multiple sibling nodes")
    func installTuple() {
        struct Three: View {
            var body: some View {
                _DebugNode(label: "a")
                _DebugNode(label: "bb")
                _DebugNode(label: "ccc")
            }
        }
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Three())

        // root → anchor (Three) → 3 debug nodes
        let anchor = tree.root?.children.first
        #expect(anchor?.children.count == 3)
        #expect(anchor?.children.map { Int($0.frame.origin.x) } == [1, 2, 3])
    }

    @Test("ModifiedContent.apply mutates the materialised node")
    func modifiedContent() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let view = _DebugNode(label: "x").modifier(MarkerModifier(value: 42))
        graph.install(root: view)

        let n = tree.root?.children.first
        #expect(n?.frame.origin.y == 42)
    }

    @Test("Multiple modifiers stack in declaration order")
    func modifierStack() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let view = _DebugNode(label: "x")
            .modifier(MarkerModifier(value: 10))
            .modifier(DisableHitTestModifier())
        graph.install(root: view)

        let n = tree.root?.children.first
        #expect(n?.frame.origin.y == 10)
        #expect(n?.isHitTestable == false)
    }
}

@Suite("State + Recomposer wiring")
struct StateWiringTests {

    struct LayoutHarness: View {
        @State var width: Float = 40

        var body: some View {
            Box(direction: .column, alignItems: .stretch) {
                EmptyView()
            }
            .frame(width: width, height: 10)
        }
    }

    /// Counter view used to verify state writes trigger recompose.
    struct Counter: View {
        @State var n: Int = 0
        var body: some View {
            _DebugNode(label: String(repeating: "x", count: n))
        }
    }

    @Test("State write through binding triggers recompose on next commitAll")
    func stateTriggersRecompose() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)

        let counter = Counter()
        graph.install(root: counter)

        // Initial: n=0 → label "" → frame.origin.x == 0
        let anchor = tree.root?.children.first
        #expect(anchor?.children.first?.frame.origin.x == 0)

        // Write through the projected binding (same shared storage as the view).
        counter.$n.wrappedValue = 3

        // Pending until commitAll.
        #expect(recomp.hasPending)
        recomp.commitAll()

        // After recompose, the anchor's child has been replaced with a fresh
        // DebugNode whose label is "xxx" (length 3).
        #expect(anchor?.children.count == 1)
        #expect(anchor?.children.first?.frame.origin.x == 3)
    }

    @Test("Multiple state writes within one frame collapse into a single recompose")
    func deduplication() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let counter = Counter()
        graph.install(root: counter)

        counter.$n.wrappedValue = 1
        counter.$n.wrappedValue = 2
        counter.$n.wrappedValue = 5

        recomp.commitAll()

        let anchor = tree.root?.children.first
        #expect(anchor?.children.first?.frame.origin.x == 5)
    }

    @Test("computeLayoutIfNeeded skips stable frames and reruns after layout changes")
    func computeLayoutIfNeededGate() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let harness = LayoutHarness()
        graph.install(root: harness)

        #expect(graph.computeLayoutIfNeeded(width: 200, height: 200))
        #expect(!graph.computeLayoutIfNeeded(width: 200, height: 200))

        harness.$width.wrappedValue = 80
        recomp.commitAll()

        #expect(graph.layoutNeedsUpdate(width: 200, height: 200))
        #expect(graph.computeLayoutIfNeeded(width: 200, height: 200))
        #expect(!graph.computeLayoutIfNeeded(width: 200, height: 200))
    }
}

// MARK: - Phase 6.6 reconcile

/// A primitive that records each Node it materialises into via `attachments`,
/// and exposes a counter so tests can detect Node-reuse vs rebuild.
struct _CountingNode: _PrimitiveView {
    let value: Int
    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) {
        node.frame.origin.x = CGFloat(value)
        let prior = (node.attachments["__count"] as? Int) ?? 0
        node.attachments["__count"] = prior + 1
    }
}

@Suite("Phase 6.6 reconcile")
struct ReconcileTests {

    /// State write should reuse the existing Node — `_updateNode` count
    /// increments rather than a new Node being created.
    struct ReuseHarness: View {
        @State var v: Int = 1
        var body: some View {
            _CountingNode(value: v)
        }
    }

    @Test("Same-shape recompose reuses the existing Node and its attachments")
    func reuseSameShape() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let h = ReuseHarness()
        graph.install(root: h)

        let anchor = tree.root?.children.first
        let firstChild = anchor?.children.first
        #expect(firstChild != nil)
        #expect(firstChild?.attachments["__count"] as? Int == 1)
        let identityBefore = firstChild.map { ObjectIdentifier($0) }

        h.$v.wrappedValue = 7
        recomp.commitAll()

        let afterChild = anchor?.children.first
        #expect(afterChild?.frame.origin.x == 7)
        #expect(afterChild?.attachments["__count"] as? Int == 2)
        #expect(afterChild.map { ObjectIdentifier($0) } == identityBefore)
    }

    /// Tag mismatch at index 0 → child is torn down and a fresh one built.
    struct SwapHarness: View {
        @State var flag: Bool = false
        var body: some View {
            if flag {
                _CountingNode(value: 100)
            } else {
                _DebugNode(label: "abc")
            }
        }
    }

    @Test("Tag mismatch tears down the old Node and rebuilds")
    func teardownOnMismatch() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let h = SwapHarness()
        graph.install(root: h)

        let anchor = tree.root?.children.first
        // Initial branch is _DebugNode("abc") — frame.origin.x = 3.
        #expect(anchor?.children.first?.frame.origin.x == 3)
        let firstIdentity = anchor?.children.first.map { ObjectIdentifier($0) }

        h.$flag.wrappedValue = true
        recomp.commitAll()

        // Now branch is _CountingNode(100); identity must differ; counter == 1.
        let after = anchor?.children.first
        #expect(after?.frame.origin.x == 100)
        #expect(after?.attachments["__count"] as? Int == 1)
        #expect(after.map { ObjectIdentifier($0) } != firstIdentity)
    }

    /// Primitive Node `attachments` survive across recompose — proves the
    /// design used for TextField's FieldState.
    @Test("Node.attachments survive a same-shape recompose")
    func attachmentsPersist() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let h = ReuseHarness()
        graph.install(root: h)

        let anchor = tree.root?.children.first
        anchor?.children.first?.attachments["__user"] = "preserved"

        h.$v.wrappedValue = 9
        recomp.commitAll()

        #expect(anchor?.children.first?.attachments["__user"] as? String == "preserved")
    }

    /// Modifier values change across recomposes — modifier is re-applied to
    /// the same Node.
    struct ModifierHarness: View {
        @State var y: CGFloat = 5
        var body: some View {
            _DebugNode(label: "z").modifier(MarkerModifier(value: y))
        }
    }

    @Test("Modifier re-applies to the reused Node when its value changes")
    func modifierReapply() {
        let tree = NodeTree()
        let recomp = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomp)
        let h = ModifierHarness()
        graph.install(root: h)

        let anchor = tree.root?.children.first
        #expect(anchor?.children.first?.frame.origin.y == 5)
        let identity = anchor?.children.first.map { ObjectIdentifier($0) }

        h.$y.wrappedValue = 99
        recomp.commitAll()

        #expect(anchor?.children.first?.frame.origin.y == 99)
        #expect(anchor?.children.first.map { ObjectIdentifier($0) } == identity)
    }
}
