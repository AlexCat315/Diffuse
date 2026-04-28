import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store, select: SettingsWindowSelection.init) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                SettingsPanel(app: app)
                    .flex()
            }
            .appearance(store.state.themeMode == .dark ? .dark : .light)
            .background(.background)
            .flex()
        }
    }
}

private struct SettingsWindowSelection: Hashable {
    let themeMode: EditorThemeMode
    let language: EditorLanguage

    init(_ state: EditorState) {
        self.themeMode = state.themeMode
        self.language = state.language
    }
}
