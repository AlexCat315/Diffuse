import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorStatusBar: View {
    let isConnected: Bool
    let sceneRevision: UInt64
    let selectedCount: Int
    let aiStatusMessage: String?
    let fps: Double
    let frameMs: Double

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(isConnected ? .success : .warning)
                .cornerRadius(3)

            Text(isConnected ? L("Connected") : L("Offline"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Revision \(sceneRevision)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Selection \(selectedCount)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Spacer(minLength: 0)

            Text(String(format: "%.0f fps  %.1f ms", fps, frameMs))
                .font(.mono)
                .foregroundColor(.onSurfaceMuted)

            Spacer(minLength: 0)

            Text(aiStatusMessage ?? L("Ready"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 5)
        .background(.surfaceVariant)
    }
}
