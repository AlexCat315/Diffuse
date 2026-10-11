import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// A sidebar is a column of full-bleed rows. Every row has to fill the lane it
/// was given, on both sides equally, or the selected destination looks like it
/// is drifting towards one edge — the kind of misalignment that reads as a bug
/// long before anyone can name it.
@Suite("Sidebar rows", .serialized)
struct SidebarTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func row(_ graph: ViewGraph, _ id: String) -> Node? {
        nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "sidebar-item-\(id)"
        }
    }

    private func mounted(_ test: (ViewGraph) -> Void) {
        GlobalTestLock.locked {
            let oldChain = FocusChainHolder.current
            FocusChainHolder.current = FocusChain()
            defer { FocusChainHolder.current = oldChain }
            var selection: String? = "button"
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Sidebar(selection: Binding(get: { selection }, set: { selection = $0 }),
                                        sections: [SidebarSection("controls", title: "Controls", items: [
                                            SidebarItem("button", "Button"),
                                            SidebarItem("checkbox", "Checkbox")
                                        ])]))
            graph.computeLayout(width: 226, height: 400)
            test(graph)
        }
    }

    private func rings(in graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root!).filter { $0.borderWidth > 0 }
    }

    @Test("A destination highlight is inset the same on both sides")
    func highlightIsSymmetric() {
        mounted { graph in
            let sidebar = graph.tree.root!
            let item = row(graph, "button")!
            let leading = item.absoluteFrame.minX - sidebar.absoluteFrame.minX
            let trailing = sidebar.absoluteFrame.maxX - item.absoluteFrame.maxX
            #expect(abs(leading - trailing) < 0.5)
            #expect(abs(leading - 10) < 0.5)  // the sidebar's own content padding
        }
    }

    @Test("Rows reach the trailing edge of the pane, not of a scrollbar lane")
    func rowsFillThePane() {
        mounted { graph in
            let sidebar = graph.tree.root!
            let item = row(graph, "checkbox")!
            // A reserved scrollbar lane is trailing-only, so the row would stop
            // 12pt short of the pane's inner edge before the padding is applied.
            #expect(abs((sidebar.absoluteFrame.maxX - 10) - item.absoluteFrame.maxX) < 0.5)
        }
    }

    @Test("A destination rings for the keyboard and stays quiet for the pointer")
    func ringFollowsTheKeyboard() {
        mounted { graph in
            let item = row(graph, "button")!
            FocusChainHolder.current!.focus(item, visible: false)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 226, height: 400)
            #expect(rings(in: graph).isEmpty)

            FocusChainHolder.current!.focus(item, visible: true)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 226, height: 400)
            #expect(rings(in: graph).contains { $0.borderWidth == 2 })
        }
    }
}
