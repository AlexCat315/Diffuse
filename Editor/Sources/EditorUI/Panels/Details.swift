internal import EditorCore
internal import GuavaUI

/// The right side follows the content: properties of the selection for a
/// scene or timeline, the outline of the open file for files.
struct EditorDetailsPanel: View {
    let app: EditorApplication
    let properties: () -> AnyView

    var body: some View {
        StoreScope(app.store) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if store.content == .files {
                    DocumentOutlinePanel(app: app).flex().frame(minWidth: 0, minHeight: 0)
                } else {
                    properties().flex().frame(minWidth: 0, minHeight: 0)
                }
            }.flex().frame(minWidth: 0, minHeight: 0)
        }
    }
}
