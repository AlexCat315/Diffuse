import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Drag and drop", .serialized)
struct DragAndDropTests: GuavaUIComposeSerializedSuite {
    private final class Model {
        var dropped: [Int] = []
        var strings: [String] = []
        var highlights: [Bool] = []
    }

    private struct Harness: View {
        let model: Model

        var body: some View {
            LayerRoot {
                DragScope {
                    Column(alignment: .leading, spacing: 16) {
                        Draggable(42, preview: { Text("42") }) {
                            Text("Drag me").frame(width: 120, height: 36)
                        }
                        DropTarget(onTargeted: { model.highlights.append($0) },
                                        onDrop: { model.dropped.append($0) }) {
                            Text("Drop here").frame(width: 160, height: 80)
                        }
                        .debugName("int-target")
                        DropTarget(onDrop: { model.strings.append($0) }) {
                            Text("Text only").frame(width: 160, height: 40)
                        }
                    }
                }
                .frame(width: 320, height: 320)
            }
        }
    }

    private func nodes(_ root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<6 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 360, height: 360)
            AnimatorScheduler.current.tick(deltaTime: 0.05)
        }
    }

    private func withScene(_ body: (ViewGraph, PlatformInputContext, EventDispatcher, Harness) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let context = PlatformInputContext()
            let portal = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(portal))
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            try context.withCurrent {
                let model = Model()
                let harness = Harness(model: model)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                                                 capture: context.pointerCapture,
                                                 focusChain: context.focusChain)
                graph.install(root: harness)
                settle(graph)
                defer { graph.install(root: EmptyView()) }
                try body(graph, context, dispatcher, harness)
            }
        }
    }

    private func frame(named name: String, _ graph: ViewGraph) throws -> CGRect {
        let node = try #require(nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
        return node.absoluteFrame
    }

    private func drag(_ dispatcher: EventDispatcher, from: CGPoint, to: CGPoint) {
        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
            button: .left, x: Float(from.x), y: Float(from.y), clicks: 1)))
        // Cross the six-point threshold while still inside the source, then
        // jump to the target as a captured drag.
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
            x: Float(from.x + 4), y: Float(from.y + 4), deltaX: 4, deltaY: 4)))
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
            x: Float(from.x + 8), y: Float(from.y + 8), deltaX: 4, deltaY: 4)))
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
            x: Float(to.x), y: Float(to.y), deltaX: Float(to.x - from.x), deltaY: Float(to.y - from.y))))
        dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
            button: .left, x: Float(to.x), y: Float(to.y), clicks: 1)))
    }

    @Test("A typed payload drops once on a matching target")
    func drop() throws {
        try withScene { graph, context, dispatcher, harness in
            let target = try frame(named: "int-target", graph)
            let source = try #require(nodes(graph.tree.root!).first {
                $0.accessibility?.label == "Drag me"
            }).absoluteFrame
            drag(dispatcher, from: CGPoint(x: source.midX, y: source.midY),
                 to: CGPoint(x: target.midX, y: target.midY))
            settle(graph)
            #expect(harness.model.dropped == [42])
            #expect(harness.model.strings.isEmpty)
            #expect(context.pointerCapture.target == nil)
            #expect(harness.model.highlights.contains(true))
            #expect(harness.model.highlights.last == false)
        }
    }

    @Test("Releasing outside every target cancels without a drop")
    func cancel() throws {
        try withScene { graph, _, dispatcher, harness in
            let source = try #require(nodes(graph.tree.root!).first {
                $0.accessibility?.label == "Drag me"
            }).absoluteFrame
            drag(dispatcher, from: CGPoint(x: source.midX, y: source.midY),
                 to: CGPoint(x: 350, y: 350))
            settle(graph)
            #expect(harness.model.dropped.isEmpty)
            #expect(harness.model.highlights.isEmpty || harness.model.highlights == [false])
        }
    }

    @Test("The preview uses the portal only while dragging")
    func preview() throws {
        try withScene { graph, _, dispatcher, _ in
            let source = try #require(nodes(graph.tree.root!).first {
                $0.accessibility?.label == "Drag me"
            }).absoluteFrame
            dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(
                button: .left, x: Float(source.midX), y: Float(source.midY), clicks: 1)))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(source.midX + 4), y: Float(source.midY + 4), deltaX: 4, deltaY: 4)))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(
                x: Float(source.midX + 8), y: Float(source.midY + 8), deltaX: 4, deltaY: 4)))
            settle(graph)
            #expect(PortalStoreHolder.current.entries.count == 1)
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(
                button: .left, x: Float(source.midX + 40), y: Float(source.midY + 40), clicks: 1)))
            settle(graph)
            #expect(PortalStoreHolder.current.entries.isEmpty)
        }
    }
}
