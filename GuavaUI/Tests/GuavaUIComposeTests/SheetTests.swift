import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Sheet edge motion", .serialized)
@MainActor
struct SheetTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private struct Harness: View {
        let edge: ModalPlacement
        @State var open = false
        var body: some View {
            LayerRoot {
                Button("Open sheet") { open = true }
                Sheet(isPresented: $open, configure: { $0.edge = edge; $0.extent = 200 }) {
                    Box(direction: .column, alignItems: .stretch) {
                        Text("Settings"); Spacer(); Button("Close") { open = false }
                    }.padding(16)
                }
            }
        }
    }

    @Test("All four edges place and animate the panel, close through Escape and restore focus")
    func edgeLifecycle() throws { try GlobalTestLock.locked {
        let prior = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = prior }
        for edge in [ModalPlacement.leading, .trailing, .top, .bottom] {
            let context = PlatformInputContext(), portal = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portal))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = Harness(edge: edge)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: harness); graph.computeLayout(width: 800, height: 600)
                let opener = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .button })
                context.focusChain.focus(opener, visible: true)
                harness.$open.wrappedValue = true
                func layout() { for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 600) } }
                layout()
                let panel = try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .dialog })
                let initial = panel.absoluteFrame
                switch edge {
                case .leading: #expect(initial.maxX <= 0.5)
                case .trailing: #expect(initial.minX >= 799.5)
                case .top: #expect(initial.maxY <= 0.5)
                case .bottom: #expect(initial.minY >= 599.5)
                case .center: Issue.record("unexpected centered sheet")
                }
                scheduler.tick(deltaTime: 1); layout()
                let frame = panel.absoluteFrame
                switch edge {
                case .leading: #expect(frame == CGRect(x: 0, y: 0, width: 200, height: 600))
                case .trailing: #expect(frame == CGRect(x: 600, y: 0, width: 200, height: 600))
                case .top: #expect(frame == CGRect(x: 0, y: 0, width: 800, height: 200))
                case .bottom: #expect(frame == CGRect(x: 0, y: 400, width: 800, height: 200))
                case .center: break
                }
                #expect(context.focusChain.hasModalScope && context.focusChain.focused !== opener)
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.escape, keycode: 0, modifiers: [], isRepeat: false)))
                layout(); #expect(!harness.open && !panel.acceptsSubtreeInput)
                scheduler.tick(deltaTime: 0.05)
                let leaving = panel.absoluteFrame
                switch edge {
                case .leading: #expect(leaving.minX < frame.minX)
                case .trailing: #expect(leaving.minX > frame.minX)
                case .top: #expect(leaving.minY < frame.minY)
                case .bottom: #expect(leaving.minY > frame.minY)
                case .center: break
                }
                scheduler.tick(deltaTime: 1); layout()
                #expect(portal.entries.isEmpty && !context.focusChain.hasModalScope)
                #expect(context.focusChain.focused === opener)
                graph.install(root: EmptyView())
            } }
        }
    } }
}
