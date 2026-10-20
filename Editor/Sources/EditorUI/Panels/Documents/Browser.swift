import EditorCore
import StudioDocuments
import Foundation
import GuavaUI
import GuavaUIRuntime

struct DocumentsPanel: View {
    let model: EditorDocumentWorkspace
    private var observed: Observed<EditorDocumentWorkspace, [TextDocument]>
    @State private var path: TextBuffer = ""
    @State private var filter: TextBuffer = ""
    @State private var pane: SplitPane = .first

    init(model: EditorDocumentWorkspace) {
        self.model = model
        observed = Observed(\.documents, on: model)
    }
    var body: some View {
        let documents = observed.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 6) {
                TextField("Project-relative file path", text: $path).flex(1, shrink: 1).frame(minWidth: 160)
                Button(L("Open")) { open(path.stringValue) }
                Button(L("Discard and Reload"), isEnabled: model.selectedPath != nil) { if let path = model.selectedPath { model.reload(path, discard: true) } }.buttonStyle(.ghost)
                Button(L("Save"), isEnabled: model.selectedPath != nil) { if let path = model.selectedPath { model.save(path) } }
            }
            if let error = model.error { Text(error).font(.caption).foregroundColor(.error) }
            SplitView(.horizontal, fraction: 0.25,
                      constraints: .init(minimumFirst: 160, minimumSecond: 240),
                      compact: .init(firstTitle: L("Files"), secondTitle: L("Document")) { $0.selection = $pane }) {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    TextField("Filter files", text: $filter)
                    ScrollView {
                        Column(alignment: .leading, spacing: 2) {
                            for file in model.files().filter({ filter.stringValue.isEmpty || $0.localizedCaseInsensitiveContains(filter.stringValue) }).prefix(200) {
                                AnyView(Button(file, isSelected: file == model.selectedPath) { open(file); path = TextBuffer(file) }.buttonStyle(.ghost))
                            }
                        }
                    }.flex()
                }
            } second: {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    if let document = documents.first(where: { $0.path == model.selectedPath }) {
                        Text(document.path + (document.isDirty ? " •" : "")).font(.label)
                        DocumentEditingSurface(model: model, path: document.path).id(document.path).flex()
                    } else { Text(L("Open a text or code file to begin.")).foregroundColor(.onSurfaceMuted) }
                }.flex().frame(minWidth: 0, minHeight: 0)
            }.flex().frame(minHeight: 0)
        }.padding(8).frame(minWidth: 0, minHeight: 0)
    }

    private func open(_ path: String) {
        model.open(path)
        if model.error == nil { pane = .second }
    }
}
