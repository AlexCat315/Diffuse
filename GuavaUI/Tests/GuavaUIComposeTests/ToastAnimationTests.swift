import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Toast transitions", .serialized)
@MainActor
struct ToastAnimationTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }
    private func opacity(_ node: Node) -> Float {
        node.opacity * (node.parent.map(opacity) ?? 1)
    }
    private func scene(reducedMotion: Bool = false,
                       _ body: (ViewGraph, ToastController, PlatformInputContext, AnimatorScheduler, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), store = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(store))
            try context.withCurrent {
                try AnimatorScheduler.$current.withValue(scheduler) {
                    let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                    let controller = ToastController(maxVisible: 1)
                    graph.install(root: LayerRoot { NotificationHost(controller) }
                        .frame(width: 720, height: 820).reducedMotion(reducedMotion))
                    defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1) }
                    try body(graph, controller, context, scheduler, store)
                }
            }
        }
    }
    private func frame(_ graph: ViewGraph, _ scheduler: AnimatorScheduler, delta: Double = 0) {
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 720, height: 820) }
        scheduler.tick(deltaTime: delta)
        for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 720, height: 820) }
    }

    @Test("Entry fades in, dismissal removes input immediately and releases the portal after exit")
    func lifecycle() throws {
        try scene { graph, controller, context, scheduler, store in
            controller.post(ToastNotification("Saved", id: "saved") { $0.duration = nil })
            frame(graph, scheduler)
            let title = try #require(nodes(graph.tree.root).first { $0.layoutNode?.textInputs?.text == "Saved" })
            #expect(opacity(title) == 0)
            frame(graph, scheduler, delta: 0.08)
            #expect(opacity(title) > 0 && opacity(title) < 1)
            frame(graph, scheduler, delta: 1)
            #expect(opacity(title) == 1)
            let dismiss = try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Dismiss notification" })
            context.focusChain.focus(dismiss)
            controller.dismiss("saved")
            frame(graph, scheduler)
            #expect(controller.notifications.isEmpty)
            #expect(!store.entries.isEmpty && !dismiss.acceptsSubtreeInput)
            #expect(context.focusChain.focused !== dismiss)
            frame(graph, scheduler, delta: 0.08)
            #expect(opacity(title) > 0 && opacity(title) < 1)
            frame(graph, scheduler, delta: 1)
            #expect(store.entries.isEmpty)
            #expect(!scheduler.hasActiveAnimations)
        }
    }

    @Test("Reduced motion snaps both directions and leaves no exit clocks")
    func reducedMotion() throws {
        try scene(reducedMotion: true) { graph, controller, _, scheduler, store in
            controller.post(ToastNotification("Saved", id: "saved") { $0.duration = nil })
            frame(graph, scheduler)
            let title = try #require(nodes(graph.tree.root).first { $0.layoutNode?.textInputs?.text == "Saved" })
            #expect(opacity(title) == 1 && !scheduler.hasActiveAnimations)
            controller.clear()
            frame(graph, scheduler)
            #expect(store.entries.isEmpty && !scheduler.hasActiveAnimations)
        }
    }

    @Test("Reposting during exit rejects stale completion and rapid changes keep a bounded tree")
    func replacement() {
        let presentation = ToastPresentation()
        let original = ToastNotification("First", id: "same")
        _ = presentation.update([original], limit: 2)
        let exit = presentation.update([], limit: 2)[0]
        _ = presentation.update([ToastNotification("Updated", id: "same")], limit: 2)
        presentation.remove(id: "same", revision: exit.revision)
        let live = presentation.update([ToastNotification("Updated", id: "same")], limit: 2)
        #expect(live.count == 1 && live[0].isVisible && live[0].notification.title == "Updated")
        for index in 0..<100 {
            let entries = presentation.update([ToastNotification("New", id: "\(index)")], limit: 2)
            #expect(entries.count <= 3)
        }
    }
}
