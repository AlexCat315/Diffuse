import EditorCore
import Foundation
import GuavaUI
import GuavaUIRuntime

/// Searchable, severity-filtered editor output. The controls deliberately
/// mirror mature engine consoles: filtering never destroys history, counts
/// stay visible, and zero-result states explain why the list is empty.
struct ConsolePanel: View {
    let store: EditorStore
    var onNavigate: ((EditorIssueTarget) -> Void)? = nil
    let outputSelector: AnyView?
    /// Window-level feedback, so a copy confirmation never pushes the list down.
    var notify: (String, StatusTone) -> Void = { _, _ in }
    @State private var searchText: TextBuffer = ""
    @State private var enabledSeverities: Set<EditorConsoleSeverity> = Set(EditorConsoleSeverity.allCases)
    @State private var selectedEntryID: UInt64? = nil
    @State private var followsLatest: Bool = true
    @State private var actionsPresented = false

    init(store: EditorStore, onNavigate: ((EditorIssueTarget) -> Void)? = nil, outputSelector: AnyView? = nil,
         notify: @escaping (String, StatusTone) -> Void = { _, _ in }) {
        self.store = store
        self.onNavigate = onNavigate
        self.outputSelector = outputSelector
        self.notify = notify
        _searchText = State(wrappedValue: "")
        _enabledSeverities = State(wrappedValue: Set(EditorConsoleSeverity.allCases))
    }

    var body: some View {
        let entries = store.consoleEntries
        let visibleEntries = ConsoleEntryFilter.filter(entries,
                                                       severities: enabledSeverities,
                                                       query: searchText.stringValue)
        let counts = Dictionary(grouping: entries, by: \.severity).mapValues(\.count)
        let selectedEntry = visibleEntries.first { $0.id == selectedEntryID }
        let entriesToCopy = selectedEntry.map { [$0] } ?? visibleEntries

        Box(direction: .column, alignItems: .stretch, spacing: 0) {
          ContainerSizeReader { size in
            EditorPanelSearchBar(
                L("Search Console"),
                text: $searchText,
                summary: size.width < 600 ? nil : "\(visibleEntries.count) / \(entries.count)",
                leading: outputSelector
            ) {
              if size.width < 600 {
                compactActions(entries: entries, entriesToCopy: entriesToCopy, counts: counts)
              } else {
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
                Button(icon: .resource(UIIcons.Navigation.arrowDown), size: 12,
                       isSelected: followsLatest,
                       tooltip: followsLatest ? L("Pause following new messages") : L("Follow newest message")) {
                    followsLatest.toggle()
                }.buttonStyle(EditorChromeButtonStyle(height: 22))
                Button(icon: .resource(UIIcons.Action.copy), size: 12,
                       isEnabled: !entriesToCopy.isEmpty, tooltip: L("Copy visible messages")) {
                    copy(entriesToCopy)
                }.buttonStyle(EditorChromeButtonStyle(height: 22))
                Button(icon: .resource(UIIcons.Action.trash), size: 12,
                       isEnabled: !entries.isEmpty, tooltip: L("Clear")) {
                    store.dispatch(.clearConsole)
                    selectedEntryID = nil
                }.buttonStyle(EditorChromeButtonStyle(height: 22))
              }
            }
          }.frame(height: 32)


            if entries.isEmpty {
                EditorPanelEmptyState(
                    L("No console messages"),
                    detail: L("Runtime, import, build, and editor diagnostics appear here.")
                )
                .flex()
            } else if visibleEntries.isEmpty {
                EditorPanelEmptyState(
                    L("No matching console messages"),
                    detail: searchText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? L("Enable a severity filter to show messages.")
                        : "\"\(searchText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))\""
                )
                .flex()
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 1) {
                        visibleEntries.suffix(200).map { entry in
                            AnyView(Column(alignment: .leading, spacing: 2) {
                            ConsoleEntryRow(entry: entry,
                                            isSelected: selectedEntryID == entry.id,
                                            onSelect: {
                                                selectedEntryID = entry.id
                                            })
                            if let nextStep = entry.nextStep, selectedEntryID == entry.id {
                                Text(L(nextStep)).font(.caption).foregroundColor(.warning)
                                    .padding(horizontal: 4, vertical: 3)
                            }
                            if let target = entry.target, let onNavigate {
                                Button(L("Go to source")) { onNavigate(target) }
                                    .buttonStyle(.ghost).controlSize(.small)
                            }
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

    private func compactActions(entries: [EditorConsoleEntry], entriesToCopy: [EditorConsoleEntry],
                                counts: [EditorConsoleSeverity: Int]) -> some View {
        Popover(isPresented: $actionsPresented, width: 220, placement: .bottomTrailing, surface: .content, overflow: .flip) {
            Icon(UIIcons.Action.moreHorizontal, size: 14, color: .onSurfaceVariant)
                .frame(width: 26, height: 26).accessibility { $0.label = L("Console") }
        } content: {
            Menu(EditorConsoleSeverity.allCases.map { severity in
                .item(MenuItem(id: severity.rawValue, title: "\(severity.title) \(counts[severity, default: 0])",
                    isSelected: enabledSeverities.contains(severity), action: { toggle(severity) }))
            } + [
                .separator("actions"),
                .item(MenuItem(id: "follow", title: followsLatest ? L("Pause following new messages") : L("Follow newest message"),
                               isSelected: followsLatest, action: { followsLatest.toggle() })),
                .item(MenuItem(id: "copy", title: L("Copy visible messages"), isEnabled: !entriesToCopy.isEmpty,
                               action: { copy(entriesToCopy) })),
                .item(MenuItem(id: "clear", title: L("Clear"), isEnabled: !entries.isEmpty, action: {
                    store.dispatch(.clearConsole)
                    selectedEntryID = nil
                })),
            ], width: 220, onDismiss: { actionsPresented = false })
        }.debugName("editor-console-actions")
    }

    private func copy(_ entries: [EditorConsoleEntry]) {
        guard let writeClipboard = ClipboardHolder.write else {
            notify(L("Clipboard is unavailable"), .warning)
            return
        }
        writeClipboard(ConsoleEntryExport.formatted(entries))
        notify(String(format: L("Copied %lld messages"), Int64(entries.count)), .success)
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
        .buttonStyle(EditorChromeButtonStyle(height: 22))
    }

    private var label: String {
        severity.title
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

private extension EditorConsoleSeverity {
    var title: String {
        switch self {
        case .info: L("Info")
        case .warning: L("Warnings")
        case .error: L("Errors")
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
                    Text(L(entry.message))
                        .lineLimit(isSelected ? nil : 1)
                        .font(.caption)
                        .foregroundColor(messageColor)
                    if let detail = entry.detail, !detail.isEmpty, isSelected {
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
