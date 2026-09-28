import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// Searchable, severity-filtered editor output. The controls deliberately
/// mirror mature engine consoles: filtering never destroys history, counts
/// stay visible, and zero-result states explain why the list is empty.
struct ConsolePanel: View {
    let store: EditorStore
    @State private var searchText: String = ""
    @State private var enabledSeverities: Set<EditorConsoleSeverity> = Set(EditorConsoleSeverity.allCases)
    @State private var selectedEntryID: UInt64? = nil
    @State private var followsLatest: Bool = true
    @State private var copyStatus: String? = nil

    init(store: EditorStore) {
        self.store = store
        _searchText = State(wrappedValue: "")
        _enabledSeverities = State(wrappedValue: Set(EditorConsoleSeverity.allCases))
    }

    var body: some View {
        let entries = store.consoleEntries
        let visibleEntries = ConsoleEntryFilter.filter(entries,
                                                       severities: enabledSeverities,
                                                       query: searchText)
        let counts = Dictionary(grouping: entries, by: \.severity).mapValues(\.count)
        let selectedEntry = visibleEntries.first { $0.id == selectedEntryID }
        let entriesToCopy = selectedEntry.map { [$0] } ?? visibleEntries

        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelToolbar {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(store.connected ? SemanticColorRef.success : .warning)
                    .cornerRadius(3)

                Text(store.connected ? L("Connected") : L("Offline"))
                    .font(.caption)
                    .foregroundColor(store.connected ? .success : .warning)

                Spacer(minLength: 0)

                Text("\(L("Revision")) \(store.sceneRevision)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Button(isSelected: followsLatest,
                       tooltip: followsLatest ? L("Pause following new messages") : L("Follow newest message"),
                       action: { followsLatest.toggle() }) {
                    Text(followsLatest ? L("Following") : L("Follow Latest"), lineLimit: 1)
                }
                .buttonStyle(ToggleButtonStyle(height: 22))

                Button(isEnabled: !entriesToCopy.isEmpty,
                       tooltip: selectedEntry == nil
                           ? L("Copy visible messages")
                           : L("Copy selected message"),
                       action: { copy(entriesToCopy) }) {
                    Text(L("Copy"))
                }
                .buttonStyle(GhostButtonStyle())

                Button(isEnabled: !entries.isEmpty,
                       action: {
                           store.dispatch(.clearConsole)
                           selectedEntryID = nil
                           copyStatus = nil
                       }) {
                    Text(L("Clear"))
                }
                .buttonStyle(GhostButtonStyle())
            }

            Divider()

            EditorPanelSearchBar(
                L("Search Console"),
                text: $searchText,
                summary: "\(visibleEntries.count) / \(entries.count)"
            ) {
                ConsoleSeverityFilterButton(
                    severity: .info,
                    count: counts[.info, default: 0],
                    isEnabled: enabledSeverities.contains(.info),
                    action: { toggle(.info) }
                )
                ConsoleSeverityFilterButton(
                    severity: .warning,
                    count: counts[.warning, default: 0],
                    isEnabled: enabledSeverities.contains(.warning),
                    action: { toggle(.warning) }
                )
                ConsoleSeverityFilterButton(
                    severity: .error,
                    count: counts[.error, default: 0],
                    isEnabled: enabledSeverities.contains(.error),
                    action: { toggle(.error) }
                )
            }

            if let copyStatus {
                Text(copyStatus)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 10, vertical: 3)
            }

            Divider()

            if entries.isEmpty {
                EditorPanelEmptyState(
                    L("No console messages"),
                    detail: L("Runtime, import, build, and editor diagnostics appear here.")
                )
                .flex()
            } else if visibleEntries.isEmpty {
                EditorPanelEmptyState(
                    L("No matching console messages"),
                    detail: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? L("Enable a severity filter to show messages.")
                        : "\"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\""
                )
                .flex()
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 1) {
                        for entry in visibleEntries.suffix(200) {
                            ConsoleEntryRow(entry: entry,
                                            isSelected: selectedEntryID == entry.id,
                                            onSelect: {
                                                selectedEntryID = entry.id
                                                copyStatus = nil
                                            })
                        }
                        ConsoleTailAnchor(entryID: visibleEntries.last?.id,
                                          followsLatest: followsLatest)
                    }
                    .padding(horizontal: 10, vertical: 6)
                }
                .background(.surfaceSunken)
                .flex(1, shrink: 1)
            }
        }
        .frame(minHeight: 140)
    }

    private func toggle(_ severity: EditorConsoleSeverity) {
        if enabledSeverities.contains(severity) {
            enabledSeverities.remove(severity)
        } else {
            enabledSeverities.insert(severity)
        }
        selectedEntryID = nil
    }

    private func copy(_ entries: [EditorConsoleEntry]) {
        guard let writeClipboard = ClipboardHolder.write else {
            copyStatus = L("Clipboard is unavailable")
            return
        }
        writeClipboard(ConsoleEntryExport.formatted(entries))
        copyStatus = String(format: L("Copied %lld messages"), Int64(entries.count))
    }
}

