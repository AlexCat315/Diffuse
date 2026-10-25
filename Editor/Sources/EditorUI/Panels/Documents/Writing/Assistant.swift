internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// AI writing actions on the selection, or the whole document without one.
/// Results are shown for review first; nothing changes until the author
/// replaces, inserts or copies them.
struct WritingAssistantButton: View, @unchecked Sendable {
    let app: EditorApplication
    let path: String
    let session: DocumentWritingSession
    @State private var isPresented = false
    @State private var running: EditorWritingAction?
    @State private var result: WritingResult?
    @State private var failure: String?
    @State private var instruction: TextBuffer = ""

    private struct WritingResult {
        let action: EditorWritingAction
        let text: String
        /// What the result applies to: the selection, or the whole document.
        let range: Range<Int>
    }

    var body: some View {
        Popover(isPresented: $isPresented, width: 360, placement: .bottomTrailing, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 4) {
                if running != nil { Spinner(size: 10) } else {
                    Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.assistantColor)
                }
                Text(L("AI")).font(.label).foregroundColor(EditorThemeTokens.assistantColor)
            }.padding(horizontal: 7).frame(height: 22)
                .background(EditorThemeTokens.assistantColor.opacity(0.10)).cornerRadius(6)
                .accessibility { $0.label = L("AI Writing Assistant") }
        } content: {
            Column(alignment: .leading, spacing: 0) {
                if let result {
                    review(result)
                } else {
                    actions
                }
            }.frame(width: .percent(100), minWidth: 0)
        }.debugName("document-ai")
    }

    // MARK: Choosing

    private var actions: some View {
        let scope = session.selection.isEmpty ? L("Whole document") : L("Selection")
        return Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 6) {
                Text(L("AI Writing Assistant")).font(.bodyStrong)
                Spacer(minLength: 0)
                EditorPanelBadge(scope)
            }.padding(EdgeInsets(top: 10, leading: 12, trailing: 12))
            if !app.isAIAvailable {
                Column(alignment: .leading, spacing: 8) {
                    Text(L("Set an AI provider in Settings to enable.")).font(.caption).foregroundColor(.onSurfaceMuted)
                    Button(L("Set up Assistant")) { isPresented = false; app.openSettingsWindow() }.buttonStyle(.secondary)
                }.padding(horizontal: 12)
            }
            Row(alignment: .center, spacing: 6) {
                TextField(L("Tell AI how to edit…"), text: $instruction) { input in
                    input.decoration.size = .small
                    input.events.onSubmit = { run(.improve, custom: instruction.stringValue) }
                }.font(.caption).flex()
                Button(icon: .resource(UIIcons.Navigation.arrowUp), size: 11,
                       isEnabled: app.isAIAvailable && running == nil && !instruction.stringValue.isEmpty,
                       tooltip: L("Send")) { run(.improve, custom: instruction.stringValue) }
                    .buttonStyle(EditorChromeButtonStyle(height: 24, agent: true))
            }.padding(horizontal: 12)
            if let failure {
                Text(failure, lineLimit: 4).font(.caption).foregroundColor(.error).padding(horizontal: 12)
            }
            Menu(EditorWritingAction.allCases.map { action in
                .item(MenuItem(id: action.rawValue, title: L(action.title),
                               isEnabled: app.isAIAvailable && running == nil) { run(action) })
            }, width: 360).debugName("document-ai-actions")
            if let running {
                Row(alignment: .center, spacing: 6) {
                    Spinner(size: 10)
                    Text(L(running.title) + "…").font(.caption).foregroundColor(.onSurfaceMuted)
                }.padding(EdgeInsets(leading: 12, bottom: 10, trailing: 12))
            }
        }
    }

    private func run(_ action: EditorWritingAction, custom: String? = nil) {
        let selection = session.selection
        let document = session.buffer.stringValue
        let range = selection.isEmpty ? 0..<session.buffer.characterCount : selection
        let text = selection.isEmpty ? document : session.selectedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failure = L("There is no text to work on yet.")
            return
        }
        let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines)
        running = action
        failure = nil
        Task { @MainActor in
            defer { running = nil }
            do {
                let output = try await app.performWritingAction(action, text: text, document: document, path: path,
                                                                customInstruction: custom?.isEmpty == false ? custom : nil)
                result = WritingResult(action: action, text: output, range: range)
                instruction = ""
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: Reviewing

    private func review(_ result: WritingResult) -> some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.assistantColor)
                Text(L(result.action.title)).font(.bodyStrong)
            }
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Text(result.text).font(.body).foregroundColor(.onSurface).padding(10)
                    .frame(width: .percent(100), minWidth: 0)
            }.frame(width: .percent(100), maxHeight: 280).background(.surfaceSunken).cornerRadius(8)
                .debugName("document-ai-result")
            Row(alignment: .center, spacing: 6) {
                Button(L("Discard")) { self.result = nil }.buttonStyle(.ghost)
                Button(L("Copy"), isEnabled: ClipboardHolder.write != nil) {
                    ClipboardHolder.write?(result.text)
                }.buttonStyle(.ghost)
                Spacer(minLength: 0)
                if result.action.replacesSource {
                    Button(L("Insert Below")) { insertBelow(result) }.buttonStyle(.secondary)
                    Button(L("Replace")) { replace(result) }.buttonStyle(.primary).debugName("document-ai-replace")
                } else {
                    Button(L("Insert")) { insertBelow(result) }.buttonStyle(.primary).debugName("document-ai-insert")
                }
            }
        }.padding(12)
    }

    private func replace(_ result: WritingResult) {
        session.replace(clamped(result.range), with: result.text)
        finish()
    }

    private func insertBelow(_ result: WritingResult) {
        let end = clamped(result.range).upperBound
        let separator = result.action == .continueWriting ? "" : "\n\n"
        session.replace(end..<end, with: separator + result.text)
        finish()
    }

    private func clamped(_ range: Range<Int>) -> Range<Int> {
        let count = session.buffer.characterCount
        return min(range.lowerBound, count)..<min(range.upperBound, count)
    }

    private func finish() {
        result = nil
        isPresented = false
    }
}
