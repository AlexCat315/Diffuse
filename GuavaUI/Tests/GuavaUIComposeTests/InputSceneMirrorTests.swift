import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 5a InputScene mirror", .serialized)
struct InputSceneMirrorTests {

    /// Configurable leaf primitive that lets each test toggle the input
    /// classification it produces on its Node.
    struct _InputLeaf: _PrimitiveView {
        let isFocusable: Bool
        let isHitTestable: Bool
        func _makeNode() -> Node {
            let n = Node()
            n.isFocusable = isFocusable
            n.isHitTestable = isHitTestable
            return n
        }
        func _updateNode(_ node: Node) {
            node.isFocusable = isFocusable
            node.isHitTestable = isHitTestable
        }
    }

    @Test("install mirrors every Node into an InputNode")
    func installMirrorsAllNodes() {
        struct Wrapper: View {
            var body: some View {
                _InputLeaf(isFocusable: true, isHitTestable: true)
            }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Wrapper())

        var nodeCount = 0
        func walk(_ n: Node) { nodeCount += 1; for c in n.children { walk(c) } }
        walk(graph.tree.root!)
        #expect(graph.inputScene.nodeCount == nodeCount)

        // Every Node has a matching InputNode back-pointer.
        func checkBackPointer(_ n: Node) {
            #expect(n.inputNode != nil)
            #expect(n.inputNode?.elementID == n.id)
            for c in n.children { checkBackPointer(c) }
        }
        checkBackPointer(graph.tree.root!)
    }

    @Test("focusables() reflects Node.isFocusable")
    func focusablesEnumeration() {
        struct Wrapper: View {
            var body: some View {
                _InputLeaf(isFocusable: true, isHitTestable: true)
            }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Wrapper())

        let focusables = graph.inputScene.focusables()
        #expect(focusables.count == 1)
        #expect(focusables.first?.node?.isFocusable == true)
    }

    @Test("hitTestables() includes only nodes with isHitTestable == true")
    func hitTestablesEnumeration() {
        struct Wrapper: View {
            var body: some View {
                _InputLeaf(isFocusable: false, isHitTestable: false)
            }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Wrapper())

        let hits = graph.inputScene.hitTestables()
        #expect(hits.allSatisfy { $0.isHitTestable })
        #expect(!hits.contains { $0.node?.isHitTestable == false })
    }

    @Test("InputNode.refreshFromNode picks up post-install property changes")
    func refreshPicksUpChanges() {
        struct Wrapper: View {
            var body: some View {
                _InputLeaf(isFocusable: false, isHitTestable: true)
            }
        }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Wrapper())

        let leafNode = graph.tree.root!.children.first!.children.first!
        let inputObj = graph.inputScene.inputNode(for: leafNode)!
        #expect(inputObj.isFocusable == false)

        leafNode.isFocusable = true
        inputObj.refreshFromNode()
        #expect(inputObj.isFocusable == true)
    }
}
