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

    init(model: EditorDocumentWorkspace) {
        self.model = model
        observed = Observed(\.documents, on: model)
    }
    var body: some View {
        let documents = observed.wrappedValue
        Column(alignment: .leading, spacing: 6) {
            Row(spacing: 6) {
                TextField("Project-relative file path", text: $path).flex()
                Button(L("Open")) { model.open(path.stringValue) }
                Button(L("Discard and Reload"), isEnabled: model.selectedPath != nil) { if let path = model.selectedPath { model.reload(path, discard: true) } }.buttonStyle(.ghost)
                Button(L("Save"), isEnabled: model.selectedPath != nil) { if let path = model.selectedPath { model.save(path) } }
            }
            if let error = model.error { Text(error).font(.caption).foregroundColor(.error) }
            Row(alignment: .top, spacing: 8) {
                Column(alignment: .leading, spacing: 4) {
                    TextField("Filter files", text: $filter)
                    ScrollView {
                        Column(alignment: .leading, spacing: 2) {
                            for file in model.files().filter({ filter.stringValue.isEmpty || $0.localizedCaseInsensitiveContains(filter.stringValue) }).prefix(200) {
                                AnyView(Button(file, isSelected: file == model.selectedPath) { model.open(file); path = TextBuffer(file) }.buttonStyle(.ghost))
                            }
                        }
                    }.flex()
                }.frame(width: 200)
                Column(alignment: .leading, spacing: 4) {
                    if let document = documents.first(where: { $0.path == model.selectedPath }) {
                        Text(document.path + (document.isDirty ? " •" : "")).font(.label)
                        DocumentEditingSurface(model: model, path: document.path).id(document.path).flex()
                    } else { Text(L("Open a text or code file to begin.")).foregroundColor(.onSurfaceMuted) }
                }.flex().frame(minWidth: 0, minHeight: 0)
            }.flex().frame(minHeight: 0)
        }.padding(8).frame(minWidth: 0, minHeight: 0)
    }
}

private struct DocumentEditingSurface: View {
    let model: EditorDocumentWorkspace
    let path: String
    @State private var history = TextEditHistory()
    var body: some View {
        TextField("", text: Binding(get: { TextBuffer(model.documents.first(where: { $0.path == path })?.text ?? "") },
                                    set: { model.edit(path, text: $0.stringValue) })) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = false
            input.layout.maxVisibleLines = 80
            input.codeEditing.showsLineNumbers = true
            input.codeEditing.editHistory = history
            input.codeEditing.indentationWidth = 4
        }.font(.mono).flex().frame(minWidth: 0, minHeight: 0)
    }
}
