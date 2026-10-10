import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Floating panels have to *look* lifted: a layered shadow plus a rim light.
/// These tests pin the token, the modifier that reads it, and one real menu.
@Suite("Floating surfaces", .serialized)
struct FloatingSurfaceTests: GuavaUIComposeSerializedSuite {

    @Test("floatingSurface() lifts the node with the theme's two layers")
    @MainActor func modifierWiring() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        FloatingSurfaceModifier().apply(node: node)

        let theme = node.theme
        #expect(node.ambientShadow == theme.elevation.floating.ambient)
        #expect(node.shadow == theme.elevation.floating.key)
        #expect(node.highlight.color == theme.colors.edgeHighlight)
    }

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

    @Test("A lifted node renders both layers and then the rim")
    @MainActor func geometryAfterModifier() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        node.cornerRadius = 6
        node.backgroundColor = Node().theme.colors.surfaceFloating
        FloatingSurfaceModifier().apply(node: node)

        let list = DrawList()
        NodeRenderer().render(root: node, into: list)

        // Shadow layers come first, the rim last — so nothing inside the panel
        // can paint over the edge.
        let rim = list.vertices.suffix(4)
        #expect(rim.first?.posX == 6)
        #expect(rim.first?.posY == 0)
        // And the halo really is there: one layer alone would be half the
        // shadow geometry.
        let shadowVertices = list.vertices.count - 4
        let haloOnly = node
        haloOnly.shadow = .none
        let haloList = DrawList()
        NodeRenderer().render(root: haloOnly, into: haloList)
        #expect(haloList.vertices.count < shadowVertices)
    }

    @Test("A menu panel floats")
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

                let panel = try #require(flatten(tree.root).first { !$0.ambientShadow.isEmpty })
                #expect(panel.shadow == panel.theme.elevation.floating.key)
                #expect(!panel.highlight.isEmpty)
                // The menu, not some inner row: it is the wide one.
                #expect(panel.frame.width > 100)
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
            Popover(isPresented: $shown, width: 180) { Text("Open") } content: {
                Menu([.item(MenuItem(id: "one", title: "One") {}),
                      .item(MenuItem(id: "two", title: "Two") {})],
                     width: 180, maxVisibleRows: 4, onItemActivated: { shown = false })
            }
        }
    }
}
