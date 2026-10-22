import EditorCore
import Foundation
import GuavaUI
import GuavaUIRuntime

/// The Swift editing surface shared by document tabs and the Scripts panel:
/// the selected script with completion, hover and diagnostics, hierarchy
/// arrows and the quick-fix bulb beside the line numbers, read-only peeks into
/// definitions outside the project, and the results of language commands.
struct ScriptSourceEditor: View {
    let app: EditorApplication
    let semantic: ScriptSemanticSession
    let insights: ScriptInsightSession
    private var _workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    private var semanticRevision: Observed<ScriptSemanticSession, UInt64>
    private var insightRevision: Observed<ScriptInsightSession, UInt64>
    @State private var hoverPresentation: ScriptEditorHoverPresentation = .hidden
    @State private var hoverSequence = ScriptEditorHoverSequence()
    @State private var histories: [String: TextEditHistory] = [:]
    @State private var completions = ScriptCompletionItems()

    init(app: EditorApplication, semantic: ScriptSemanticSession, insights: ScriptInsightSession) {
        self.app = app
        self.semantic = semantic
        self.insights = insights
        _workspace = Observed(\.snapshot, on: app.workstation.scripts)
        semanticRevision = Observed(\.revision, on: semantic)
        insightRevision = Observed(\.revision, on: insights)
    }

    private var workspace: ScriptWorkspaceSnapshot { _workspace.wrappedValue }

