internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// The repository's system, current branch (a menu to switch or create one)
/// and sync actions with their ahead/behind counts.
struct SourceControlToolbar: View, @unchecked Sendable {
    let app: EditorApplication
    let snapshot: VersionControlSnapshot
    let repository: VersionControlRepository
    @State private var isBranchMenuPresented = false
    @State private var newBranch: TextBuffer = ""

    private var model: EditorVersionControl { app.workstation.versionControl }

    var body: some View {
        let tracking = snapshot.status.tracking
        let busy = snapshot.operation != nil
        EditorPanelToolbar(spacing: 4) {
            EditorPanelBadge(repository.system.title, foreground: repository.system == .lore ? .accent : .onSurfaceVariant)
            branchMenu(tracking.branch ?? L("Detached")).flex(1, shrink: 1).frame(minWidth: 0)
            syncButton(UIIcons.Device.cloudDownload, count: tracking.behind,
                       tooltip: repository.system == .lore ? L("Sync") : L("Pull"), isEnabled: !busy) {
                Task { await model.pull() }
            }.debugName("source-control-pull")
            syncButton(UIIcons.Device.cloudUpload, count: tracking.ahead, tooltip: L("Push"), isEnabled: !busy) {
                Task { await model.push() }
            }.debugName("source-control-push")
            EditorPanelIconButton(UIIcons.Navigation.refresh, tooltip: L("Refresh"), isEnabled: !busy) {
                Task { await model.refresh() }
            }
        }
    }

    private func syncButton(_ icon: BundleImageResource, count: Int, tooltip: String, isEnabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(isEnabled: isEnabled, tooltip: tooltip, action: action) {
            Row(alignment: .center, spacing: 3) {
                Icon(icon, size: 12)
                if count > 0 { Text("\(count)").font(.caption) }
            }
        }.buttonStyle(EditorChromeButtonStyle(height: 22))
    }

    private func branchMenu(_ current: String) -> some View {
        let local = snapshot.branches.filter { !$0.isRemote }
        let remote = snapshot.branches.filter { $0.isRemote }
        return Popover(isPresented: $isBranchMenuPresented, width: 260, placement: .bottomLeading,
                       surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 5) {
                Icon(UIIcons.Editor.gitBranch, size: 12, color: .onSurfaceVariant)
                Text(current, lineLimit: 1).font(.label).foregroundColor(.onSurface).flex(0, shrink: 1).frame(minWidth: 0)
                Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
            }.padding(horizontal: 6).frame(height: 24).frame(minWidth: 0)
                .accessibility { $0.label = L("Branch") + " " + current }
        } content: {
            Column(alignment: .leading, spacing: 4) {
                Row(alignment: .center, spacing: 6) {
                    TextField(L("New branch name"), text: $newBranch) { input in
                        input.decoration.size = .small
                        input.events.onSubmit = createBranch
                    }.font(.caption).flex()
                    Button(icon: .resource(UIIcons.Action.plus), size: 11, tooltip: L("Create Branch"), action: createBranch)
                        .buttonStyle(ToggleButtonStyle(height: 22))
                }.padding(6)
                Menu((local + remote.filter { branch in !local.contains { branch.name.hasSuffix("/" + $0.name) } }).prefix(40).map { branch in
                    .item(MenuItem(id: branch.id, title: branch.name, isSelected: branch.isCurrent, action: {
                        isBranchMenuPresented = false
                        guard !branch.isCurrent else { return }
                        // Switching to a remote branch tracks it under its local name.
                        let name = branch.isRemote && repository.system == .git
                            ? String(branch.name.split(separator: "/", maxSplits: 1).last ?? Substring(branch.name)) : branch.name
                        Task { await model.switchBranch(name) }
                    }))
                }, width: 260)
            }
        }.debugName("source-control-branch")
    }

    private func createBranch() {
        let name = newBranch.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isBranchMenuPresented = false
        newBranch = ""
        Task { await model.createBranch(name) }
    }
}

