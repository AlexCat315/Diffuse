import EditorCore
import GuavaUICompose

struct ConsolePanel: View {
    let store: EditorStore

    var body: some View {
        StoreScope(store) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 8) {
                Row(alignment: .center, spacing: 8) {
                    Text(store.connected ? L("Connected") : L("Offline"))
                        .font(.caption)
                        .foregroundColor(store.connected ? .success : .warning)

                    Spacer(minLength: 0)

                    Text("revision \(store.sceneRevision)")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)

                    Button(L("Clear")) {
                        store.dispatch(.clearConsole)
                    }
                    .buttonStyle(.ghost)
                    .frame(height: 24)
                }

                ScrollView(.vertical) {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
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
                .flex()
            }
            .padding(10)
            .frame(minHeight: 140)
        }
    }
}

private struct ConsoleEntryRow: View {
    let entry: EditorConsoleEntry

    var body: some View {
        Row(alignment: .top, spacing: 8) {
            Text(severityLabel)
                .font(.mono)
                .foregroundColor(severityColor)
                .frame(width: 44)

            Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(entry.message, lineLimit: 1)
                    .font(.mono)
                    .foregroundColor(.onSurface)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail, lineLimit: 2)
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .flex()
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
