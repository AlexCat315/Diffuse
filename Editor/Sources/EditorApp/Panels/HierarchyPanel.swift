import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct HierarchyPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    @State private var expanded: Set<UInt64>

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        _expanded = State(wrappedValue: scene.defaultExpandedEntityIDs)
    }

    var body: some View {
        StoreScope(store) { store in
            let selection = Binding<UInt64?>(
                get: { store.state.selectedEntityID },
                set: { next in
                    if store.state.selectedEntityID != next {
                        store.dispatch(.setSelectedEntity(next))
                    }
                }
            )

            Box(direction: .column, alignItems: .stretch) {
                Text("Scene Hierarchy")
                    .font(.headline)
                Text("\(scene.entityCount) entities")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Text(store.state.connected ? "Runtime connected" : "Runtime offline")
                    .font(.caption)
                    .foregroundColor(store.state.connected ? .success : .warning)
                Tree(scene.roots,
                     children: \.children,
                     selection: selection,
                     expanded: $expanded,
                     rowHeight: 36,
                     rowSpacing: 1,
                     indentation: 10,
                     disclosureWidth: 14) { entity, _, _, _ in
                    Box(direction: .column, alignItems: .stretch, justifyContent: .center) {
                        Text(entity.name)
                            .font(.bodyStrong)
                        Text(entity.kind)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(horizontal: 4, vertical: 2)
                }
                .flex()
            }
            .padding(8)
        }
    }
}
