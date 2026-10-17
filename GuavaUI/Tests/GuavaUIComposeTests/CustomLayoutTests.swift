import Foundation
import Testing
import GuavaUIRuntime
@_spi(CustomLayout) import GuavaUIScene
@testable import GuavaUICompose

@Suite("Public measurement and placement", .serialized)
struct CustomLayoutTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }
    private func find(_ name: String, in graph: ViewGraph) -> Node {
        nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name }!
    }

    @Test("Custom placement participates in flex, padding, nested layouts and real hit testing")
    func nesting() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Row {
            TestColumnLayout(spacing: 7) {
                Box {}.frame(width: 80, height: 20).debugName("first")
                TestColumnLayout(spacing: 3) {
                    Box {}.frame(width: 60, height: 15).debugName("nested-first")
                    LayoutHitBox().debugName("nested-second")
                }.debugName("nested")
            }.padding(10).debugName("custom")
            Box {}.frame(width: 30, height: 10).debugName("sibling")
        })
        graph.computeLayout(width: 300, height: 200)
        let custom = find("custom", in: graph)
        #expect(custom.frame.size == CGSize(width: 100, height: 90))
        #expect(find("first", in: graph).frame.origin == CGPoint(x: 10, y: 10))
        #expect(find("nested", in: graph).frame.origin == CGPoint(x: 10, y: 37))
        #expect(find("nested-second", in: graph).frame.origin == CGPoint(x: 0, y: 18))
        #expect(find("sibling", in: graph).frame.minX == 100)
        let target = find("nested-second", in: graph)
        let hitPoint = CGPoint(x: target.absoluteFrame.minX + 2, y: target.absoluteFrame.minY + 2)
        #expect(HitTester.hitTest(rootNode: graph.tree.root!, point: hitPoint)?.node === target)
        #expect(!graph.computeLayoutIfNeeded(width: 300, height: 200))
    } }

    @Test("Calculation direction invalidates custom placements without authored direction overrides")
    func calculationDirection() {
        let root = LayoutNode()
        let container = LayoutNode()
        let child = LayoutNode()
        child.width = 20
        child.height = 10
        root.addChild(container)
        var placements = 0
        container.setCustomLayout(measure: { _, _, _ in CGSize(width: 80, height: 20) }, place: { bounds, children in
            placements += 1
            let x = children[0].customLayoutDirection == .rtl ? bounds.maxX - 20 : bounds.minX
            children[0].placeForCustomLayout(at: CGPoint(x: x, y: 0), width: 20, height: 10, isVisible: true)
        })
        container.addChild(child)
        root.calculateLayout(availableWidth: 80, availableHeight: 20, direction: .ltr)
        #expect(child.frame.minX == 0)
        root.calculateLayout(availableWidth: 80, availableHeight: 20, direction: .rtl)
        #expect(child.frame.minX == 60)
        #expect(placements == 2)
    }

    @Test("Child edits invalidate a measured custom parent and cached layout")
    func invalidation() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: TestColumnLayout(spacing: 4) {
            Box {}.frame(width: 40, height: 20).debugName("mutable")
            Box {}.frame(width: 40, height: 20).debugName("tail")
        }.debugName("owner"))
        graph.computeLayout(width: 200, height: 200)
        find("mutable", in: graph).layoutNode!.height = 70
        #expect(graph.layoutNeedsUpdate(width: 200, height: 200))
        graph.computeLayout(width: 200, height: 200)
        #expect(find("owner", in: graph).frame.height == 94)
        #expect(find("tail", in: graph).frame.minY == 74)
        #expect(!graph.layoutNeedsUpdate(width: 200, height: 200))
    } }

    @Test("At-most proposals preserve intrinsic widths and authored minimums")
    func proposals() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: TestColumnLayout(spacing: 0) {
            Box {}.frame(width: 60, height: 20).debugName("natural")
            Box {}.frame(minWidth: 220, minHeight: 30).debugName("minimum")
        }.frame(width: 140).debugName("owner"))
        graph.computeLayout(width: 300, height: 200)
        #expect(find("natural", in: graph).frame.width == 60)
        #expect(find("minimum", in: graph).frame.width == 220)
        #expect(find("owner", in: graph).frame.height == 50)
        #expect(ProposedViewSize(width: .infinity, height: -.infinity) == .unspecified)
        #expect(ProposedViewSize(width: -4).width == 0)
    } }

    @Test("Nested percentage children retain finite geometry after repeated measurement proposals")
    func nestedPercentages() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Column {
            Grid(columns: [.fixed(100), .flexible(minimum: 120)], columnSpacing: 12) {
                Box { Box {}.frame(height: 20) }.padding(12).frame(width: .percent(100))
                TestColumnLayout(spacing: 3) {
                    Box {}.frame(width: .percent(100), height: .points(20))
                    Box {}.frame(width: .percent(100), height: .points(30))
                }.frame(width: .percent(100))
            }.frame(width: .percent(100))
        }.frame(width: .percent(100)))
        for width: Float in [500, 200, 500, 500] {
            graph.computeLayout(width: width, height: 300)
            for node in nodes(graph.tree.root!) {
                #expect(node.frame.width.isFinite)
                #expect(node.frame.height.isFinite)
            }
        }
    } }

    @Test("Logical padding mirrors with flex direction and custom placements")
    func rtl() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Row {
            Box {}.frame(width: 20, height: 20).debugName("first")
            Box {}.frame(width: 30, height: 20).debugName("second")
        }.padding(EdgeInsets(leading: 11, trailing: 23))
            .frame(width: 140, height: 50).layoutDirection(.rtl).debugName("row"))
        graph.computeLayout(width: 140, height: 50)
        #expect(find("first", in: graph).frame.minX == 109)
        #expect(find("second", in: graph).frame.minX == 79)
        let layout = find("row", in: graph).layoutNode!
        #expect(layout.resolvedPadding.right == 11)
        #expect(layout.resolvedPadding.left == 23)
    } }

    @Test("Nested safe areas consume logical edges once, and resize with host insets")
    func safeArea() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: SafeArea(.horizontal) {
            SafeArea {
                Box {}.frame(height: 20).debugName("safe-content")
            }.debugName("inner-safe")
        }.frame(width: 200).layoutDirection(.rtl)
            .safeAreaInsets(EdgeInsets(top: 7, leading: 11, bottom: 13, trailing: 23))
            .debugName("outer-safe"))
        graph.computeLayout(width: 200, height: 200)
        #expect(find("outer-safe", in: graph).frame.height == 40)
        #expect(find("inner-safe", in: graph).frame.minX == 23)
        #expect(find("inner-safe", in: graph).frame.width == 166)
        #expect(find("safe-content", in: graph).frame.minY == 7)
        #expect(find("safe-content", in: graph).frame.width == 166)
    } }
}

private struct LayoutHitBox: _PrimitiveView {
    func _makeNode() -> Node { Node() }
    func _updateNode(_ node: Node) { node.isHitTestable = true }
    func _updateLayout(_ layout: LayoutNode) { layout.width = 40; layout.height = 25 }
}

private struct TestColumnLayout: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.init(width: proposal.width)) }
        return CGSize(width: sizes.map(\.width).max() ?? 0,
                      height: sizes.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, sizes.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        var y = bounds.minY
        for child in subviews {
            let size = child.sizeThatFits(.init(width: bounds.width))
            child.place(at: CGPoint(x: bounds.minX, y: y), proposal: .init(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
    }
}
