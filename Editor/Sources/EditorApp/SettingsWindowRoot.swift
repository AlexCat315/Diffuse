import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
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