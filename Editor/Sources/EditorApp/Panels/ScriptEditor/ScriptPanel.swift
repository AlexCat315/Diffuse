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
    @State private var bottomPanel = ScriptBottomPanel.problems
    @State private var isBottomPanelExpanded = false
    @State private var isNavigatorVisible = false
    @State private var isActionsMenuPresented = false
    @State private var isFileMenuPresented = false

    init(app: EditorApplication) {
        self.app = app
        self._workspace = Observed(\.snapshot, on: app.scriptWorkspace)
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            toolbar
            Divider()
            trustBanner
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                if isNavigatorVisible {
                    sidebar.frame(width: 180)
                    Divider(axis: .vertical)
                }
                editorPane.flex(1, shrink: 1, basis: 0)
            }
            .flex(1, shrink: 1)
        }
    }

    private var toolbar: some View {
        EditorPanelToolbar(spacing: 4) {
            Button(icon: .resource(toolbarIcon("folder")), size: 12,
                   isSelected: isNavigatorVisible, tooltip: L("Project Scripts")) {
                isNavigatorVisible.toggle()
            }
            .buttonStyle(ToggleButtonStyle(minWidth: 24, height: 24))
            Text("Swift").font(.label).foregroundColor(.onSurfaceVariant)
            Spacer(minLength: 0)
            languageServiceIndicator
            statusIndicator
            Button(icon: .resource(toolbarIcon("save")), size: 12,
                   isEnabled: selectedScript != nil && isDirty && !isCompiling,
                   tooltip: L("Save"), action: saveSource)
                .buttonStyle(.ghost)
            if isCompiling {
                Button(icon: .resource(toolbarIcon("stop")), size: 11,
                       tooltip: L("Stop Build"), action: cancelBuild)
                    .buttonStyle(.destructive)
            } else {
                Button(isEnabled: selectedScript != nil && workspace.trustState.allowsExecution,
                       tooltip: L("Build & Reload"),
                       action: compile) {
                    Row(alignment: .center, spacing: 4) {
                        Icon(toolbarIcon("play"), size: 10, color: .onAccent)
                        Text(L("Build")).font(.label)
                    }
                }
                .buttonStyle(.primary)
            }
            Popover(isPresented: $isActionsMenuPresented, width: 200) {
                Text("···").font(.bodyStrong).padding(horizontal: 5, vertical: 3)
            } content: {
                Menu(actionEntries, width: 200, onItemActivated: { isActionsMenuPresented = false })
            }
        }
    }

    private func toolbarIcon(_ name: String) -> BundleImageResource {
        .svg(named: name, in: EditorAppResourceBundle.bundle, subdirectory: "ToolbarIcons")
    }

    private var actionEntries: [MenuEntry] {
        [
            .item(MenuItem(id: "new", title: L("New Script"), action: newScript)),
            .item(MenuItem(id: "external", title: L("Open External"), isEnabled: selectedScript != nil, action: editInExternalEditor)),
            .item(MenuItem(id: "reveal", title: L("Reveal"), isEnabled: selectedScript != nil, action: revealInFinder)),
            .separator("file-actions"),
            .item(MenuItem(id: "trust", title: workspace.trustState.allowsExecution ? L("Revoke Project Trust") : L("Trust Project"),
                           action: workspace.trustState.allowsExecution ? revokeProjectTrust : trustProject)),
            .separator("trust-actions"),
            .item(MenuItem(id: "delete", title: L("Delete"), isEnabled: selectedScript != nil,
                           role: .destructive, action: deleteSelectedScript)),
        ]
    }

    private var trustBanner: some View {
        if !workspace.trustState.allowsExecution {
            return AnyView(Row(alignment: .center, spacing: 10) {
                Column(alignment: .leading, spacing: 2) {
                    Text(L("Swift script execution is restricted"))
                        .font(.bodyStrong)
                        .foregroundColor(.warning)
                    Text(L("Scripts are native code with the Editor's permissions. Trust only projects you know."),
                         lineLimit: 2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }
                .flex(1, shrink: 1)
                Button(action: trustProject) { Text(L("Trust Project")) }
                    .buttonStyle(.primary)
            }
            .padding(horizontal: 12, vertical: 8)
            .background(.warning.opacity(0.10)))
        }
        if let warning = workspace.trustWarning {
            return AnyView(Row(alignment: .center, spacing: 8) {
                Text(warning, lineLimit: 2)
                    .font(.caption)
                    .foregroundColor(.warning)
                Spacer(minLength: 0)
            }
            .padding(horizontal: 12, vertical: 6)
            .background(.warning.opacity(0.08)))
        }
        return AnyView(EmptyView())
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
            case .cancelled: return (L("Cancelled"), .onSurfaceMuted)
            case .blocked: return (L("Restricted"), .warning)
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
            Row(alignment: .center, spacing: 6) {
                Text(L("PROJECT SCRIPTS"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
                EditorPanelBadge("\(scriptFiles.count)")
            }
            .padding(horizontal: 10, vertical: 7)
            EditorPanelSearchBar(
                L("Search scripts"),
                text: $searchText,
                summary: searchText.isEmpty ? nil : "\(visibleDocuments.count) / \(scriptFiles.count)"
            )
            Divider()
            if scriptFiles.isEmpty {
                EditorPanelEmptyState(
                    L("No scripts yet"),
                    detail: L("Create a Swift script to add custom behavior to your project.")
                )
                .flex(1, shrink: 1)
            } else if visibleDocuments.isEmpty {
                EditorPanelEmptyState(L("No matching scripts")).flex(1, shrink: 1)
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 1) {
                        for document in visibleDocuments {
                            ScriptFileRow(document: document,
                                          isSelected: document.file.identifier == workspace.selectedScriptID,
                                          action: { select(document.file) })
                        }
                    }
                    .padding(horizontal: 5, vertical: 6)
                }
                .background(.surfaceSunken)
                .flex(1, shrink: 1)
            }
            Divider()
            Row(alignment: .center, spacing: 6) {
                Text("Scripts/", lineLimit: 1)
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
                Button(action: revealScriptsDirectory) { Text(L("Reveal")) }
                    .buttonStyle(.ghost)
            }
            .padding(horizontal: 9, vertical: 5)
        }
        .background(.surface)
    }

    private var editorPane: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let selectedScript {
                editorHeader(selectedScript)
                Divider()
                externalChangeBanner
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
                Divider()
                bottomPanelView
            } else {
                EditorPanelEmptyState(
                    L("Select a script"),
                    detail: L("Create a script or choose one from the project list.")
                )
                .flex(1, shrink: 1)
            }
        }
        .frame(minWidth: 0)
    }

    private func editorHeader(_ file: DynamicScriptManager.ScriptFile) -> some View {
        Row(alignment: .center, spacing: 0) {
            Popover(isPresented: $isFileMenuPresented, width: 240) {
                Row(alignment: .center, spacing: 6) {
                    Text("S").font(.label).foregroundColor(Color(red: 0x77, green: 0xA8, blue: 0xFF))
                    Text("\(file.displayName).swift", lineLimit: 1)
                        .font(.label).foregroundColor(Color(red: 0xDA, green: 0xE2, blue: 0xF2))
                    if isDirty {
                        Box { EmptyView() }
                            .frame(width: 5, height: 5)
                            .background(.warning)
                            .cornerRadius(3)
                    }
                    Icon(UICommonIcons.chevronDown, size: 8,
                         color: Color(red: 0x95, green: 0xA3, blue: 0xBE))
                }
                .padding(horizontal: 10, vertical: 6)
                .background(Color(red: 0x28, green: 0x32, blue: 0x47))
            } content: {
                Menu(scriptFiles.map { candidate in
                    .item(MenuItem(id: candidate.identifier,
                                   title: "\(candidate.displayName).swift",
                                   isSelected: candidate.identifier == file.identifier,
                                   action: { select(candidate) }))
                }, width: 240, onItemActivated: { isFileMenuPresented = false })
            }
            Spacer(minLength: 0)
        }
        .background(Color(red: 0x1D, green: 0x25, blue: 0x35))
    }

    private var externalChangeBanner: some View {
        guard let selectedDocument else { return AnyView(EmptyView()) }
        switch selectedDocument.externalChange {
        case .none:
            return AnyView(EmptyView())
        case .modifiedOnDisk:
            return AnyView(externalChangeRow(
                message: L("This file changed on disk while you have unsaved edits."),
                diskAction: L("Reload from Disk"),
                editorAction: L("Keep Editor Version")
            ))
        case .deletedOnDisk:
            return AnyView(externalChangeRow(
                message: L("This file was deleted outside the Editor."),
                diskAction: L("Close File"),
                editorAction: L("Recreate File")
            ))
        }
    }

    private func externalChangeRow(message: String,
                                   diskAction: String,
                                   editorAction: String) -> some View {
        Row(alignment: .center, spacing: 8) {
            Text(L("EXTERNAL CHANGE"))
                .font(.caption)
                .foregroundColor(.warning)
            Text(message, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)
                .flex(1, shrink: 1)
            Button(action: { app.scriptWorkspace.resolveSelectedExternalChange(useDiskVersion: true) }) {
                Text(diskAction)
            }
            .buttonStyle(.secondary)
            Button(action: { app.scriptWorkspace.resolveSelectedExternalChange(useDiskVersion: false) }) {
                Text(editorAction)
            }
            .buttonStyle(.primary)
        }
        .padding(horizontal: 10, vertical: 6)
        .background(.warning.opacity(0.10))
    }

    private var bottomPanelView: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Button(isSelected: bottomPanel == .problems,
                       action: {
                           bottomPanel = .problems
                           isBottomPanelExpanded = true
                       }) {
                    Text("\(L("Problems")) \(selectedDocument?.diagnostics.count ?? 0)")
                }
                .buttonStyle(TabButtonStyle(height: 26))
                Button(isSelected: bottomPanel == .output,
                       action: {
                           bottomPanel = .output
                           isBottomPanelExpanded = true
                       }) {
                    Text(L("Build Output"))
                }
                .buttonStyle(TabButtonStyle(height: 26))
                Spacer(minLength: 0)
                if bottomPanel == .output, !(selectedDocument?.output ?? "").isEmpty {
                    Button(action: app.scriptWorkspace.clearSelectedOutput) { Text(L("Clear")) }
                        .buttonStyle(.ghost)
                }
                Button(action: { isBottomPanelExpanded.toggle() }) {
                    Text(isBottomPanelExpanded ? L("Hide") : L("Show"))
                }
                .buttonStyle(.ghost)
            }
            .padding(horizontal: 2, vertical: 0)
            .background(.surface)

            if isBottomPanelExpanded {
                if bottomPanel == .problems {
                    problemsPanel
                } else {
                    outputPanel
                }
            }
        }
    }

    private var problemsPanel: some View {
        let diagnostics = selectedDocument?.diagnostics ?? []
        return ScrollView(.vertical, scrollbarGutter: .stable) {
            if diagnostics.isEmpty {
                Row(alignment: .center, spacing: 8) {
                    Box { EmptyView() }
                        .frame(width: 6, height: 6)
                        .background(.success)
                        .cornerRadius(3)
                    Text(L("No problems detected"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Spacer(minLength: 0)
                }
                .padding(horizontal: 10, vertical: 10)
            } else {
                Column(alignment: .leading, spacing: 2) {
                    for diagnostic in diagnostics {
                        ScriptDiagnosticRow(diagnostic: diagnostic)
                    }
                }
                .padding(horizontal: 7, vertical: 6)
            }
        }
        .frame(height: 120)
        .background(.surfaceSunken)
    }

    private var outputPanel: some View {
        ScrollView(.vertical, scrollbarGutter: .stable) {
            Text((selectedDocument?.output ?? "").isEmpty
                 ? L("Build output will appear here.")
                 : selectedDocument?.output ?? "")
                .font(.mono)
                .foregroundColor(isBuildFailed ? .error : .onSurfaceMuted)
                .padding(horizontal: 10, vertical: 8)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 120)
        .background(.surfaceSunken)
    }

    private var visibleDocuments: [ScriptWorkspaceDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.documents }
        return workspace.documents.filter {
            $0.file.displayName.localizedCaseInsensitiveContains(query)
                || $0.file.identifier.localizedCaseInsensitiveContains(query)
                || $0.file.assetID.shortDescription.localizedCaseInsensitiveContains(query)
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

    private func revealScriptsDirectory() {
        #if canImport(AppKit)
        NSWorkspace.shared.open(app.dynamicScriptManager.scriptsDirectoryURL)
        #else
        app.scriptWorkspace.setSelectedOutput(app.dynamicScriptManager.scriptsDirectoryURL.path)
        #endif
    }

    private func trustProject() {
        app.scriptWorkspace.setProjectTrusted(true)
    }

    private func revokeProjectTrust() {
        app.scriptWorkspace.setProjectTrusted(false)
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

    private func cancelBuild() {
        app.scriptWorkspace.cancelSelectedBuild()
    }
}

private enum ScriptBottomPanel: Sendable, Equatable {
    case problems
    case output
}

private struct ScriptFileRow: View {
    let document: ScriptWorkspaceDocument
    let isSelected: Bool
    let action: () -> Void

    private var statusColor: SemanticColorRef {
        if document.externalChange.requiresResolution { return .warning }
        if document.isDirty { return .warning }
        switch document.buildState {
        case .succeeded: return .success
        case .failed: return .error
        case .building: return .accent
        case .blocked: return .warning
        case .idle, .cancelled: return .onSurfaceMuted
        }
    }

    var body: some View {
        Button(action: action) {
            Row(alignment: .center, spacing: 8) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(statusColor)
                    .cornerRadius(3)
                Box(direction: .column, alignItems: .center, justifyContent: .center) {
                    Text("S")
                        .font(.caption)
                        .foregroundColor(.accent)
                }
                .frame(width: 24, height: 24)
                .background(.background)
                .cornerRadius(4)
                Column(alignment: .leading, spacing: 1) {
                    Row(alignment: .center, spacing: 3) {
                        Text(document.file.displayName, lineLimit: 1)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                        Text(".swift")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    Text("asset:\(document.file.assetID.shortDescription)", lineLimit: 1)
                        .font(.mono)
                        .foregroundColor(.onSurfaceMuted)
                }
                .flex(1, shrink: 1)
                Spacer(minLength: 0)
                if document.isDirty {
                    Text("M").font(.caption).foregroundColor(.warning)
                }
            }
            .padding(horizontal: 7, vertical: 7)
            .background(isSelected ? .accent.opacity(0.16) : SemanticColorRef { _ in .clear })
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}
