internal import EditorCore
internal import CoveUI
internal import PluginRuntime

/// All plugin modes use the same renderer and public view protocol.
struct PluginSurface: View {
    let app: EditorApplication
    let panel: ContributedPanel
    var body: some View {
        let session = MainActor.assumeIsolated { app.viewSession(for: panel) }
        return PluginView(session: session)
            .padding(12).flex().frame(minWidth: 0, minHeight: 0)
            .debugName("plugin-surface-" + panel.id)
    }
}
