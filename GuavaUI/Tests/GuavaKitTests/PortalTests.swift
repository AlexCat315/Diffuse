import Testing
@testable import GuavaKit

@Suite("GuavaKit portal")
struct PortalTests {
    private final class ActionBox { var fire: () -> Void = {} }
    private let blue = Color(r: 0, g: 0, b: 1)

    private struct PopoverApp: View {
        @State var open: Bool = false
        @State var showPopover: Bool = true
        let toggle: PortalTests.ActionBox
        let remove: PortalTests.ActionBox
        var body: some View {
            toggle.fire = { open.toggle() }
            remove.fire = { showPopover = false }
            return Stack(.column) {
                if showPopover {
                    Popover(isPresented: $open) {
                        Element(width: 50, height: 30, color: Color(r: 0, g: 0, b: 1))
                    } trigger: {
                        Element(width: 40, height: 20)
                    }
                }
                PortalHost()
            }
        }
    }

    private func makeApp() -> (graph: ViewGraph, ctx: UIContext, toggle: ActionBox, remove: ActionBox) {
        let ctx = UIContext()
        let graph = ViewGraph(context: ctx)
        let toggle = ActionBox(); let remove = ActionBox()
        graph.install(root: PopoverApp(toggle: toggle, remove: remove))
        drain(graph)
        return (graph, ctx, toggle, remove)
    }

    private func drain(_ graph: ViewGraph) {
        var guardCount = 0
        while graph.commitIfNeeded() { guardCount += 1; if guardCount > 50 { break } }
    }

    @Test("Presenting registers a portal entry and materializes the overlay")
    func presentRegisters() {
        let app = makeApp()
        #expect(app.ctx.portals.count == 0)

        app.toggle.fire()           // open = true
        drain(app.graph)
        #expect(app.ctx.portals.count == 1)
        // The overlay node exists under the PortalHost (high-z) node.
        let host = app.graph.root.children[0].children.first { $0.geometry.zIndex >= 1_000_000 }
        #expect(host != nil)
        #expect(host!.children.count == 1) // one portal slot
    }

    @Test("Dismissing removes the entry and the overlay")
    func dismissRemoves() {
        let app = makeApp()
        app.toggle.fire(); drain(app.graph)
        #expect(app.ctx.portals.count == 1)
        app.toggle.fire(); drain(app.graph) // open = false
        #expect(app.ctx.portals.count == 0)
        let host = app.graph.root.children[0].children.first { $0.geometry.zIndex >= 1_000_000 }
        #expect(host!.children.isEmpty)
    }

    // MARK: - The leak, structurally prevented

    @Test("Removing the popover from the tree WHILE OPEN releases its entry (no leak)")
    func removalReleasesEntry() {
        let app = makeApp()
        app.toggle.fire(); drain(app.graph)     // open = true → entry registered
        #expect(app.ctx.portals.count == 1)

        // Remove the whole Popover from the view tree while it's still open —
        // exactly the panel-relayout case that leaked in the legacy stack.
        app.remove.fire()                        // showPopover = false
        drain(app.graph)

        // The popover node detached → PortalResource.unmount ran → entry gone.
        // No modifier, no manual cleanup — the node lifecycle did it.
        #expect(app.ctx.portals.count == 0)
    }

    @Test("Portal state is per-context (no global registry)")
    func portalScoped() {
        let a = makeApp()
        let b = makeApp()
        a.toggle.fire(); drain(a.graph)
        #expect(a.ctx.portals.count == 1)
        #expect(b.ctx.portals.count == 0) // unaffected by another tree
    }

    @Test("Reopen after close works (no stale entry blocks it)")
    func reopen() {
        let app = makeApp()
        app.toggle.fire(); drain(app.graph); #expect(app.ctx.portals.count == 1)
        app.toggle.fire(); drain(app.graph); #expect(app.ctx.portals.count == 0)
        app.toggle.fire(); drain(app.graph); #expect(app.ctx.portals.count == 1)
    }
}
