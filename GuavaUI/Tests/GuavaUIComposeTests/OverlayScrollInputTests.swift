import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Overlay and background scroll input", .serialized)
@MainActor
struct OverlayScrollInputTests: GuavaUIComposeSerializedSuite {
    private struct Harness: View {
        @State var presented = false
        @State var selections = 0
        @State var clears = 0
        var body: some View {
            ScrollView(.vertical) {
                Column(spacing: 12) {
                    Popover(isPresented: $presented, width: 220, surface: .content) {
                        Text("Choose")
                    } content: {
                        Menu([.item(MenuItem(id: "choice", title: "Select resource") {
                            selections += 1; presented = false
                        })], width: 220)
                    }
                    Box {}.frame(height: 220)
                    Button("Clear") { clears += 1 }.accessibilityLabel("Clear")
                    Text("Background content").frame(height: 900)
                }
            }.frame(width: 320, height: 600)
        }
    }

    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Selecting a portal menu leaves the next touch click and background scroll intact")
    func nextTouch() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), store = PortalStore()
            context.addScopedAmbient(PortalStoreAmbient(store))
            try context.withCurrent {
                var surface = UIEnvironment(); surface.viewport.width = 390; surface.viewport.height = 820
                surface.input = [.touch, .keyboard]
                let harness = Harness(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: LayerRoot { harness }.surfaceEnvironment(surface).reducedMotion())
                defer { graph.install(root: EmptyView()) }
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                func settle() { for _ in 0..<6 { graph.recomposer.commitAll(); graph.computeLayout(width: 390, height: 820) } }
                func click(_ node: Node) {
                    let x = Float(node.absoluteFrame.midX), y = Float(node.absoluteFrame.midY)
                    dispatcher.dispatch(.mouseMotion(.init(x: x, y: y, deltaX: 0, deltaY: 0)))
                    dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: x, y: y, clicks: 1)))
                    dispatcher.dispatch(.mouseButtonUp(.init(button: .left, x: x, y: y, clicks: 1)))
                    settle()
                }
                settle()
                let scroll = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .scrollArea })
                harness.presented = true; settle()
                let option = try #require(nodes(graph.tree.root!).first { $0.accessibility?.label == "Select resource" })
                #expect(scroll.absoluteFrame.contains(CGPoint(x: option.absoluteFrame.midX, y: option.absoluteFrame.midY)))
                click(option)
                #expect(harness.selections == 1 && !harness.presented)
                dispatcher.dispatch(.mouseMotion(.init(x: Float(option.absoluteFrame.midX), y: 500, deltaX: 0, deltaY: 400)))
                #expect(scroll.contentOffset == .zero)
                #expect(context.pointerCapture.target == nil)
                let clear = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .button && $0.accessibility?.label == "Clear" })
                click(clear)
                #expect(harness.clears == 1)
                #expect(scroll.contentOffset == .zero)
                #expect(context.pointerCapture.target == nil)
            }
        }
    }
}
