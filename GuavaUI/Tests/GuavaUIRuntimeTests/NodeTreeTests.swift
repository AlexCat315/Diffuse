import Testing
@testable import GuavaUIRuntime

@Suite("NodeTree")
struct NodeTreeTests {

    @Test("addChild links parent ↔ child")
    func addChild() {
        let parent = Node()
        let child = Node()
        parent.addChild(child)
        #expect(parent.children.count == 1)
        #expect(child.parent === parent)
    }

    @Test("removeChild unlinks both directions")
    func removeChild() {
        let parent = Node()
        let child = Node()
        parent.addChild(child)
        parent.removeChild(child)
        #expect(parent.children.isEmpty)
        #expect(child.parent == nil)
    }

    @Test("removeFromParent uses parent reference")
    func removeFromParent() {
        let parent = Node()
        let child = Node()
        parent.addChild(child)
        child.removeFromParent()
        #expect(parent.children.isEmpty)
        #expect(child.parent == nil)
    }

    @Test("markDirty propagates to every ancestor")
    func markDirtyPropagates() {
        let root = Node()
        let mid = Node()
        let leaf = Node()
        root.addChild(mid)
        mid.addChild(leaf)

        leaf.markDirty()

        #expect(leaf.isDirty)
        #expect(mid.isDirty)
        #expect(root.isDirty)
        #expect(leaf.renderDirty)
        #expect(mid.renderDirty)
        #expect(root.renderDirty)
    }

    @Test("markRenderDirty propagates without setting layout dirty")
    func markRenderDirtyPropagates() {
        let root = Node()
        let mid = Node()
        let leaf = Node()
        root.addChild(mid)
        mid.addChild(leaf)
        root.renderDirty = false
        mid.renderDirty = false
        leaf.renderDirty = false

        leaf.markRenderDirty()

        #expect(!leaf.isDirty)
        #expect(!mid.isDirty)
        #expect(!root.isDirty)
        #expect(leaf.renderDirty)
        #expect(mid.renderDirty)
        #expect(root.renderDirty)
    }

    @Test("NodeTree.markDirty is equivalent to Node.markDirty")
    func treeMark() {
        let tree = NodeTree()
        let root = Node()
        let child = Node()
        root.addChild(child)
        tree.root = root

        tree.markDirty(child)

        #expect(child.isDirty)
        #expect(root.isDirty)
    }

    @Test("flush resets all dirty flags depth-first")
    func flush() {
        let tree = NodeTree()
        let root = Node()
        let child = Node()
        let grandchild = Node()
        root.addChild(child)
        child.addChild(grandchild)
        tree.root = root

        grandchild.markDirty()
        tree.flush()

        #expect(!root.isDirty)
        #expect(!child.isDirty)
        #expect(!grandchild.isDirty)
        #expect(!root.renderDirty)
        #expect(!child.renderDirty)
        #expect(!grandchild.renderDirty)
    }

    @Test("flush on empty tree does not crash")
    func flushEmptyTree() {
        let tree = NodeTree()
        tree.flush()
    }

    @Test("flush preserves tree structure")
    func flushPreservesStructure() {
        let tree = NodeTree()
        let root = Node()
        let a = Node()
        let b = Node()
        root.addChild(a)
        root.addChild(b)
        tree.root = root

        tree.flush()

        #expect(root.children.count == 2)
    }
}
