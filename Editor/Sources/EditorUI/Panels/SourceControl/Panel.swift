internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Git or Lore for the project: branch and sync in the toolbar, a commit
/// composer with an AI-drafted message, staged and unstaged changes with inline
/// diffs, then recent history. Every command runs through the shared model,
/// which re-reads the working tree afterwards.
struct SourceControlPanel: View, @unchecked Sendable {
    let app: EditorApplication
    private let observed: Observed<EditorVersionControl, VersionControlSnapshot>
    @State private var message: TextBuffer = ""
    @State private var isDrafting = false
    @State private var expandedDiff: String?
    @State private var diffText = ""
    @State private var showsHistory = true

    init(app: EditorApplication) {
        self.app = app
        observed = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    private var model: EditorVersionControl { app.workstation.versionControl }

    var body: some View {
        let snapshot = observed.wrappedValue
        Column(alignment: .leading, spacing: 0) {
            switch snapshot.availability {
            case .unknown:
                Box(direction: .column, alignItems: .center, justifyContent: .center) { Spinner(size: 14) }.flex()
            case .noRepository, .toolMissing:
                SourceControlSetup(app: app, snapshot: snapshot).flex()
            case let .ready(repository):
                SourceControlToolbar(app: app, snapshot: snapshot, repository: repository)
                composer(snapshot)
                errorBanner(snapshot.error)
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .column, alignItems: .stretch, spacing: 2) {
                        if snapshot.status.changes.isEmpty {
                            Row(alignment: .center, spacing: 6) {
                                Icon(UIIcons.Status.checkCircle, size: 12, color: .success)
                                Text(L("No changes")).font(.caption).foregroundColor(.onSurfaceMuted)
                            }.padding(horizontal: 12, vertical: 10)
                        }
                        if !snapshot.staged.isEmpty { section(L("Staged Changes"), snapshot.staged, snapshot: snapshot) }
                        if !snapshot.unstaged.isEmpty { section(L("Changes"), snapshot.unstaged, snapshot: snapshot) }
                        history(snapshot)
                    }.padding(vertical: 6).frame(width: .percent(100), minWidth: 0)
                }.flex().frame(minWidth: 0, minHeight: 0)
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("source-control")
    }

    // MARK: Commit

    private func composer(_ snapshot: VersionControlSnapshot) -> some View {
        let hasChanges = !snapshot.status.changes.isEmpty
        let busy = snapshot.operation != nil
        let canCommit = hasChanges && !busy && !message.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Column(alignment: .leading, spacing: 8) {
                TextField(L("Commit message"), text: $message) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 6
                    input.events.onKeyDown = { event in
                        guard EditorShortcut(.enter).matches(event), canCommit else { return false }
                        commit(); return true
                    }
                }.font(.body).frame(width: .percent(100), minHeight: 40).debugName("source-control-message")
                Row(alignment: .center, spacing: 6) {
                    Button(isEnabled: hasChanges && !isDrafting && app.isAIAvailable,
                           tooltip: app.isAIAvailable ? L("Draft a message from the changes") : L("Set an AI provider in Settings to enable.")) {
                        draftMessage()
                    } label: {
                        Row(alignment: .center, spacing: 5) {
                            if isDrafting { Spinner(size: 10) } else {
                                Icon(UIIcons.Status.sparkles, size: 11, color: EditorChromeTokens.agentColor)
                            }
                            Text(L("Generate")).font(.caption)
                        }
                    }.buttonStyle(EditorChromeButtonStyle(height: 24, agent: true))
                        .background(EditorChromeTokens.agentColor.opacity(0.10)).cornerRadius(6)
                        .debugName("source-control-generate")
                    Spacer(minLength: 0)
                    if let operation = snapshot.operation {
                        Spinner(size: 10)
                        Text(L(operation.title), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                    Button(isEnabled: canCommit, tooltip: EditorShortcut(.enter).label) { commit() } label: {
                        Row(alignment: .center, spacing: 5) {
                            Icon(UIIcons.Action.check, size: 11)
                            Text(snapshot.staged.isEmpty ? L("Commit All") : L("Commit"))
                        }
                    }.buttonStyle(.primary).controlSize(.small).debugName("source-control-commit")
                }.frame(width: .percent(100), minWidth: 0)
            }.padding(10).background(.surfaceSunken).cornerRadius(10).border(.border, width: 1)
        }.padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8)).frame(width: .percent(100), minWidth: 0)
    }

    private func commit() {
        let text = message.stringValue
        Task { @MainActor in
            if await model.commit(message: text) {
                message = ""
                EditorNotifications.of(app).post(L("Committed"), id: "vcs-commit", tone: .success,
                                                 message: model.snapshot.history.first?.summary ?? "")
            }
        }
    }

    private func draftMessage() {
        isDrafting = true
        Task { @MainActor in
            defer { isDrafting = false }
            do {
                message = TextBuffer(try await app.draftCommitMessage())
            } catch {
                EditorNotifications.of(app).post(L("Could not draft a message"), id: "vcs-draft", tone: .danger,
                                                 duration: 5, message: error.localizedDescription)
            }
        }
    }

    private func errorBanner(_ error: String?) -> some View {
        AnimatedVisibility(isVisible: error != nil) {
            Row(alignment: .top, spacing: 8) {
                Icon(UIIcons.Status.alertTriangle, size: 12, color: .error)
                Text(error ?? "", lineLimit: 4).font(.caption).foregroundColor(.error).flex().frame(minWidth: 0)
            }.padding(horizontal: 12, vertical: 6).background(SemanticColorRef.error.opacity(0.10))
                .debugName("source-control-error")
        }
    }

    // MARK: Changes

    private func section(_ title: String, _ changes: [VersionControlChange], snapshot: VersionControlSnapshot) -> some View {
        let staged = changes.first?.isStaged == true
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 6) {
                Text(title.uppercased()).font(.caption).foregroundColor(.onSurfaceMuted)
                EditorPanelBadge("\(changes.count)")
                Spacer(minLength: 0)
                if staged {
                    EditorPanelIconButton(UIIcons.Action.minus, tooltip: L("Unstage All")) {
                        Task { await model.unstage(changes) }
                    }
                } else {
                    DiscardButton(title: L("Discard All Changes"), count: changes.count) {
                        Task { await model.discard(changes) }
                    }
                    EditorPanelIconButton(UIIcons.Action.plus, tooltip: L("Stage All")) {
                        Task { await model.stage(changes) }
                    }
                }
            }.padding(horizontal: 12).frame(height: 28)
            for change in changes {
                AnyView(SourceControlChangeRow(app: app, change: change, isLocked: snapshot.locks.contains(change.path),
                                               supportsLocks: snapshot.repository?.system == .lore,
                                               isExpanded: expandedDiff == change.id, onToggle: { toggleDiff(change) }))
                if expandedDiff == change.id {
                    AnyView(DiffView(text: diffText).padding(EdgeInsets(leading: 12, bottom: 6, trailing: 8)))
                }
            }
        }.padding(EdgeInsets(bottom: 6))
    }

    private func toggleDiff(_ change: VersionControlChange) {
        guard expandedDiff != change.id else { expandedDiff = nil; return }
        expandedDiff = change.id
        diffText = ""
        Task { @MainActor in
            let text = await model.diff(change)
            if expandedDiff == change.id { diffText = text }
        }
    }

    // MARK: History

    @ViewBuilder
    private func history(_ snapshot: VersionControlSnapshot) -> some View {
        if !snapshot.history.isEmpty {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Button(action: { showsHistory.toggle() }) {
                    Row(alignment: .center, spacing: 6) {
                        Icon(showsHistory ? UIIcons.Navigation.chevronDown : UIIcons.Navigation.chevronRight,
                             size: 9, color: .onSurfaceMuted)
                        Text(L("History").uppercased()).font(.caption).foregroundColor(.onSurfaceMuted)
                        Spacer(minLength: 0)
                    }.padding(horizontal: 12).frame(width: .percent(100), height: .points(28))
                }.buttonStyle(.plain).frame(width: .percent(100)).debugName("source-control-history-toggle")
                if showsHistory {
                    for revision in snapshot.history.prefix(30) {
                        AnyView(SourceControlRevisionRow(revision: revision))
                    }
                }
            }
        }
    }
}

