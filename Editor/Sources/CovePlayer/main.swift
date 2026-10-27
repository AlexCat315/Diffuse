import EditorCore
import Foundation
import CoveLogging
private var loggingConfiguration = LoggingConfiguration()
try loggingConfiguration.applyEnvironment(ProcessInfo.processInfo.environment)
try LogSystem.bootstrap(application: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, configuration: loggingConfiguration)
defer { LogSystem.flush() }
import GameRuntime
import EngineCore
import CoveUI
import CoveUICompose
import CoveUIRuntime
import EngineKernel
import RenderBackend
import NativeRHI

// MARK: - Observable viewport state

/// Holds the most recent rendered viewport surface and invalidates observers
/// (ViewGraph scopes) whenever it changes, triggering `GamePlayerRootView` to
/// recompose automatically via `ObservableStateTracking`.
private enum PlayerPreparationState {
    case preparing(ResourcePreparationProgress?), ready, failed(String), cancelled
}
private final class GamePlayerState: @unchecked Sendable {
    private var preparationValue = PlayerPreparationState.preparing(nil)
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    var preparationTask: Task<Void, Never>?
    var retryPreparation: (() -> Void)?
    var preparation: PlayerPreparationState { registrar.access("preparation"); return preparationValue }
    func beginPreparation() -> UInt64 {
        preparationTask?.cancel(); generation &+= 1; sequence = 0
        preparationValue = .preparing(nil); registrar.invalidate("preparation"); return generation
    }
    func progress(_ value: ResourcePreparationProgress, generation: UInt64) {
        guard self.generation == generation, value.sequence > sequence,
              case .preparing = preparationValue else { return }
        sequence = value.sequence; preparationValue = .preparing(value); registrar.invalidate("preparation")
    }
    func complete(_ value: PlayerPreparationState, generation: UInt64) {
        guard self.generation == generation else { return }
        preparationValue = value; preparationTask = nil; registrar.invalidate("preparation")
    }
    func cancelPreparation() {
        preparationTask?.cancel(); preparationTask = nil; generation &+= 1
        preparationValue = .cancelled; registrar.invalidate("preparation")
    }
    private let registrar = ObservableStateRegistrar()
    private var _viewportSurface: ViewportSurfaceState = .init()

    /// Logical (point) size of the viewport, for HUD layout. Written from
    /// `onScreenFrameChange`; no recompose dependency needed.
    var logicalSize: (width: Float, height: Float) = (1280, 720)

    /// Reading this property inside a view body registers a recompose dependency.
    var viewportSurface: ViewportSurfaceState {
        registrar.access("viewportSurface")
        return _viewportSurface
    }

    func update(surface: ViewportSurfaceState) {
        _viewportSurface = surface
        registrar.invalidate("viewportSurface")
    }
}

// MARK: - Root view

/// Full-window `ViewportHost` that displays the engine's rendered scene.
/// Recomposes automatically each time `GamePlayerState.viewportSurface` changes.
private struct GamePlayerRootView: View {
    let app: GameApplication
    let state: GamePlayerState

