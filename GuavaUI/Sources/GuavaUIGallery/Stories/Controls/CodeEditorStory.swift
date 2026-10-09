import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct CodeEditorStory: View {
    let options: GalleryOptions
    @State private var source: TextBuffer = "struct Greeting {\n    let name: String\n\n    func message() -> String {\n        return name\n    }\n}\n\npri"
    @State private var history = TextEditHistory()
    @State private var navigationRequest = 0
    @State private var navigationIndex = 0
    @State private var showsDiagnostic = true
    @State private var hover: TextFieldHoverAnchor?
    @State private var status = "Type pri or press Control-Space to request completion"
    private var diagnostic: TextDiagnostic {
        let range = source.lineRange(forLine: 0)
        return TextDiagnostic(utf8Range: source.utf8Offset(forCharacterIndex: range.lowerBound)..<source.utf8Offset(forCharacterIndex: range.upperBound),
                              severity: .warning, message: "Sample warning: this declaration is unused.")
    }
    var body: some View {
        StorySection("Code editing", "This example supplies sample completions and a diagnostic. The Script editor supplies Tree-sitter highlighting and SourceKit-LSP results.") {
            Row(alignment: .center, spacing: 12) {
                Button("Go to beginning", isEnabled: options.isEnabled) { navigate(to: 0) }.buttonStyle(.secondary)
                Button("Load 200,000 lines", isEnabled: options.isEnabled) {
                    source = TextBuffer((0..<200_000).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
                    hover = nil; navigate(to: source.lineRange(forLine: 100_000).upperBound)
                    status = "200,000 lines · caret at line 100,001 · type, scroll, undo and redo"
                }.buttonStyle(.secondary)
                Checkbox(isOn: $showsDiagnostic, isEnabled: options.isEnabled)
                Text("Sample warning").font(.caption)
            }
            ResizableEditor(initialHeight: 300) { editor }
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            Text("Tab / Return accepts completion · Escape dismisses · Up / Down chooses · Undo reverses the whole edit")
                .font(.caption).foregroundColor(.onSurfaceMuted)
            hoverTooltip
        }
    }
    private var editor: some View {
        TextField("", text: $source) { input in
            input.layout.axis = .vertical; input.layout.wrapsLines = false; input.layout.maxVisibleLines = 24
            input.codeEditing.showsLineNumbers = true; input.codeEditing.indentationWidth = 4
            input.codeEditing.editHistory = history
            input.codeEditing.diagnostics = showsDiagnostic ? TextDiagnostics([diagnostic]) : .empty
            input.codeEditing.onRequestCompletion = { _, reply in
                var print = TextCompletionItem(id: "print", label: "print", insertText: "print(value)")
                print.detail = "Writes a value to standard output"
                var privateItem = TextCompletionItem(id: "private", label: "private", insertText: "private ")
                privateItem.detail = "Access control"
                let items = [print, privateItem]
                Task { @MainActor in reply(items) }
            }
            input.codeEditing.onAcceptCompletion = { status = "Accepted \($0.label)" }
            input.behavior.disabled = !options.isEnabled
            input.events.onChange = { _ in hover = nil }
            input.events.onHoverChange = { hover = $0 }
            if navigationRequest > 0 { input.navigation.caretRequestID = navigationRequest; input.navigation.caretRequestIndex = navigationIndex }
        }.font(.mono).flex(1, shrink: 1).frame(minHeight: 0).debugName("gallery-code-editor")
    }
    private var hoverTooltip: AnyView {
        guard showsDiagnostic, let hover,
              source.lineIndex(forCharacterIndex: hover.characterIndex) == 0 else { return AnyView(EmptyView()) }
        return AnyView(Tooltip(anchor: .point(CGPoint(x: CGFloat(hover.windowX), y: CGFloat(hover.windowY))), configure: { $0.maxWidth = 320 }) {
            Text(diagnostic.message).font(.caption).padding(10).background(.surfaceFloating).border(.border, width: 1).cornerRadius(6)
        })
    }
    private func navigate(to index: Int) { navigationIndex = index; navigationRequest += 1 }
}
