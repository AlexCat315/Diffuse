import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Status bar & panel truncation", .serialized)
struct StatusBarPanelTruncationTests {
    @Test("Multiple facts remain two layout slots with finite descendant geometry")
    func multipleFacts() throws { try GlobalTestLock.locked {
        try withText {
            for width: Float in [120, 390, 720, 1280] {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: StatusBar {
                    StatusBarText("main")
                    StatusBarText("UTF-8")
                } trailing: {
                    StatusBarText("Ln 42", detail: "Col 7")
                    StatusBarText("Connected", tone: .success)
                }.frame(width: .points(width)))
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 40) }
                for node in nodes(graph.tree.root) {
                    #expect(node.frame.width.isFinite && node.frame.height.isFinite)
                    #expect(node.frame.width >= 0 && node.frame.height >= 0)
                }
                let trailing = try #require(textNodes(in: graph.tree.root).first { $0.layoutNode?.textInputs?.text == "Connected" })
                if width >= 390 { #expect(trailing.frame.width > 0) }
                graph.install(root: EmptyView())
            }
        }
    } }

    @Test("a long status fact truncates without hiding the trailing state")
    func statusBar() throws { try GlobalTestLock.locked {
        try withText {
            let leading = "feature/workspace-permissions-and-collaboration"
            let trailing = "Connected"
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: StatusBar {
                StatusBarText(leading, icon: UIIcons.Editor.gitBranch)
            } trailing: {
                StatusBarText(trailing, tone: .success)
            }.frame(width: 320))
            graph.computeLayout(width: 320, height: 40)
            let texts = textNodes(in: graph.tree.root)
            let leadingText = try #require(texts.first { $0.layoutNode?.textInputs?.text == leading })
            let trailingText = try #require(texts.first { $0.layoutNode?.textInputs?.text == trailing })
            #expect(leadingText.frame.width > 0)
            #expect(leadingText.absoluteFrame.maxX <= trailingText.absoluteFrame.minX)
            let line = try #require(leadingText.layoutNode?.textMeasure as? TextLayoutCacheEntry)
            #expect(line.result.lines.count == 1)
            let cell = try #require(nodes(graph.tree.root).first {
                $0.accessibility?.role == .staticText && $0.accessibility?.label == leading
            })
            #expect(cell.accessibility?.value.contains(leading) == true)
        }
    } }

    @Test("a long panel title stays one line and gives space back to the accessory")
    func panelTitle() throws { try GlobalTestLock.locked {
        try withText {
            let title = "A workspace inspector title that is far too long for this narrow panel"
            let narrow = graph(title: title, width: 240)
            let wide = graph(title: title, width: 600)
            let narrowTitle = try #require(textNodes(in: narrow.tree.root).first {
                $0.layoutNode?.textInputs?.text == title
            })
            let wideTitle = try #require(textNodes(in: wide.tree.root).first {
                $0.layoutNode?.textInputs?.text == title
            })
            let narrowLayout = try #require(narrowTitle.layoutNode?.textMeasure as? TextLayoutCacheEntry)
            let wideLayout = try #require(wideTitle.layoutNode?.textMeasure as? TextLayoutCacheEntry)
            #expect(narrowLayout.result.lines.count == 1 && wideLayout.result.lines.count == 1)
            #expect(narrowTitle.frame.width < wideTitle.frame.width)
        }
    } }

    private func graph(title: String, width: Float) -> ViewGraph {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Panel(title, accessory: { Badge("Live", tone: .success) }) {
            Text("Panel content")
        }.frame(width: width, height: 120))
        graph.computeLayout(width: width, height: 120)
        return graph
    }

    private func withText(_ body: () throws -> Void) rethrows {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        try body()
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func textNodes(in root: Node?) -> [Node] {
        nodes(root).filter { $0.layoutNode?.textInputs?.text != nil }
    }
}
