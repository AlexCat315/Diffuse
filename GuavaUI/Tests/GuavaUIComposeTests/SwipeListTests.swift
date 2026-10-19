import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Swipe list", .serialized)
struct SwipeListTests: GuavaUIComposeSerializedSuite {
    private final class Model {
        var actions: [String] = []
    }

    private struct Harness: View {
        let model: Model
        @State var selection: Int? = 0

        var body: some View {
            LayerRoot {
                SwipeList(0..<12, id: \.self, selection: $selection,
                          rowLabel: { "Item \($0 + 1)" },
                          actions: { index in
                    [
                        SwipeAction(id: "archive-\(index)", title: "Archive") {
                            model.actions.append("archive-\(index)")
                        },
                        SwipeAction(id: "delete-\(index)", title: "Delete", tone: .danger) {
                            model.actions.append("delete-\(index)")
                        }
                    ]
                }) { index, _ in
                    Text("Item \(index + 1)")
                }
                .frame(width: 320, height: 400)
            }
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<12 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 460)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func row(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first {
            $0.accessibility?.role == .listItem && $0.accessibility?.label == label
        })
    }

    private func button(_ label: String, _ graph: ViewGraph) -> Node? {
        nodes(graph.tree.root!).first {
            $0.accessibility?.role == .button && $0.accessibility?.label == label
        }
    }

