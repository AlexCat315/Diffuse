import EditorCore
import GuavaUICompose

struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store, select: ConsolePanelSelection.init) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Text(store.state.connected ? L("Connected") : L("Offline"))
                        .font(.caption)
                        .foregroundColor(store.state.connected ? .success : .warning)

                    Spacer(minLength: 0)

                    Text("revision \(store.state.sceneRevision)")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }

                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    Text("playbackState = .\(store.state.playbackState.rawValue)")
                        .font(.mono)
                    Text("selectedEntityID = \(store.state.selectedEntityID.map(String.init) ?? "nil")")
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

private struct ConsolePanelSelection: Hashable {
    let connected: Bool
    let sceneRevision: UInt64
    let playbackState: PlaybackState
    let selectedEntityID: UInt64?
    let themeMode: EditorThemeMode
    let language: EditorLanguage

    init(_ state: EditorState) {
        self.connected = state.connected
        self.sceneRevision = state.sceneRevision
        self.playbackState = state.playbackState
        self.selectedEntityID = state.selectedEntityID
        self.themeMode = state.themeMode
        self.language = state.language
    }
}
