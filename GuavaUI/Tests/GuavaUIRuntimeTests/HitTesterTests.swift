import Testing
import CoreGraphics
@testable import GuavaUIRuntime

@Suite("HitTester")
struct HitTesterTests {

    private func makeNode(frame: CGRect,
                         hitTestable: Bool = true,
                         clips: Bool = false) -> Node {
        let n = Node()
        n.frame = frame
        n.isHitTestable = hitTestable
        n.clipsToBounds = clips
        return n
    }

    @Test("Point inside a leaf node returns that node")
    func leafHit() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let leaf = makeNode(frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        root.addChild(leaf)

        let result = HitTester.hitTest(rootNode: root, point: CGPoint(x: 15, y: 15))
        #expect(result?.node === leaf)
        #expect(result?.path.count == 2)
        #expect(result?.path.first === root)
        #expect(result?.path.last === leaf)
    }

    @Test("Point outside everything returns nil")
    func miss() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let result = HitTester.hitTest(rootNode: root, point: CGPoint(x: 200, y: 200))
        #expect(result == nil)
    }

    @Test("Last child wins (z-order)")
    func zOrder() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bottom = makeNode(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        let top    = makeNode(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        root.addChild(bottom)
        root.addChild(top)

        let result = HitTester.hitTest(rootNode: root, point: CGPoint(x: 20, y: 20))
        #expect(result?.node === top)
    }

    @Test("Non-hit-testable node is skipped but children still tested")
    func passThroughParent() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                            hitTestable: false)
        let leaf = makeNode(frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        root.addChild(leaf)

        let hitOnLeaf = HitTester.hitTest(rootNode: root, point: CGPoint(x: 15, y: 15))
        #expect(hitOnLeaf?.node === leaf)

        // Point in root but not in leaf → no hit because root is not hit-testable.
        let missOnRoot = HitTester.hitTest(rootNode: root, point: CGPoint(x: 80, y: 80))
        #expect(missOnRoot == nil)
    }

    @Test("clipsToBounds rejects child hits outside frame")
    func clipping() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                            clips: true)
        // Child extends past parent's right edge.
        let leaf = makeNode(frame: CGRect(x: 80, y: 10, width: 80, height: 20))
        root.addChild(leaf)

        // Point at (150, 15) — would be inside leaf in local coords (70, 5),
        // but parent clips so the entire subtree is rejected.
        let result = HitTester.hitTest(rootNode: root, point: CGPoint(x: 150, y: 15))
        #expect(result == nil)
    }

    @Test("Coordinates are converted to local space for the hit node")
    func localCoordinates() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let leaf = makeNode(frame: CGRect(x: 50, y: 60, width: 100, height: 100))
        root.addChild(leaf)

        let result = HitTester.hitTest(rootNode: root, point: CGPoint(x: 70, y: 90))
        #expect(result?.node === leaf)
        #expect(result?.localPoint == CGPoint(x: 20, y: 30))
    }

    @Test("contentOffset shifts child hit regions")
    func contentOffsetAffectsHitTest() {
        let root = makeNode(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let child = makeNode(frame: CGRect(x: 0, y: 30, width: 120, height: 30))
        root.addChild(child)

        // Before scrolling, y=5 is above the child.
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 10, y: 5))?.node !== child)

        // Scroll content down by 30 logical px: child visually moves to y=0.
        root.contentOffset = CGPoint(x: 0, y: 30)

        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 10, y: 5))?.node === child)
        #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 10, y: 35))?.node !== child)
    }
}
