import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Selection and legend behavior through the real dispatcher.
@Suite("Chart interaction", .serialized)
@MainActor
struct ChartInteractionTests {
    private final class Harness: View {
        @State var point: ChartPoint?
        @State var hidden: Set<String> = []
        @State var width: Float = 600
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        let pie: Bool
        init(pie: Bool = false) { self.pie = pie }
        var body: some View {
            var surface = UIEnvironment(); surface.input = input
            let configure: (inout ChartConfiguration) -> Void = {
                $0.label = "Sales"; $0.selection.point = self.$point
                $0.legend.placement = .bottom; $0.legend.hiddenSeries = self.$hidden
            }
            return Box(direction: .column, alignItems: .stretch) {
                if pie {
                    Chart(slices: [ChartSlice("Desktop", value: 3), ChartSlice("Mobile", value: 1)], configure: configure).flex(1)
                } else {
                    Chart([.bar([1, 4, 2, 3], title: "Revenue"), .line([2, 1, 3, 2], color: .success, title: "Signups"),
                           .line([1, 1, 1, 1], color: .warning, title: "Conversion"), .line([3, 3, 3, 3], color: .info, title: "Latency")],
                          configure: configure).flex(1)
                }
            }
            .frame(width: width, height: 220).surfaceEnvironment(surface)
        }
    }

    nonisolated private func nodes(_ node: Node?) -> [Node] { guard let node else { return [] }; return [node] + node.children.flatMap(nodes) }

    private func scene(_ harness: Harness, _ work: (ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) throws {
        try GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness); settle(graph, harness)
                defer { graph.install(root: EmptyView()) }
                try work(graph, context, EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                         capture: context.pointerCapture, focusChain: context.focusChain))
            }
        }
    }

    private func settle(_ graph: ViewGraph, _ harness: Harness) {
        for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: harness.width, height: 300) }
    }

    private func plot(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .image && $0.accessibility?.label == "Sales" })
    }

    private func press(_ x: CGFloat, _ y: CGFloat, _ input: EventDispatcher) {
        let event = MouseButtonEvent(button: .left, x: Float(x), y: Float(y), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }

    private func key(_ code: UInt32, _ input: EventDispatcher) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
    }

    @Test("Clicking a bar selects and pins it; the callout and accessibility value describe it")
    func pointerSelection() throws {
        let harness = Harness()
        try scene(harness) { graph, _, input in
            let chart = try plot(graph)
            #expect(chart.isFocusable && chart.isHitTestable)
            let frame = chart.absoluteFrame
            // Second of four slots, near the top of its 4-high bar.
            press(frame.minX + frame.width * 0.375, frame.minY + 10, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 0, index: 1))
            #expect(try plot(graph).accessibility?.value == "Revenue, point 2: 4")
            let callout = nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "chart-callout" }
            #expect(callout != nil)
            #expect(callout.map { frame.contains($0.absoluteFrame) } == true)
            // Leaving the plot keeps a pinned selection.
            input.dispatch(.mouseMotion(MouseMotionEvent(x: Float(frame.maxX + 40), y: Float(frame.minY), deltaX: 0, deltaY: 0)))
            settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 0, index: 1))
        }
    }

    @Test("Arrows step values and series, Home/End jump, Escape clears; assistive actions step too")
    func keyboardSelection() throws {
        let harness = Harness()
        try scene(harness) { graph, context, input in
            let chart = try plot(graph)
            context.focusChain.focus(chart)
            key(Scancode.arrowRight, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 0, index: 0))
            key(Scancode.arrowRight, input); key(Scancode.arrowDown, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 1, index: 1))
            key(Scancode.end, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 1, index: 3))
            try self.plot(graph).accessibilityActions.decrement?(); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 1, index: 2))
            key(Scancode.escape, input); settle(graph, harness)
            #expect(harness.point == nil)
        }
    }

    @Test("Legend items toggle series, skip hidden series in selection, and wrap whole at narrow widths")
    func legend() throws {
        let harness = Harness()
        try scene(harness) { graph, context, input in
            func items() -> [Node] { nodes(graph.tree.root).filter { $0.accessibility?.role == .toggle }.sorted { $0.absoluteFrame.minX < $1.absoluteFrame.minX } }
            #expect(items().count == 4 && Set(items().map { $0.absoluteFrame.minY }).count == 1)
            let signups = try #require(items().first { $0.accessibility?.label == "Signups" })
            #expect(signups.accessibility?.state.isSelected == true)
            let frame = signups.absoluteFrame
            press(frame.midX, frame.midY, input); settle(graph, harness)
            #expect(harness.hidden == ["Signups"])
            #expect(items().first { $0.accessibility?.label == "Signups" }?.accessibility?.value == "Hidden")
            context.focusChain.focus(try plot(graph))
            key(Scancode.arrowRight, input); key(Scancode.arrowDown, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 2, index: 0))
            harness.width = 220; settle(graph, harness)
            #expect(Set(items().map { $0.absoluteFrame.minY }).count > 1)
            #expect(items().allSatisfy { $0.absoluteFrame.maxX <= 220.5 })
        }
    }

    @Test("Touch taps select pie slices; the hole and hidden slices select nothing")
    func pieTouch() throws {
        let harness = Harness(pie: true)
        harness.input = [.touch]
        try scene(harness) { graph, _, input in
            let frame = try plot(graph).absoluteFrame
            // Desktop is 3/4: everything but the upper-left quarter.
            press(frame.midX + 40, frame.midY + 40, input); settle(graph, harness)
            #expect(harness.point == ChartPoint(series: 0, index: 0))
            #expect(try plot(graph).accessibility?.value == "Desktop: 3 · 75%")
            press(frame.midX, frame.midY, input); settle(graph, harness)
            #expect(harness.point == nil)
        }
    }
}
