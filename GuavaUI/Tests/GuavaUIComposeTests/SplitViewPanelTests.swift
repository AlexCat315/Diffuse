import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Phase 7 SplitView & Panel")
struct SplitViewPanelTests {

    @Test("SplitView horizontal layout honours fraction and divider thickness")
    func splitViewHorizontalLayout() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        let firstColor = Color(red: 255, green: 0, blue: 0)
        let secondColor = Color(red: 0, green: 0, blue: 255)

        graph.install(root:
            SplitView(.horizontal, fraction: 0.25) {
                Box { EmptyView() }
                    .background(firstColor)
            } second: {
                Box { EmptyView() }
                    .background(secondColor)
            }
            .frame(width: 400, height: 120)
        )

        graph.computeLayout(width: 400, height: 120)

        let split = materialisedRoot(in: tree)
        #expect(split.children.count == 3)

        let first = split.children[0]
        let divider = split.children[1]
        let second = split.children[2]

        #expect(first.backgroundColor == firstColor)
        #expect(second.backgroundColor == secondColor)
        #expect(divider.frame.width == 1)
        #expect(abs(first.frame.width - 100) <= 1)
        #expect(abs(second.frame.width - 299) <= 1)
        #expect(first.frame.height == 120)
        #expect(second.frame.height == 120)
    }

    @Test("Panel creates header, divider, and content regions")
    func panelShellLayout() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())

        graph.install(root:
            Panel("Inspector", contentPadding: .zero) {
                Box { EmptyView() }
                    .frame(height: 40)
                    .background(Color(red: 40, green: 48, blue: 60))
            }
            .frame(width: 240, height: 160)
        )

        graph.computeLayout(width: 240, height: 160)

        let panel = materialisedRoot(in: tree)
        #expect(panel.children.count == 3)
        #expect(panel.backgroundColor != nil)

        let header = panel.children[0]
        let divider = panel.children[1]
        let content = panel.children[2]

        #expect(header.frame.height == 36)
        #expect(header.backgroundColor != nil)
        #expect(divider.frame.height == 1)
        #expect(content.frame.origin.y == 37)
        #expect(content.frame.height == 123)
    }

    private func materialisedRoot(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!
    }
}