import Testing
import CoreGraphics
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 6.3 Primitives & Layout")
struct PrimitiveLayoutTests {

    @Test("Box(direction: row) lays children horizontally")
    func boxRow() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Box(direction: .row) {
                Box { EmptyView() }.frame(width: 50, height: 30)
                Box { EmptyView() }.frame(width: 70, height: 40)
            }
        )

        graph.computeLayout(width: 200, height: 100)

        // root → Box → [child1, child2]
        let box = tree.root?.children.first
        let kids = box?.children ?? []
        #expect(kids.count == 2)
        #expect(kids[0].frame == CGRect(x: 0,  y: 0, width: 50, height: 30))
        #expect(kids[1].frame == CGRect(x: 50, y: 0, width: 70, height: 40))
    }

    @Test("Column stacks vertically")
    func column() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                Box { EmptyView() }.frame(width: 100, height: 20)
                Box { EmptyView() }.frame(width: 100, height: 30)
                Box { EmptyView() }.frame(width: 100, height: 40)
            }
        )

        graph.computeLayout(width: 200, height: 200)
        let kids = tree.root?.children.first?.children ?? []
        #expect(kids.count == 3)
        #expect(kids[0].frame.origin.y == 0)
        #expect(kids[1].frame.origin.y == 20)
        #expect(kids[2].frame.origin.y == 50)
    }

    @Test("Spacer absorbs remaining space in a Row")
    func spacerInRow() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Row {
                Box { EmptyView() }.frame(width: 30, height: 30)
                Spacer()
                Box { EmptyView() }.frame(width: 40, height: 30)
            }
        )

        graph.computeLayout(width: 200, height: 60)
        let kids = tree.root?.children.first?.children ?? []
        #expect(kids.count == 3)
        #expect(kids[0].frame.origin.x == 0)
        #expect(kids[2].frame.origin.x == 160)  // 200 - 40
    }

    @Test("Box alignment convenience maps center-bottom for columns")
    func boxAlignmentColumnMapping() {
        let layout = LayoutNode()
        let box = Box(direction: .column, alignment: .bottom) {
            EmptyView()
        }

        box._updateLayout(layout)

        #expect(layout.flexDirection == .column)
        #expect(layout.alignItems == .center)
        #expect(layout.justifyContent == .flexEnd)
    }

    @Test("Box alignment convenience respects reverse row directions")
    func boxAlignmentRowReverseMapping() {
        let layout = LayoutNode()
        let box = Box(direction: .rowReverse, alignment: .topLeading) {
            EmptyView()
        }

        box._updateLayout(layout)

        #expect(layout.flexDirection == .rowReverse)
        #expect(layout.alignItems == .flexStart)
        #expect(layout.justifyContent == .flexEnd)
    }

    @Test("Padding modifier insets children")
    func padding() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Column {
                Box { EmptyView() }.frame(width: 50, height: 50)
            }
            .padding(20)
            .frame(width: 100, height: 100)
        )

        graph.computeLayout(width: 200, height: 200)
        // Outer column = 100x100 at (0,0).
        let outer = tree.root?.children.first
        #expect(outer?.frame == CGRect(x: 0, y: 0, width: 100, height: 100))
        // Inner box should be inset by padding 20.
        let inner = outer?.children.first
        #expect(inner?.frame.origin == CGPoint(x: 20, y: 20))
        #expect(inner?.frame.size == CGSize(width: 50, height: 50))
    }

    @Test("Background modifier sets node fill")
    func background() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Box { EmptyView() }
                .frame(width: 50, height: 50)
                .background(Color(red: 255, green: 0, blue: 0))
        )
        graph.computeLayout(width: 100, height: 100)
        let box = tree.root?.children.first
        #expect(box?.backgroundColor == Color(red: 255, green: 0, blue: 0))
    }

    @Test("Opacity modifier sets node opacity")
    func opacity() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Box { EmptyView() }.opacity(0.5))
        let box = tree.root?.children.first
        #expect(box?.opacity == 0.5)
    }

    @Test("Clipped sets clipsToBounds")
    func clipped() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Box { EmptyView() }.clipped())
        let box = tree.root?.children.first
        #expect(box?.clipsToBounds == true)
    }

    @Test("CornerRadius modifier sets node radius")
    func cornerRadius() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: Box { EmptyView() }.cornerRadius(12))
        let box = tree.root?.children.first
        #expect(box?.cornerRadius == 12)
    }

    @Test("Image draw uses texture tint and fixed layout size")
    func imageDrawUsesTintAndOpacity() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(textureID: 7, width: 32, height: 24)
                .foregroundColor(Color(red: 255, green: 0, blue: 0))
                .opacity(0.5)
                .cornerRadius(8)
        )

        graph.computeLayout(width: 100, height: 100)
        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(image?.frame.size == CGSize(width: 32, height: 24))
        #expect(list.batches.first?.textureID == 7)
        #expect(list.vertices.count > 4)

        let packed = list.vertices.first!.color
        let redByte = packed & 0xFF
        let alphaByte = (packed >> 24) & 0xFF
        #expect(redByte >= 250)
        #expect(alphaByte >= 126 && alphaByte <= 129)
    }

    @Test("Image stretch mode fills container")
    func imageStretchModeFillsContainer() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(textureID: 7,
                  width: 100,
                  height: 100,
                  sourcePixelSize: (200, 100),
                  contentMode: .stretch)
        )

        graph.computeLayout(width: 100, height: 100)
        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(list.vertices.count == 4)
        let xs = list.vertices.map(\.posX)
        let ys = list.vertices.map(\.posY)
        #expect(xs.min() == 0)
        #expect(xs.max() == 100)
        #expect(ys.min() == 0)
        #expect(ys.max() == 100)
    }

    @Test("Image fit mode preserves aspect ratio")
    func imageFitModePreservesAspectRatio() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(textureID: 7,
                  width: 100,
                  height: 100,
                  sourcePixelSize: (200, 100),
                  contentMode: .fit)
        )

        graph.computeLayout(width: 100, height: 100)
        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(list.vertices.count == 4)
        let xs = list.vertices.map(\.posX)
        let ys = list.vertices.map(\.posY)
        #expect(xs.min() == 0)
        #expect(xs.max() == 100)
        #expect(ys.min() == 25)
        #expect(ys.max() == 75)
    }

    @Test("Image fill mode preserves aspect ratio and overdraws")
    func imageFillModePreservesAspectRatioAndOverdraws() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Image(textureID: 7,
                  width: 100,
                  height: 100,
                  sourcePixelSize: (200, 100),
                  contentMode: .fill)
        )

        graph.computeLayout(width: 100, height: 100)
        let image = tree.root?.children.first
        let list = DrawList()
        image?.draw?(list, .zero)

        #expect(list.vertices.count == 4)
        let xs = list.vertices.map(\.posX)
        let ys = list.vertices.map(\.posY)
        #expect(xs.min() == -50)
        #expect(xs.max() == 150)
        #expect(ys.min() == 0)
        #expect(ys.max() == 100)
    }

    @Test("Modifier stack: padding + frame + background")
    func stack() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            Box { EmptyView() }
                .padding(10)
                .frame(width: 80, height: 80)
                .background(Color.white)
        )
        graph.computeLayout(width: 200, height: 200)
        let box = tree.root?.children.first
        #expect(box?.frame.size == CGSize(width: 80, height: 80))
        #expect(box?.backgroundColor == Color.white)
    }
}
