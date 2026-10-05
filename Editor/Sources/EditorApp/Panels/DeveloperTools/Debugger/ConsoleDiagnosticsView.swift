import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct ConsoleDiagnosticsView: View {
    let store: EditorStore
    @State private var searchText = ""
    @State private var enabledSeverities = Set(EditorConsoleSeverity.allCases)
    @State private var selectedEntryID: UInt64?

    var body: some View {
        let entries = store.consoleEntries
        let visibleEntries = developerDebuggerConsoleEntries(entries: entries,
                                                             severities: enabledSeverities,
                                                             query: searchText)
        let counts = Dictionary(grouping: entries, by: \.severity).mapValues(\.count)
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text(L("Console"))
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                Text("\(visibleEntries.count) / \(entries.count)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Spacer(minLength: 0)

                Button(isEnabled: !entries.isEmpty, action: {
                    store.dispatch(.clearConsole)
                    selectedEntryID = nil
                }) {
                    Text(L("Clear"))
                }
                .buttonStyle(GhostButtonStyle())
            }
            .padding(horizontal: 12, vertical: 8)

            TextField(L("Filter console messages"), text: $searchText, size: .small, clearable: true)
                .padding(horizontal: 8, vertical: 3)

            Row(alignment: .center, spacing: 4) {
                DeveloperDebuggerSeverityChip(label: L("All"),
                                              count: entries.count,
                                              isSelected: enabledSeverities.count == EditorConsoleSeverity.allCases.count,
                                              action: { enabledSeverities = Set(EditorConsoleSeverity.allCases); selectedEntryID = nil })
                for severity in EditorConsoleSeverity.allCases {
                    DeveloperDebuggerSeverityChip(label: developerDebuggerSeverityLabel(severity),
                                                  count: counts[severity, default: 0],
                                                  isSelected: enabledSeverities.contains(severity),
                                                  action: { toggle(severity) })
                }
            }
            .padding(horizontal: 8, vertical: 2)

            Divider()

            if entries.isEmpty {
                EditorPanelEmptyState(L("No console messages"),
                                      detail: L("Runtime, import, build, and editor diagnostics appear here."))
                    .flex(1, shrink: 1)
            } else if visibleEntries.isEmpty {
                EditorPanelEmptyState(L("No matching console messages"),
                                      detail: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? L("Enable a severity filter to show messages.")
                                        : "\(L("Search")): \(searchText.trimmingCharacters(in: .whitespacesAndNewlines))")
                    .flex(1, shrink: 1)
            } else {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 4) {
                        for entry in visibleEntries {
                            DeveloperConsoleRow(entry: entry,
                                                isSelected: selectedEntryID == entry.id,
                                                onSelect: {
                                                    selectedEntryID = selectedEntryID == entry.id ? nil : entry.id
                                                })
                        }
                    }
                    .padding(horizontal: 12, vertical: 8)
                }
                .flex(1, shrink: 1)
            }
        }
    }

    private func toggle(_ severity: EditorConsoleSeverity) {
        if enabledSeverities.contains(severity) {
            enabledSeverities.remove(severity)
        } else {
            enabledSeverities.insert(severity)
        }
        selectedEntryID = nil
    }
}

private struct DeveloperDebuggerSeverityChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(isSelected: isSelected, action: action) {
            Row(alignment: .center, spacing: 3) {
                Text(label, lineLimit: 1)
                Text("\(count)").font(.mono)
            }
        }
        .buttonStyle(ToggleButtonStyle(minWidth: 40, height: 22))
    }
}

private struct DeveloperConsoleRow: View {
    let entry: EditorConsoleEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Row(alignment: .top, spacing: 8) {
                Text(severityLabel)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(severityColor)
                    .frame(width: 44)

                Column(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .lineLimit(isSelected ? 8 : 1)
                        .font(.caption)
                        .foregroundColor(messageColor)
                    if isSelected, let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .lineLimit(8)
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
                .flex(1, shrink: 1)
            }
            .padding(horizontal: 6, vertical: 4)
            .background(isSelected ? .accent.opacity(0.12) : .surface)
            .border(isSelected ? .accent : .divider, width: isSelected ? 1 : 0)
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

    private var messageColor: SemanticColorRef { severityColor }
}

func developerDebuggerConsoleEntries(entries: [EditorConsoleEntry],
                                      severities: Set<EditorConsoleSeverity>,
                                      query: String) -> [EditorConsoleEntry] {
    ConsoleEntryFilter.filter(entries, severities: severities, query: query)
        .sorted { $0.id > $1.id }
}

private func developerDebuggerSeverityLabel(_ severity: EditorConsoleSeverity) -> String {
    switch severity {
    case .info: L("Info")
    case .warning: L("Warnings")
    case .error: L("Errors")
    }
}
