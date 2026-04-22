import EditorCore
import GuavaUICompose

struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch) {
                Text("Console")
                    .font(.headline)
                Text(store.state.connected ? "editor.runtime.connected" : "editor.runtime.offline")
                    .font(.mono)
                    .foregroundColor(store.state.connected ? .success : .warning)
                Text("sceneRevision = \(store.state.sceneRevision)")
                    .font(.mono)
                Text("playbackState = .\(store.state.playbackState.rawValue)")
                    .font(.mono)
                Text("selectedEntityID = \(store.state.selectedEntityID.map(String.init) ?? "nil")")
                    .font(.mono)
            }
            .padding(8)
        }
    }
}
