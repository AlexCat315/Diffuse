import EditorCore
import GuavaUICompose
import Foundation

/// 24px editor footer in the floating-island language: muted captions on the
/// bare canvas, no divider. Left: connection + scene revision + selection.
/// Right: frame timing (mono) + latest status/console message.
struct EditorStatusBar: View {
    let store: EditorStore
    let getTiming: () -> EditorFrameTiming

    var body: some View {
        let timing = getTiming()
        Row(alignment: .center, spacing: 8) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(store.connected ? SemanticColorRef.success : .warning)
                .cornerRadius(3)

            Text(store.connected ? L("Connected") : L("Offline"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Text("\(L("Revision")) \(store.sceneRevision)")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            if store.sceneDirty {
                Text("• \(L("Unsaved"))")
                    .font(.caption)
                    .foregroundColor(.warning)
            }

            Text("\(L("Selection")) \(store.selectedEntityIDsCount)")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Spacer(minLength: 0)

            // Frame-on-demand rendering reports zero while idle; "0 fps" reads
            // like a failure, so only show timing while frames are flowing.
            if timing.framesPerSecond > 0 {
                Text(String(format: "%.0f fps  %.1f ms",
                            timing.framesPerSecond, timing.frameMilliseconds))
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }

            // Status message can be long (AI output, console entries); cap
            // width and clip so it never pushes other items off screen.
            Box {
                Text(statusText)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            .frame(maxWidth: 260)
            .flex(0, shrink: 1)
            .clipped()
        }
        .padding(horizontal: 12, vertical: 0)
        .frame(height: 24)
    }

    // Info-level console traffic stays in the console panel; the footer only
    // echoes AI status and warnings/errors. (Info echo also duplicated the
    // left-side connection indicator whenever the latest log was
    // "connected".)
    private var statusText: String {
        if let message = store.aiStatusMessage {
            return message
        }
        if let latest = store.latestConsoleEntry, latest.severity != .info {
            return latest.message
        }
        return L("Ready")
    }

    private var statusColor: SemanticColorRef {
        guard store.aiStatusMessage == nil,
              let latest = store.latestConsoleEntry,
              latest.severity != .info else {
            return .onSurfaceMuted
        }
        switch latest.severity {
        case .info: return .onSurfaceMuted
        case .warning: return .warning
        case .error: return .error
        }
    }
}
