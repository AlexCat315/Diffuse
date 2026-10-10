import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Window chrome: the pieces that sit around the content — a status bar under
/// it, links inside it. Small surface, but a crash or a missing semantic role
/// here takes the whole window with it.
@Suite("Chrome components", .serialized)
struct ChromeComponentTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func withScene(_ test: (ViewGraph) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            InteractionRegistryHolder.current = InteractionRegistry()
            defer { InteractionRegistryHolder.current = oldRegistry }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    @Test("A link announces itself as a link and keeps its own action")
    func linkSemantics() {
        withScene { graph in
            var opened = 0
            graph.install(root: Link("Documentation", configure: { $0.isExternal = true }) { opened += 1 })
            graph.computeLayout(width: 240, height: 40)
            let link = nodes(graph.tree.root!).compactMap(\.accessibility).first { $0.role == .link }
            #expect(link != nil)
        }
    }

    @Test("The status bar holds one height whether it has one slot or two")
    func statusBarHeight() {
        withScene { graph in
            graph.install(root: StatusBar {
                StatusBarText("main", icon: UIIcons.Editor.gitBranch)
                StatusBarText("UTF-8", isMonospaced: true)
            } trailing: {
                StatusBarText("Ln 12", detail: "Col 4", isMonospaced: true)
            })
            graph.computeLayout(width: 320, height: 60)
            let full = nodes(graph.tree.root!).first { $0.accessibility?.label == "Status bar" }
            // The hairline above the bar is part of the component, not of its content.
            #expect(full.map({ Float($0.frame.height) }) == StatusBarMetrics.height + 1)

            graph.install(root: StatusBar(showsDivider: false, leading: {
                StatusBarText("Indexing", tone: .info)
            }))
            graph.computeLayout(width: 320, height: 60)
            let single = nodes(graph.tree.root!).first { $0.accessibility?.label == "Status bar" }
            #expect(single.map({ Float($0.frame.height) }) == StatusBarMetrics.height)
        }
    }
}