    var body: some View {
        switch state.preparation {
        case .ready:
            ViewportHost(
                surface: state.viewportSurface,
                automaticallyFocus: true,
                onInputEvent: { app.enqueueInput($0) },
                onDrawableSizeChange: { app.setViewportDrawableSize($0) },
                onScreenFrameChange: { frame in
                    state.logicalSize = (frame.width, frame.height)
                }
            ) {
                EmptyView()
            }
            .flex()
        case let .preparing(progress):
            Column(alignment: .center, spacing: 12) {
                Spinner(size: 18)
                Text("Preparing shaders…")
                if let step = progress?.currentStep { Text(step).font(.caption) }
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction).frame(width: 240)
                }
                Button("Cancel") { state.cancelPreparation() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            Column(alignment: .center, spacing: 12) {
                Text("Shader preparation failed")
                Text(message).font(.caption)
                Button("Retry") { state.retryPreparation?() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cancelled:
            Column(alignment: .center, spacing: 12) {
                Text("Shader preparation cancelled")
                Button("Retry") { state.retryPreparation?() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private func startPlayerPreparation(app: GameApplication, state: GamePlayerState) {
    let generation = state.beginPreparation()
    state.preparationTask = Task { @MainActor in
        do {
            try await app.bootstrapPrepared { progress in
                Task { @MainActor in state.progress(progress, generation: generation) }
            }
            try Task.checkCancellation()
            state.complete(.ready, generation: generation)
        } catch is CancellationError {
            state.complete(.cancelled, generation: generation)
        } catch {
            state.complete(.failed(String(describing: error)), generation: generation)
        }
    }
}

// MARK: - Entry point helpers

private func resolveProjectDirectory() -> String? {
    GameProjectDirectoryResolver.resolve()
}

private func requestedRendererName() throws -> String {
    if let index = CommandLine.arguments.firstIndex(of: "--renderer") {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw NSError(domain: "CovePlayer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "--renderer requires native, metal, vulkan, or dx12."])
        }
        return CommandLine.arguments[index + 1].lowercased()
    }
    return ProcessInfo.processInfo.environment["COVE_RENDERER"]?.lowercased() ?? "native"
}

private func makeRenderDevice() throws -> Device {
    let requested = try requestedRendererName()
    var config = DeviceConfig(enableValidation: true, framesInFlight: 3)
    switch requested {
    case "native": break
    case "metal": config.preferredBackends = [.metal]
    case "vulkan": config.preferredBackends = [.vulkan]
    case "dx12", "d3d12": config.preferredBackends = [.dx12]
    default:
        throw NSError(domain: "CovePlayer", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown renderer '\(requested)'."])
    }
    return try Device.make(config)
}

@MainActor
@preconcurrency
private func runPlayer() throws {
    let projectDirectory = resolveProjectDirectory()
    let renderDevice = try makeRenderDevice()
    let inGameUIHost = try InGameUIHost(device: renderDevice)
    let app = try GameApplication(projectDirectory: projectDirectory, renderDevice: renderDevice, inGameUI: inGameUIHost)
    let playerState = GamePlayerState()

    app.onViewportSurfaceChanged = { surface in
        playerState.update(surface: surface)
    }

    playerState.retryPreparation = { [weak app, weak playerState] in
        guard let app, let playerState else { return }
        startPlayerPreparation(app: app, state: playerState)
    }
    startPlayerPreparation(app: app, state: playerState)
    defer { playerState.cancelPreparation(); app.shutdown() }


    try Application.run(
        config: ApplicationConfiguration(title: "Cove Player") {
            $0.rendering.clearColor = SIMD4(0, 0, 0, 1)
            $0.frames.policy = .continuous
            $0.frames.targetRate = 60
        },
        backend: renderDevice,
        onTick: { dt in
            app.tick(deltaTime: dt)
            let logical = playerState.logicalSize
            inGameUIHost.tick(width: Int(logical.width.rounded()),
                              height: Int(logical.height.rounded()),
                              contentScale: max(1, ContentScaleHolder.current),
                              canvas: app.scene.currentInGameCanvas())
        }
    ) {
        GamePlayerRootView(app: app, state: playerState)
    }
}

if CommandLine.arguments.contains("--validate-project") {
    do {
        guard let project = resolveProjectDirectory() else {
            throw NSError(domain: "CovePlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Project validation requires --project <directory>."])
        }
        var frames = 0
        if let index = CommandLine.arguments.firstIndex(of: "--simulation-frames") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let count = Int(CommandLine.arguments[index + 1]), (0...600).contains(count) else {
                throw NSError(domain: "CovePlayer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "--simulation-frames must be between 0 and 600."])
            }
            frames = count
        }
        let app = try GameApplication(projectDirectory: project)
        app.simulateFrames(frames)
        let report = "CovePlayer project validation passed (\(app.compiledScriptCount) compiled scripts, \(app.scene.manifest().entityCount) entities, \(frames) simulation frames)\n"
        FileHandle.standardOutput.write(Data(report.utf8))
    } catch {
        LogSystem.logger("com.cove.player").error("[CovePlayer] project validation failed: \(error)")
        LogSystem.flush()
        exit(1)
    }
} else if CommandLine.arguments.contains("--validate-install") {
    do {
        let report = try PlayerInstallValidator.validateLayout()
        FileHandle.standardOutput.write(Data("\(report)\n".utf8))
    } catch {
        LogSystem.logger("com.cove.player").error("\(error)")
        LogSystem.flush()
        exit(1)
    }
} else {
    do {
        try runPlayer()
    } catch {
        LogSystem.logger("com.cove.player").error("[CovePlayer] startup failed: \(error)")
        LogSystem.flush()
        exit(1)
    }
}
