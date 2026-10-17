import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Narrow reflow", .serialized)
struct NarrowReflowTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    private func key(_ code: UInt32) -> KeyEvent {
        KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false)
    }

    private func withLayout(width: Float, height: Float,
                            input: UIEnvironment.Input = [.pointer, .keyboard],
                            root: AnyView,
                            _ body: (ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            try context.withCurrent {
                var environment = UIEnvironment()
                environment.viewport.width = width
                environment.input = input
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                graph.install(root: root
                    .frame(width: .points(width), height: .points(height))
                    .surfaceEnvironment(environment))
                for _ in 0..<10 {
                    graph.recomposer.commitAll()
                    graph.computeLayout(width: width, height: height)
                }
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher)
            }
        }
    }

    private func buttons(_ graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root!).filter {
            $0.attachments[ButtonHost.markerKey] as? Bool == true && $0.acceptsSubtreeInput
        }
    }

    @Test("Stepper stacks on a narrow container and keeps the axis-aware keyboard path")
    func stepperReflow() throws {
        var selected: String? = "first"
        let steps = [
            StepperItem("first", "Account") { $0.status = .completed; $0.detail = "Profile saved" },
            StepperItem("second", "Details") { $0.detail = "Configure your workspace" },
            StepperItem("third", "Review") { $0.detail = "Ready to review" }
        ]
        let binding = Binding(get: { selected }, set: { selected = $0 })

        withLayout(width: 390, height: 600, input: [.touch, .keyboard], root: AnyView(Stepper(steps, selection: binding))) { graph, context, dispatcher in
            let items = buttons(graph)
            #expect(items.count == 3)
            #expect(items[1].absoluteFrame.minY >= items[0].absoluteFrame.maxY)
            #expect(items[2].absoluteFrame.minY >= items[1].absoluteFrame.maxY)
            #expect(items[1].frame.width >= 44 && items[1].frame.height >= 44)
            context.focusChain.focus(items[0])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "first")
            dispatcher.dispatch(.keyDown(key(Scancode.arrowDown)))
            #expect(selected == "second")
        }

        selected = "first"
        withLayout(width: 720, height: 600, input: [.touch, .keyboard], root: AnyView(Stepper(steps, selection: binding))) { graph, context, dispatcher in
            let items = buttons(graph)
            #expect(items.count == 3)
            #expect(abs(items[0].absoluteFrame.minY - items[1].absoluteFrame.minY) < 0.5)
            #expect(abs(items[1].absoluteFrame.minY - items[2].absoluteFrame.minY) < 0.5)
            context.focusChain.focus(items[0])
            dispatcher.dispatch(.keyDown(key(Scancode.arrowDown)))
            #expect(selected == "first")
            dispatcher.dispatch(.keyDown(key(Scancode.arrowRight)))
            #expect(selected == "second")
        }
    }

    @Test("ButtonGroup wraps segments instead of shrinking them")
    func buttonGroupReflow() throws {
        let items = [
            ButtonGroupItem(0, "Grid view"), ButtonGroupItem(1, "List view"),
            ButtonGroupItem(2, "Timeline"), ButtonGroupItem(3, "Inspector"),
            ButtonGroupItem(4, "Materials")
        ]
        withLayout(width: 220, height: 400, input: [.touch, .keyboard],
                       root: AnyView(ButtonGroup(items, selection: .constant(0)))) { graph, _, _ in
            let segments = buttons(graph)
            #expect(segments.count == 5)
            #expect(Set(segments.map { Int($0.absoluteFrame.minY.rounded()) }).count >= 2)
            #expect(segments.allSatisfy { $0.frame.height >= 44 && $0.frame.width >= 44 })
        }
        withLayout(width: 720, height: 400, input: [.touch, .keyboard],
                       root: AnyView(ButtonGroup(items, selection: .constant(0)))) { graph, _, _ in
            let segments = buttons(graph)
            #expect(segments.count == 5)
            #expect(Set(segments.map { Int($0.absoluteFrame.minY.rounded()) }).count == 1)
        }
    }

    @Test("Vec3Field wraps X/Y before Z and never shrinks a cell below its editing width")
    func vec3Reflow() throws {
        var x: Float = 1, y: Float = 2, z: Float = 3
        let field = AnyView(Vec3Field(
            x: Binding(get: { x }, set: { x = $0 }),
            y: Binding(get: { y }, set: { y = $0 }),
            z: Binding(get: { z }, set: { z = $0 })))

        withLayout(width: 220, height: 200, root: field) { graph, _, _ in
            let labels = nodes(graph.tree.root!).filter {
                $0.accessibility?.role == .staticText && ["X", "Y", "Z"].contains($0.accessibility?.label ?? "")
            }
            #expect(labels.count == 3)
            guard labels.count == 3 else { return }
            #expect(abs(labels[0].absoluteFrame.minY - labels[1].absoluteFrame.minY) < 0.5)
            #expect(labels[2].absoluteFrame.minY >= labels[0].absoluteFrame.maxY)
        }

        withLayout(width: 420, height: 200, root: field) { graph, _, _ in
            let labels = nodes(graph.tree.root!).filter {
                $0.accessibility?.role == .staticText && ["X", "Y", "Z"].contains($0.accessibility?.label ?? "")
            }
            #expect(labels.count == 3)
            guard labels.count == 3 else { return }
            #expect(abs(labels[0].absoluteFrame.minY - labels[1].absoluteFrame.minY) < 0.5)
            #expect(abs(labels[1].absoluteFrame.minY - labels[2].absoluteFrame.minY) < 0.5)
            #expect(labels[0].absoluteFrame.maxX <= labels[1].absoluteFrame.minX)
            #expect(labels[1].absoluteFrame.maxX <= labels[2].absoluteFrame.minX)
        }
    }
}
