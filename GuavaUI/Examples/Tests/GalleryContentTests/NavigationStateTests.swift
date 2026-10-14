import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent

@Suite("Gallery navigation state", .serialized)
@MainActor
struct NavigationStateTests {
    @Test("The 100K LazyGrid story applies text scaling once without expanding the viewport")
    func lazyGridTextScale() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()) }
            graph.install(root: LayoutFoundationExamples().theme(.defaultLight).textScaler(.init(2)))
            for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 900, height: 1_000) }
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let viewport = try #require(all(graph.tree.root!).first {
                $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "layout-lazy-grid"
            })
            #expect(viewport.clipsToBounds && viewport.frame.height == 240)
            var cells: [Node] = []
            for node in all(viewport) {
                if node.layoutNode?.textInputs?.text.hasPrefix("Cell ") == true { cells.append(node) }
            }
            #expect(!cells.isEmpty && cells.count < 100)
            #expect(cells.allSatisfy { $0.frame.height == 96 })
        }
    }

    @Test("The scaled tree example owns a scroll viewport so rows cannot paint over its selection summary")
    func treeViewport() throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()) }
            graph.install(root: TreeStory().theme(.defaultLight).textScaler(.init(2)))
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 900, height: 700) }
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            let viewport = all(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "gallery-tree" }
            #expect(viewport?.clipsToBounds == true && viewport?.frame.height == 250)
            let summary = all(graph.tree.root!).first { $0.layoutNode?.textInputs?.text.hasPrefix("Selected:") == true }
            #expect((summary?.absoluteFrame.minY ?? 0) > (viewport?.absoluteFrame.maxY ?? 0))
        }
    }
    @Test("Searching, navigating, editing and collapsing preserve shell selection and search")
    func editingPreservesNavigation() throws {
        let oldText = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = oldText }
        let context = PlatformInputContext()
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(AnimatorScheduler()) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()) }
                graph.install(root: GalleryView(initialPage: .icon))
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
                func named(_ name: String) throws -> Node {
                    try #require(all(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
                }
                func settle() {
                    for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 720) }
                }
                func click(_ name: String) throws {
                    let frame = try named(name).absoluteFrame
                    input.dispatch(.mouseMotion(MouseMotionEvent(x: Float(frame.midX), y: Float(frame.midY), deltaX: 0, deltaY: 0))); settle()
                    let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                    input.dispatch(.mouseButtonDown(event)); settle()
                    input.dispatch(.mouseButtonUp(event)); settle()
                }
                settle()
                try click("gallery-search")
                input.dispatch(.textInput("Accordion")); settle()
                try click("sidebar-item-accordion")
                #expect(try named("sidebar-item-accordion").accessibility?.state.isSelected == true)
                try click("accordion-project-name")
                input.dispatch(.textInput(" edited")); settle()
                try click("accordion-collapse-all")
                AnimatorScheduler.current.tick(deltaTime: 1); settle()
                try click("accordion-collapse-all")
                AnimatorScheduler.current.tick(deltaTime: 1); settle()
                #expect(try named("sidebar-item-accordion").accessibility?.state.isSelected == true)
                #expect(!all(graph.tree.root!).contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "sidebar-item-icon" })
                let search = try named("gallery-search")
                #expect(all(search).contains { $0.resolvedAccessibilityValue == "Accordion" })
                #expect(all(try named("accordion-project-name")).contains { $0.resolvedAccessibilityValue.contains("edited") })
            }
        }
    }
}
