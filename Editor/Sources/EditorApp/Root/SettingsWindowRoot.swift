import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorSettingsWindowRoot: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store, select: SettingsWindowSelection.init) { store in
            EditorPresentationBoundary(presentation: store.state.presentation) {
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

private struct SettingsWindowSelection: Hashable {
    let presentation: EditorPresentationState

    init(_ state: EditorState) {
        self.presentation = state.presentation
    }
}
