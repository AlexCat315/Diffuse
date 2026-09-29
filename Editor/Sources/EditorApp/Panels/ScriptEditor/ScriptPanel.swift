import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
#if canImport(AppKit)
import AppKit
#endif

struct ScriptPanel: View {
    let app: EditorApplication

    @State private var scriptFiles: [DynamicScriptManager.ScriptFile]
    @State private var selectedScriptID: String?
    @State private var searchText = ""
    @State private var sourceText: String
    @State private var savedSource: String
    @State private var status: DynamicScriptManager.CompilationStatus = .idle
    @State private var outputText = ""
    @State private var isCompiling = false
    @State private var diagnosticsByScriptID: [String: [ScriptLanguageDiagnostic]] = [:]
    @State private var languageServiceMessage = L("Starting Swift language service…")
    @State private var hoverPresentation: ScriptEditorHoverPresentation = .hidden
    @State private var hoverSequence = ScriptEditorHoverSequence()
    @State private var caretLabel = ""

    init(app: EditorApplication) {
        self.app = app
        let files = (try? app.dynamicScriptManager.scanScriptFiles()) ?? []
        let firstFile = files.first
        let initialSource = firstFile.flatMap { try? app.dynamicScriptManager.readSource(at: $0.url) } ?? ""
        _scriptFiles = State(wrappedValue: files)
        _selectedScriptID = State(wrappedValue: firstFile?.identifier)
        _sourceText = State(wrappedValue: initialSource)
        _savedSource = State(wrappedValue: initialSource)

        let diagnosticsState = _diagnosticsByScriptID
        let serviceMessageState = _languageServiceMessage
        Task { @MainActor in
            do {
                try await app.dynamicScriptManager.startLanguageService { update in
                    Task { @MainActor in
                        var current = diagnosticsState.wrappedValue
                        current[update.scriptID] = update.diagnostics
                        diagnosticsState.wrappedValue = current
                    }
                }
                serviceMessageState.wrappedValue = ""
            } catch {
                serviceMessageState.wrappedValue = error.localizedDescription
            }
        }
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
        guard !languageServiceMessage.isEmpty else {
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
            switch status {
            case .idle: return (L("Ready"), .onSurfaceMuted)
            case .compiling: return (L("Building"), .accent)
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
                                          isSelected: file.identifier == selectedScriptID,
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
                ScriptCodeEditor(source: $sourceText,
                                 hover: $hoverPresentation,
                                 caretLabel: $caretLabel,
                                 onChange: { text in
                                     guard let scriptID = selectedScriptID else { return }
                                     Task {
                                         try? await app.dynamicScriptManager
                                             .updateLanguageSource(scriptID: scriptID, text: text)
                                     }
                                 },
                                 onHover: requestHover,
                                 onHoverEnd: cancelHover)
                    .flex(1, shrink: 1)
                if !languageServiceMessage.isEmpty {
                    Row(alignment: .center, spacing: 8) {
                        Text(languageServiceMessage, lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.warning)
                        Spacer(minLength: 0)
                        Button(action: { languageServiceMessage = "" }) { Text(L("Dismiss")) }
                            .buttonStyle(GhostButtonStyle())
                    }
                    .padding(horizontal: 10, vertical: 4)
                    .background(.surfaceSunken)
                }
                if let diagnostics = diagnosticsByScriptID[selectedScript.identifier],
                   !diagnostics.isEmpty {
                    ScriptEditorDiagnostics(diagnostics: diagnostics)
                }
                if !outputText.isEmpty {
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
                Text(status.isFailed ? L("Build Diagnostics") : L("Build Output"))
                    .font(.caption)
                    .foregroundColor(status.isFailed ? .error : .onSurfaceMuted)
                Spacer(minLength: 0)
                Button(action: { outputText = "" }) { Text(L("Clear")) }
                    .buttonStyle(GhostButtonStyle())
            }
            .padding(horizontal: 10, vertical: 5)
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Text(outputText)
                    .font(.mono)
                    .foregroundColor(status.isFailed ? .error : .onSurfaceMuted)
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
        scriptFiles.first { $0.identifier == selectedScriptID }
    }

    private var isDirty: Bool { selectedScript != nil && sourceText != savedSource }

    private func statusColor(for scriptID: String) -> SemanticColorRef {
        let itemStatus = scriptID == selectedScriptID ? status : .idle
        switch itemStatus {
        case .succeeded: return .success
        case .failed: return .error
        case .compiling: return .accent
        case .idle: return .onSurfaceMuted
        }
    }

    private func refresh() {
        do {
            scriptFiles = try app.dynamicScriptManager.scanScriptFiles()
        } catch {
            outputText = L("Failed to scan scripts: \(error.localizedDescription)")
        }
    }

    private func select(_ file: DynamicScriptManager.ScriptFile) {
        guard file.identifier != selectedScriptID, persistSource() else { return }
        do {
            sourceText = try app.dynamicScriptManager.readSource(at: file.url)
            savedSource = sourceText
            selectedScriptID = file.identifier
            status = .idle
            outputText = ""
            // A pending reply belongs to the previous file's positions.
            cancelHover()
        } catch {
            outputText = L("Failed to read script: \(error.localizedDescription)")
            status = .failed(message: error.localizedDescription)
        }
    }

    private func newScript() {
        guard persistSource() else { return }
        let existingNames = Set(scriptFiles.map { $0.displayName.lowercased() })
        var name = "NewScript"
        var suffix = 2
        while existingNames.contains(name.lowercased()) {
            name = "NewScript\(suffix)"
            suffix += 1
        }
        do {
            let url = try app.dynamicScriptManager.createScript(name: name, source: ScriptTemplate.default)
            refresh()
            Task { try? await app.dynamicScriptManager.refreshLanguageWorkspace() }
            if let file = scriptFiles.first(where: { $0.url == url }) {
                selectedScriptID = nil
                select(file)
            }
        } catch {
            outputText = L("Failed to create script: \(error.localizedDescription)")
            status = .failed(message: error.localizedDescription)
        }
    }

    private func saveSource() { _ = persistSource(reportSuccess: true) }

    private func persistSource(reportSuccess: Bool = false) -> Bool {
        guard isDirty, let selectedScript else { return true }
        do {
            try app.dynamicScriptManager.writeSource(sourceText, at: selectedScript.url)
            savedSource = sourceText
            if reportSuccess {
                outputText = L("Saved \(selectedScript.displayName).swift")
                status = .idle
            }
            return true
        } catch {
            outputText = L("Failed to save script: \(error.localizedDescription)")
            status = .failed(message: error.localizedDescription)
            return false
        }
    }

    private func editInExternalEditor() {
        guard let file = selectedScript, persistSource() else { return }
        openInExternalEditor(url: file.url)
    }

    private func openInExternalEditor(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        outputText = L("Open this file in your editor: \(url.path)")
        #endif
    }

    private func revealInFinder() {
        guard let file = selectedScript else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
        #else
        outputText = L("Script path: \(file.url.path)")
        #endif
    }

    private func deleteSelectedScript() {
        guard let file = selectedScript else { return }
        Task { @MainActor in
            guard persistSource() else { return }
            #if canImport(AppKit)
            let alert = NSAlert()
            alert.messageText = L("Delete \(file.displayName).swift?")
            alert.informativeText = L("This permanently removes the script from the project.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            #endif
            do {
                try app.dynamicScriptManager.deleteScript(file)
                Task { try? await app.dynamicScriptManager.refreshLanguageWorkspace() }
                selectedScriptID = nil
                sourceText = ""
                savedSource = ""
                status = .idle
                outputText = ""
                refresh()
            } catch {
                outputText = L("Failed to delete script: \(error.localizedDescription)")
                status = .failed(message: error.localizedDescription)
            }
        }
    }

    // MARK: - Hover

    /// Pointer settled on something that may have documentation.
    private func requestHover(_ anchor: TextFieldHoverAnchor) {
        guard app.dynamicScriptManager.isLanguageServiceAvailable,
              let scriptID = selectedScriptID else {
            cancelHover()
            return
        }
        let source = sourceText
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
        Task { @MainActor in
            guard let presentation = await ScriptEditorHoverResolver.resolve(
                scriptID: scriptID,
                source: source,
                characterIndex: characterIndex,
                anchor: windowAnchor,
                sequence: sequence,
                request: { position in
                    try await app.dynamicScriptManager.hover(scriptID: scriptID, at: position)
                }
            ) else { return }
            hoverPresentation = presentation
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
        guard let file = selectedScript, persistSource() else { return }
        isCompiling = true
        status = .compiling
        outputText = L("Compiling \(file.displayName).swift…")
        app.dynamicScriptManager.compileAndLoad(scriptID: file.identifier, sourceURL: file.url) { result in
            isCompiling = false
            status = result
            switch result {
            case .succeeded:
                app.scene.registerDynamicScriptOption(identifier: file.identifier,
                                                      displayName: file.displayName)
                app.store.dispatch(.forceUIRefresh)
                outputText = L("Compiled and reloaded \(file.displayName).swift")
            case .failed(let message):
                outputText = message
            case .compiling, .idle:
                break
            }
        }
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