import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            EditorPresentationBoundary(presentation: store.presentation) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    SettingsPanel(app: app)
                        .flex()
                }
                .background(.background)
                .flex()
            }
        }
    }
}
