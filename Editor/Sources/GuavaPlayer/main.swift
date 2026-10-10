import Foundation
import GameRuntime
import EngineCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import RenderBackend
import RHIWGPU
import NativeRHI

// MARK: - Observable viewport state

/// Holds the most recent rendered viewport surface and invalidates observers
/// (ViewGraph scopes) whenever it changes, triggering `GamePlayerRootView` to
/// recompose automatically via `ObservableStateTracking`.
private final class GamePlayerState: @unchecked Sendable {
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
    }
}

// MARK: - Entry point helpers

private func resolveProjectDirectory() -> String? {
    GameProjectDirectoryResolver.resolve()
}

private func requestedRendererName() throws -> String {
    if let index = CommandLine.arguments.firstIndex(of: "--renderer") {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw NSError(domain: "GuavaPlayer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "--renderer requires wgpu, native, metal, vulkan, or dx12."])
        }
        return CommandLine.arguments[index + 1].lowercased()
    }
    return ProcessInfo.processInfo.environment["GUAVA_RENDERER"]?.lowercased() ?? "native"
}

private func makeRenderDevice() throws -> EngineRenderDevice {
    let requested = try requestedRendererName()
    guard requested != "wgpu" else { return .wgpu(WGPUBackend()) }
    let api: GraphicsAPI
    switch requested {
    case "native":
        guard let platformAPI = NativeRHI.platformDefaultBackends.first else {
            throw NSError(domain: "GuavaPlayer", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "NativeRHI has no backend for this platform."])
        }
        api = platformAPI
    case "metal": api = .metal
    case "vulkan": api = .vulkan
    case "dx12", "d3d12": api = .dx12
    default:
        throw NSError(domain: "GuavaPlayer", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown renderer '\(requested)'."])
    }
    let config = DeviceConfig(preferredBackends: [api], enableValidation: true, framesInFlight: 3)
    return .native(try Device.make(config))
}

@MainActor
@preconcurrency
private func runPlayer() throws {
    let projectDirectory = resolveProjectDirectory()
    let renderDevice = try makeRenderDevice()
    let app = try GameApplication(projectDirectory: projectDirectory, renderDevice: renderDevice)
    let playerState = GamePlayerState()

    app.onViewportSurfaceChanged = { surface in
        playerState.update(surface: surface)
    }

    app.bootstrap()
    defer { app.shutdown() }

    let inGameUIHost: InGameUIHost
    switch renderDevice {
    case .wgpu(let backend): inGameUIHost = InGameUIHost(backend: backend)
    case .native(let device): inGameUIHost = try InGameUIHost(device: device)
    }
    InGameUIRegistry.shared.provider = inGameUIHost

    try AppRuntime.run(
        config: AppConfig(
            title: "Guava Player",
            clearColor: GPUColor(r: 0, g: 0, b: 0, a: 1),
            backendConfig: WGPUDeviceConfig(),
            titleBarStyle: .standard,
            targetFrameRate: 60
        ),
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
            throw NSError(domain: "GuavaPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Project validation requires --project <directory>."])
        }
        var frames = 0
        if let index = CommandLine.arguments.firstIndex(of: "--simulation-frames") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let count = Int(CommandLine.arguments[index + 1]), (0...600).contains(count) else {
                throw NSError(domain: "GuavaPlayer", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "--simulation-frames must be between 0 and 600."])
            }
            frames = count
        }
        let app = try GameApplication(projectDirectory: project)
        app.simulateFrames(frames)
        let report = "GuavaPlayer project validation passed (\(app.compiledScriptCount) compiled scripts, \(app.scene.manifest().entityCount) entities, \(frames) simulation frames)\n"
        FileHandle.standardOutput.write(Data(report.utf8))
    } catch {
        FileHandle.standardError.write(Data("[GuavaPlayer] project validation failed: \(error)\n".utf8))
        exit(1)
    }
} else if CommandLine.arguments.contains("--validate-install") {
    do {
        let report = try PlayerInstallValidator.validateLayout()
        FileHandle.standardOutput.write(Data("\(report)\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
} else {
    do {
        try runPlayer()
    } catch {
        FileHandle.standardError.write(Data("[GuavaPlayer] startup failed: \(error)\n".utf8))
        exit(1)
    }
}