    private func withScene(input: UIEnvironment.Input = [.touch, .keyboard],
                          direction: Direction = .ltr,
                          textScale: Float = 1,
                          _ body: (ViewGraph, PlatformInputContext, EventDispatcher, Harness) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            let previousText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previousText }
            try context.withCurrent {
                var environment = UIEnvironment()
                environment.viewport.width = 360
                environment.input = input
                let model = Model()
                let harness = Harness(model: model)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                graph.install(root: harness.surfaceEnvironment(environment).layoutDirection(direction).textScaler(.init(textScale)))
                settle(graph)
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher, harness)
            }
        }
    }

    private func swipe(_ row: Node, _ dispatcher: EventDispatcher, by dx: Float) {
        let start = row.absoluteFrame
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
            button: .left, x: Float(start.midX), y: Float(start.midY), clicks: 1)))
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
            x: Float(start.midX) + dx, y: Float(start.midY), deltaX: dx, deltaY: 0)))
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
            button: .left, x: Float(start.midX) + dx, y: Float(start.midY), clicks: 1)))
    }

    @Test("A left swipe reveals touch-sized actions and runs the tapped one")
    func swipeAction() throws {
        try withScene { graph, context, dispatcher, harness in
            let first = try row("Item 1", graph)
            #expect(first.frame.height >= 44)
            #expect(first.frame.width >= 300, "row width \(first.frame.width)")
            swipe(first, dispatcher, by: -140)
            settle(graph)
            let archive = try #require(button("Archive", graph))
            #expect(archive.frame.height >= 44)
            #expect(context.pointerCapture.target == nil)
            archive.accessibilityActions.activate?()
            settle(graph)
            #expect(harness.model.actions == ["archive-0"])
        }
    }

    @Test("Trailing actions mirror their gesture and placement; Escape closes from an action", arguments: [false, true], [Float(1), Float(2)])
    func mirroredActions(_ rtl: Bool, _ scale: Float) throws {
        let direction: Direction = rtl ? .rtl : .ltr
        try withScene(direction: direction, textScale: scale) { graph, context, dispatcher, harness in
            let first = try row("Item 1", graph)
            let bounds = first.absoluteFrame
            let scroll = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .scrollArea })
            // Touch-only rows span the viewport; the indicator overlays them.
            #expect(abs(first.frame.width - scroll.frame.width) < 0.5)
            #expect(bounds.minX >= scroll.absoluteFrame.minX - 0.5)
            #expect(bounds.maxX <= scroll.absoluteFrame.maxX + 0.5)
            let delta: Float = direction == .rtl ? 140 : -140
            swipe(first, dispatcher, by: -delta)
            settle(graph)
            #expect(button("Archive", graph) == nil)
            swipe(first, dispatcher, by: delta)
            settle(graph)
            let archive = try #require(button("Archive", graph))
            let delete = try #require(button("Delete", graph))
            #expect(context.pointerCapture.target == nil)
            let extent = min(CGFloat(74 * scale), bounds.width / 2)
            #expect(archive.frame.height >= 44 && archive.frame.width == extent)
            if direction == .rtl {
                #expect(archive.absoluteFrame.maxX == bounds.minX + extent * 2)
                #expect(delete.absoluteFrame.minX < archive.absoluteFrame.minX)
            } else {
                #expect(archive.absoluteFrame.minX == bounds.maxX - extent * 2)
                #expect(delete.absoluteFrame.minX > archive.absoluteFrame.minX)
            }
            context.focusChain.focus(archive)
            dispatcher.dispatch(.keyDown(.init(scancode: Scancode.escape, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            #expect(button("Archive", graph) == nil && harness.model.actions.isEmpty)
            let toggle = try #require(button("Actions for Item 1", graph))
            toggle.accessibilityActions.activate?(); settle(graph)
            let action = try #require(button("Archive", graph))
            action.accessibilityActions.activate?(); settle(graph)
            #expect(harness.model.actions == ["archive-0"])
        }
    }

    @Test("The row actions button expands the non-swipe path")
    func actionsMenu() throws {
        try withScene { graph, _, dispatcher, harness in
            let toggle = try #require(button("Actions for Item 2", graph))
            let frame = toggle.absoluteFrame
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
            settle(graph)
            let delete = try #require(button("Delete", graph))
            delete.accessibilityActions.activate?()
            settle(graph)
            #expect(harness.model.actions == ["delete-1"])
        }
    }

    @Test("A vertical drag scrolls instead of revealing actions")
    func verticalDrag() throws {
        try withScene { graph, _, dispatcher, _ in
            let first = try row("Item 4", graph)
            let scroll = try #require(nodes(graph.tree.root!).first {
                $0.attachments[ScrollReveal.handlerKey] != nil
            })
            let start = first.absoluteFrame
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(start.midX), y: Float(start.midY), clicks: 1)))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(start.midX), y: Float(start.midY) - 90, deltaX: 0, deltaY: -90)))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(start.midX), y: Float(start.midY) - 90, clicks: 1)))
            settle(graph)
            #expect(button("Archive", graph) == nil)
            #expect(scroll.contentOffset.y > 0)
        }
    }

    @Test("Disabled rows expose no swipe actions or actions button")
    func disabled() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            var selection: Int? = 0
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot {
                SwipeList(0..<4, id: \.self,
                          selection: Binding(get: { selection }, set: { selection = $0 }),
                          isEnabled: false, rowLabel: { "Item \($0 + 1)" },
                          actions: { _ in [SwipeAction(title: "Archive") {}] }) { index, _ in
                    Text("Item \(index + 1)")
                }.frame(width: 320, height: 300)
            })
            settle(graph)
            #expect(button("Archive", graph) == nil)
            #expect(button("Actions for Item 1", graph) == nil)
        }
    }

    @Test("Pointer surfaces reveal through the row button, not a swipe")
    func pointerDoesNotSwipe() throws {
        try withScene(input: [.pointer, .keyboard]) { graph, _, dispatcher, _ in
            let first = try row("Item 1", graph)
            swipe(first, dispatcher, by: -140)
            settle(graph)
            #expect(button("Archive", graph) == nil)
            let toggle = try #require(button("Actions for Item 1", graph))
            let frame = toggle.absoluteFrame
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)))
            settle(graph)
            #expect(button("Archive", graph) != nil)
            #expect(button("Delete", graph) != nil)
        }
    }
}
