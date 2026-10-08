import Testing
import EngineKernel
import GuavaUIRuntime
import RenderBackend
@testable import GuavaUICompose

/// Drawable-size reporting and UV-cropped compositing of `ViewportHost`:
/// the host reports physical pixels (logical frame × content scale) and
/// samples only the used sub-region of the grow-only allocated texture.
@Suite("ViewportHost Scale", .serialized)
struct ViewportHostScaleTests: GuavaUIComposeSerializedSuite {
    @Test("standalone viewport accepts keys immediately without stealing subsequent focus")
    func initialKeyboardFocus() { GlobalTestLock.locked {
        let previous = FocusChainHolder.current
        let focus = FocusChain()
        FocusChainHolder.current = focus
        defer { FocusChainHolder.current = previous }
        let embedded = ViewportHost(surface: ViewportSurfaceState())
        embedded._updateNode(embedded._makeNode())
        #expect(focus.focused == nil)
        let standalone = ViewportHost(surface: ViewportSurfaceState(), automaticallyFocus: true)
        let node = standalone._makeNode()
        standalone._updateNode(node)
        #expect(focus.focused === node)
        #expect(!focus.isFocusVisible)
        let field = Node(); field.isFocusable = true
        focus.focus(field)
        standalone._updateNode(node)
        #expect(focus.focused === field)
        focus.clear()
        standalone._updateNode(node)
        #expect(focus.focused == nil)
    } }

    private final class RecordingBridge: ViewportTextureBridge {
        var registeredSize: (width: UInt32, height: UInt32)?
        func textureID(for surface: ViewportSurfaceState) -> TextureID? {
            guard surface.surfaceID != 0, surface.region.isValid else { return nil }
            registeredSize = (surface.region.capacity.width, surface.region.capacity.height)
            return 10_000
        }
    }

    private func firstDrawNode(_ node: Node?) -> Node? {
        guard let node else { return nil }
        if node.draw != nil { return node }
        for child in node.children {
            if let found = firstDrawNode(child) { return found }
        }
        return nil
    }

    @Test("Reports drawable size in physical pixels honoring the content scale")
    func reportsPixelDrawableSize() { GlobalTestLock.locked {
        let previousScale = ContentScaleHolder.current
        ContentScaleHolder.current = 2
        defer { ContentScaleHolder.current = previousScale }

        var reported: [RenderDrawableSize] = []
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ViewportHost(surface: ViewportSurfaceState(),
                         onDrawableSizeChange: { reported.append($0) })
                .frame(width: 200, height: 120)
        )
        graph.computeLayout(width: 200, height: 120)

        let list = DrawList()
        let node = firstDrawNode(tree.root)
        #expect(node != nil)
        node?.draw?(list, .zero)

        #expect(reported.last == RenderDrawableSize(width: 400, height: 240))
    } }

    @Test("Composites the used sub-region of the allocated texture")
    func cropsToUsedRegion() { GlobalTestLock.locked {
        let previousScale = ContentScaleHolder.current
        ContentScaleHolder.current = 1
        defer { ContentScaleHolder.current = previousScale }

        let bridge = RecordingBridge()
        let previousBridge = ViewportTextureBridgeHolder.current
        ViewportTextureBridgeHolder.current = bridge
        defer { ViewportTextureBridgeHolder.current = previousBridge }

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            ViewportHost(surface: ViewportSurfaceState(surfaceID: 7, region: ViewportSamplingRegion(
                size: RenderDrawableSize(width: 300, height: 200),
                capacity: RenderDrawableSize(width: 512, height: 256))))
                .frame(width: 200, height: 120)
        )
        graph.computeLayout(width: 200, height: 120)

        let list = DrawList()
        let node = firstDrawNode(tree.root)
        #expect(node != nil)
        node?.draw?(list, .zero)

        #expect(bridge.registeredSize?.width == 512)
        #expect(bridge.registeredSize?.height == 256)

        // Image quad u carries a +10 sentinel bias (see DrawList.addImageQuad).
        let us = list.vertices.map { $0.u - 10 }
        let vs = list.vertices.map(\.v)
        let maxU = us.max() ?? -1
        let maxV = vs.max() ?? -1
        #expect(abs(maxU - 299.5 / 512.0) < 1e-5)
        #expect(abs(maxV - 199.5 / 256.0) < 1e-5)
        #expect(list.batches.count == 1)
    } }
}
