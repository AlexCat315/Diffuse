internal import EditorCore
internal import StudioDocuments
internal import CoveUI
internal import CoveUIRuntime
internal import CoveUIWorkspace

/// Live, compact status on the same surface as the title bar: problems and
/// document state on the left; background work and the Agent on the right.
/// Every segment that reports something actionable opens the place to act.
struct EditorStatusBar: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let onCommand: (EditorCommand) -> Void
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    private var documents: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private var tasks: Observed<EditorTasks, TaskSnapshot>
    private var layout: Observed<WorkspaceController, UInt64>

    init(app: EditorApplication, controller: WorkspaceController, onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.controller = controller
        layout = Observed(\.version, on: controller)
        self.onCommand = onCommand
        workspace = Observed(\.snapshot, on: app.workstation.scripts)
        documents = Observed(\.snapshot, on: app.workstation.documents)
        tasks = Observed(\.snapshot, on: app.workstation.tasks)
    }

    var body: some View {
        let store = app.store
        let snapshot = workspace.wrappedValue
        let hasScene = store.content == .scene
        let _ = layout.wrappedValue
        let document = documents.wrappedValue.selected
        // Scene modes show file facts only while the editor tab is in front.
        let showsDocumentInfo = !hasScene || controller.document.groups.values.contains {
            $0.activePanelID == "documents" && !$0.isCollapsed
        }
        let scriptID = document.flatMap { app.workstation.scriptID(forDocument: $0.path) }
        Row(alignment: .center, spacing: 10) {
            // Being connected is the normal state and needs no mark; only
            // losing the connection is worth a signal.
            if !store.connected {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(.warning)
                    .cornerRadius(3)
                    .accessibility { $0.label = L("Offline") }
                    .debugName("editor-status-connection")
            }
            problems(EditorProblemSummary(documents: snapshot.documents, consoleEntries: store.consoleEntries,
                                          taskProblems: tasks.wrappedValue.problems))
            SourceControlStatus(app: app) { onCommand(.showPanel("source-control")) }
            if hasScene {
                if store.sceneDirty { unsaved }
                Text("r\(store.sceneRevision)").font(.caption).foregroundColor(.onSurfaceMuted)
                    .accessibility { $0.label = L("Revision") }
                if store.selectedEntityIDsCount > 0 {
                    Text("\(L("Selection")) \(store.selectedEntityIDsCount)").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            } else if let document {
                if document.isDirty { unsaved }
            }

            Spacer(minLength: 0)

            if showsDocumentInfo, let document {
                if let scriptID {
                    Text(store.scriptCaretLabel(for: scriptID)).font(.caption).foregroundColor(.onSurfaceVariant)
                }
                Text(L(DocumentKind(path: document.path).name) + " · UTF-8 · " + (document.text.contains("\r\n") ? "CRLF" : "LF"))
                    .font(.caption).foregroundColor(.onSurfaceMuted)
                Divider(axis: .vertical).frame(height: 12)
            }
            TaskStatus(app: app) { onCommand(.showPanel("tasks")) }
            Button(icon: .resource(UIIcons.Editor.terminal), size: 12, tooltip: L("Terminal")) {
                onCommand(.togglePanel("terminal"))
            }.buttonStyle(EditorChromeButtonStyle(height: 20))
                .accessibility { $0.label = L("Terminal") }
                .debugName("editor-status-terminal")
            activity(snapshot)
            LanguageServerStatus(app: app, snapshot: snapshot, onCommand: onCommand)
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(height: 24)
        .debugName("editor-status-bar")
    }

    private var unsaved: some View {
        Row(alignment: .center, spacing: 4) {
            Box { EmptyView() }.frame(width: 5, height: 5).background(.warning).cornerRadius(3)
            Text(L("Unsaved")).font(.caption).foregroundColor(.warning)
        }.debugName("editor-status-unsaved")
    }

    private func problems(_ summary: EditorProblemSummary) -> some View {
        Button(tooltip: L("Problems")) {
            onCommand(.showProblems)
        } label: {
            Row(alignment: .center, spacing: 8) {
                Row(alignment: .center, spacing: 3) {
                    Icon(UIIcons.Status.xCircle, size: 11, color: summary.errors > 0 ? .error : .onSurfaceMuted)
                    Text("\(summary.errors)").font(.caption)
                        .foregroundColor(summary.errors > 0 ? .error : .onSurfaceMuted)
                }
                Row(alignment: .center, spacing: 3) {
                    Icon(UIIcons.Status.alertTriangle, size: 11, color: summary.warnings > 0 ? .warning : .onSurfaceMuted)
                    Text("\(summary.warnings)").font(.caption)
                        .foregroundColor(summary.warnings > 0 ? .warning : .onSurfaceMuted)
                }
            }
        }
        .buttonStyle(EditorChromeButtonStyle(height: 20))
        .accessibility { $0.label = "\(L("Problems")) \(summary.errors) / \(summary.warnings)" }
        .debugName("editor-status-problems")
    }

    /// Background work in priority order: long operations, script builds, then
    /// the most recent warning or error the editor raised. Subsystem log records
    /// stay in the console: they are diagnostics, not something to act on.
    /// Idle shows nothing.
    @ViewBuilder
    private func activity(_ snapshot: ScriptWorkspaceSnapshot) -> some View {
        let store = app.store
        let building = snapshot.documents.filter { $0.buildState.isBuilding }.count
        if let operation = store.operations.last(where: { $0.status == .running }) {
            Row(alignment: .center, spacing: 6) {
                Spinner(size: 10)
                Text(L(operation.message), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                    .frame(maxWidth: 220).clipped()
                if operation.total > 0 {
                    ProgressView(value: Double(operation.completed) / Double(operation.total)) { $0.height = 3 }
                        .frame(width: 54)
                    Text("\(operation.completed)/\(operation.total)").font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }.debugName("editor-status-activity")
        } else if building > 0 {
            Row(alignment: .center, spacing: 6) {
                Spinner(size: 10)
                Text("\(L("Compiling scripts…")) \(building)").font(.caption).foregroundColor(.onSurfaceVariant)
            }.debugName("editor-status-activity")
        } else if let latest = store.latestConsoleEntry, latest.severity != .info, latest.record == nil {
            Button(tooltip: L(latest.message)) { onCommand(.showProblems) } label: {
                Text(L(latest.message), lineLimit: 1).font(.caption)
                    .foregroundColor(latest.severity == .error ? .error : .warning)
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.plain).flex(0, shrink: 1).frame(minWidth: 0)
            .debugName("editor-status-activity")
        }
    }
}

/// Branch, sync counts and pending changes; opens the Source Control panel.
private struct SourceControlStatus: View {
    let app: EditorApplication
    let action: () -> Void
    private let observed: Observed<EditorVersionControl, VersionControlSnapshot>

    init(app: EditorApplication, action: @escaping () -> Void) {
        self.app = app
        self.action = action
        observed = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    @ViewBuilder
    var body: some View {
        let snapshot = observed.wrappedValue
        if let repository = snapshot.repository {
            let tracking = snapshot.status.tracking
            let changes = Set(snapshot.status.changes.map(\.path)).count
            Button(tooltip: L("Source Control") + " · " + repository.system.title, action: action) {
                Row(alignment: .center, spacing: 4) {
                    if snapshot.operation != nil {
                        Spinner(size: 10)
                    } else {
                        Icon(UIIcons.Editor.gitBranch, size: 11, color: .onSurfaceMuted)
                    }
                    Text(tracking.branch ?? L("Detached"), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                        .frame(maxWidth: 160).clipped()
                    if tracking.ahead > 0 || tracking.behind > 0 {
                        Text("↓\(tracking.behind) ↑\(tracking.ahead)").font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    if changes > 0 {
                        Text("● \(changes)").font(.caption).foregroundColor(.warning)
                    }
                }
            }
            .buttonStyle(EditorChromeButtonStyle(height: 20))
            .accessibility { $0.label = L("Branch") + " " + (tracking.branch ?? "") + ", \(changes) " + L("changes") }
            .debugName("editor-status-source-control")
        }
    }
}
