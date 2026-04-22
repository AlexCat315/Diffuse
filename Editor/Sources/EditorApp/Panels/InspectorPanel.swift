import EditorCore
import GuavaUICompose

struct InspectorPanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch) {
                Text("Inspector")
                    .font(.system(size: 13, weight: .semibold))
                if let id = store.state.selectedEntityID {
                    Text("Selected: \(id)").font(.system(size: 11))
                } else {
                    Text("No selection").font(.system(size: 11))
                }
            }
            .padding(8)
        }
    }
}
