internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// A change in the editor's diff tab: the file's path, area and actions on the
/// bar, then the unified diff with old and new line numbers. Rows are
/// virtualized, so a long diff scrolls as smoothly as a short one.
struct DocumentComparisonSurface: View, @unchecked Sendable {
    let app: EditorApplication
    private let observed: Observed<EditorVersionControl, VersionControlSnapshot>

    init(app: EditorApplication) {
        self.app = app
        observed = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    private var model: EditorVersionControl { app.workstation.versionControl }

    var body: some View {
        let snapshot = observed.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let comparison = snapshot.comparison {
                let lines = comparison.diff.map(DiffLine.parse) ?? []
                bar(comparison, lines: lines, snapshot: snapshot)
                if !comparison.isCurrent {
                    Row(alignment: .center, spacing: 8) {
                        Icon(UIIcons.Status.checkCircle, size: 12, color: .success)
                        Text(L("This file has no changes now.")).font(.caption).foregroundColor(.onSurfaceVariant)
                    }.padding(horizontal: 12, vertical: 6).background(.surfaceVariant)
                }
                if comparison.diff == nil {
                    centered { Spinner(size: 14) }
                } else if lines.isEmpty {
                    centered {
                        Text(L("No textual changes")).font(.body).foregroundColor(.onSurfaceMuted)
                    }
                } else {
                    DiffLines(lines: lines).id(comparison.change.id).flex()
                }
            } else {
                centered { Spinner(size: 14) }
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("document-comparison")
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center) { content() }
            .flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
    }

    private func bar(_ comparison: VersionControlComparison, lines: [DiffLine], snapshot: VersionControlSnapshot) -> some View {
        let change = comparison.change
        let added = lines.filter { $0.kind == .added }.count, removed = lines.filter { $0.kind == .removed }.count
        let busy = snapshot.operation != nil
        return Row(alignment: .center, spacing: 8) {
            DocumentPathCrumbs(path: change.path).flex(0, shrink: 1).frame(minWidth: 0).clipped()
            Badge(L(change.isStaged ? "Staged" : "Working Tree"), tone: change.isStaged ? .success : .neutral) { $0.variant = .outline }
            Text(L(change.state.title)).font(.caption).foregroundColor(change.state.color)
            if added > 0 || removed > 0 {
                Text("+\(added)").font(.caption).foregroundColor(.success)
                Text("−\(removed)").font(.caption).foregroundColor(.error)
            }
            Spacer(minLength: 8)
            if comparison.isCurrent {
                if change.state != .deleted, let path = model.projectPath(forRepositoryPath: change.path) {
                    EditorPanelIconButton(UIIcons.Action.externalLink, tooltip: L("Open File")) { app.openDocument(path) }
                }
                if change.isStaged {
                    EditorPanelIconButton(UIIcons.Action.minus, tooltip: L("Unstage"), isEnabled: !busy) {
                        Task { await model.unstage([change]) }
                    }
                } else {
                    DiscardButton(title: L("Discard Changes"), count: 1) { Task { await model.discard([change]) } }
                    EditorPanelIconButton(UIIcons.Action.plus, tooltip: L("Stage"), isEnabled: !busy) {
                        Task { await model.stage([change]) }
                    }
                }
            }
        }
        .padding(horizontal: 10)
        .frame(height: 32)
        .debugName("document-comparison-bar")
    }
}

/// One row of a unified diff, numbered on both sides.
struct DiffLine: Identifiable, Equatable {
    enum Kind { case context, added, removed, hunk, note }
    let id: Int
    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String

    /// Reads a unified diff; file headers are dropped, hunk headers restart the counts.
    static func parse(_ diff: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0, new = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            let kind: Kind
            var numbers: (Int?, Int?) = (nil, nil)
            if text.hasPrefix("diff --git") {
                // The next file's headers follow; counts restart at its first hunk.
                old = 0; new = 0
                continue
            } else if text.hasPrefix("@@") {
                // `@@ -old,count +new,count @@ context`
                let fields = text.split(separator: " ")
                old = fields.first { $0.hasPrefix("-") }.flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 0
                new = fields.first { $0.hasPrefix("+") }.flatMap { Int($0.dropFirst().split(separator: ",")[0]) } ?? 0
                kind = .hunk
            } else if old == 0 && new == 0 {
                // File headers before the first hunk; only a binary notice is worth showing.
                guard text.hasPrefix("Binary files") else { continue }
                kind = .note
            } else if text.hasPrefix("+") {
                kind = .added; numbers = (nil, new); new += 1
            } else if text.hasPrefix("-") {
                kind = .removed; numbers = (old, nil); old += 1
            } else if text.hasPrefix("\\") {
                kind = .note
            } else if text.isEmpty && raw.endIndex == diff.endIndex {
                continue
            } else {
                kind = .context; numbers = (old, new); old += 1; new += 1
            }
            let body = kind == .added || kind == .removed || kind == .context ? String(text.dropFirst()) : text
            lines.append(DiffLine(id: lines.count, kind: kind, old: numbers.0, new: numbers.1, text: body))
        }
        return lines
    }
}

