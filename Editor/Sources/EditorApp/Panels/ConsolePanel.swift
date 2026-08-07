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

                Button(isEnabled: !entries.isEmpty,
                       action: { store.dispatch(.clearConsole) }) {
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
                            ConsoleEntryRow(entry: entry)
                        }
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

    var body: some View {
        Row(alignment: .top, spacing: 8) {
            Text(severityLabel)
                .font(.caption)
                .foregroundColor(severityColor)
                .frame(width: 44)

            Column(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(messageColor)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .lineLimit(2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .flex(1, shrink: 1)
        }
        .padding(horizontal: 4, vertical: 3)
        .background(entry.severity == .error
            ? SemanticColorRef.error.opacity(0.08)
            : SemanticColorRef { _ in .clear })
        .cornerRadius(3)
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
}
