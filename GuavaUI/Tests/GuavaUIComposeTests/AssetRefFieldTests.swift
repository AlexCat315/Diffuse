import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("AssetRefField", .serialized)
struct AssetRefFieldTests: GuavaUIComposeSerializedSuite {
    final class Store {
        var active: AssetDropPayload?
        var value: AssetRef?
    }

    @Test("Kinds without a preview map to a glyph by keyword, case-insensitively")
    func kindGlyphs() {
        #expect(AssetKindTile.icon(for: "image") == UIIcons.Media.image)
        #expect(AssetKindTile.icon(for: "Texture") == UIIcons.Media.image)
        #expect(AssetKindTile.icon(for: "Static Mesh") == UIIcons.Editor.box)
        #expect(AssetKindTile.icon(for: "material") == UIIcons.Editor.brush)
        #expect(AssetKindTile.icon(for: "weird") == UIIcons.File.file)
        #expect(AssetKindTile.icon(for: nil) == UIIcons.File.file)
    }

    @Test("The thumbnail slot draws a glyph, never the kind as truncated text")
    func thumbnailIsAGlyph() { GlobalTestLock.locked {
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        for value in [AssetRef?.none, AssetRef(id: "cam", name: "Camera", kind: "image")] {
            graph.install(root: AssetRefField(value: .constant(value), acceptedKinds: ["image"]).frame(width: 220))
            graph.computeLayout(width: 220, height: 80)
            func texts(_ node: Node) -> [String] { [node.layoutNode?.textInputs?.text].compactMap { $0 } + node.children.flatMap(texts) }
            #expect(!texts(graph.tree.root!).contains("image"), "kind text: \(texts(graph.tree.root!))")
        }
        graph.install(root: EmptyView())
    } }

    @Test("AssetDropRegistry dispatches a matching payload to the target")
    func registryDropDispatchesToTarget() { GlobalTestLock.locked {
        let registry = AssetDropRegistry()
        AssetDropRegistryHolder.current = registry
        defer { AssetDropRegistryHolder.current = nil }

        let store = Store()
        store.active = AssetDropPayload(id: "asset-1",
                                        name: "SM_Ruin_Arch_01",
                                        subtitle: "Content/Environment/Ruins",
                                        kind: "mesh",
                                        previewPath: "/tmp/preview.png")

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            AssetRefField(
                value: Binding(get: { store.value }, set: { store.value = $0 }),
                activePayload: Binding(get: { store.active }, set: { store.active = $0 }),
                acceptedKinds: ["mesh"]
            )
            .frame(width: 220, height: 32)
        )
        graph.computeLayout(width: 220, height: 32)

        #expect(registry.drop(store.active!, atX: 12, y: 12) == true)
        #expect(store.value?.id == "asset-1")
        #expect(store.value?.kind == "mesh")
        #expect(store.value?.previewPath == "/tmp/preview.png")
    } }

    @Test("AssetDropRegistry rejects unsupported asset kinds")
    func registryRejectsUnsupportedKind() { GlobalTestLock.locked {
        let registry = AssetDropRegistry()
        AssetDropRegistryHolder.current = registry
        defer { AssetDropRegistryHolder.current = nil }

        let store = Store()
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root:
            AssetRefField(
                value: Binding(get: { store.value }, set: { store.value = $0 }),
                activePayload: .constant(AssetDropPayload(id: "mat-1", name: "M_Ruin", kind: "material")),
                acceptedKinds: ["mesh"]
            )
            .frame(width: 220, height: 32)
        )
        graph.computeLayout(width: 220, height: 32)

        let payload = AssetDropPayload(id: "mat-1", name: "M_Ruin", kind: "material")
        #expect(registry.drop(payload, atX: 12, y: 12) == false)
        #expect(store.value == nil)
    } }
}
