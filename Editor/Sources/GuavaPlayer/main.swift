import Foundation
import GameRuntime
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import RenderBackend
import RHIWGPU

// MARK: - Observable viewport state

/// Holds the most recent rendered viewport surface and invalidates observers
/// (ViewGraph scopes) whenever it changes, triggering `GamePlayerRootView` to
/// recompose automatically via `ObservableStateTracking`.
private final class GamePlayerState: @unchecked Sendable {
    private let registrar = ObservableStateRegistrar()
    private var _viewportSurface: ViewportSurfaceState = .init()

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
            onInputEvent: { app.enqueueInput($0) },
            onDrawableSizeChange: { app.setViewportDrawableSize($0) }
        ) {
            EmptyView()
        }
        .flex()
    }
}

// MARK: - Entry point helpers

private func resolveProjectDirectory() -> String? {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--project"), args.indices.contains(idx + 1) {
        return args[idx + 1]
    }
    return nil
}

@MainActor
@preconcurrency
private func runPlayer() throws {
    let projectDirectory = resolveProjectDirectory()
    let backend = WGPUBackend()
    let app = try GameApplication(projectDirectory: projectDirectory, backend: backend)
    let playerState = GamePlayerState()

    app.onViewportSurfaceChanged = { surface in
        playerState.update(surface: surface)
    }

    app.bootstrap()
    defer { app.shutdown() }

    let inGameUIHost = InGameUIHost(backend: backend)
    InGameUIRegistry.shared.provider = inGameUIHost

    try AppRuntime.run(
        config: AppConfig(
            title: "Guava Player",
            clearColor: GPUColor(r: 0, g: 0, b: 0, a: 1),
            backendConfig: WGPUDeviceConfig(),
            titleBarStyle: .standard,
            targetFrameRate: 60
        ),
        backend: backend,
        onTick: { dt in
            app.tick(deltaTime: dt)
            let size = app.viewportDrawableSize
            inGameUIHost.tick(width: Int(size.width), height: Int(size.height))
        }
    ) {
        GamePlayerRootView(app: app, state: playerState)
    }
}

do {
    try runPlayer()
} catch {
    fputs("[GuavaPlayer] startup failed: \(error)\n", stderr)
    exit(1)
}
