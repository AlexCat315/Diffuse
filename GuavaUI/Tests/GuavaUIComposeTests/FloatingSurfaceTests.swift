import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Floating panels have to *look* lifted. These tests pin the token, the one
/// modifier that assembles the material, and a real menu.
@Suite("Floating surfaces", .serialized)
struct FloatingSurfaceTests: GuavaUIComposeSerializedSuite {

    @Test("The floating token is two different layers, not one twice")
    @MainActor func tokenIsLayered() {
        let floating = Node().theme.elevation.floating
        // A halo that is wider, fainter and shallower than the contact shadow
        // under it. Identical layers would defeat the point of having two.
        #expect(floating.ambient.blur > floating.key.blur * 2)
        #expect(floating.ambient.color?.a ?? 0 < floating.key.color?.a ?? 1)
        #expect(floating.ambient.offsetY < floating.key.offsetY)
        #expect(floating.key.blur > 0)
    }

    @Test("A lifted node renders both shadow layers")
    @MainActor func geometryAfterModifier() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        node.cornerRadius = 6
        node.backgroundColor = Node().theme.colors.surfaceFloating
        FloatingSurfaceModifier(cornerRadius: 6).apply(node: node)

        let list = DrawList()
        NodeRenderer().render(root: node, into: list)

        // The halo is really there: one layer alone would be half the geometry.
        let shadowVertices = list.vertices.count
        let haloOnly = node
        haloOnly.shadow = .none
        let haloList = DrawList()
        NodeRenderer().render(root: haloOnly, into: haloList)
        #expect(haloList.vertices.count < shadowVertices)
    }

    /// The material is several properties that only work together. A menu once
    /// assembled the chain by hand and missed part of it, rendering as a plain
    /// card that looked finished in review; this pins every part.
    @Test("floatingSurface() asks for the whole material, not part of it")
    @MainActor func floatingSurfaceWiring() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        FloatingSurfaceModifier(cornerRadius: 7).apply(node: node)
        let theme = node.theme
        #expect(node.backgroundColor == theme.colors.surfaceFloating)
        // Solid: labels stay legible over anything, and no live sample of
        // what is behind the panel can show through as noise.
        #expect(node.backgroundColor?.a == 1)
        #expect(node.backdropBlur == 0)
        #expect(node.cornerRadius == 7)
        #expect(node.borderColor == theme.colors.floatingOutline)
        #expect(node.borderWidth == 1)
        #expect(node.ambientShadow == theme.elevation.floating.ambient)
        #expect(node.shadow == theme.elevation.floating.key)
    }

    @Test("Light panels keep a neutral hairline; dark ones use the palette border")
    func edgeTokens() {
        let light = Theme.defaultLight.colors, dark = Theme.defaultDark.colors
        #expect(light.floatingOutline != light.border && light.floatingOutline.a < 0.2)
        #expect(dark.floatingOutline == dark.border)
    }

    @Test("A menu panel is the floating material, like every other floating panel")
    @MainActor func menuPanelFloats() throws {
        try GlobalTestLock.locked {
            PortalStoreHolder.current.clear()
            defer { PortalStoreHolder.current.clear() }
            let prior = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = prior }
            let scheduler = AnimatorScheduler()
            try AnimatorScheduler.$current.withValue(scheduler) {
                let harness = MenuHarness()
                let tree = NodeTree()
                let graph = ViewGraph(tree: tree, recomposer: Recomposer())
                func settle() {
                    while graph.recomposer.commitAll() {}
                    graph.computeLayout(width: 400, height: 300)
                }
                graph.install(root: harness)
                settle()
                harness.$shown.wrappedValue = true
                settle()
                scheduler.tick(deltaTime: 1)
                settle()

                // The menu panel, not some inner row: it is the wide one.
                let panel = try #require(flatten(tree.root).first {
                    $0.backgroundColor != nil && $0.frame.width > 100
                })
                // Every floating panel is the same material; a menu that skipped
                // part of it would render as a plain card among floating ones.
                let theme = panel.theme
                #expect(panel.backgroundColor == theme.colors.surfaceFloating)
                #expect(panel.cornerRadius == theme.radius.md)
                #expect(panel.borderColor == theme.colors.floatingOutline)
                #expect(panel.ambientShadow == theme.elevation.floating.ambient)
                #expect(panel.shadow == theme.elevation.floating.key)
                // Nothing above the panel clips it: a portal clip cut the shadow
                // to the panel's box and left square shadow corners.
                var ancestor = panel.parent
                while let node = ancestor {
                    #expect(!node.clipsToBounds)
                    ancestor = node.parent
                }
            }
        }
    }

    private func flatten(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { flatten($0) }
    }
}

private struct MenuHarness: View {
    @State var shown = false
    var body: some View {
        LayerRoot {
            Popover(isPresented: $shown, width: 180, surface: .content, overflow: .flip) { Text("Open") } content: {
                Menu([.item(MenuItem(id: "one", title: "One") {}),
                      .item(MenuItem(id: "two", title: "Two") {})],
                     width: 180, maxVisibleRows: 4, onItemActivated: { shown = false })
            }
        }
    }
}


@Suite("Overflow-only clipping", .serialized)
struct OverflowClippingTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }

    @Test("A fallback scroller clips only while its content overflows")
    func clipsOnlyOverflow() {
        GlobalTestLock.locked {
            for (height, clips) in [(Float(40), false), (Float(400), true)] {
                var scroller = ScrollView(.vertical) { Box(direction: .column) {}.frame(height: height) }
                scroller.clipsOnlyOverflow = true
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: scroller.frame(height: 100))
                graph.computeLayout(width: 200, height: 300)
                let scroll = nodes(graph.tree.root!).first { $0.scrollReveal != nil }
                #expect(scroll?.clipsToBounds == clips)
                graph.install(root: EmptyView())
            }
        }
    }
}
