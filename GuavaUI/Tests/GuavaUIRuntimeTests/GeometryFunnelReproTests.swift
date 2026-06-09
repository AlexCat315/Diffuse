import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// Phase 0 acceptance baseline for the in-place architecture refactor
/// (docs/guavaui-inplace-architecture-refactor.md, 坏味 #1).
///
/// These pin the "click once then dead" bug class: a geometry / hit-test
/// classification change made the way the layout pass and runtime make it —
/// a plain property write, with no follow-up `scene.refresh(node:)` or
/// `invalidateHitCache()` — must keep hit-testing correct.
///
/// `frame` and `contentOffset` already invalidate (see InputSceneHitCacheTests).
/// `clipsToBounds` and `isHitTestable` did NOT until the geometry single funnel
/// (Phase 1) routed every geometry mutation through one invalidation path that
/// also refreshes the InputScene mirror. RED before Phase 1, GREEN after.
@Suite("Geometry funnel repro (Phase 0/1)", .serialized)
struct GeometryFunnelReproTests {

    /// Toggling `clipsToBounds` on a parent at runtime must immediately gate
    /// hit-testing of children that overflow its frame — no manual refresh.
    @Test("clipsToBounds toggle updates hit-testing with no manual refresh")
    func clipsToBoundsTogglesHitTesting() {
        let scene = InputScene()
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let p = Node();    p.frame    = CGRect(x: 50, y: 50, width: 40, height: 40)
        // `c` overflows `p`: in p-local it spans 20..60 but p is only 40 wide.
        let c = Node();    c.frame    = CGRect(x: 20, y: 20, width: 40, height: 40)
        root.addChild(p)
        p.addChild(c)
        scene.install(rootNode: root)

        // Point over the overflowing part of `c` (window 100,100): inside `c`
        // (window 70..110) but outside `p` (window 50..90).
        let pt = CGPoint(x: 100, y: 100)

        // Prime: with no clipping the overflow is hittable → `c`.
        #expect(HitTester.hitTest(scene: scene, point: pt)?.node === c)
        #expect(HitTester.hitTest(scene: scene, point: pt)?.node === c) // warm cache

        // Runtime mutation: clip the parent. No manual scene.refresh / invalidate.
        p.clipsToBounds = true

        // The overflow is now clipped away; `c` must no longer claim the point.
        let after = HitTester.hitTest(scene: scene, point: pt)
        #expect(after?.node !== c)
        #expect(after?.node === root)
    }

    /// Flipping `isHitTestable` to false at runtime must let the point fall
    /// through to the ancestor — no manual refresh.
    @Test("isHitTestable flip updates hit-testing with no manual refresh")
    func isHitTestableFlipUpdatesHitTesting() {
        let scene = InputScene()
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let a = Node();    a.frame    = CGRect(x: 10, y: 10, width: 80, height: 80)
        let b = Node();    b.frame    = CGRect(x: 5, y: 5, width: 30, height: 30)
        root.addChild(a)
        a.addChild(b)
        scene.install(rootNode: root)

        let pt = CGPoint(x: 20, y: 20) // hits b

        #expect(HitTester.hitTest(scene: scene, point: pt)?.node === b)
        #expect(HitTester.hitTest(scene: scene, point: pt)?.node === b) // warm cache

        // Runtime mutation: take `b` out of hit-testing. No manual refresh.
        b.isHitTestable = false

        // `b` no longer claims the point; `a` (its parent) does.
        #expect(HitTester.hitTest(scene: scene, point: pt)?.node === a)
    }
}
