import Foundation
import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Appearance reveal controls", .serialized)
struct AppearanceRevealTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var dark = false
        @State var reduced = false
        var body: some View {
            Box {
                Button("Theme") { self.dark.toggle() }
                    .frame(width: 90, height: 36).absolutePosition(left: 100, top: 70)
                Toggle(isOn: $dark).absolutePosition(left: 280, top: 120)
            }.frame(width: 640, height: 400)
                .appearance(dark ? .dark : .light, transition: .circular(duration: 0.4))
                .reducedMotion(reduced)
        }
    }

    @Test("Button and Switch reveals start at the control center and reverse without replaying old progress",
          arguments: [false, true])
    func controlOrigin(usesSwitch: Bool) throws {
        try scene { harness, graph, context, input, scheduler in
            let control = try #require(all(graph.tree.root!).first {
                usesSwitch ? $0.accessibility?.role == .toggle : $0.attachments[ButtonHost.markerKey] as? Bool == true
            })
            let frame = control.absoluteFrame
            let event = MouseButtonEvent(button: .left, x: Float(frame.minX + 3), y: Float(frame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event)); settle(graph)
            input.dispatch(.mouseButtonUp(event)); settle(graph)
            #expect(harness.dark)
            let first = try #require(record(graph).reveal)
            #expect(first.centerX == Float(frame.midX) && first.centerY == Float(frame.midY))
            #expect(first.radius == 0)
            scheduler.tick(deltaTime: 0.15); settle(graph)
            #expect(try #require(record(graph).reveal).radius > 0)
            context.focusChain.focus(control)
            input.dispatch(.keyDown(KeyEvent(scancode: Scancode.space, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            let reversal = try #require(record(graph).reveal)
            #expect(!harness.dark && reversal.sequence != first.sequence && reversal.radius == 0)
            #expect(reversal.centerX == Float(frame.midX) && reversal.centerY == Float(frame.midY))
            harness.reduced = true; settle(graph)
            #expect(record(graph).reveal == nil)
            scheduler.tick(deltaTime: 1)
            #expect(scheduler.activeCount == 0)
        }
    }

    @Test("Programmatic changes use the window center; completion and unmount clear requests")
    func programmaticLifecycle() throws {
        try scene { harness, graph, _, _, scheduler in
            harness.dark = true; settle(graph)
            let reveal = try #require(record(graph).reveal)
            #expect(reveal.centerX == 320 && reveal.centerY == 200)
            scheduler.tick(deltaTime: 0.5); settle(graph)
            #expect(record(graph).reveal == nil && scheduler.activeCount == 0)
            harness.dark = false; settle(graph)
            #expect(record(graph).reveal != nil)
            graph.install(root: EmptyView())
            #expect(scheduler.activeCount == 0)
        }
    }

    private func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
    private func record(_ graph: ViewGraph) -> DrawList {
        let list = DrawList()
        LayerAwareNodeRenderer().render(tree: graph.renderTree, into: list)
        return list
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 {
            graph.recomposer.commitAll()
            WindowRevealContext.clearActivation(in: graph.tree.root)
            graph.computeLayout(width: 640, height: 400)
        }
    }
    private func scene(_ body: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), scheduler = AnimatorScheduler()
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: harness); settle(graph)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try body(harness, graph, context, input, scheduler)
            } }
        }
    }
}
