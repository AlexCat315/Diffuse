import CinematicRenderer
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

/// Offline render panel: resolution/SPP fields, primary Render action, and a
/// slim accent progress bar.
struct RenderPipelinePanel: View, @unchecked Sendable {
    @State var isRendering: Bool = false
    @State var progressFraction: Float = 0
    @State var completeSamples: Int = 0
    @State var totalSamples: Int = 0
    @State var lastOutputPath: String = ""
    @State var statusMessage: String = ""
    @State var width: String = "640"
    @State var height: String = "480"
    @State var samples: String = "64"

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text("W").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("640", text: $width).frame(width: 56)
                Text("H").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("480", text: $height).frame(width: 56)
                Text("SPP").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("64", text: $samples).frame(width: 56)
            }

            Button(isEnabled: !isRendering, action: { startRender() }) {
                Text(isRendering ? "Rendering..." : "Render")
            }

            if isRendering || progressFraction > 0 {
                Column(alignment: .leading, spacing: 4) {
                    Row(alignment: .center, spacing: 0) {
                        Box { EmptyView() }
                            .frame(width: 240 * progressFraction, height: 4)
                            .background(.accent)
                        Box { EmptyView() }
                            .frame(width: 240 * (1 - progressFraction), height: 4)
                            .background(.surfaceVariant)
                    }
                    .cornerRadius(2)
                    Text("\(completeSamples) / \(totalSamples) spp")
                        .font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }

            if !lastOutputPath.isEmpty {
                Text("→ \(lastOutputPath)")
                    .font(.caption).foregroundColor(.success)
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption).foregroundColor(.warning)
            }
        }
        .padding(horizontal: 8, vertical: 8)
    }

    private func startRender() {
        guard !isRendering else { return }
        let w = Int(width) ?? 640
        let h = Int(height) ?? 480
        let spp = Int(samples) ?? 64
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_render_\(Int(Date().timeIntervalSince1970)).exr").path

        isRendering = true
        progressFraction = 0
        completeSamples = 0
        totalSamples = spp
        lastOutputPath = output
        statusMessage = ""

        let runner = RenderPipelineRunner(config: RenderPipelineRunner.Config(
            width: w, height: h, samplesPerPixel: spp, outputPath: output))
        runner.run(
            scene: SimpleTestScene(),
            onProgress: { p in
                MainActor.assumeIsolated {
                    progressFraction = p.fraction
                    completeSamples = p.completed
                }
            },
            onComplete: { result in
                MainActor.assumeIsolated {
                    isRendering = false
                    switch result {
                    case .success(let path):
                        lastOutputPath = path
                    case .failure(let error):
                        statusMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        )
    }
}
