import Darwin
import GameRuntime
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import EngineKernel
import RHIWGPU

/// Resolves the project directory from `--project <path>` or defaults to the
/// current working directory.
private func resolveProjectDirectory() -> String? {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--project"), args.indices.contains(idx + 1) {
        return args[idx + 1]
    }
    return nil
}

@MainActor
private func runPlayer() throws {
    let projectDirectory = resolveProjectDirectory()
    let backend = WGPUBackend()
    let app = try GameApplication(projectDirectory: projectDirectory, backend: backend)
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
        EmptyView()
    }
}

do {
    try runPlayer()
} catch {
    fputs("[GuavaPlayer] startup failed: \(error)\n", stderr)
    exit(1)
}
