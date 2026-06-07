import Testing
@testable import GuavaKit

@Suite("GuavaKit core")
struct CoreTests {

    // Builds: root(100x100) > a(0,0,100x100) > b(10,10,30x30, hittable)
    private func makeTree() -> (ctx: UIContext, root: UINode, a: UINode, b: UINode) {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        root.debugName = "root"
        let a = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        a.debugName = "a"
        let b = UINode(geometry: Geometry(frame: Rect(x: 10, y: 10, width: 30, height: 30)))
        b.debugName = "b"
        root.append(a)
        a.append(b)
        let ctx = UIContext()
        ctx.install(root: root)
        return (ctx, root, a, b)
    }

    // MARK: - Bug class 1: geometry move must never leave a stale hit

    @Test("A geometry move always invalidates the hit cache (the dropdown bug class)")
    func geometryMoveInvalidatesHitCache() {
        let t = makeTree()
        let p = Point(x: 20, y: 20) // inside b

        #expect(t.ctx.hitTest(p)?.node === t.b)
        // Prime the cache for this exact point.
        #expect(t.ctx.hitTest(p)?.node === t.b)
        #expect(t.ctx.hitIndex.hits == 1)

        // Move b out from under p — a pure geometry change, no structural edit.
        // In the legacy stack this did NOT bump the hit-cache version → stale.
        t.b.setFrame(Rect(x: 200, y: 200, width: 30, height: 30))

        // Cache must have been invalidated through the single funnel; the walk
        // now correctly returns `a`, never the stale `b`.
        let after = t.ctx.hitTest(p)
        #expect(after?.node === t.a)
        #expect(t.ctx.hitIndex.misses == 2) // re-walked, not served stale
    }

    @Test("Every geometry setter routes through the same invalidation")
    func allSettersInvalidate() {
        for mutate in [
            { (n: UINode) in n.setFrame(Rect(x: 5, y: 5, width: 30, height: 30)) },
            { (n: UINode) in n.setContentOffset(Point(x: 1, y: 1)) },
            { (n: UINode) in n.setZIndex(3) },
            { (n: UINode) in n.setClipsToBounds(true) },
            { (n: UINode) in n.setHitTestable(false) },
        ] {
            let t = makeTree()
            _ = t.ctx.hitTest(Point(x: 20, y: 20))
            _ = t.ctx.hitTest(Point(x: 20, y: 20))
            let hitsBefore = t.ctx.hitIndex.hits
            mutate(t.b)
            // After any geometry mutation, the next identical lookup must miss
            // (cache was dropped), proving no setter can bypass invalidation.
            _ = t.ctx.hitTest(Point(x: 20, y: 20))
            #expect(t.ctx.hitIndex.hits == hitsBefore) // no new cache hit
        }
    }

    // MARK: - Bug class 2: resources released on detach (the portal leak)

    private final class TrackingResource: NodeResource {
        var mounted = 0
        var unmounted = 0
        func mount(node: UINode, context: UIContext) { mounted += 1 }
        func unmount(node: UINode, context: UIContext) { unmounted += 1 }
    }

    @Test("Removing a node releases its resources — no matter how it leaves the tree")
    func detachReleasesResources() {
        let t = makeTree()
        let res = TrackingResource()
        t.b.addResource(res)
        #expect(res.mounted == 1 && res.unmounted == 0)

        // Remove b directly.
        t.b.removeFromParent()
        #expect(res.unmounted == 1) // released on detach, not via any side-effect
    }

    @Test("Detaching an ancestor releases nested resources too")
    func detachReleasesNestedResources() {
        let t = makeTree()
        let res = TrackingResource()
        t.b.addResource(res)

        // Remove the *parent* `a` while `b` (open/registered) is still under it —
        // exactly the panel-relayout case that leaked in the legacy Popover.
        t.a.removeFromParent()
        #expect(res.unmounted == 1)
    }

    @Test("A resource added before attach mounts when the node is installed")
    func resourceMountsOnAttach() {
        let res = TrackingResource()
        let root = UINode()
        let child = UINode()
        child.addResource(res)   // not attached yet
        #expect(res.mounted == 0)
        root.append(child)
        let ctx = UIContext()
        ctx.install(root: root)
        #expect(res.mounted == 1)
    }

    // MARK: - No global state

    @Test("Two contexts are fully independent (no process globals)")
    func contextsAreIndependent() {
        let t1 = makeTree()
        let t2 = makeTree()
        _ = t1.ctx.hitTest(Point(x: 20, y: 20))
        _ = t1.ctx.hitTest(Point(x: 20, y: 20))
        #expect(t1.ctx.hitIndex.hits == 1)
        // t2 was never queried; its cache is untouched by t1.
        #expect(t2.ctx.hitIndex.hits == 0)
        #expect(t2.ctx.hitIndex.misses == 0)
    }

    // MARK: - Hit-test correctness

    @Test("Hit-test honours z-order: higher z wins")
    func hitTestZOrder() {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        let low = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 50, height: 50), zIndex: 0))
        low.debugName = "low"
        let high = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 50, height: 50), zIndex: 10))
        high.debugName = "high"
        root.append(low)
        root.append(high)
        let ctx = UIContext()
        ctx.install(root: root)
        #expect(ctx.hitTest(Point(x: 25, y: 25))?.node === high)
    }

    @Test("clipsToBounds rejects hits on the clipped subtree outside its frame")
    func clipRejectsOutside() {
        let root = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 100, height: 100)))
        root.debugName = "root"
        let clip = UINode(geometry: Geometry(frame: Rect(x: 0, y: 0, width: 20, height: 20),
                                             clipsToBounds: true))
        clip.debugName = "clip"
        let child = UINode(geometry: Geometry(frame: Rect(x: 10, y: 10, width: 80, height: 80)))
        child.debugName = "child"
        clip.append(child)
        root.append(clip)
        let ctx = UIContext()
        ctx.install(root: root)

        // Inside the clip: the child is reachable.
        #expect(ctx.hitTest(Point(x: 15, y: 15))?.node === child)
        // Outside the clip: the child is clipped away, so the hit falls through
        // to the root — crucially it is NOT the (visually clipped) child.
        let outside = ctx.hitTest(Point(x: 50, y: 50))
        #expect(outside?.node === root)
        #expect(outside?.node !== child)
    }
}
