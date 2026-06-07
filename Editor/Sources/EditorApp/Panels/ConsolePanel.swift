import EditorCore
import GuavaKit

struct ConsolePanel: GuavaKit.View {
    @Observed var store: EditorStore

    init(store: EditorStore) {
        self.store = store
    }

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text(store.connected ? L("Connected") : L("Offline"))
                    .font(.caption)
                    .foregroundColor(store.connected ? .success : .warning)

                Spacer()

                Text("revision \(store.sceneRevision)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Button(action: { store.dispatch(.clearConsole) }) {
                    Text(L("Clear"))
                        .foregroundColor(.onSurfaceVariant)
                        .font(.caption)
                }
                .frame(height: 24)
            }

            ScrollView(.column) {
                Column(alignment: .stretch, spacing: 4) {
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
                .padding(8)
            }
            .background(.surfaceSunken)
            .cornerRadius(2)
            .flex(1, shrink: 1)
        }
        .padding(10)
        .frame(minHeight: 140)
    }
}

private struct ConsoleEntryRow: GuavaKit.View {
    let entry: EditorConsoleEntry

    var body: some GuavaKit.View {
        Row(alignment: .start, spacing: 8) {
            Text(severityLabel)
                .font(.mono)
                .foregroundColor(severityColor)
                .frame(width: 44)

            Column(alignment: .stretch, spacing: 2) {
                Text(entry.message, lineLimit: 1)
                    .font(.mono)
                    .foregroundColor(.onSurface)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail, lineLimit: 2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .flex(1, shrink: 1)
        }
        .padding(horizontal: 6, vertical: 3)
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
}
