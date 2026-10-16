import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing

@testable import GalleryContent

@Suite("Gallery navigation rail", .serialized)
@MainActor
struct RailTests {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func named(_ name: String, in node: Node?) throws -> Node {
        try #require(nodes(node).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event))
        input.dispatch(.mouseButtonUp(event))
    }

    @Test("The real story retains icon destinations and updates shared selection when labels are toggled")
    func story() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(
            atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        let scheduler = AnimatorScheduler()
        let portals = PortalStore()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: GalleryView(initialPage: .navigationRail).reducedMotion())
                let input = EventDispatcher(
                    tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                func settle() {
                    for _ in 0..<8 {
                        graph.recomposer.commitAll()
                        graph.computeLayout(width: 1280, height: 1100)
                    }
                }
                settle()
                defer {
                    graph.install(root: EmptyView())
                    scheduler.reset()
                }
                let rail = try named("gallery-rail", in: graph.tree.root)
                let projects = try named("sidebar-item-1", in: rail)
                #expect(rail.frame.width == 72)
                click(projects, input)
                settle()
                #expect(
                    try named("rail-summary", in: graph.tree.root).layoutNode?.textInputs?.text
                        == "Selected: 1 · Activations: 1")
                click(try named("rail-show-labels", in: graph.tree.root), input)
                settle()
                #expect(rail.frame.width == 56 && projects.frame.height >= 44)
                #expect(projects.id == (try named("sidebar-item-1", in: rail)).id)
                #expect(projects.accessibility?.label == "Projects" && projects.accessibility?.value == "12")
                #expect(!nodes(rail).contains { $0.layoutNode?.textInputs?.text == "Projects" })
                let retained = try named("gallery-retained-rail", in: graph.tree.root)
                #expect(try named("sidebar-item-1", in: retained).accessibility?.state.isSelected == true)
                #expect(AdaptiveControlExamples.supports(.navigationRail))
                for suffix in ["narrow", "wide", "touch"] {
                    #expect(
                        nodes(graph.tree.root).contains {
                            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String
                                == "adaptive-navigationRail-\(suffix)"
                        })
                }
            }
        }
    }
}
