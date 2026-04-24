import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("AssetRefField", .serialized)
struct AssetRefFieldTests: GuavaUIComposeSerializedSuite {
    final class Store {
        var active: AssetDropPayload?
        var value: AssetRef?
    }

    @Test("AssetDropRegistry dispatches a matching payload to the target")
    func registryDropDispatchesToTarget() { GlobalTestLock.locked {
        let registry = AssetDropRegistry()
        AssetDropRegistryHolder.current = registry
        defer { AssetDropRegistryHolder.current = nil }

        let store = Store()
        store.active = AssetDropPayload(id: "asset-1",
                                        name: "SM_Ruin_Arch_01",
                                        subtitle: "Content/Environment/Ruins",
                                        kind: "mesh")

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
