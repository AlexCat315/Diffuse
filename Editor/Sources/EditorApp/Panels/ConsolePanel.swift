import EditorCore
import GuavaUICompose

struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch) {
                Text("Console")
                    .font(.system(size: 13, weight: .semibold))
                Text("scene revision: \(store.state.sceneRevision)")
                    .font(.system(size: 11))
                Text("playback: \(store.state.playbackState.rawValue)")
                    .font(.system(size: 11))
            }
            .padding(8)
        }
    }
}
