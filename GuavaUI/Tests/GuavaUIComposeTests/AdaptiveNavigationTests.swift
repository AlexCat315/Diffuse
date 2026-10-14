import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive tab placement", .serialized)
struct AdaptiveNavigationTests: GuavaUIComposeSerializedSuite {
    private struct Panel: View {
        @State private var count = 0
        var body: some View {
            Button("Count \(count)") { count += 1 }.debugName("panel-counter")
        }
    }
    private struct Harness: View {
        @State var width: Float = 800
        let placement: TabStripPlacement
        var body: some View {
            var surface = UIEnvironment(); surface.viewport.width = width; surface.input = [.touch]
            return TabView(selection: .constant(0), tabs: [TabItem("Overview", id: 0) { Panel() }, TabItem("Details", id: 1) { EmptyView() }]) {
                $0.placement = placement; $0.overflow = .scroll
            }.frame(width: width, height: 200).surfaceEnvironment(surface)
        }
    }
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func settle(_ graph: ViewGraph, width: Float) {
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 200) }
    }
    @Test("compact moves the strip below the retained panel; explicit top placement wins")
    func compactStrip() throws { try GlobalTestLock.locked {
        let oldText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = oldText }
        for placement: TabStripPlacement in [.adaptive, .top, .bottom] {
            let harness = Harness(placement: placement), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: harness); settle(graph, width: 800)
            let panel = try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "panel-counter" })
            let tab = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .tab })
            #expect(tab.frame.height >= 44)
            panel.accessibilityActions.activate?(); settle(graph, width: 800)
            #expect(panel.accessibility?.label == "Count 1" || AccessibilityTree.snapshot(root: panel).first?.semantics.label == "Count 1")
            harness.width = 390; settle(graph, width: 390)
            let retained = try #require(nodes(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "panel-counter" })
            #expect(retained === panel)
            #expect(AccessibilityTree.snapshot(root: panel).first?.semantics.label == "Count 1")
            if placement == .top { #expect(tab.absoluteFrame.maxY <= panel.absoluteFrame.minY) }
            else { #expect(panel.absoluteFrame.maxY <= tab.absoluteFrame.minY) }
            harness.width = 800; settle(graph, width: 800)
            #expect(nodes(graph.tree.root!).contains { $0 === panel })
            #expect(!graph.recomposer.hasPending)
        }
    } }
}
