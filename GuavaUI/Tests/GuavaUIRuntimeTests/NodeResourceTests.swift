import Testing
@testable import GuavaUIRuntime

/// Phase 2 acceptance: external registrations are released by the node
/// lifecycle (坏味 #4). A resource attached to a node must `unmount` whenever
/// the node leaves the tree — including a node deep inside a removed subtree —
/// with no help from any modifier or teardown bookkeeping.
@Suite("NodeResource lifecycle (Phase 2)")
struct NodeResourceTests {

    private final class ProbeResource: NodeResource {
        var mounts = 0
        var unmounts = 0
        func mount(node: Node) { mounts += 1 }
        func unmount(node: Node) { unmounts += 1 }
    }

    @Test("addResource mounts immediately")
    func addResourceMounts() {
        let node = Node()
        let r = ProbeResource()
        node.addResource(r)
        #expect(r.mounts == 1)
        #expect(r.unmounts == 0)
    }

    @Test("removeChild unmounts the removed node's resource")
    func removeChildUnmounts() {
        let parent = Node()
        let child = Node()
        let r = ProbeResource()
        child.addResource(r)
        parent.addChild(child)

        parent.removeChild(child)
        #expect(r.unmounts == 1)
    }

    @Test("removeChild unmounts resources deep in the removed subtree")
    func removeChildUnmountsSubtree() {
        let root = Node()
        let mid = Node()
        let leaf = Node()
        let midResource = ProbeResource()
        let leafResource = ProbeResource()
        mid.addResource(midResource)
        leaf.addResource(leafResource)
        root.addChild(mid)
        mid.addChild(leaf)

        // Remove the mid subtree; both mid's and leaf's resources release.
        root.removeChild(mid)
        #expect(midResource.unmounts == 1)
        #expect(leafResource.unmounts == 1)
    }

    @Test("removeFromParent releases resources")
    func removeFromParentUnmounts() {
        let parent = Node()
        let child = Node()
        let r = ProbeResource()
        child.addResource(r)
        parent.addChild(child)

        child.removeFromParent()
        #expect(r.unmounts == 1)
    }

    @Test("removing a non-child does not unmount")
    func removingNonChildIsNoOp() {
        let parent = Node()
        let stranger = Node()
        let r = ProbeResource()
        stranger.addResource(r)

        parent.removeChild(stranger) // not a child
        #expect(r.unmounts == 0)
    }

    @Test("firstResource finds the attached resource by type")
    func firstResourceLookup() {
        let node = Node()
        let r = ProbeResource()
        node.addResource(r)
        #expect(node.firstResource(ProbeResource.self) === r)
    }
}
