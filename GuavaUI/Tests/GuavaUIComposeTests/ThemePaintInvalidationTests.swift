import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Theme paint invalidation", .serialized)
struct ThemePaintInvalidationTests: GuavaUIComposeSerializedSuite {
    private final class Harness: View {
        @State var dark = false
        var body: some View {
            Column {
                Text("Your workspace, at a glance").font(.headline)
                Tree([0], id: \.self, children: { _ in [] }) { _, _, _, _ in Text("Camera") }
                    .frame(height: 80)
                Text("Pinned theme").theme(.defaultLight)
            }.theme(dark ? .defaultDark : .defaultLight)
        }
    }

    @Test("Default heading and tree text repaint on theme changes without changing their text or layout")
    func themeUpdatesCachedPaint() throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            defer { graph.install(root: EmptyView()) }
            let harness = Harness(), renderer = LayerAwareNodeRenderer()
            graph.install(root: harness)
            func settle() { for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 300) } }
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            settle()
            let heading = try #require(all(graph.tree.root!).first { $0.layoutNode?.textInputs?.text == "Your workspace, at a glance" })
            let camera = try #require(all(graph.tree.root!).first { $0.layoutNode?.textInputs?.text == "Camera" })
            for dark in [false, true, false] {
                harness.dark = dark; settle()
                // Build and reuse retained layers, then compare actual glyph tints.
                for _ in 0..<2 {
                    let cached = DrawList(), direct = DrawList()
                    renderer.render(tree: graph.renderTree, into: cached)
                    NodeRenderer().render(root: graph.tree.root!, into: direct)
                    #expect(cached.vertices.map(\.color) == direct.vertices.map(\.color))
                }
                #expect(all(graph.tree.root!).contains { $0 === heading })
                #expect(all(graph.tree.root!).contains { $0 === camera })
                for node in [heading, camera] {
                    let glyphs = DrawList()
                    node.draw?(glyphs, .zero)
                    let expected = (dark ? Theme.defaultDark : .defaultLight).colors.onSurface.rgba8
                    #expect(!glyphs.vertices.isEmpty && glyphs.vertices.allSatisfy { $0.color == expected })
                }
            }
        }
    }
}
