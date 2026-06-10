import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// Phase 0 acceptance baseline for the in-place architecture refactor
/// (docs/guavaui-inplace-architecture-refactor.md, 坏味 #1), kept current
/// through Phase 7. Hit-testing walks the live `Node` tree every time — there is
/// no cached classification to go stale — so a geometry / hit-classification
/// change made the way the layout pass and runtime make it (a plain property
/// write) is reflected on the very next hit-test, with nothing to invalidate.
/// The "click once then dead" bug class is structurally impossible.
@Suite("Geometry funnel repro (Phase 0/1/7)")
struct GeometryFunnelReproTests {

    /// Toggling `clipsToBounds` on a parent at runtime immediately gates
    /// hit-testing of children that overflow its frame.
    @Test("clipsToBounds toggle updates hit-testing immediately")
    func clipsToBoundsTogglesHitTesting() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let p = Node();    p.frame    = CGRect(x: 50, y: 50, width: 40, height: 40)
        // `c` overflows `p`: in p-local it spans 20..60 but p is only 40 wide.
        let c = Node();    c.frame    = CGRect(x: 20, y: 20, width: 40, height: 40)
        root.addChild(p)
        p.addChild(c)

        // Point over the overflowing part of `c` (window 100,100): inside `c`
        // (window 70..110) but outside `p` (window 50..90).
        let pt = CGPoint(x: 100, y: 100)
        #expect(HitTester.hitTest(rootNode: root, point: pt)?.node === c)

        p.clipsToBounds = true

        let after = HitTester.hitTest(rootNode: root, point: pt)
        #expect(after?.node !== c)
        #expect(after?.node === root)
    }

    /// Flipping `isHitTestable` to false at runtime lets the point fall through
    /// to the ancestor.
    @Test("isHitTestable flip updates hit-testing immediately")
    func isHitTestableFlipUpdatesHitTesting() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let a = Node();    a.frame    = CGRect(x: 10, y: 10, width: 80, height: 80)
        let b = Node();    b.frame    = CGRect(x: 5, y: 5, width: 30, height: 30)
        root.addChild(a)
        a.addChild(b)

        let pt = CGPoint(x: 20, y: 20) // hits b
        #expect(HitTester.hitTest(rootNode: root, point: pt)?.node === b)

        b.isHitTestable = false

        #expect(HitTester.hitTest(rootNode: root, point: pt)?.node === a)
    }

    /// A pure layout move (frame change, no structural reconcile) is reflected
    /// immediately — the headline reflow-staleness case.
    @Test("frame move updates hit-testing immediately")
    func frameMoveUpdatesHitTesting() {
        let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let a = Node();    a.frame    = CGRect(x: 10, y: 10, width: 80, height: 80)
        let b = Node();    b.frame    = CGRect(x: 5, y: 5, width: 30, height: 30)
        root.addChild(a)
        a.addChild(b)
        let pt = CGPoint(x: 20, y: 20) // hits b
        #expect(HitTester.hitTest(rootNode: root, point: pt)?.node === b)

        b.frame = CGRect(x: 100, y: 100, width: 30, height: 30) // moved out

        #expect(HitTester.hitTest(rootNode: root, point: pt)?.node === a)
    }
}
