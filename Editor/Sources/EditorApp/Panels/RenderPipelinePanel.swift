import CinematicRenderer
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct RenderPipelinePanel: View {
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
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text("W").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField(text: $width).frame(width: 50)
                Text("H").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField(text: $height).frame(width: 50)
                Text("SPP").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField(text: $samples).frame(width: 50)
            }

            Button(role: .normal, isEnabled: !isRendering) {
                startRender()
            } label: {
                Text(isRendering ? "Rendering..." : "Render")
                    .font(.body)
            }
            .buttonStyle(.primary)

            if isRendering || progressFraction > 0 {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    Row(alignment: .center, spacing: 0) {
                        Box(direction: .row, alignItems: .center, spacing: 0) {}
                            .frame(width: 240 * progressFraction, height: 4)
                            .background(.accent)
                        Box(direction: .row, alignItems: .center, spacing: 0) {}
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
        .padding(8)
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
