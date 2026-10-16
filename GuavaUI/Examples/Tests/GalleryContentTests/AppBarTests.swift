import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing
@testable import GalleryContent

@Suite("Gallery application bar", .serialized)
@MainActor
struct AppBarTests {
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }
    @Test("The story commits actions from the real app bar, reflows its primary label, and exposes safe-area and adaptive samples")
    func story() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext(), scheduler = AnimatorScheduler(), portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: GalleryView(initialPage: .appBar).reducedMotion())
            func settle() { for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 820) } }
            settle()
            defer { graph.install(root: EmptyView()); scheduler.reset() }
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
            let bar = try named("gallery-appbar", graph)
            let primary = try #require(nodes(bar).first { $0.isFocusable && $0.accessibility?.label == "Save workspace" })
            click(primary, input); settle()
            #expect(nodes(graph.tree.root).contains { $0.layoutNode?.textInputs?.text == "Saved" })
            click(try named("appbar-text-primary", graph), input); settle()
            #expect(nodes(bar).contains { $0.layoutNode?.textInputs?.text == "Save workspace" })
            let safeHost = try named("appbar-safe-host", graph), safeBar = try named("appbar-safe-content", graph)
            #expect(safeBar.absoluteFrame.minY - safeHost.absoluteFrame.minY == 24)
            for suffix in ["narrow", "wide", "touch"] { _ = try named("adaptive-appBar-\(suffix)", graph) }
        } }
    }
}
