import CinematicRenderer
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

/// Offline render panel: resolution/SPP fields, primary Render action, and a
/// slim accent progress bar.
struct RenderPipelinePanel: View, @unchecked Sendable {
    let app: EditorApplication
    @State var isRendering: Bool = false
    @State var progressFraction: Float = 0
    @State var completeSamples: Int = 0
    @State var totalSamples: Int = 0
    @State var lastOutputPath: String = ""
    @State var statusMessage: String = ""
    @State var statusIsError: Bool = false
    @State var activeRunner: RenderPipelineRunner? = nil
    @AppStorage("renderPipeline.width") var width: String = "640"
    @AppStorage("renderPipeline.height") var height: String = "480"
    @AppStorage("renderPipeline.samples") var samples: String = "64"

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

            Row(alignment: .center, spacing: 8) {
                Button(isEnabled: !isRendering, action: { startRender() }) {
                    Text(isRendering ? L("Rendering…") : L("Render Current Scene"))
                }
                if isRendering {
                    Button(L("Cancel")) {
                        statusMessage = L("Cancelling render…")
                        statusIsError = false
                        activeRunner?.cancel()
                    }
                    .buttonStyle(.secondary)
                }
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
                Row(alignment: .center, spacing: 8) {
                    Text("→ \(lastOutputPath)", lineLimit: 2)
                        .font(.caption).foregroundColor(.success)
                        .flex(1, shrink: 1)
                    Button(L("Reveal Output"), action: revealOutput)
                        .buttonStyle(.secondary)
                }
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(statusIsError ? .error : .warning)
            }
        }
        .padding(horizontal: 8, vertical: 8)
    }

    private func startRender() {
        guard !isRendering else { return }
        let request: RenderPipelineRequest
        switch validateRenderPipelineRequest(width: width, height: height, samples: samples) {
        case .success(let validated):
            request = validated
        case .failure(let error):
            statusMessage = error.localizedDescription
            statusIsError = true
            return
        }

        let renderScene = app.currentRenderScene()
        let geometry = RenderScenePathTraceGeometry(scene: renderScene)
        guard geometry.triangleCount > 0 else {
            statusMessage = L("The current scene has no visible mesh geometry to render.")
            statusIsError = true
            return
        }

        let outputDirectory = URL(fileURLWithPath: app.projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("renders", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            statusMessage = "\(L("Could not prepare the render output folder:")) \(error.localizedDescription)"
            statusIsError = true
            return
        }
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let output = outputDirectory
            .appendingPathComponent("guava_render_\(timestamp).exr")
            .path

        isRendering = true
        progressFraction = 0
        completeSamples = 0
        totalSamples = request.samples
        lastOutputPath = ""
        statusMessage = ""
        statusIsError = false

        let runner = RenderPipelineRunner(config: RenderPipelineRunner.Config(
            width: request.width,
            height: request.height,
            samplesPerPixel: request.samples,
            outputPath: output))
        activeRunner = runner
        let environment = renderScene.environment.ambientColor
            * max(0.08, renderScene.environment.ambientIntensity)
        runner.run(
            scene: geometry,
            camera: renderScene.camera,
            environmentColor: environment,
            onProgress: { p in
                MainActor.assumeIsolated {
                    progressFraction = p.fraction
                    completeSamples = p.completed
                }
            },
            onComplete: { result in
                MainActor.assumeIsolated {
                    isRendering = false
                    activeRunner = nil
                    switch result {
                    case .success(let path):
                        lastOutputPath = path
                        progressFraction = 1
                    case .failure(let error):
                        statusMessage = error.localizedDescription
                        statusIsError = !(error is RenderPipelineRunnerError)
                    }
                }
            }
        )
    }

    private func revealOutput() {
        guard !lastOutputPath.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", lastOutputPath]
        do {
            try process.run()
        } catch {
            statusMessage = "\(L("Could not reveal render output:")) \(error.localizedDescription)"
            statusIsError = true
        }
    }
}

struct RenderPipelineRequest: Equatable {
    var width: Int
    var height: Int
    var samples: Int
}

enum RenderPipelineInputError: LocalizedError, Equatable {
    case invalidInteger
    case dimensionsOutOfRange
    case samplesOutOfRange

    var errorDescription: String? {
        switch self {
        case .invalidInteger:
            return L("Width, height, and SPP must be whole numbers.")
        case .dimensionsOutOfRange:
            return L("Width and height must be between 16 and 2048 pixels.")
        case .samplesOutOfRange:
            return L("SPP must be between 1 and 1024.")
        }
    }
}

func validateRenderPipelineRequest(width: String,
                                   height: String,
                                   samples: String) -> Result<RenderPipelineRequest, RenderPipelineInputError> {
    guard let width = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
          let height = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
          let samples = Int(samples.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return .failure(.invalidInteger)
    }
    guard (16...2048).contains(width), (16...2048).contains(height) else {
        return .failure(.dimensionsOutOfRange)
    }
    guard (1...1024).contains(samples) else {
        return .failure(.samplesOutOfRange)
    }
    return .success(RenderPipelineRequest(width: width,
                                          height: height,
                                          samples: samples))
}
