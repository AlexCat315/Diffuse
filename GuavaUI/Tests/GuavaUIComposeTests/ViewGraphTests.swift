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
}
