import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import EngineKernel
import GuavaUIRuntime
@testable import GuavaUICompose

/// Floating panels have to *look* lifted and read as glass. These tests pin
/// the token, the one modifier that assembles the material, and a real menu.
@Suite("Glass surfaces", .serialized)
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
        GlassSurfaceModifier(cornerRadius: 6).apply(node: node)

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

    /// Glass is five properties that only work together, and the order is not
    /// obvious from any one of them: the fill buries the frost unless it is
    /// translucent, and without `backdropBlur` there is no frost to bury. A
    /// menu once assembled the chain by hand and missed the blur, rendering as
    /// a plain card that looked finished in review. The modifier exists so that
    /// cannot be done by accident, and this pins every part of it.
    @Test("glassSurface() asks for the whole material, not part of it")
    @MainActor func glassSurfaceWiring() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        GlassSurfaceModifier(cornerRadius: 7).apply(node: node)

        let theme = node.theme
        #expect(node.backdropBlur == 12)
        #expect(node.backgroundColor == theme.colors.surfaceMaterial)
        #expect(node.cornerRadius == 7)
        #expect(node.borderColor == theme.colors.border)
        #expect(node.borderWidth == 1)
        #expect(node.ambientShadow == theme.elevation.floating.ambient)
        #expect(node.shadow == theme.elevation.floating.key)
        // The fill has to let the backdrop through, or the frost the pass just
        // drew underneath it is simply covered.
        #expect(node.backgroundColor?.a ?? 1 < 1)
    }

    @Test("The frost strength is the caller's, and zero is honoured")
    @MainActor func glassBlurIsConfigurable() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        GlassSurfaceModifier(cornerRadius: 6, blurRadius: 24).apply(node: node)
        #expect(node.backdropBlur == 24)

        // A negative radius has to clamp rather than reach the pass as one:
        // it would size the capture backwards.
        let clamped = Node()
        clamped.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        GlassSurfaceModifier(cornerRadius: 6, blurRadius: -5).apply(node: clamped)
        #expect(clamped.backdropBlur == 0)
    }

    @Test("A menu panel is glass, like every other floating panel")
    @MainActor func menuPanelFrosts() throws {
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
                // Every floating panel is the same material. A menu that quietly skipped the
                // frost used to render as a plain card among glass ones, which
                // is the one outcome this modifier exists to prevent.
                let theme = panel.theme
                #expect(panel.backdropBlur > 0)
                #expect(panel.backgroundColor == theme.colors.surfaceMaterial)
                #expect(panel.cornerRadius == theme.radius.md)
                #expect(panel.borderColor == theme.colors.border)
                #expect(panel.ambientShadow == theme.elevation.floating.ambient)
                #expect(panel.shadow == theme.elevation.floating.key)
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
