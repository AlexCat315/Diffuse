import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
#if canImport(AppKit)
import AppKit
#endif

struct ScriptPanel: View {
    let app: EditorApplication

    private var _workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    @State private var searchText = ""
    @State private var hoverPresentation: ScriptEditorHoverPresentation = .hidden
    @State private var hoverSequence = ScriptEditorHoverSequence()
    @State private var caretLabel = ""

    init(app: EditorApplication) {
        self.app = app
        self._workspace = Observed(\.snapshot, on: app.scriptWorkspace)
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            toolbar
            Divider()
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                sidebar.frame(width: 224)
                Divider(axis: .vertical)
                editorPane.flex(1, shrink: 1)
            }
            .flex(1, shrink: 1)
        }
    }

    private var toolbar: some View {
        EditorPanelToolbar {
            Text(L("Swift Scripts")).font(.bodyStrong)
            EditorPanelBadge("\(scriptFiles.count)")
            Spacer(minLength: 0)
            // The dirty state already lives in the status indicator next to the
            // buttons, so a second "Unsaved changes" label only added noise.
            Button(action: newScript) { Text(L("New Script")) }
                .buttonStyle(GhostButtonStyle())
            Button(isEnabled: selectedScript != nil && isDirty && !isCompiling,
                   action: saveSource) { Text(L("Save")) }
                .buttonStyle(GhostButtonStyle())
            Button(isEnabled: selectedScript != nil && !isCompiling,
                   action: compile) {
                Text(isCompiling ? L("Building…") : L("Compile & Reload"))
            }
            .buttonStyle(GhostButtonStyle())
            statusIndicator
            languageServiceIndicator
        }
    }

    /// Traffic light for the SourceKit-LSP session next to the build state.
    /// Empty when the service is healthy — absence is the normal case, not a
    /// placeholder waiting to be filled.
    private var languageServiceIndicator: some View {
        guard languageServiceMessage != nil else {
            return AnyView(EmptyView())
        }
        return AnyView(Row(alignment: .center, spacing: 4) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(.warning)
                .cornerRadius(3)
            Text(L("LSP")).font(.caption).foregroundColor(.warning)
        })
    }

    private var statusIndicator: some View {
        let (label, color): (String, SemanticColorRef) = {
            if isDirty { return (L("Modified"), .warning) }
            switch selectedDocument?.buildState ?? .idle {
            case .idle: return (L("Ready"), .onSurfaceMuted)
            case .building: return (L("Building"), .accent)
            case .succeeded: return (L("Built"), .success)
            case .failed: return (L("Build failed"), .error)
            }
        }()
        return Row(alignment: .center, spacing: 6) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(color)
                .cornerRadius(3)
            Text(label).font(.caption).foregroundColor(color)
        }
    }

    private var sidebar: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelSearchBar(
                L("Filter scripts"),
                text: $searchText,
                summary: "\(visibleScriptFiles.count) / \(scriptFiles.count)"
            )
            Divider()
            if scriptFiles.isEmpty {
                EditorPanelEmptyState(
                    L("No scripts yet"),
                    detail: L("Create a Swift script to add custom behavior to your project.")
                )
                .flex(1, shrink: 1)
            } else if visibleScriptFiles.isEmpty {
                EditorPanelEmptyState(L("No matching scripts")).flex(1, shrink: 1)
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 2) {
                        for file in visibleScriptFiles {
                            ScriptFileRow(file: file,
                                          isSelected: file.identifier == workspace.selectedScriptID,
                                          statusColor: statusColor(for: file.identifier),
                                          action: { select(file) })
                        }
                    }
                    .padding(6)
                }
                .background(.surfaceSunken)
                .flex(1, shrink: 1)
            }
            Divider()
            Text(app.dynamicScriptManager.scriptsDirectoryURL.path, lineLimit: 2)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 9, vertical: 6)
        }
        .background(.surface)
    }

    private var editorPane: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let selectedScript {
                editorHeader(selectedScript)
                Divider()
                ScriptCodeEditor(source: sourceText,
                                 hover: $hoverPresentation,
                                 caretLabel: $caretLabel,
                                 onChange: { text in
                                     app.scriptWorkspace.updateSelectedSource(text)
                                 },
                                 onHover: requestHover,
                                 onHoverEnd: cancelHover)
                    .flex(1, shrink: 1)
                if let languageServiceMessage {
                    Row(alignment: .center, spacing: 8) {
                        Text(languageServiceMessage, lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.warning)
                        Spacer(minLength: 0)
                        Button(action: app.scriptWorkspace.dismissLanguageServiceMessage) {
                            Text(L("Dismiss"))
                        }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(horizontal: 10, vertical: 4)
                    .background(.surfaceSunken)
                }
                if let diagnostics = selectedDocument?.diagnostics, !diagnostics.isEmpty {
                    ScriptEditorDiagnostics(diagnostics: diagnostics)
                }
                if !(selectedDocument?.output ?? "").isEmpty {
                    Divider()
                    buildOutput
                }
            } else {
                EditorPanelEmptyState(
                    L("Select a script"),
                    detail: L("Create a script or choose one from the project list.")
                )
                .flex(1, shrink: 1)
            }
        }
        .frame(minWidth: 260)
    }

    private func editorHeader(_ file: DynamicScriptManager.ScriptFile) -> some View {
        // Single row: the identifier rides next to the file name instead of
        // claiming a second line, and the destructive action is pushed right.
        Row(alignment: .center, spacing: 8) {
            Text(file.displayName).font(.headline)
            Text(".swift").font(.caption).foregroundColor(.onSurfaceMuted)
            Text(file.identifier, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Spacer(minLength: 0)
            Button(action: editInExternalEditor) { Text(L("Open Externally")) }
                .buttonStyle(GhostButtonStyle())
            Button(action: revealInFinder) { Text(L("Reveal")) }
                .buttonStyle(GhostButtonStyle())
            Button(action: deleteSelectedScript) { Text(L("Delete")) }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(horizontal: 12, vertical: 7)
        .background(.surface)
    }

    private var buildOutput: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text(isBuildFailed ? L("Build Diagnostics") : L("Build Output"))
                    .font(.caption)
                    .foregroundColor(isBuildFailed ? .error : .onSurfaceMuted)
                Spacer(minLength: 0)
                Button(action: app.scriptWorkspace.clearSelectedOutput) { Text(L("Clear")) }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(horizontal: 10, vertical: 5)
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Text(selectedDocument?.output ?? "")
                    .font(.mono)
                    .foregroundColor(isBuildFailed ? .error : .onSurfaceMuted)
                    .padding(horizontal: 10, vertical: 6)
                    .frame(maxWidth: .infinity)
            }
            .background(.surfaceSunken)
            .frame(maxHeight: 132)
        }
    }

    private var visibleScriptFiles: [DynamicScriptManager.ScriptFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scriptFiles }
        return scriptFiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedScript: DynamicScriptManager.ScriptFile? {
        selectedDocument?.file
    }

    private var workspace: ScriptWorkspaceSnapshot { _workspace.wrappedValue }

    private var scriptFiles: [DynamicScriptManager.ScriptFile] {
        workspace.documents.map(\.file)
    }

    private var selectedDocument: ScriptWorkspaceDocument? { workspace.selectedDocument }

    private var sourceText: Binding<String> {
        Binding(
            get: { app.scriptWorkspace.snapshot.selectedDocument?.source ?? "" },
            set: app.scriptWorkspace.updateSelectedSource
        )
    }

    private var isDirty: Bool { selectedDocument?.isDirty ?? false }

    private var isCompiling: Bool { selectedDocument?.buildState.isBuilding ?? false }

    private var isBuildFailed: Bool { selectedDocument?.buildState.isFailed ?? false }

    private var languageServiceMessage: String? {
        switch workspace.languageServiceState {
        case .inactive, .ready: return nil
        case .starting: return L("Starting Swift language service…")
        case .unavailable(let message): return message
        }
    }

    private func statusColor(for scriptID: String) -> SemanticColorRef {
        guard let document = workspace.documents.first(where: { $0.file.identifier == scriptID }) else {
            return .onSurfaceMuted
        }
        if document.isDirty { return .warning }
        switch document.buildState {
        case .succeeded: return .success
        case .failed: return .error
        case .building: return .accent
        case .idle: return .onSurfaceMuted
        }
    }

    private func select(_ file: DynamicScriptManager.ScriptFile) {
        guard file.identifier != workspace.selectedScriptID else { return }
        if app.scriptWorkspace.select(scriptID: file.identifier) {
            cancelHover()
        }
    }

    private func newScript() {
        let existingNames = Set(scriptFiles.map { $0.displayName.lowercased() })
        var name = "NewScript"
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "NewScript\(suffix)"
            suffix += 1
        }
        _ = app.scriptWorkspace.createScript(name: name, source: ScriptTemplate.default)
    }

    private func saveSource() { _ = app.scriptWorkspace.persistSelected(reportSuccess: true) }

    private func editInExternalEditor() {
        guard let file = selectedScript, app.scriptWorkspace.persistSelected() else { return }
        openInExternalEditor(url: file.url)
    }

    private func openInExternalEditor(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        app.scriptWorkspace.setSelectedOutput(L("Open this file in your editor: \(url.path)"))
        #endif
    }

    private func revealInFinder() {
        guard let file = selectedScript else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
        #else
        app.scriptWorkspace.setSelectedOutput(L("Script path: \(file.url.path)"))
        #endif
    }

    private func deleteSelectedScript() {
        guard let file = selectedScript else { return }
        let workspaceModel = app.scriptWorkspace
        Task { @MainActor in
            #if canImport(AppKit)
            let alert = NSAlert()
            alert.messageText = L("Delete \(file.displayName).swift?")
            alert.informativeText = L("This permanently removes the script from the project.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            #endif
            _ = workspaceModel.deleteSelectedScript()
        }
    }

    // MARK: - Hover

    /// Pointer settled on something that may have documentation.
    private func requestHover(_ anchor: TextFieldHoverAnchor) {
        guard app.dynamicScriptManager.isLanguageServiceAvailable,
              let scriptID = workspace.selectedScriptID else {
            cancelHover()
            return
        }
        let source = sourceText.wrappedValue
        // Asking about punctuation or whitespace would waste a round-trip per
        // mouse move and return nothing printable.
        guard ScriptEditorHoverResolver.queryPosition(in: source,
                                                      characterIndex: anchor.characterIndex) != nil else {
            cancelHover()
            return
        }

        let windowAnchor = ScriptEditorHoverAnchor(windowX: anchor.windowX,
                                                   windowY: anchor.windowY)
        hoverPresentation = ScriptEditorHoverPresentation(anchor: windowAnchor,
                                                          content: nil,
                                                          isPending: true,
                                                          message: nil)
        let characterIndex = anchor.characterIndex
        let sequence = hoverSequence
        let manager = app.dynamicScriptManager
        let presentationBinding = $hoverPresentation
        Task { @MainActor in
            guard let presentation = await ScriptEditorHoverResolver.resolve(
                scriptID: scriptID,
                source: source,
                characterIndex: characterIndex,
                anchor: windowAnchor,
                sequence: sequence,
                request: { position in
                    try await manager.hover(scriptID: scriptID, at: position)
                }
            ) else { return }
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

    private func compile() {
        app.scriptWorkspace.compileSelected()
    }
}

private struct ScriptFileRow: View {
    let file: DynamicScriptManager.ScriptFile
    let isSelected: Bool
    let statusColor: SemanticColorRef
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(alignment: .center, spacing: 7) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(statusColor)
                    .cornerRadius(3)
                Text(file.displayName, lineLimit: 1).font(.caption)
                Spacer(minLength: 0)
                Text("SWIFT").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 7, vertical: 6)
            .background(isSelected ? .accent.opacity(0.15) : SemanticColorRef { _ in .clear })
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}
