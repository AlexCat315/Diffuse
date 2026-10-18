import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Time picker", .serialized)
@MainActor
struct TimePickerTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var time: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)
        let configure: (inout TimePickerOptions) -> Void
        var body: some View {
            TimePicker(selection: $time, configure: configure)
                .frame(width: 340, height: 220)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap(nodes)
    }

    private func scene(configure: @escaping (inout TimePickerOptions) -> Void,
                       _ body: (Harness, ViewGraph) -> Void) {
        GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TextEnvironment.bootstrapped(
                atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            context.addScopedAmbient(PortalStoreAmbient(PortalStore()))
            context.withCurrent {
                let harness = Harness(configure: configure)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 380, height: 300) }
                body(harness, graph)
                graph.install(root: EmptyView())
            }
        }
    }

    private func wheel(_ label: String, _ graph: ViewGraph) -> Node {
        nodes(graph.tree.root).first {
            $0.accessibility?.role == .slider && $0.accessibility?.label == label
        }!
    }

    private func settle(_ graph: ViewGraph) {
        graph.recomposer.commitAll()
        graph.computeLayout(width: 380, height: 300)
    }

    @Test("Hour, minute, AM/PM and accessibility actions commit a TimeOfDay")
    func twelveHour() {
        scene(configure: { $0.hourCycle = .twelve; $0.minuteStep = 5 }) { h, graph in
            let hour = wheel("Hour", graph), minute = wheel("Minute", graph), period = wheel("AM or PM", graph)
            hour.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 30))
            minute.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 35))
            period.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 22, minute: 35))
            period.accessibilityActions.decrement?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 35))
        }
    }

    @Test("24-hour mode, seconds and bounds clamp at commit")
    func twentyFourHourBounds() {
        scene(configure: {
            $0.hourCycle = .twentyFour; $0.showsSeconds = true; $0.minuteStep = 5
            $0.minimum = TimeOfDay(hour: 8)
            $0.maximum = TimeOfDay(hour: 10, minute: 45, second: 59)
        }) { h, graph in
            let hour = wheel("Hour", graph), second = wheel("Second", graph)
            hour.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 30))
            second.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 30, second: 1))
            hour.accessibilityActions.increment?(); settle(graph)
            #expect(h.time == TimeOfDay(hour: 10, minute: 45, second: 59))
        }
    }
}
