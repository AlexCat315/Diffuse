import Foundation
import Testing
import GuavaUIRuntime

@Suite("Accessibility placement")
struct AccessibilityGeometryTests {
    @Test("Traversal matches window geometry through nested scales and scrolling")
    func nestedPlacement() {
        let root = Node()
        root.frame = CGRect(x: 15, y: 20, width: 800, height: 600)
        root.transform.scale = 0.9
        root.contentOffset = CGPoint(x: 3, y: 5)
        let scroll = Node()
        scroll.frame = CGRect(x: 30, y: 40, width: 400, height: 300)
        scroll.transform.scale = 0.8
        scroll.contentOffset = CGPoint(x: 7.5, y: 12.5)
        root.addChild(scroll)
        let label = Node()
        label.frame = CGRect(x: 25, y: 35, width: 100, height: 30)
        label.accessibility = AccessibilitySemantics(.staticText) { $0.label = "Nested" }
        scroll.addChild(label)
        for subtree in [root, scroll] {
            let snapshot = AccessibilityTree.snapshot(root: subtree, viewport: root.absoluteFrame)
            #expect(snapshot.count == 1)
            guard let actual = snapshot.first?.frame else { continue }
            let expected = label.absoluteFrame
            #expect(abs(actual.minX - expected.minX) < 0.001)
            #expect(abs(actual.minY - expected.minY) < 0.001)
            #expect(abs(actual.width - expected.width) < 0.001)
            #expect(abs(actual.height - expected.height) < 0.001)
        }
    }
}
