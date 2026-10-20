internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Live, compact status on the same surface as the title bar: problems and
/// document state on the left; background work and the Agent on the right.
/// Every segment that reports something actionable opens the place to act.
struct EditorStatusBar: View {
    let app: EditorApplication
    let showsScriptInfo: Bool
    let onCommand: (EditorCommand) -> Void
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>

    init(app: EditorApplication, showsScriptInfo: Bool, onCommand: @escaping (EditorCommand) -> Void) {
        self.app = app
        self.showsScriptInfo = showsScriptInfo
        self.onCommand = onCommand
        workspace = Observed(\.snapshot, on: app.workstation.scripts)
    }

    var body: some View {
        let store = app.store
        let snapshot = workspace.wrappedValue
        Row(alignment: .center, spacing: 10) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(store.connected ? SemanticColorRef.success : .warning)
                .cornerRadius(3)
                .accessibility { $0.label = store.connected ? L("Connected") : L("Offline") }
                .debugName("editor-status-connection")
            problems(EditorProblemSummary(documents: snapshot.documents, consoleEntries: store.consoleEntries))
            Divider(axis: .vertical).frame(height: 12)
            space(EditorSpace(mode: store.workspaceMode))
            if store.sceneDirty {
                Row(alignment: .center, spacing: 4) {
                    Box { EmptyView() }.frame(width: 5, height: 5).background(.warning).cornerRadius(3)
                    Text(L("Unsaved")).font(.caption).foregroundColor(.warning)
                }.debugName("editor-status-unsaved")
            }
            Text("r\(store.sceneRevision)").font(.caption).foregroundColor(.onSurfaceMuted)
                .accessibility { $0.label = L("Revision") }
            if store.selectedEntityIDsCount > 0 {
                Text("\(L("Selection")) \(store.selectedEntityIDsCount)").font(.caption).foregroundColor(.onSurfaceMuted)
            }

            Spacer(minLength: 0)

            if showsScriptInfo, let document = snapshot.selectedDocument {
                Text("Swift · UTF-8").font(.caption).foregroundColor(.onSurfaceMuted)
                Text(store.scriptCaretLabel(for: document.file.identifier))
                    .font(.caption).foregroundColor(.onSurfaceVariant)
                Divider(axis: .vertical).frame(height: 12)
            }
            activity(snapshot)
            agent
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(height: 24)
        .background(.surfaceRaised)
        .debugName("editor-status-bar")
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

    private func space(_ space: EditorSpace) -> some View {
        Row(alignment: .center, spacing: 5) {
            Icon(space.icon, size: 11, color: .onSurfaceMuted)
            Text(L(space.title) + " Space").font(.caption).foregroundColor(.onSurfaceMuted)
        }.debugName("editor-status-space")
    }

    /// Background work in priority order: long operations, script builds, then
    /// the most recent warning or error. Idle shows nothing.
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
        } else if let latest = store.latestConsoleEntry, latest.severity != .info {
            Button(tooltip: L("Problems")) { onCommand(.showProblems) } label: {
                Text(L(latest.message), lineLimit: 1).font(.caption)
                    .foregroundColor(latest.severity == .error ? .error : .warning)
            }
            .buttonStyle(.plain).frame(maxWidth: 260).flex(0, shrink: 1).clipped()
            .debugName("editor-status-activity")
        }
    }

    /// The Agent's state, always reachable: what needs review comes first.
    private var agent: some View {
        let store = app.store
        let reviews = store.agentTasks.filter { $0.phase == .awaitingReview }.count
            + (store.pendingConfirmationRequest == nil ? 0 : 1)
        let working = store.agentTasks.contains { $0.phase == .planning }
        let available = app.isAIAvailable
        let title = reviews > 0 ? "\(reviews) \(L("Awaiting Review"))"
            : working ? L("Guava is working")
            : available ? L("Agent ready") : L("Agent offline")
        let emphasized = reviews > 0 || working
        return Button(tooltip: available ? (store.aiStatusMessage ?? L("Agent"))
                                         : L("Set an AI provider in Settings to enable.")) {
            onCommand(.showPanel("intent-input"))
        } label: {
            Row(alignment: .center, spacing: 5) {
                if working && reviews == 0 {
                    Spinner(size: 10)
                } else {
                    Icon(UIIcons.Status.sparkles, size: 11,
                         color: available ? EditorChromeTokens.agentColor : .onSurfaceMuted)
                }
                Text(title, lineLimit: 1).font(emphasized ? .label : .caption)
                    .foregroundColor(emphasized ? EditorChromeTokens.agentColor : .onSurfaceMuted)
            }
        }
        .buttonStyle(EditorChromeButtonStyle(height: 20))
        .accessibility { $0.label = L("Agent") + ": " + title }
        .debugName("editor-status-agent")
    }
}
