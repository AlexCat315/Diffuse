import Foundation
import GuavaUI
import GuavaUIRuntime

/// A general multiline editor. The same `TextField` supports prose (soft wrap,
/// no chrome) and code (line numbers, diagnostics, completion) without
/// changing component.
struct TextEditorStory: View {
    let options: GalleryOptions
    @State private var source: TextBuffer = "struct Greeting {\n    let name: String\n\n    func message() -> String {\n        return name\n    }\n}\n"
    @State private var history = TextEditHistory()
    @State private var navigationRequest = 0
    @State private var navigationIndex = 0
    @State private var showsDiagnostic = true
    @State private var codeMode = true
    @State private var caret = TextFieldCaretState.initial
    @State private var hover: TextFieldHoverAnchor?
    @State private var status = "Press Control-Space at the end of a line to request completion"

    private var diagnostic: TextDiagnostic {
        let range = source.lineRange(forLine: 0)
        return TextDiagnostic(
            utf8Range: source.utf8Offset(forCharacterIndex: range.lowerBound)..<source.utf8Offset(forCharacterIndex: range.upperBound),
            severity: .warning, message: "Sample warning: this declaration is unused.")
    }

    var body: some View {
        StorySection(
            "Text editing",
            "A multiline editor for prose and code. Code mode adds line numbers, indentation, diagnostics and completion; plain mode soft-wraps and removes code chrome."
        ) {
            Row(alignment: .center, spacing: 12) {
                Button("Go to beginning", isEnabled: options.isEnabled) { navigate(to: 0) }
                    .buttonStyle(.secondary)
                Button("Load 200,000 lines", isEnabled: options.isEnabled && codeMode) {
                    source = TextBuffer((0..<200_000).map { "let value\($0) = \($0)" }.joined(separator: "\n"))
                    hover = nil; navigate(to: source.lineRange(forLine: 100_000).upperBound)
                    status = "200,000 lines · caret at line 100,001 · type, scroll, undo and redo"
                }.buttonStyle(.secondary)
                if codeMode {
                    Checkbox(isOn: $showsDiagnostic, isEnabled: options.isEnabled)
                    Text("Sample warning").font(.caption).foregroundColor(.onSurfaceMuted)
                }
                Box {}.flex(1)
            }

            ThemeReader { theme in
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    documentHeader
                    Box {}.frame(height: 1).background(.border)
                    ResizableEditor(initialHeight: 280) { editor }
                    Box {}.frame(height: 1).background(.border)
                    statusBar
                }
                .background(.surface)
                .border(.border, width: 1)
                .cornerRadius(theme.radius.md)
                .clipped()
            }

            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            Text("Tab / Return accepts completion · Escape dismisses · Up / Down chooses · Undo reverses the whole edit")
                .font(.caption).foregroundColor(.onSurfaceMuted)
            hoverTooltip
        }
    }

    private var documentHeader: some View {
        Row(alignment: .center, spacing: 8) {
            Icon(UIIcons.Editor.code, size: .small, color: .onSurfaceMuted)
            Text(codeMode ? "Greeting.swift" : "Notes.txt").font(.label)
            Badge(codeMode ? "Swift" : "Plain text", tone: codeMode ? .info : .neutral)
            Box {}.flex(1)
            Checkbox(isOn: $codeMode, isEnabled: options.isEnabled)
            Text("Code mode").font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 12)
        .frame(height: 36)
        .background(.surfaceRaised)
    }

    private var statusBar: some View {
        Row(alignment: .center, spacing: 12) {
            Text("Ln \(caretLine + 1), Col \(caretColumn)").font(.caption)
                .debugName("text-editor-caret")
            Box {}.flex(1)
            Text(codeMode ? "Spaces: 4" : "Soft wrap").font(.caption)
            Text("UTF-8").font(.caption)
            Text(codeMode ? "Swift" : "Plain text").font(.caption)
        }
        .foregroundColor(.onSurfaceMuted)
        .padding(horizontal: 12)
        .frame(height: 28)
        .background(.surfaceRaised)
    }

    private var editor: some View {
        TextField("", text: $source) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = !codeMode
            input.layout.maxVisibleLines = 24
            input.codeEditing.showsLineNumbers = codeMode
            input.codeEditing.indentationWidth = 4
            input.codeEditing.editHistory = history
            input.codeEditing.diagnostics = codeMode && showsDiagnostic ? TextDiagnostics([diagnostic]) : .empty
            input.codeEditing.onRequestCompletion = codeMode ? { _, reply in
                var print = TextCompletionItem(id: "print", label: "print", insertText: "print(value)")
                print.detail = "Writes a value to standard output"
                var privateItem = TextCompletionItem(id: "private", label: "private", insertText: "private ")
                privateItem.detail = "Access control"
                let items = [print, privateItem]
                Task { @MainActor in reply(items) }
            } : nil
            input.codeEditing.onAcceptCompletion = { status = "Accepted \($0.label)" }
            input.behavior.disabled = !options.isEnabled
            input.events.onChange = { _ in hover = nil }
            input.events.onCaretChange = { caret = $0 }
            input.events.onHoverChange = { hover = $0 }
            if navigationRequest > 0 {
                input.navigation.caretRequestID = navigationRequest
                input.navigation.caretRequestIndex = navigationIndex
            }
        }
        .font(codeMode ? .mono : .body)
        .textFieldStyle(TextEditorFieldStyle())
        .flex(1, shrink: 1)
        .frame(minHeight: 0)
        .debugName("gallery-text-editor")
    }

    private var hoverTooltip: AnyView {
        guard codeMode, showsDiagnostic, let hover,
              source.lineIndex(forCharacterIndex: hover.characterIndex) == 0 else { return AnyView(EmptyView()) }
        return AnyView(Tooltip(anchor: .point(CGPoint(x: CGFloat(hover.windowX), y: CGFloat(hover.windowY))), configure: { $0.maxWidth = 320 }) {
            Text(diagnostic.message).font(.caption).padding(10).background(.surfaceFloating).border(.border, width: 1).cornerRadius(6)
        })
    }

    private var caretLine: Int {
        source.lineIndex(forCharacterIndex: min(caret.caretIndex, source.characterCount))
    }

    private var caretColumn: Int {
        caret.caretIndex - source.lineRange(forLine: caretLine).lowerBound + 1
    }

    private func navigate(to index: Int) {
        navigationIndex = index
        navigationRequest += 1
    }
}

/// The editor owns the chrome (header, status, rounded clipping), so the field
/// itself becomes a flat content slot inside it instead of a second bordered
/// input.
private struct TextEditorFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content
            .background(.surface)
            .border(configuration.isFocused ? configuration.theme.colors.focusRing : .clear, width: 1)
    }
}
