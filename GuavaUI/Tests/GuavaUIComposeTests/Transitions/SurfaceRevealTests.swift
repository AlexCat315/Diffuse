public import Foundation
public import Testing
public import GuavaUIRuntime
@testable public import GuavaUICompose

@Suite("Floating surface scale reveal", .serialized)
struct SurfaceRevealTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var shown = false
        var actions = 0
        let trailing: Bool
        let reducedMotion: Bool
        init(trailing: Bool, reducedMotion: Bool) { self.trailing = trailing; self.reducedMotion = reducedMotion }
        var body: some View {
            LayerRoot {
                Popover(isPresented: $shown, width: 180, placement: trailing ? .end : .start) {
                    Text("Open")
                } content: {
                    Menu([.item(MenuItem(id: "command", title: "Command") { self.actions += 1 })],
                         width: 180, onItemActivated: { self.shown = false })
                }.frame(width: 80, height: 40).absolutePosition(left: 200, top: 80)
            }.reducedMotion(reducedMotion)
        }
    }

    @Test("A menu uses its trigger corner, accepts pointer input while growing and tears down after exit",
          arguments: [false, true], [false, true])
    func menuReveal(trailing: Bool, reducedMotion: Bool) throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portal))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1) }
                let harness = Harness(trailing: trailing, reducedMotion: reducedMotion)
                graph.install(root: harness)
                func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 400) } }
                settle(); harness.$shown.wrappedValue = true; settle()
                var reveal: Node?, row: Node?
                for node in descendants(graph.tree.root!) {
                    if !node.transform.isIdentity { reveal = node }
                    if node.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("command") { row = node }
                }
                if reducedMotion {
                    #expect(reveal == nil && scheduler.activeCount == 0)
                } else {
                    let host = try #require(reveal)
                    #expect(abs(host.transform.scale - 0.96) < 0.0001)
                    #expect(host.transform.anchor == CGPoint(x: trailing ? 1 : 0, y: 0))
                    #expect(!host.transform.scalesShadow)
                    scheduler.tick(deltaTime: 0.08); settle()
                    #expect(host.transform.scale > 0.96 && host.transform.scale < 1)
                    #expect(host.transform.anchor == CGPoint(x: trailing ? 1 : 0, y: 0))
                }
                let command = try #require(row)
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                let frame = command.absoluteFrame
                let click = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(click)); settle()
                dispatcher.dispatch(.mouseButtonUp(click)); settle()
                #expect(harness.actions == 1 && !harness.shown)
                if reducedMotion { #expect(!descendants(graph.tree.root!).contains { $0 === command }) }
                else { #expect(!command.acceptsSubtreeInput) }
                scheduler.tick(deltaTime: 1); settle()
                #expect(portal.entries.isEmpty && scheduler.activeCount == 0)
            } }
        }
    }

    private func descendants(_ node: Node) -> [Node] { [node] + node.children.flatMap(descendants) }

    @Test("A context menu grows from the pointer and accepts a command during entry")
    func contextMenuReveal() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portal))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1) }
                var actions = 0
                graph.install(root: LayerRoot {
                    ContextMenu(width: 180, entries: {
                        [.item(MenuItem(id: "command", title: "Command") { actions += 1 })]
                    }) { Box {}.frame(width: 100, height: 60) }
                        .absolutePosition(left: 80, top: 40)
                })
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 400) } }
                settle()
                let click = MouseButtonEvent(button: .right, x: 100, y: 60, clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(click)); settle()
                dispatcher.dispatch(.mouseButtonUp(click)); settle()
                var reveal: Node?, row: Node?
                for node in descendants(graph.tree.root!) {
                    if !node.transform.isIdentity { reveal = node }
                    if node.attachments["__menu_item_id"] as? AnyHashable == AnyHashable("command") { row = node }
                }
                let host = try #require(reveal), command = try #require(row)
                #expect(abs(host.transform.scale - 0.96) < 0.0001 && host.transform.anchor == .zero)
                #expect(!host.transform.scalesShadow)
                scheduler.tick(deltaTime: 0.08); settle()
                let frame = command.absoluteFrame
                let activate = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(activate)); settle()
                dispatcher.dispatch(.mouseButtonUp(activate)); settle()
                #expect(actions == 1 && !command.acceptsSubtreeInput)
                scheduler.tick(deltaTime: 1); settle()
                #expect(portal.entries.isEmpty && scheduler.activeCount == 0)
            } }
        }
    }
}
