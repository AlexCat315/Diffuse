import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Wheel picker", .serialized)
@MainActor
struct WheelPickerTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var value = 1
        let options: [WheelPickerOption<Int>]
        var body: some View {
            WheelPicker(selection: $value, options: options, visibleRows: 5, label: "Level")
                .frame(width: 220, height: 220)
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap(nodes)
    }

    private func scene(_ options: [WheelPickerOption<Int>],
                       _ body: (Harness, ViewGraph, EventDispatcher, FocusChain) -> Void) {
        GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TextEnvironment.bootstrapped(
                atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
            defer { TextEnvironmentHolder.current = old }
            let context = PlatformInputContext()
            context.addScopedAmbient(PortalStoreAmbient(PortalStore()))
            context.withCurrent {
                let harness = Harness(options: options)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness)
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 300) }
                let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                            capture: context.pointerCapture, focusChain: context.focusChain)
                body(harness, graph, input, context.focusChain)
                graph.install(root: EmptyView())
            }
        }
    }

    private func wheel(_ graph: ViewGraph) -> Node {
        nodes(graph.tree.root).first {
            $0.accessibility?.role == .slider && $0.accessibility?.label == "Level"
        }!
    }

    private func settle(_ graph: ViewGraph) {
        graph.recomposer.commitAll()
        graph.computeLayout(width: 300, height: 300)
    }

    @Test("Keyboard, wheel, pointer drag and accessibility commit enabled values")
    func inputParity() {
        scene([0, 1, 2, 3, 4].map { WheelPickerOption($0, "Row \($0)") }) { h, graph, input, focus in
            let wheel = wheel(graph)
            #expect(wheel.accessibility?.value == "Row 1")
            #expect(abs(wheel.frame.height - 160) < 0.5)
            focus.focus(wheel)
            input.dispatch(.keyDown(.init(scancode: Scancode.arrowDown, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(h.value == 2)
            input.dispatch(.keyDown(.init(scancode: Scancode.home, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(h.value == 0)
            input.dispatch(.keyDown(.init(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(h.value == 4)

            let center = wheel.absoluteFrame
            input.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: 1,
                mouseX: Float(center.midX), mouseY: Float(center.midY))))
            settle(graph)
            #expect(h.value == 3)

            let start = CGPoint(x: center.midX, y: center.midY)
            let down = MouseButtonEvent(button: .left, x: Float(start.x), y: Float(start.y), clicks: 1)
            input.dispatch(.mouseButtonDown(down))
            input.dispatch(.mouseMotion(MouseMotionEvent(x: Float(start.x), y: Float(start.y - 36),
                                                        deltaX: 0, deltaY: -36)))
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: Float(start.x),
                                                          y: Float(start.y - 36), clicks: 1)))
            settle(graph)
            #expect(h.value == 4)

            wheel.accessibilityActions.decrement?()
            settle(graph)
            #expect(h.value == 3)
            wheel.accessibilityActions.increment?()
            settle(graph)
            #expect(h.value == 4)
        }
    }

    @Test("Steps skip disabled rows and never commit them")
    func disabledRows() {
        scene([
            WheelPickerOption(0, "Zero"),
            WheelPickerOption(1, "One"),
            WheelPickerOption(2, "Two", isEnabled: false),
            WheelPickerOption(3, "Three")
        ]) { h, graph, _, _ in
            let wheel = wheel(graph)
            wheel.accessibilityActions.increment?()
            settle(graph)
            #expect(h.value == 3)
            wheel.accessibilityActions.setValue?("Three")
            settle(graph)
            #expect(h.value == 3)
            wheel.accessibilityActions.setValue?("Two")
            settle(graph)
            #expect(h.value == 3)
        }
    }
}

@Suite("Wheel picker touch density", .serialized)
@MainActor
struct WheelPickerTouchTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var value = 2
        var body: some View {
            WheelPicker(selection: $value,
                        options: (0..<5).map { WheelPickerOption($0, "Row \($0)") },
                        visibleRows: 5, label: "Touch wheel")
                .surfaceEnvironment({ var environment = UIEnvironment(); environment.input = [.touch]; return environment }())
                .frame(width: 220, height: 260)
        }
    }

    @Test("Touch surfaces reserve 44pt per row")
    func touchRowHeight() {
        GlobalTestLock.locked {
            let old = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TextEnvironment.bootstrapped(
                atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
            defer { TextEnvironmentHolder.current = old }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Harness())
            for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 300, height: 300) }
            let wheel = all(graph.tree.root).first {
                $0.accessibility?.role == .slider && $0.accessibility?.label == "Touch wheel"
            }!
            #expect(abs(wheel.frame.height - 220) < 0.5)
            graph.install(root: EmptyView())
        }
    }

    private func all(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap(all)
    }
}

extension WheelPickerTests {
    @Test("Empty option sets expose no crash and no actions")
    func emptyOptions() {
        scene([]) { _, graph, _, _ in
            let wheel = wheel(graph)
            #expect(wheel.accessibility?.value == "")
            wheel.accessibilityActions.increment?()
            wheel.accessibilityActions.decrement?()
            #expect(wheel.accessibility?.value == "")
        }
    }
}
