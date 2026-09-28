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
        let estimate = estimateRenderPipelineInputs(width: width, height: height, samples: samples)
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                Text("W").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("640", text: $width).frame(width: 56)
                Text("H").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("480", text: $height).frame(width: 56)
                Text("SPP").font(.caption).foregroundColor(.onSurfaceMuted)
                TextField("64", text: $samples).frame(width: 56)
            }

            Row(alignment: .center, spacing: 5) {
                Text(L("Presets"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                presetButton(.preview)
                presetButton(.hd)
                presetButton(.fullHD)
            }

            if let estimate {
                Text(String(format: L("%lld path samples · about %lld MiB image buffers"),
                            Int64(estimate.pathSampleCount),
                            Int64(estimate.imageBufferMiB)))
                    .font(.caption)
                    .foregroundColor(estimate.pathSampleCount > RenderPipelineRequest.maximumPathSamples
                        ? .warning : .onSurfaceMuted)
                if estimate.pathSampleCount > RenderPipelineRequest.maximumPathSamples {
                    Text(L("Reduce resolution or SPP to stay within the render budget."))
                        .font(.caption)
                        .foregroundColor(.warning)
                }
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
                            .frame(width: 240 * min(1, max(0, progressFraction)), height: 4)
                            .background(.accent)
                        Box { EmptyView() }
                            .frame(width: 240 * (1 - min(1, max(0, progressFraction))), height: 4)
                            .background(.surfaceVariant)
                    }
                    .cornerRadius(2)
                    Text(String(format: L("%lld / %lld sample passes · %lld%%"),
                                Int64(completeSamples),
                                Int64(totalSamples),
                                Int64((min(1, max(0, progressFraction)) * 100).rounded())))
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
                        if error is RenderPipelineRunnerError {
                            progressFraction = 0
                            completeSamples = 0
                            totalSamples = 0
                        }
                    }
                }
            }
        )
    }

    private func revealOutput() {
        guard !lastOutputPath.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: lastOutputPath) else {
            statusMessage = L("The render output no longer exists.")
            statusIsError = true
            return
        }
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

    private func apply(_ preset: RenderPipelinePreset) {
        width = String(preset.width)
        height = String(preset.height)
        samples = String(preset.samples)
        statusMessage = ""
        statusIsError = false
    }

    private func presetButton(_ preset: RenderPipelinePreset) -> some View {
        Button(isSelected: preset.matches(width: width,
                                          height: height,
                                          samples: samples),
               action: { apply(preset) }) {
            Text(preset.title, lineLimit: 1)
        }
        .buttonStyle(ToggleButtonStyle(height: 22))
    }
}

struct RenderPipelineRequest: Equatable {
    static let maximumPathSamples = 64_000_000

    var width: Int
    var height: Int
    var samples: Int

    var pathSampleCount: Int { width * height * samples }
    var estimatedImageBufferMiB: Int {
        let imageBufferBytes = width * height * MemoryLayout<Float>.size * 7
        return (imageBufferBytes + 1_048_575) / 1_048_576
    }
}

struct RenderPipelineEstimate: Equatable {
    let pathSampleCount: Int
    let imageBufferMiB: Int
}

enum RenderPipelinePreset: String, CaseIterable {
    case preview
    case hd
    case fullHD

    var title: String {
        switch self {
        case .preview: return L("Preview")
        case .hd: return "720p"
        case .fullHD: return "1080p"
        }
    }

    var width: Int {
        switch self {
        case .preview: return 320
        case .hd: return 1280
        case .fullHD: return 1920
        }
    }

    var height: Int {
        switch self {
        case .preview: return 240
        case .hd: return 720
        case .fullHD: return 1080
        }
    }

    var samples: Int { self == .preview ? 16 : 8 }

    func matches(width: String, height: String, samples: String) -> Bool {
        width == String(self.width)
            && height == String(self.height)
            && samples == String(self.samples)
    }
}

enum RenderPipelineInputError: LocalizedError, Equatable {
    case invalidInteger
    case dimensionsOutOfRange
    case samplesOutOfRange
    case workloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidInteger:
            return L("Width, height, and SPP must be whole numbers.")
        case .dimensionsOutOfRange:
            return L("Width and height must be between 16 and 2048 pixels.")
        case .samplesOutOfRange:
            return L("SPP must be between 1 and 1024.")
        case .workloadTooLarge:
            return L("The render exceeds the 64 million path-sample budget. Reduce resolution or SPP.")
        }
    }
}

func estimateRenderPipelineInputs(width: String,
                                  height: String,
                                  samples: String) -> RenderPipelineEstimate? {
    guard let width = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
          let height = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
          let samples = Int(samples.trimmingCharacters(in: .whitespacesAndNewlines)),
          (16...2048).contains(width),
          (16...2048).contains(height),
          (1...1024).contains(samples) else { return nil }
    let request = RenderPipelineRequest(width: width, height: height, samples: samples)
    return RenderPipelineEstimate(pathSampleCount: request.pathSampleCount,
                                  imageBufferMiB: request.estimatedImageBufferMiB)
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
    let request = RenderPipelineRequest(width: width, height: height, samples: samples)
    guard request.pathSampleCount <= RenderPipelineRequest.maximumPathSamples else {
        return .failure(.workloadTooLarge)
    }
    return .success(request)
}
