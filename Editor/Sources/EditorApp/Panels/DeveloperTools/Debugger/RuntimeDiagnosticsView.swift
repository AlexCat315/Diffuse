import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct RuntimeDiagnosticsView: View {
    let store: EditorStore
    let timingRevision: UInt64
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats

    var body: some View {
        ScrollView(.vertical) {
            Box(direction: .row, alignItems: .stretch, wrap: .wrap, spacing: 8) {
                StatGroup(title: L("Editor")) {
                    StatRow(label: L("Status"), value: store.connected ? L("Connected") : L("Offline"))
                    StatRow(label: L("Revision"), value: "\(store.sceneRevision)")
                    StatRow(label: L("Frame Index"), value: "\(store.frameIndex)")
                    StatRow(label: L("Timing Sample"), value: "#\(timingRevision)")
                }
                .frame(minWidth: 200, maxWidth: 280)

                StatGroup(title: L("Performance")) {
                    StatRow(label: L("Frame Work"), value: formatMs(frameStats.workMs))
                    StatRow(label: L("Observed FPS"), value: formatFPS(frameStats.fps))
                    StatRow(label: L("CPU Total"), value: formatMs(frameStats.cpuWorkSeconds * 1000))
                    StatRow(label: L("GPU / Present"), value: formatMs(frameStats.gpuPresentSeconds * 1000))
                    StatRow(label: L("Pacing Gap"), value: formatMs(frameStats.pacingGapMs))
                }
                .frame(minWidth: 200, maxWidth: 280)

                StatGroup(title: L("Render")) {
                    StatRow(label: L("Draw Calls"), value: "\(renderStats.drawCallCount)")
                    StatRow(label: L("Passes"), value: "\(renderStats.passCount)")
                    StatRow(label: L("Render Bundles"), value: "\(renderStats.renderBundleCount)")
                    StatRow(label: L("CPU Encode"), value: formatNs(renderStats.cpuEncodeNS))
                }
                .frame(minWidth: 200, maxWidth: 280)

                StatGroup(title: L("Viewport")) {
                    StatRow(label: L("Realtime"), value: store.viewportRealtimeEnabled ? L("On") : L("Off"))
                    StatRow(label: L("Render Scale"), value: "\(store.viewportRenderScalePercent)%")
                    StatRow(label: L("Shading"), value: L(String(describing: store.viewportShadingMode).capitalized))
                    StatRow(label: L("Shadows"), value: store.viewportShadowsEnabled ? L("On") : L("Off"))
                }
                .frame(minWidth: 200, maxWidth: 280)

                StatGroup(title: L("Selection")) {
                    if let selected = store.selectedEntityID {
                        StatRow(label: L("Primary"), value: "\(selected)")
                    } else {
                        StatRow(label: L("Primary"), value: "--")
                    }
                    StatRow(label: L("Count"), value: "\(store.selectedEntityIDs.count)")
                    StatRow(label: L("Playback"), value: L(String(describing: store.playbackState).capitalized))
                }
                .frame(minWidth: 200, maxWidth: 280)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)
        }
    }
}
