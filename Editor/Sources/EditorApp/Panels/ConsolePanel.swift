import EditorCore
import GuavaUICompose

struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Text(store.connected ? L("Connected") : L("Offline"))
                        .font(.caption)
                        .foregroundColor(store.connected ? .success : .warning)

                    Spacer(minLength: 0)

                    Text("revision \(store.sceneRevision)")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }

                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    Text("playbackState = .\(store.playbackState.rawValue)")
                        .font(.mono)
                    Text("selectedEntityID = \(store.selectedEntityID.map(String.init) ?? "nil")")
                        .font(.mono)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(8)
                .background(.surfaceSunken)
                .cornerRadius(2)
            }
            .padding(10)
            .frame(minHeight: 140)
        }
    }
}
