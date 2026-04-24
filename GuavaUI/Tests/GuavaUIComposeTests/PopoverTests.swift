import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct _PopoverProbe: _PrimitiveView {
    let id: String
    let width: Float
    let height: Float

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["probeID"] = id
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = width
        layout.height = height
    }
}

@Suite("Popover")
struct PopoverTests {

    struct Harness: View {
        @State var isPresented: Bool = false

        var body: some View {
            Column(alignment: .leading, spacing: 8) {
                Popover(isPresented: $isPresented,
                        width: 120) {
                    _PopoverProbe(id: "trigger", width: 80, height: 20)
                } content: {
                    _PopoverProbe(id: "menu", width: 120, height: 60)
                }

                _PopoverProbe(id: "sibling", width: 80, height: 20)
            }
        }
    }

    @Test("Opening Popover does not move following siblings")
    func openingPopoverDoesNotAffectSiblingLayout() {
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        let harness = Harness()

        graph.install(root: harness)
        graph.computeLayout(width: 240, height: 200)

        let initialSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(initialSiblingY != nil)

        harness.$isPresented.wrappedValue = true
        recomposer.commitAll()
        graph.computeLayout(width: 240, height: 200)

        let expandedSiblingY = findProbe(id: "sibling", in: tree.root)?.frame.origin.y
        #expect(expandedSiblingY == initialSiblingY)
    }

    private func findProbe(id: String, in node: Node?) -> Node? {
        guard let node else { return nil }
        if node.attachments["probeID"] as? String == id {
            return node
        }
        for child in node.children {
            if let match = findProbe(id: id, in: child) {
                return match
            }
        }
        return nil
    }
}