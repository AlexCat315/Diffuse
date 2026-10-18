import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Calendar narrow surfaces", .serialized)
struct CalendarAdaptiveTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Narrow calendars scroll whole months while keeping 44pt cells and a clear scrollbar lane")
    func narrow() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            for range in [false, true] {
                for width: Float in [200, 286, 390, 720, 1280] {
                    for scale: Float in [1, 2] {
                        let context = PlatformInputContext()
                        try context.withCurrent {
                            var surface = UIEnvironment(); surface.viewport.width = width; surface.input = [.touch, .keyboard]
                            var selected: Date?
                            let calendar: AnyView = range
                                ? AnyView(DateRangeCalendar(selection: .constant(nil)))
                                : AnyView(CalendarView(selection: Binding(get: { selected }, set: { selected = $0 })))
                            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                            graph.install(root: calendar.frame(width: .points(width)).surfaceEnvironment(surface).textScaler(.init(scale)))
                            for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: 600) }
                            let all = nodes(graph.tree.root!)
                            let scroll = try #require(all.first { $0.accessibility?.role == .scrollArea })
                            let days = all.filter { $0.attachments["calendar.day"] != nil }
                            #expect(days.count == 42)
                            #expect(days.allSatisfy { $0.frame.width >= 44 && $0.frame.height >= 44 })
                            #expect(scroll.frame.width == CGFloat(width))
                            #expect((days.map { $0.absoluteFrame.maxY }.max() ?? 0) <= scroll.absoluteFrame.maxY - 12)
                            if width < 340 {
                                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                    capture: context.pointerCapture, focusChain: context.focusChain)
                                let start = try #require(days.first { $0.isFocusable && $0.absoluteFrame.midX < scroll.absoluteFrame.maxX && $0.absoluteFrame.midX > scroll.absoluteFrame.minX + 100 })
                                let x = Float(start.absoluteFrame.midX), y = Float(start.absoluteFrame.midY)
                                dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: x, y: y, clicks: 1)))
                                dispatcher.dispatch(.mouseMotion(.init(x: x - 50, y: y, deltaX: -50, deltaY: 0)))
                                dispatcher.dispatch(.mouseMotion(.init(x: x - 100, y: y, deltaX: -50, deltaY: 0)))
                                #expect(scroll.contentOffset.x > 0)
                                dispatcher.dispatch(.mouseButtonUp(.init(button: .left, x: x - 100, y: y, clicks: 1)))
                                #expect(selected == nil)
                            }
                            for node in all { #expect(node.frame.width.isFinite && node.frame.height.isFinite) }
                            graph.install(root: EmptyView())
                        }
                    }
                }
            }
        }
    }
}
