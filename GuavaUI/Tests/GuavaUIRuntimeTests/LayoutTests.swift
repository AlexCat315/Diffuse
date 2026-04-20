import Testing
@testable import GuavaUIRuntime

@Suite("Layout")
struct LayoutTests {

    // MARK: - Basic direction

    @Test("Row lays out children horizontally without overlap")
    func rowLayout() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 200
        root.height = 100

        let a = LayoutNode(); a.width = 80; a.height = 100
        let b = LayoutNode(); b.width = 80; b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        let fa = a.frame, fb = b.frame
        #expect(fa.minX < fb.minX)      // a is left of b
        #expect(fa.maxX <= fb.minX)     // no overlap
    }

    @Test("Column stacks children vertically without overlap")
    func columnLayout() {
        let root = LayoutNode()
        root.flexDirection = .column
        root.width = 100
        root.height = 200

        let a = LayoutNode(); a.width = 100; a.height = 60
        let b = LayoutNode(); b.width = 100; b.height = 60
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        let fa = a.frame, fb = b.frame
        #expect(fa.minY < fb.minY)      // a is above b
        #expect(fa.maxY <= fb.minY)     // no overlap
    }

    // MARK: - flexGrow

    @Test("flexGrow fills remaining space in a row")
    func flexGrowFillsRow() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 200
        root.height = 100

        let fixed = LayoutNode(); fixed.width = 60; fixed.height = 100
        let grow = LayoutNode(); grow.flexGrow = 1; grow.height = 100
        root.addChild(fixed)
        root.addChild(grow)

        root.calculateLayout()

        // 200 - 60 = 140
        #expect(abs(Float(grow.frame.width) - 140) < 1)
    }

    @Test("Two flexGrow children split remaining space equally")
    func flexGrowEqualSplit() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 300
        root.height = 100

        let a = LayoutNode(); a.flexGrow = 1; a.height = 100
        let b = LayoutNode(); b.flexGrow = 1; b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        #expect(abs(Float(a.frame.width) - 150) < 1)
        #expect(abs(Float(b.frame.width) - 150) < 1)
    }

    // MARK: - LayoutPass integration

    @Test("LayoutPass writes Yoga results to Node.frame")
    func layoutPassWritesFrames() {
        // GuavaUI node tree
        let rootNode = Node()
        let childA = Node()
        let childB = Node()
        rootNode.addChild(childA)
        rootNode.addChild(childB)

        // Mirrored Yoga tree
        let rootLayout = LayoutNode()
        rootLayout.flexDirection = .row
        rootLayout.width = 200
        rootLayout.height = 100

        let la = LayoutNode(); la.width = 80; la.height = 100
        let lb = LayoutNode(); lb.width = 80; lb.height = 100
        rootLayout.addChild(la)
        rootLayout.addChild(lb)

        LayoutPass.run(
            rootLayoutNode: rootLayout,
            rootNode: rootNode,
            availableWidth: 200,
            availableHeight: 100
        )

        #expect(childA.frame.width == 80)
        #expect(childB.frame.width == 80)
        #expect(childA.frame.minX < childB.frame.minX)
    }

    // MARK: - Padding

    @Test("Padding offsets child positions")
    func paddingOffsetsChildren() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 200
        root.height = 100
        root.setPadding(10, edge: .all)

        let child = LayoutNode(); child.width = 50; child.height = 80
        root.addChild(child)

        root.calculateLayout()

        // Child should be offset by padding
        #expect(child.frame.minX >= 10)
        #expect(child.frame.minY >= 10)
    }

    // MARK: - flexWrap

    @Test("flexWrap wraps children to next line")
    func flexWrapWraps() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.flexWrap = .wrap
        root.width = 100
        root.height = 200

        let a = LayoutNode(); a.width = 60; a.height = 40
        let b = LayoutNode(); b.width = 60; b.height = 40
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        // b wraps to second line (different Y)
        #expect(b.frame.minY > a.frame.minY)
    }

    // MARK: - alignSelf

    @Test("alignSelf overrides parent alignItems")
    func alignSelfOverride() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.alignItems = .flexStart
        root.width = 200
        root.height = 100

        let child = LayoutNode()
        child.alignSelf = .center
        child.width = 50
        child.height = 30
        root.addChild(child)

        root.calculateLayout()

        // (100 - 30) / 2 = 35
        #expect(abs(Float(child.frame.minY) - 35) < 1)
    }

    // MARK: - positionType absolute

    @Test("Absolute position places child at specified coordinates")
    func absolutePosition() {
        let root = LayoutNode()
        root.width = 200
        root.height = 200

        let child = LayoutNode()
        child.positionType = .absolute
        child.setPosition(10, edge: .left)
        child.setPosition(20, edge: .top)
        child.width = 50
        child.height = 50
        root.addChild(child)

        root.calculateLayout()

        #expect(abs(Float(child.frame.minX) - 10) < 1)
        #expect(abs(Float(child.frame.minY) - 20) < 1)
    }

    // MARK: - flexBasis

    @Test("flexBasis sets initial main axis size")
    func flexBasisSetsSize() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 300
        root.height = 100

        let a = LayoutNode()
        a.setFlexBasis(100)
        a.height = 100
        let b = LayoutNode()
        b.flexGrow = 1
        b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        #expect(abs(Float(a.frame.width) - 100) < 1)
        #expect(abs(Float(b.frame.width) - 200) < 1)
    }

    // MARK: - gap

    @Test("Gap adds spacing between children")
    func gapSpacing() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 200
        root.height = 100
        root.setGap(10, gutter: .column)

        let a = LayoutNode(); a.width = 50; a.height = 100
        let b = LayoutNode(); b.width = 50; b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        // b.minX should be a.maxX + 10 gap
        #expect(abs(Float(b.frame.minX) - 60) < 1)
    }

    // MARK: - border

    @Test("Border offsets child like padding")
    func borderOffsetsChild() {
        let root = LayoutNode()
        root.flexDirection = .column
        root.width = 100
        root.height = 100
        root.setBorder(5, edge: .all)

        let child = LayoutNode(); child.width = 50; child.height = 50
        root.addChild(child)

        root.calculateLayout()

        #expect(child.frame.minX >= 5)
        #expect(child.frame.minY >= 5)
    }

    // MARK: - margin

    @Test("Margin pushes child away from siblings")
    func marginBetweenSiblings() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 300
        root.height = 100

        let a = LayoutNode(); a.width = 50; a.height = 100
        let b = LayoutNode(); b.width = 50; b.height = 100
        b.setMargin(20, edge: .left)
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout()

        // b should start at a.maxX + 20
        #expect(abs(Float(b.frame.minX) - 70) < 1)
    }

    // MARK: - removeChild

    @Test("removeChild detaches node from layout tree")
    func removeChildWorks() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.width = 200
        root.height = 100

        let a = LayoutNode(); a.width = 80; a.height = 100
        let b = LayoutNode(); b.width = 80; b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.removeChild(a)

        root.calculateLayout()

        #expect(root.children.count == 1)
        #expect(abs(Float(b.frame.minX) - 0) < 1)
    }

    // MARK: - RTL direction

    @Test("RTL direction reverses row order")
    func rtlDirection() {
        let root = LayoutNode()
        root.flexDirection = .row
        root.direction = .rtl
        root.width = 200
        root.height = 100

        let a = LayoutNode(); a.width = 50; a.height = 100
        let b = LayoutNode(); b.width = 50; b.height = 100
        root.addChild(a)
        root.addChild(b)

        root.calculateLayout(direction: .rtl)

        // In RTL, first child is on the right
        #expect(a.frame.minX > b.frame.minX)
    }
}
