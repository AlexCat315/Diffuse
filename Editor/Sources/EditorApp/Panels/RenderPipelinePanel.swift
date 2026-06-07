import CinematicRenderer
import EditorCore
import GuavaKit
import Foundation

struct RenderPipelinePanel: GuavaKit.View, @unchecked Sendable {
    @State var isRendering: Bool = false
    @State var progressFraction: Float = 0
    @State var completeSamples: Int = 0
    @State var totalSamples: Int = 0
    @State var lastOutputPath: String = ""
    @State var statusMessage: String = ""
    @State var width: String = "640"
    @State var height: String = "480"
    @State var samples: String = "64"

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 8) {
            // TODO: TextField needs GuavaKit TextField widget (batch 4)
            // For now, show the configured values as labels.
            Row(alignment: .center, spacing: 8) {
                Text("W").font(.caption).foregroundColor(.onSurfaceMuted)
                Text(width).font(.caption).foregroundColor(.onSurface).frame(width: 50)
                Text("H").font(.caption).foregroundColor(.onSurfaceMuted)
                Text(height).font(.caption).foregroundColor(.onSurface).frame(width: 50)
                Text("SPP").font(.caption).foregroundColor(.onSurfaceMuted)
                Text(samples).font(.caption).foregroundColor(.onSurface).frame(width: 50)
            }

            Button(action: { startRender() }) {
                Text(isRendering ? "Rendering..." : "Render")
                    .font(.body)
            }

            if isRendering || progressFraction > 0 {
                Column(alignment: .stretch, spacing: 4) {
                    Row(alignment: .center, spacing: 0) {
                        Element()
                            .frame(width: 240 * progressFraction, height: 4)
                            .background(.accent)
                        Element()
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