private struct DiffLines: View {
    let lines: [DiffLine]

    var body: some View {
        let largest = lines.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
        let gutter = Float(String(largest).count) * 7.5 + 14
        VirtualStack(lines, id: \.id, rowHeight: 20) { line in
            row(line, gutter: gutter)
        }
        .padding(vertical: 4)
        .frame(width: .percent(100), minWidth: 0, minHeight: 0)
        .debugName("document-comparison-lines")
    }

    private func row(_ line: DiffLine, gutter: Float) -> some View {
        let (ink, background, marker): (SemanticColorRef, SemanticColorRef, String) = switch line.kind {
        case .added: (.onSurface, SemanticColorRef.success.opacity(0.12), "+")
        case .removed: (.onSurface, SemanticColorRef.error.opacity(0.12), "−")
        case .hunk: (.onSurfaceMuted, SemanticColorRef.surfaceVariant.opacity(0.6), "")
        case .note: (.onSurfaceMuted, .clear, "")
        case .context: (.onSurfaceVariant, .clear, "")
        }
        let markerColor: SemanticColorRef = line.kind == .added ? .success : .error
        return Row(alignment: .center, spacing: 0) {
            number(line.old, width: gutter)
            number(line.new, width: gutter)
            Text(marker).font(.mono).foregroundColor(markerColor).frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text, lineLimit: 1).font(.mono).foregroundColor(ink)
                .flex(1, shrink: 1).frame(minWidth: 0)
        }
        .padding(EdgeInsets(trailing: 12))
        .frame(width: .percent(100), height: .points(20), minWidth: 0)
        .background(background)
    }

    private func number(_ value: Int?, width: Float) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .flexEnd) {
            Text(value.map(String.init) ?? "", lineLimit: 1).font(.mono).foregroundColor(.onSurfaceMuted)
        }.padding(EdgeInsets(trailing: 8)).frame(width: width)
    }
}

/// The diff tab: the file's name and area, after the document tabs. It
/// follows the compared file between the staged and unstaged areas.
struct ComparisonTab: View, @unchecked Sendable {
    let app: EditorApplication
    let isSelected: Bool
    private let observed: Observed<EditorVersionControl, VersionControlSnapshot>
    @State private var isHovered = false

    init(app: EditorApplication, isSelected: Bool) {
        self.app = app
        self.isSelected = isSelected
        observed = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    var body: some View {
        let change = observed.wrappedValue.comparison?.change
        let name = change.map { $0.path.split(separator: "/").last.map(String.init) ?? $0.path } ?? L("Changes")
        let area = change.map { L($0.isStaged ? "Staged" : "Working Tree") }
        Row(alignment: .center, spacing: 0) {
            Button(isSelected: isSelected, tooltip: change?.path ?? L("Changes")) {
                app.workstation.documents.showComparison()
            } label: {
                Row(alignment: .center, spacing: 6) {
                    Icon(UIIcons.Editor.gitCompare, size: 12, color: isSelected ? .accent : .onSurfaceVariant)
                    Text(name, lineLimit: 1).font(.label)
                        .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant).frame(maxWidth: 160)
                    if let area {
                        Text(area, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }.padding(EdgeInsets(leading: 10, trailing: 4))
            }.buttonStyle(.plain).frame(height: 26)
            if isSelected || isHovered {
                Button(icon: .resource(UIIcons.Action.x), size: 10, tooltip: L("Close")) {
                    app.closeComparison()
                }.buttonStyle(EditorChromeButtonStyle(height: 18))
            } else {
                Box {}.frame(width: 18, height: 18)
            }
        }
        .padding(EdgeInsets(trailing: 4))
        .frame(height: 26)
        .onHover { isHovered = $0 }
        .background(isSelected ? .surfaceVariant : .clear)
        .cornerRadius(6)
        .animation(motion: .fast, value: [isSelected, isHovered])
        .accessibility { $0.label = name + (area.map { " (\($0))" } ?? ""); $0.state.isSelected = isSelected }
        .debugName("document-tab-comparison")
    }
}
