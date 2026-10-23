import Foundation
import Testing
@_spi(CustomLayout) import GuavaUIScene

@Suite("Layout measurement lifecycle")
@MainActor
struct MeasurementLifecycleTests {
    @Test("A reused container restores pending measurement after its last child is removed")
    func leafContainerRoundTrip() {
        let node = LayoutNode()
        node.alignItems = .flexStart
        node.setMeasureFunc { _, _, _, _ in CGSize(width: 40, height: 20) }
        let first = LayoutNode(), second = LayoutNode()
        first.width = 60; first.height = 30
        second.width = 10; second.height = 10
        node.addChild(first)
        node.addChild(second)
        #expect(!node.hasMeasureFunc)
        node.markDirty()
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 60, height: 40))

        node.setMeasureFunc { _, _, _, _ in CGSize(width: 70, height: 25) }
        #expect(!node.hasMeasureFunc)
        node.removeChild(first)
        #expect(!node.hasMeasureFunc)
        node.removeChild(second)
        #expect(node.hasMeasureFunc)
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 70, height: 25))
    }

    @Test("Removing container children does not restore a stale leaf measurement")
    func staleMeasurementIsDiscarded() {
        let node = LayoutNode(), child = LayoutNode()
        node.setMeasureFunc { _, _, _, _ in CGSize(width: 40, height: 20) }
        node.addChild(child)
        node.removeChild(child)
        #expect(!node.hasMeasureFunc)
        node.calculateLayout()
        #expect(node.frame.size == .zero)
    }

    @Test("Custom layouts keep measurement when authored children change")
    func customLayoutKeepsMeasurement() {
        let node = LayoutNode(), child = LayoutNode()
        child.width = 60; child.height = 30
        node.addChild(child)
        node.setCustomLayout(measure: { _, _, children in
            CGSize(width: children.count * 40, height: 20)
        }, place: { _, _ in })
        #expect(node.hasMeasureFunc)
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 40, height: 20))

        let second = LayoutNode()
        node.addChild(second)
        #expect(node.hasMeasureFunc)
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 80, height: 20))
        node.removeChild(child)
        #expect(node.hasMeasureFunc)
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 40, height: 20))

        node.setCustomLayout(measure: { _, _, _ in CGSize(width: 90, height: 35) }, place: { _, _ in })
        node.calculateLayout()
        #expect(node.frame.size == CGSize(width: 90, height: 35))
    }
}
