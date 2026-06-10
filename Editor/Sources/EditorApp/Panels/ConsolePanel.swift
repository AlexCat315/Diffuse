import EditorCore
import GuavaUICompose

/// Console / output panel in the floating-island language: an 11px log list
/// on the panel's sunken body, severity-tinted, with a muted header row.
struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Row(alignment: .center, spacing: 8) {
                Text(store.connected ? L("Connected") : L("Offline"))
                    .font(.caption)
                    .foregroundColor(store.connected ? .success : .warning)

                Spacer(minLength: 0)

                Text("revision \(store.sceneRevision)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Button(action: { store.dispatch(.clearConsole) }) {
                    Text(L("Clear"))
                }
                .buttonStyle(GhostButtonStyle())
            }

            ScrollView(.vertical) {
                Column(alignment: .leading, spacing: 4) {
                    if store.consoleEntries.isEmpty {
                        ConsoleEntryRow(
                            entry: EditorConsoleEntry(id: 0,
                                                      severity: .info,
                                                      message: L("No console messages"))
                        )
                    } else {
                        for entry in store.consoleEntries.suffix(80) {
                            ConsoleEntryRow(entry: entry)
                        }
                    }
                }
                .padding(horizontal: 12, vertical: 8)
            }
            .flex(1, shrink: 1)
        }
        .padding(horizontal: 0, vertical: 6)
        .frame(minHeight: 140)
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

    /// Mockup log idiom: info lines stay muted, warnings/errors tint the
    /// message itself, not just the badge.
    private var messageColor: SemanticColorRef {
        switch entry.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }
}
