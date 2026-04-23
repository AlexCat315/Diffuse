import Testing
import CoreGraphics
@testable import GuavaUIRuntime

/// Phase 5c: hit-test cache on `InputScene`. Repeated lookups at the same
/// point and version reuse the previous walk's result.
@Suite("Phase 5c InputScene hit cache", .serialized)
struct InputSceneHitCacheTests {

    private final class Tree {
        let scene = InputScene()
        let root = Node()
        let a = Node()
        let b = Node()

        init() {
            root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            a.frame = CGRect(x: 10, y: 10, width: 80, height: 80)
            b.frame = CGRect(x: 5, y: 5, width: 30, height: 30)
            root.addChild(a)
            a.addChild(b)
            scene.install(rootNode: root)
        }
    }

    @Test("Repeat hit at same point + version is served from cache")
    func cachedRepeat() {
        let t = Tree()
        let p = CGPoint(x: 20, y: 20) // hits b
        let h0 = HitTester.hitTest(scene: t.scene, point: p)
        #expect(h0?.node === t.b)
        #expect(t.scene.hitCacheMisses == 1)
        #expect(t.scene.hitCacheHits == 0)

        let h1 = HitTester.hitTest(scene: t.scene, point: p)
        #expect(h1?.node === t.b)
        #expect(t.scene.hitCacheHits == 1)
        #expect(t.scene.hitCacheMisses == 1)

        let h2 = HitTester.hitTest(scene: t.scene, point: p)
        #expect(h2?.node === t.b)
        #expect(t.scene.hitCacheHits == 2)
    }

    @Test("Different point bypasses the cache")
    func differentPoint() {
        let t = Tree()
        _ = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 20, y: 20))
        let other = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 80, y: 80))
        #expect(other?.node === t.a)
        #expect(t.scene.hitCacheMisses == 2)
        #expect(t.scene.hitCacheHits == 0)
    }

    @Test("Cached miss is served without re-walking")
    func cachedMiss() {
        let t = Tree()
        let off = CGPoint(x: 1000, y: 1000)
        let m0 = HitTester.hitTest(scene: t.scene, point: off)
        #expect(m0 == nil)
        let m1 = HitTester.hitTest(scene: t.scene, point: off)
        #expect(m1 == nil)
        #expect(t.scene.hitCacheHits == 1)
    }

    @Test("Structural reconcile invalidates the cache")
    func reconcileInvalidates() {
        let t = Tree()
        _ = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 20, y: 20))
        #expect(t.scene.hitCacheMisses == 1)

        // Add a new child; reconcile bumps version, cache lookup misses.
        let c = Node()
        c.frame = CGRect(x: 0, y: 0, width: 5, height: 5)
        t.root.addChild(c)
        t.scene.reconcileChildren(of: t.root)

        _ = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 20, y: 20))
        #expect(t.scene.hitCacheMisses == 2)
        #expect(t.scene.hitCacheHits == 0)
    }

    @Test("refresh(node:) invalidates the cache (classification may flip)")
    func refreshInvalidates() {
        let t = Tree()
        _ = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 20, y: 20))
        #expect(t.scene.hitCacheMisses == 1)

        t.b.isHitTestable = false
        t.scene.refresh(node: t.b)

        let h = HitTester.hitTest(scene: t.scene, point: CGPoint(x: 20, y: 20))
        // b is now non-hit-testable; a should claim the point.
        #expect(h?.node === t.a)
        #expect(t.scene.hitCacheMisses == 2)
        #expect(t.scene.hitCacheHits == 0)
    }

    @Test("Manual invalidate clears the cache")
    func manualInvalidate() {
        let t = Tree()
        let p = CGPoint(x: 20, y: 20)
        _ = HitTester.hitTest(scene: t.scene, point: p)
        t.scene.invalidateHitCache()
        _ = HitTester.hitTest(scene: t.scene, point: p)
        #expect(t.scene.hitCacheMisses == 2)
        #expect(t.scene.hitCacheHits == 0)
    }
}
