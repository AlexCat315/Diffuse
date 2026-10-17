import Testing
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// A focus ring is an answer to "where did the keyboard go?", so it belongs to
/// keyboard focus only. Pointer focus still moves the keyboard target — the next
/// Tab has to continue from where you clicked — but it must not leave a ring
/// behind on a control the pointer just touched.
@Suite("Focus rings follow the keyboard", .serialized)
struct FocusRingTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func rings(in graph: ViewGraph) -> [Node] {
        nodes(graph.tree.root!).filter { $0.borderWidth > 0 }
    }

    private func withScene(_ root: any View, _ test: (ViewGraph, FocusChain, Node) -> Void) {
        GlobalTestLock.locked {
            let oldChain = FocusChainHolder.current
            let chain = FocusChain()
            FocusChainHolder.current = chain
            defer { FocusChainHolder.current = oldChain }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: root)
            graph.computeLayout(width: 320, height: 200)
            let target = nodes(graph.tree.root!).first { $0.isFocusable }!
            test(graph, chain, target)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    /// A ring-only style, the shape every custom list/tab/sidebar style uses.
    private struct RowStyle: ButtonStyle {
        func makeBody(configuration: ButtonStyleConfiguration) -> some View {
            AnyView(configuration.label)
                .border(configuration.isFocused ? configuration.theme.colors.focusRing : .clear,
                        width: configuration.isFocused ? 2 : 0)
        }
    }

    private var styled: some View {
        Button(action: {}) { Text("Destination") }.buttonStyle(RowStyle())
    }

    @Test("A pointer click focuses without ringing")
    func pointerFocusIsSilent() {
        withScene(styled) { graph, chain, target in
            chain.focus(target, visible: false)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 200)
            #expect(chain.focused === target)
            #expect(rings(in: graph).isEmpty)
        }
    }

    @Test("Keyboard focus rings, and the ring is dropped again on click")
    func keyboardFocusRings() {
        withScene(styled) { graph, chain, target in
            chain.focus(target, visible: true)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 200)
            let ring = rings(in: graph).first
            #expect(ring?.borderWidth == 2)
            #expect(ring?.borderColor == graph.tree.root!.theme.colors.focusRing)

            // Same node, pointer-acquired focus: routing stays, the ring goes.
            chain.focus(target, visible: false)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 200)
            #expect(chain.focused === target)
            #expect(rings(in: graph).isEmpty)
        }
    }

    @Test("Losing focus clears the ring")
    func blurClearsRing() {
        withScene(styled) { graph, chain, target in
            chain.focus(target, visible: true)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 200)
            #expect(!rings(in: graph).isEmpty)
            chain.focus(nil, visible: false)
            graph.recomposer.commitAll()
            graph.computeLayout(width: 320, height: 200)
            #expect(rings(in: graph).isEmpty)
        }
    }

    @Test("Custom-drawn toggle, slider and range slider ring only for keyboard focus")
    func customDrawnControlsFollowFocusVisibility() {
        let root = Box(direction: .column, alignItems: .flexStart, spacing: 12) {
            Toggle(isOn: .constant(false)).debugName("ring-toggle")
            Slider(value: .constant(0.4)).frame(width: 200).debugName("ring-slider")
            RangeSlider(values: .constant(20...80), in: 0...100)
                .frame(width: 200).debugName("ring-range")
        }.frame(width: 320, height: 260)
        withScene(root) { graph, chain, _ in
            let theme = graph.tree.root!.theme
            func node(_ name: String) -> Node? {
                nodes(graph.tree.root!).first {
                    $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
                }
            }
            func ringVertices(_ node: Node?) -> Int {
                guard let node else { return -1 }
                let list = DrawList()
                node.draw?(list, node.absoluteOrigin)
                return list.vertices.filter { $0.color == theme.colors.focusRing.rgba8 }.count
            }
            for name in ["ring-toggle", "ring-slider", "ring-range"] {
                let target = node(name)
                #expect(target != nil)
                guard let target else { continue }
                chain.focus(target, visible: false)
                #expect(ringVertices(target) == 0, "\(name) drew a pointer focus ring")
                chain.focus(target, visible: true)
                #expect(ringVertices(target) > 0, "\(name) did not draw a keyboard focus ring")
            }
        }
    }
}