extension VersionControlOperation {
    var title: String {
        switch self {
        case .staging: "Staging…"
        case .unstaging: "Unstaging…"
        case .discarding: "Discarding…"
        case .committing: "Committing…"
        case .pulling: "Pulling…"
        case .pushing: "Pushing…"
        case .switchingBranch: "Switching branch…"
        case .creatingBranch: "Creating branch…"
        case .initializing: "Initializing…"
        case .locking: "Updating locks…"
        }
    }
}

extension VersionControlFileState {
    var color: SemanticColorRef {
        switch self {
        case .modified, .renamed, .copied: .warning
        case .added, .untracked: .success
        case .deleted, .conflicted: .error
        }
    }

    var title: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }
}

/// A destructive icon action that asks first, since discarding cannot be undone
/// from the editor (new files go to the Trash).
struct DiscardButton: View {
    let title: String
    let count: Int
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Popover(isPresented: $isConfirming, width: 240, placement: .bottomTrailing, surface: .bubble, overflow: .flip) {
            Button(icon: .resource(UIIcons.Action.revert), size: 11, tooltip: title) { isConfirming = true }
                .buttonStyle(ToggleButtonStyle(height: 22))
        } content: {
            Column(alignment: .leading, spacing: 10) {
                Text(title + "?").font(.bodyStrong)
                Text(String(format: L("%d file(s) return to the last revision. New files move to the Trash."), count), lineLimit: 3)
                    .font(.caption).foregroundColor(.onSurfaceVariant)
                Row(alignment: .center, spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("Cancel")) { isConfirming = false }.buttonStyle(.ghost)
                    Button(L("Discard")) { isConfirming = false; action() }.buttonStyle(.destructive)
                }
            }.padding(12)
        }
    }
}
