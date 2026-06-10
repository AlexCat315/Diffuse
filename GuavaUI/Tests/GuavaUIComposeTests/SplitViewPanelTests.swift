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

    @Test("Panel creates header and content regions (floating-island chrome)")
    func panelShellLayout() {
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())

        graph.install(root:
            Panel("Inspector") {
                Box { EmptyView() }
                    .frame(height: 40)
                    .background(Color(red: 40, green: 48, blue: 60))
            }
            .frame(width: 240, height: 160)
        )

        graph.computeLayout(width: 240, height: 160)

        // Panel is a composite: root → frame box → PanelHost → style body.
        // The floating-island chrome is a Column with a 34px header row and
        // the content region — no divider, separation comes from the rounded
        // surfaceSunken slab itself.
        let panelHost = materialisedRoot(in: tree)
        let body = panelHost.children.first!
        #expect(body.children.count == 2)
        // Background lives on the style body, not the host shell.
        #expect(body.backgroundColor != nil)

        let header = body.children[0]
        let content = body.children[1]

        #expect(header.frame.height == 34)
        #expect(content.frame.origin.y == 34)
    }

    private func materialisedRoot(in tree: NodeTree) -> Node {
        tree.root!.children.first!.children.first!
    }
}