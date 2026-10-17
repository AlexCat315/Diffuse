import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Date range picker", .serialized)
struct DateRangePickerTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let oldText = TextEnvironmentHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
                TextEnvironmentHolder.current = oldText
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func day(_ day: Int, in graph: ViewGraph) throws -> Node {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try #require(nodes(graph.tree.root).first {
            guard let date = $0.attachments["calendar.day"] as? Date else { return false }
            return calendar.component(.day, from: date) == day
        })
    }

    private func click(_ node: Node, graph: ViewGraph, registry: InteractionRegistry,
                       focus: FocusChain, capture: PointerCapture) {
        let frame = node.absoluteFrame
        let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                         capture: capture, focusChain: focus)
        let point = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(point))
        graph.recomposer.commitAll()
        dispatcher.dispatch(.mouseButtonUp(point))
        graph.recomposer.commitAll()
    }

    @Test("Two clicks select a range; clicking before the start swaps the bounds")
    func selectsAndSwaps() {
        withScene { graph, registry, focus, capture in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            calendar.firstWeekday = 1
            var components = DateComponents()
            components.year = 2026; components.month = 10; components.day = 1
            let today = calendar.date(from: components)!
            var month = today
            var selection: ClosedRange<Date>?
            graph.install(root: DateRangeCalendar(selection: Binding(get: { selection }, set: { selection = $0 })) {
                $0.calendar = calendar
                $0.locale = Locale(identifier: "en_US_POSIX")
                $0.today = today
                $0.visibleMonth = Binding(get: { month }, set: { month = $0 })
            }.frame(width: 420, height: 520))
            graph.computeLayout(width: 500, height: 600)
            guard let tenth = try? day(10, in: graph), let fifteenth = try? day(15, in: graph),
                  let twentieth = try? day(20, in: graph), let twelfth = try? day(12, in: graph) else {
                Issue.record("calendar days were not mounted")
                return
            }
            click(tenth, graph: graph, registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            click(fifteenth, graph: graph, registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection.map { calendar.component(.day, from: $0.lowerBound) } == 10)
            #expect(selection.map { calendar.component(.day, from: $0.upperBound) } == 15)

            click(twentieth, graph: graph, registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            click(twelfth, graph: graph, registry: registry, focus: focus, capture: capture)
            graph.recomposer.commitAll()
            #expect(selection.map { calendar.component(.day, from: $0.lowerBound) } == 12)
            #expect(selection.map { calendar.component(.day, from: $0.upperBound) } == 20)
        }
    }
}
