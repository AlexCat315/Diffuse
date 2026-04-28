import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorStatusBar: View {
    private let store: EditorStore
    private let getTiming: () -> EditorFrameTiming
    private let _frameTimingRevision: Observed<EditorStore, UInt64>
    private let _connected: Observed<EditorStore, Bool>
    private let _sceneRevision: Observed<EditorStore, UInt64>
    private let _selectedCount: Observed<EditorStore, Int>
    private let _aiMsg: Observed<EditorStore, String?>

    init(store: EditorStore, getTiming: @escaping () -> EditorFrameTiming) {
        self.store = store
        self.getTiming = getTiming
        self._frameTimingRevision = Observed(\.frameTimingRevision, on: store)
        self._connected = Observed(\.connected, on: store)
        self._sceneRevision = Observed(\.sceneRevision, on: store)
        self._selectedCount = Observed(\.selectedEntityIDsCount, on: store)
        self._aiMsg = Observed(\.aiStatusMessage, on: store)
    }

    var body: some View {
        let _ = _frameTimingRevision.wrappedValue
        let timing = getTiming()
        Row(alignment: .center, spacing: 8) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(_connected.wrappedValue ? .success : .warning)
                .cornerRadius(3)

            Text(_connected.wrappedValue ? L("Connected") : L("Offline"))
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Revision \(_sceneRevision.wrappedValue)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Divider()
                .frame(width: 1, height: 14)

            Text("Selection \(_selectedCount.wrappedValue)")
                .font(.caption)
                .foregroundColor(.onSurfaceVariant)

            Spacer(minLength: 0)

            Text(String(format: "%.0f fps  %.1f ms", timing.framesPerSecond, timing.frameMilliseconds))
                .font(.mono)
                .foregroundColor(.onSurfaceMuted)

            Divider()
                .frame(width: 1, height: 14)

            Text(_aiMsg.wrappedValue ?? L("Ready"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 5)
        .background(.surfaceVariant)
    }
}