enum ConsoleEntryFilter {
    static func filter(_ entries: [EditorConsoleEntry],
                       severities: Set<EditorConsoleSeverity>,
                       query: String) -> [EditorConsoleEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard severities.contains(entry.severity) else { return false }
            guard !needle.isEmpty else { return true }
            return entry.message.range(of: needle, options: .caseInsensitive) != nil
                || entry.detail?.range(of: needle, options: .caseInsensitive) != nil
        }
    }
}

enum ConsoleEntryExport {
    static func formatted(_ entries: [EditorConsoleEntry]) -> String {
        entries.map { entry in
            let severity = entry.severity.rawValue.uppercased()
            guard let detail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty else {
                return "[\(severity)] \(entry.message)"
            }
            return "[\(severity)] \(entry.message)\n\(detail)"
        }
        .joined(separator: "\n")
    }
}

enum ConsoleScrollGeometry {
    static func bottomOffset(currentOffset: CGFloat,
                             anchorMaxY: CGFloat,
                             viewportMaxY: CGFloat) -> CGFloat {
        currentOffset + max(0, anchorMaxY - viewportMaxY)
    }
}

private struct ConsoleSeverityFilterButton: View {
    let severity: EditorConsoleSeverity
    let count: Int
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(isSelected: isEnabled,
               tooltip: tooltip,
               action: action) {
            Row(alignment: .center, spacing: 4) {
                Box { EmptyView() }
                    .frame(width: 5, height: 5)
                    .background(color)
                    .cornerRadius(3)
                Text("\(label) \(count)", lineLimit: 1)
                    .font(.caption)
            }
        }
        .buttonStyle(ToggleButtonStyle(height: 22))
    }

    private var label: String {
        switch severity {
        case .info: return L("Info")
        case .warning: return L("Warnings")
        case .error: return L("Errors")
        }
    }

    private var tooltip: String {
        String(format: L("Toggle %@ messages"), label)
    }

    private var color: SemanticColorRef {
        switch severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }
}

private struct ConsoleEntryRow: View {
    let entry: EditorConsoleEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Row(alignment: .top, spacing: 8) {
                Text(severityLabel)
                    .font(.caption)
                    .foregroundColor(severityColor)
                    .frame(width: 44)

                Column(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .lineLimit(isSelected ? nil : 1)
                        .font(.caption)
                        .foregroundColor(messageColor)
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .lineLimit(isSelected ? nil : 2)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 4, vertical: 3)
            .background(rowBackground)
            .cornerRadius(3)
            .border(selectionBorder, width: 1)
        }
        .buttonStyle(.plain)
    }

    private var severityLabel: String {
        switch entry.severity {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERR"
        }
    }

    private var severityColor: SemanticColorRef {
        switch entry.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }

    private var messageColor: SemanticColorRef {
        switch entry.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }

    private var rowBackground: SemanticColorRef {
        if isSelected { return .accent.opacity(0.12) }
        if entry.severity == .error { return .error.opacity(0.08) }
        return SemanticColorRef { _ in .clear }
    }

    private var selectionBorder: SemanticColorRef {
        isSelected ? .accent : SemanticColorRef { _ in .clear }
    }
}

/// A one-pixel tail marker scrolls the console only when a new last entry
/// arrives or the user explicitly resumes follow mode. Layout timing matters:
/// the marker runs after its new frame has been assigned, so the scroll
/// viewport's offset lands on the actual bottom rather than the stale row size.
private struct ConsoleTailAnchor: _PrimitiveView {
    let entryID: UInt64?
    let followsLatest: Bool

    private static let entryIDKey = "console.tail.entryID"
    private static let followKey = "console.tail.followsLatest"

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        let previousEntryID = node.attachments[Self.entryIDKey] as? UInt64
        let wasFollowing = node.attachments[Self.followKey] as? Bool ?? false
        let shouldScroll = followsLatest && (previousEntryID != entryID || !wasFollowing)
        if followsLatest, !wasFollowing, previousEntryID == entryID {
            // Resuming follow mode does not necessarily cause a layout pass,
            // and the existing tail geometry is already current in that case.
            Self.scrollToBottom(from: node)
        }
        node.attachments[Self.entryIDKey] = entryID
        node.attachments[Self.followKey] = followsLatest
        node.layoutDidUpdate = { anchor in
            guard shouldScroll else { return }
            Self.scrollToBottom(from: anchor)
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 1
        layout.height = 1
        return layout
    }

    private static func scrollToBottom(from anchor: Node) {
        guard var scrollView = anchor.parent else { return }
        while !scrollView.clipsToBounds {
            guard let parent = scrollView.parent else { return }
            scrollView = parent
        }

        let viewport = scrollView.absoluteFrame
        let tail = anchor.absoluteFrame
        let nextY = ConsoleScrollGeometry.bottomOffset(currentOffset: scrollView.contentOffset.y,
                                                       anchorMaxY: tail.maxY,
                                                       viewportMaxY: viewport.maxY)
        guard nextY != scrollView.contentOffset.y else { return }
        scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: nextY)
    }
}
