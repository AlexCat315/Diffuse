import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Slider orientation", .serialized)
struct SliderAxisTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Vertical sliders use the Y axis, stay touch-sized and preserve value semantics")
    func vertical() throws {
        try GlobalTestLock.locked {
            for width: Float in [390, 720, 1280] {
                for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    let context = PlatformInputContext()
                    try context.withCurrent {
                        var value = 50.0
                        var environment = UIEnvironment()
                        environment.viewport.width = width
                        environment.input = input
                        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                        graph.install(root: Slider(value: Binding(get: { value }, set: { value = $0 }),
                            range: 0...100, step: 5, showsTicks: true, axis: .vertical)
                            .frame(height: 180).surfaceEnvironment(environment))
                        graph.computeLayout(width: width, height: 300)
                        let host = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .slider })
                        #expect(host.frame.height == 180)
                        #expect(host.frame.width >= (input.contains(.touch) ? 44 : 24))
                        let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                            capture: context.pointerCapture, focusChain: context.focusChain)
                        let frame = host.absoluteFrame
                        let x = Float(frame.midX), top = Float(frame.minY)
                        dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: x, y: top + 45, clicks: 1)))
                        #expect(value == 75)
                        dispatcher.dispatch(.mouseMotion(.init(x: x, y: top - 40, deltaX: 0, deltaY: -85)))
                        #expect(value == 100)
                        dispatcher.dispatch(.mouseMotion(.init(x: x, y: top + 220, deltaX: 0, deltaY: 260)))
                        #expect(value == 0)
                        dispatcher.dispatch(.mouseButtonUp(.init(button: .left, x: x, y: top + 220, clicks: 1)))
                        #expect(context.pointerCapture.target == nil)
                        context.focusChain.focus(host)
                        dispatcher.dispatch(.keyDown(.init(scancode: Scancode.arrowUp, keycode: 0, modifiers: [], isRepeat: false)))
                        #expect(value == 5)
                        host.accessibilityActions.setValue?("40")
                        #expect(value == 40)
                        host.accessibilityActions.increment?()
                        #expect(value == 45)
                        let draw = DrawList(); host.draw?(draw, .zero)
                        #expect(!draw.vertices.isEmpty)
                        graph.install(root: EmptyView())
                    }
                }
            }
        }
    }

    @Test("Horizontal RTL maps the leading edge to zero and reverses horizontal keys")
    func rtl() throws {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            try context.withCurrent {
                var value = 0.0
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: Slider(value: Binding(get: { value }, set: { value = $0 }), range: 0...100, step: 5)
                    .frame(width: 200).layoutDirection(.rtl))
                graph.computeLayout(width: 300, height: 200)
                let host = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .slider })
                let pointer = try #require(context.interactions.handlers(for: host).pointer)
                let frame = host.absoluteFrame
                _ = pointer(.init(button: .left, x: Float(frame.minX + 50), y: Float(frame.midY), clicks: 1), .down, .target)
                #expect(value == 75)
                let key = try #require(context.interactions.handlers(for: host).key)
                _ = key(.init(scancode: Scancode.arrowRight, keycode: 0, modifiers: [], isRepeat: false), .target)
                #expect(value == 70)
                graph.install(root: EmptyView())
            }
        }
    }
}
