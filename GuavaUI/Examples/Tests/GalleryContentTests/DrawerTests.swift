import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing

@testable import GalleryContent

@Suite("Gallery navigation drawer", .serialized)
@MainActor
struct DrawerTests {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func scene(
        page: GalleryPage, _ work: (ViewGraph, PlatformInputContext, EventDispatcher, () -> Void) throws -> Void
    ) rethrows {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(
            atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        let portals = PortalStore()
        let scheduler = AnimatorScheduler()
        context.addScopedAmbient(PortalStoreAmbient(portals))
        try context.withCurrent {
            try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(
                    tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: GalleryView(initialPage: page).reducedMotion())
                let settle = {
                    for _ in 0..<8 {
                        graph.recomposer.commitAll()
                        graph.computeLayout(width: 1280, height: 820)
                    }
                }
                settle()
                defer {
                    graph.install(root: EmptyView())
                    scheduler.reset()
                }
                try work(graph, context, input, settle)
            }
        }
    }
    private func named(_ name: String, _ graph: ViewGraph) throws -> Node {
        try #require(
            nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event))
        input.dispatch(.mouseButtonUp(event))
    }

    @Test("The dedicated story opens a modal and commits keyboard navigation back into its summary")
    func storyKeyboard() throws {
        try scene(page: .navigationDrawer) { graph, context, input, settle in
            let opener = try named("drawer-open", graph)
            click(opener, input)
            settle()
            let dialog = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .dialog })
            #expect(dialog.frame.width == 320 && dialog.frame.height == 820)
            let selected = try named("sidebar-item-8", graph)
            context.focusChain.focus(selected)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false)))
            settle()
            #expect(context.focusChain.hasModalScope)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.return, keycode: 0, modifiers: [], isRepeat: false)))
            settle()
            #expect(!context.focusChain.hasModalScope && context.focusChain.focused?.id == opener.id)
            #expect(try named("drawer-selection", graph).layoutNode?.textInputs?.text == "Selected destination: 9")
            #expect(AdaptiveControlExamples.supports(.navigationDrawer))
            for name in ["narrow", "wide", "touch"] {
                #expect(
                    nodes(graph.tree.root).contains {
                        $0.attachments[LayoutDebugAttachmentKey.debugName] as? String
                            == "adaptive-navigationDrawer-\(name)"
                    })
            }
        }
    }

    @Test("Sidebar and its drawer share selection and restore the explicit opener")
    func sharedSidebarSelection() throws {
        try scene(page: .sidebar) { graph, context, input, settle in
            let opener = try named("sidebar-open-drawer", graph)
            click(opener, input)
            settle()
            let row = try #require(
                nodes(graph.tree.root).first {
                    $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "sidebar-item-projects"
                        && context.focusChain.permitsInput($0)
                })
            click(row, input)
            settle()
            #expect(!context.focusChain.hasModalScope && context.focusChain.focused?.id == opener.id)
            #expect(try named("sidebar-item-projects", graph).accessibility?.state.isSelected == true)
            #expect(try named("sidebar-destination", graph).layoutNode?.textInputs?.text == "Projects")
        }
    }
}