/// One changed file: name, folder and state letter; hover actions to open, stage
/// or unstage, discard and (Lore) lock. Clicking the row opens its diff tab.
struct SourceControlChangeRow: View, @unchecked Sendable {
    let app: EditorApplication
    let change: VersionControlChange
    let isLocked: Bool
    let supportsLocks: Bool
    let isCompared: Bool
    let onOpen: () -> Void
    @State private var isHovered = false

    private var model: EditorVersionControl { app.workstation.versionControl }

    var body: some View {
        let parts = change.path.split(separator: "/").map(String.init)
        let name = parts.last ?? change.path
        let folder = parts.dropLast().joined(separator: "/")
        // Padding and background share a node, so the row's margin needs a wrapper.
        Box {
            Row(alignment: .center, spacing: 6) {
                Button(tooltip: change.originalPath.map { "\($0) → \(change.path)" } ?? change.path, action: onOpen) {
                    Row(alignment: .center, spacing: 6) {
                        FileIcon(path: change.path, size: 13)
                        Text(name, lineLimit: 1).font(.body)
                            .foregroundColor(change.state == .deleted ? .onSurfaceMuted : .onSurface)
                            .flex(0, shrink: 1).frame(minWidth: 0)
                        if !folder.isEmpty {
                            Text(folder, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted).flex(0, shrink: 2).frame(minWidth: 0)
                        }
                    }.frame(minWidth: 0)
                }.buttonStyle(.plain).flex(0, shrink: 1).frame(minWidth: 0)
                Spacer(minLength: 0)
                if isHovered {
                    actions
                } else if isLocked {
                    Icon(UIIcons.Status.lock, size: 11, color: .onSurfaceMuted).padding(horizontal: 4)
                }
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Text(change.state.badge, lineLimit: 1).font(.label).foregroundColor(change.state.color)
                }.frame(width: 16).accessibility { $0.label = L(change.state.title) }
            }
            .padding(EdgeInsets(leading: 10, trailing: 6)).frame(height: 26)
            .background(isCompared ? .surfaceVariant : isHovered ? .stateLayerHover : .clear).cornerRadius(6)
            .onHover { isHovered = $0 }
        }.padding(horizontal: 6)
        .debugName("source-control-change-" + change.id)
    }

    @ViewBuilder
    private var actions: some View {
        Row(alignment: .center, spacing: 0) {
            if change.state != .deleted, let path = model.projectPath(forRepositoryPath: change.path) {
                EditorPanelIconButton(UIIcons.Action.externalLink, tooltip: L("Open File")) { app.openDocument(path) }
            }
            if supportsLocks {
                EditorPanelIconButton(isLocked ? UIIcons.Status.unlock : UIIcons.Status.lock,
                                      tooltip: isLocked ? L("Release Lock") : L("Lock File")) {
                    Task { await model.setLocked(!isLocked, paths: [change.path]) }
                }
            }
            if change.isStaged {
                EditorPanelIconButton(UIIcons.Action.minus, tooltip: L("Unstage")) { Task { await model.unstage([change]) } }
            } else {
                DiscardButton(title: L("Discard Changes"), count: 1) { Task { await model.discard([change]) } }
                EditorPanelIconButton(UIIcons.Action.plus, tooltip: L("Stage")) { Task { await model.stage([change]) } }
            }
        }
    }
}

struct SourceControlRevisionRow: View {
    let revision: VersionControlRevision

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Icon(UIIcons.Editor.gitCommit, size: 11, color: .onSurfaceMuted)
            Text(revision.summary.isEmpty ? L("(no message)") : revision.summary, lineLimit: 1)
                .font(.body).foregroundColor(.onSurfaceVariant).flex(1, shrink: 1).frame(minWidth: 0)
            Text(detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
        }.padding(horizontal: 12).frame(height: 24)
            .accessibility { $0.label = revision.summary + ", " + detail }
    }

    private var detail: String {
        var parts = [revision.id.count > 12 ? String(revision.id.prefix(7)) : "#" + revision.id]
        if let date = revision.date { parts.append(Self.relative(date)) }
        return parts.joined(separator: " · ")
    }

    private static func relative(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return L("now")
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<2_592_000: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 2_592_000))mo"
        }
    }
}

