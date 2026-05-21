import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorStatusBar: View {
    private let store: EditorStore
    private let getTiming: () -> EditorFrameTiming

    init(store: EditorStore, getTiming: @escaping () -> EditorFrameTiming) {
        self.store = store
        self.getTiming = getTiming
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.frameTimingRevision
            let timing = getTiming()
            Row(alignment: .center, spacing: 8) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(store.connected ? .success : .warning)
                    .cornerRadius(3)

                Text(store.connected ? L("Connected") : L("Offline"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)

                Divider()
                    .frame(width: 1, height: 14)

                Text("Revision \(store.sceneRevision)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)

                Divider()
                    .frame(width: 1, height: 14)

                Text("Selection \(store.selectedEntityIDsCount)")
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)

                Spacer(minLength: 0)

                Text(String(format: "%.0f fps  %.1f ms", timing.framesPerSecond, timing.frameMilliseconds))
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)

                Divider()
                    .frame(width: 1, height: 14)

                // Status message can be long (AI output, console entries); cap
                // width and clip so it never pushes other items off screen.
                Box {
                    Text(statusText(store: store))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundColor(statusColor(store: store))
                }
                .frame(maxWidth: 260)
                .flex(0, shrink: 1)
                .clipped()
            }
            .padding(horizontal: 10, vertical: 5)
            .background(.surfaceSunken)
        }
    }

    private func statusText(store: EditorStore) -> String {
        if let message = store.aiStatusMessage {
            return message
        }
        if let latest = store.latestConsoleEntry {
            return latest.message
        }
        return L("Ready")
    }

    private func statusColor(store: EditorStore) -> SemanticColorRef {
        guard store.aiStatusMessage == nil,
              let latest = store.latestConsoleEntry else {
            return .onSurfaceMuted
        }
        switch latest.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }
}
