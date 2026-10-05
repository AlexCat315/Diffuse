import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperDebuggerWorkbenchView: View {
    let store: EditorStore
    let timingRevision: UInt64
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats

    var body: some View {
        Row(alignment: .top, spacing: 0) {
            RuntimeDiagnosticsView(store: store,
                                   timingRevision: timingRevision,
                                   frameStats: frameStats,
                                   renderStats: renderStats)
                .frame(minWidth: 420, maxWidth: 640)
                .flex(1, shrink: 1, basis: 620)

            Divider(axis: .vertical)
                .frame(width: 1)

            ConsoleDiagnosticsView(store: store)
                .frame(minWidth: 320, maxWidth: 460)
                .flex(0.8, shrink: 1, basis: 360)
        }
        .background(.surface)
    }
}
