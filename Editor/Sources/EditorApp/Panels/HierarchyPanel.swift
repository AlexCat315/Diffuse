import EditorCore
import GuavaUICompose

struct HierarchyPanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch) {
                Text("Scene Hierarchy")
                    .font(.system(size: 13, weight: .semibold))
                Text(store.state.connected ? "Engine: connected" : "Engine: offline")
                    .font(.system(size: 11))
            }
            .padding(8)
        }
    }
}
