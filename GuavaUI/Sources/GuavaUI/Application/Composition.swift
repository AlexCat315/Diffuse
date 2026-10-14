import Foundation
import GuavaUICompose
import GuavaUIRuntime

@MainActor
final class MainComposition {
    let tree = NodeTree()
    let environment = State<UIEnvironment>(wrappedValue: UIEnvironment())
    let portalStore: PortalStore
    let graph: ViewGraph
    let imageAssets = ImageAssetRegistry()
    let assetDropRegistry = AssetDropRegistry()
    let drawList = DrawList()
    let layerRenderer = LayerAwareNodeRenderer()
    let nodeRenderer = NodeRenderer()
    let useLegacyRenderer = ProcessInfo.processInfo.environment["GUAVAUI_LEGACY_RENDERER"] == "1"

    init(recomposer: Recomposer, portalStore: PortalStore) {
        self.portalStore = portalStore
        graph = ViewGraph(tree: tree, recomposer: recomposer)
    }
}
