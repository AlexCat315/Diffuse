import Foundation
import Testing
import GuavaUIRuntime
import GuavaUICompose
@testable import GalleryContent

@Suite("Gallery appearance", .serialized)
@MainActor
struct GalleryAppearanceTests {
    @Test("Dashboard and Tree text update retained glyph colors on every appearance switch",
          arguments: [GalleryPage.introduction, .tree])
    func liveTextColors(page: GalleryPage) throws {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = .bootstrapped(atlasTextureID: 1, primaryFontName: SystemFontDefaults.primaryFontName)
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext(), scheduler = AnimatorScheduler()
        try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
            let gallery = GalleryView(initialPage: page)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer()), renderer = LayerAwareNodeRenderer()
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                capture: context.pointerCapture, focusChain: context.focusChain)
            graph.install(root: gallery)
            defer { graph.install(root: EmptyView()); scheduler.reset() }
            func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
            func settle() {
                for _ in 0..<4 { graph.recomposer.commitAll(); graph.computeLayout(width: 1280, height: 900) }
                scheduler.tick(deltaTime: 1)
                graph.recomposer.commitAll()
            }
            settle()
            let title = page == .tree ? "Camera" : "Your workspace, at a glance"
            let text = try #require(all(graph.tree.root!).first { $0.layoutNode?.textInputs?.text == title })
            for dark in [false, true, false, true] {
                if gallery.isDark != dark {
                    let toggle = try #require(all(graph.tree.root!).first {
                        $0.accessibility?.label == (dark ? "Switch to dark theme" : "Switch to light theme")
                    })
                    let frame = toggle.absoluteFrame
                    let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
                    input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
                    settle()
                }
                for _ in 0..<2 { renderer.render(tree: graph.renderTree, into: DrawList()) }
                let glyphs = try #require(graph.renderTree.renderObject(for: text)?.cachedLayerList)
                let expected = (dark ? Theme.defaultDark : .defaultLight).colors.onSurface.rgba8
                #expect(!glyphs.vertices.isEmpty && glyphs.vertices.allSatisfy { $0.color == expected })
                #expect(all(graph.tree.root!).contains { $0 === text })
                #expect(gallery.isDark == dark)
            }
        } }
    }
}
