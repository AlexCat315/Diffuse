import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

// MARK: - Test primitives

/// A minimal `_PrimitiveView` used by tests — materialises into a tagged Node.
struct _DebugNode: _PrimitiveView {
    let label: String

    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) {
        // Stash the label as the frame's origin.x so tests can inspect it
        // without us inventing a new property on Node.
        node.frame.origin.x = CGFloat(label.count)
    }
}

@Suite("ViewBuilder")
struct ViewBuilderTests {

    @Test("Empty block produces EmptyView")
    func emptyBlock() {
        @ViewBuilder var v: some View { }
        #expect(v is EmptyView)
    }

    @Test("Single-element block returns the element")
    func singleBlock() {
        @ViewBuilder var v: some View { _DebugNode(label: "x") }
        #expect(v is _DebugNode)
    }

    @Test("Variadic block produces TupleView")
    func tupleBlock() {
        @ViewBuilder var v: some View {
            _DebugNode(label: "a")
            _DebugNode(label: "b")
            _DebugNode(label: "c")
        }
        #expect(v is any _StructuralView)
        let s = v as! any _StructuralView
        #expect(s._expanded.count == 3)
    }

    @Test("Conditional buildIf wraps in Optional")
    func optionalIf() {
        let flag = false
        @ViewBuilder var v: some View {
            if flag { _DebugNode(label: "shown") }
        }
        let s = v as! any _StructuralView
        #expect(s._expanded.isEmpty)
    }

    @Test("if/else produces _ConditionalContent that picks one branch")
    func conditional() {
        @ViewBuilder func make(_ flag: Bool) -> some View {
            if flag { _DebugNode(label: "T") } else { _DebugNode(label: "F") }
        }
        let t = make(true) as! any _StructuralView
        #expect(t._expanded.count == 1)
        let arr = t._expanded
        #expect((arr.first as? _DebugNode)?.label == "T")
    }
}
