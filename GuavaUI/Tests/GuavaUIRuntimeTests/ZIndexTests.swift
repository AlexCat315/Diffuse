import CoreGraphics
import Testing
import GuavaUIRuntime

@Suite("zIndex")
struct ZIndexTests {
    @Test("Hit testing prefers the highest sibling zIndex")
    func hitTestingPrefersHighestZIndex() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let back = Node()
        back.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        back.isHitTestable = true

        let front = Node()
        front.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        front.isHitTestable = true
        front.zIndex = 10

        root.addChild(front)
        root.addChild(back)

        let hit = HitTester.hitTest(rootNode: root, point: CGPoint(x: 50, y: 50))
        #expect(hit?.node === front)
    }
}