    var body: some View {
        let _ = semanticRevision.wrappedValue
        let _ = insightRevision.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let external = semantic.externalDocument {
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Status.lock, size: 11, color: .onSurfaceMuted)
                    Text(external.url.lastPathComponent, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                    Text(L("Read Only")).font(.caption).foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                    Button(L("Close"), action: semantic.selectedProjectDocument).buttonStyle(.ghost)
                }.padding(horizontal: 12).frame(height: 28)
                ScriptCodeEditor(source: .constant(external.source), annotations: .constant(.init()), hover: .constant(.hidden),
                                 caretLabel: .constant(""), onChange: { _ in }, navigation: external.navigation,
                                 onHover: { _ in }, onHoverEnd: {}, onCaret: semantic.updateCaret,
                                 onKey: semantic.handleKey, languageEntries: languageEntries, isReadOnly: true)
                    .id(external.url.absoluteString).flex(1, shrink: 1)
            } else if let document = workspace.selectedDocument {
                editor(document)
                AnimatedVisibility(isVisible: languageServiceMessage != nil) {
                    Row(alignment: .center, spacing: 8) {
                        Text(languageServiceMessage ?? "", lineLimit: 1).font(.caption).foregroundColor(.warning)
                        Spacer(minLength: 0)
                        if case .unavailable = workspace.languageServiceState {
                            Button(L("Retry"), action: app.workstation.scripts.retryLanguageService).buttonStyle(.secondary)
                        }
                        Button(L("Dismiss"), action: app.workstation.scripts.dismissLanguageServiceMessage).buttonStyle(.ghost)
                    }.padding(horizontal: 12, vertical: 4)
                }
            }
            ScriptSemanticResults(session: semantic)
        }
        .frame(minWidth: 0, minHeight: 0)
    }

    private func editor(_ document: ScriptWorkspaceDocument) -> some View {
        let id = document.file.identifier
        let scripts = app.workstation.scripts
        return ThemeReader { theme in
            ScriptCodeEditor(source: Binding(get: { scripts.snapshot.selectedDocument?.source ?? "" }, set: scripts.updateSelectedSource),
                             annotations: Binding(get: { scripts.snapshot.documents.first { $0.file.identifier == id }?.annotations ?? .init() },
                                                  set: { scripts.setEditorAnnotations($0, for: id) }),
                             hover: $hoverPresentation,
                             caretLabel: Binding(get: { app.store.scriptCaretLabel(for: id) },
                                                 set: { app.store.setScriptCaretLabel($0, for: id) }),
                             onChange: { text in
                                 cancelHover()
                                 semantic.sourceChanged()
                                 scripts.updateSelectedSource(text)
                             },
                             diagnostics: document.diagnostics,
                             completionProvider: completionProvider(for: id),
                             completionResolver: completions.resolver(app.dynamicScriptManager),
                             editHistory: history(for: id),
                             navigation: app.store.scriptNavigation.flatMap { $0.scriptID == id ? $0 : nil },
                             onHover: requestHover,
                             onHoverEnd: cancelHover,
                             onCaret: { semantic.updateCaret($0); insights.caretMoved($0) },
                             onKey: semantic.handleKey,
                             languageEntries: languageEntries,
                             occurrences: insights.occurrences,
                             markers: markers(document, colors: theme.colors))
                .id(id)
                .flex(1, shrink: 1)
        }
    }

    /// Hierarchy arrows and the bulb sit in the marker lane; hovering one
    /// names the declaration, the command and its shortcut.
    private func markers(_ document: ScriptWorkspaceDocument, colors: ColorScheme) -> [TextGutterMarker] {
        var markers = insights.relations.map { relation in
            let count = relation.locations.count > 1 ? " · \(relation.locations.count)" : ""
            return TextGutterMarker("relation-\(relation.direction)-\(relation.line)", line: relation.line,
                                    label: "\(relation.symbol) — \(relation.command.help)\(count)",
                                    icon: relation.command.icon) {
                semantic.show(relation.locations, title: relation.command.title)
            }
        }
        if let line = insights.fixLine {
            let isFix = document.diagnostics.contains { $0.startLine <= line && line <= $0.endLine }
            markers.append(TextGutterMarker("quick-fix-\(line)", line: line, label: ScriptSemanticCommand.codeActions.help,
                                            icon: UIIcons.Editor.lightbulb, color: isFix ? colors.warning : colors.onSurfaceVariant) {
                semantic.perform(.codeActions)
            })
        }
        return markers
    }

    private var languageEntries: [MenuEntry] {
        ScriptSemanticCommand.allCases.map { command in
            .item(MenuItem(id: "script-language-\(command)", title: L(command.title), shortcut: command.shortcut.label,
                           isEnabled: semantic.canPerform(command), action: { semantic.perform(command) }))
        }
    }

    private var languageServiceMessage: String? {
        guard !workspace.isLanguageServiceMessageDismissed else { return nil }
        switch workspace.languageServiceState {
        case .inactive, .ready: return nil
        case .starting: return L("Starting Swift language service…")
        case .unavailable(let message): return message
        }
    }

    private func history(for documentID: String) -> TextEditHistory {
        if let history = histories[documentID] { return history }
        let history = TextEditHistory()
        var next = histories; next[documentID] = history; histories = next
        return history
    }

    private func completionProvider(for scriptID: String) -> TextCompletionProvider {
        let manager = app.dynamicScriptManager, model = app.workstation.scripts, completions = completions
        return { request, reply in
            Task { @MainActor in
                let position = ScriptSourceCoordinates.position(in: request.buffer, atCharacterIndex: request.caretIndex)
                let result = (try? await manager.completion(scriptID: scriptID, at: position)) ?? .empty
                guard model.snapshot.selectedScriptID == scriptID, model.snapshot.selectedDocument?.source == request.buffer else { return }
                reply(completions.convert(result, for: request))
            }
        }
    }

    // MARK: - Hover

    /// Pointer settled on something that may have documentation.
    private func requestHover(_ anchor: TextFieldHoverAnchor) {
        let model = app.workstation.scripts
        guard model.snapshot.languageServiceState == .ready,
              let scriptID = model.snapshot.selectedScriptID,
              let source = model.snapshot.selectedDocument?.source else {
            cancelHover()
            return
        }
        // Asking about punctuation or whitespace would waste a round-trip per
        // mouse move and return nothing printable.
        guard ScriptEditorHoverResolver.queryPosition(in: source, characterIndex: anchor.characterIndex) != nil else {
            cancelHover()
            return
        }
        let windowAnchor = ScriptEditorHoverAnchor(windowX: anchor.windowX, windowY: anchor.windowY)
        hoverPresentation = ScriptEditorHoverPresentation(anchor: windowAnchor, content: nil, isPending: true, message: nil)
        let characterIndex = anchor.characterIndex
        let sequence = hoverSequence
        let manager = app.dynamicScriptManager
        let presentationBinding = $hoverPresentation
        Task { @MainActor in
            guard let presentation = await ScriptEditorHoverResolver.resolve(
                scriptID: scriptID, source: source, characterIndex: characterIndex,
                anchor: windowAnchor, sequence: sequence,
                request: { position in try await manager.hover(scriptID: scriptID, at: position) }
            ) else { return }
            guard model.snapshot.selectedScriptID == scriptID, model.snapshot.selectedDocument?.source == source else { return }
            presentationBinding.wrappedValue = presentation
        }
    }

    /// Pointer left the field or landed somewhere without a symbol: drop any
    /// popup now and make in-flight replies irrelevant.
    private func cancelHover() {
        hoverSequence.invalidateAll()
        if hoverPresentation.isVisible || hoverPresentation.isPending {
            hoverPresentation = .hidden
        }
    }
}
