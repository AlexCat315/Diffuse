import Darwin
import EditorCore
import GuavaUIApp
import GuavaUIRuntime
import RHIWGPU

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    var resolvedBackendConfig = launchOptions.backendConfig
    if resolvedBackendConfig.libraryPath == nil {
        resolvedBackendConfig.libraryPath = EditorApplication.locateWGPUDylib()
    }
    let backend = WGPUBackend(config: resolvedBackendConfig)
    let events = PlatformEventBridge()
    let app = try EditorApplication(projectDirectory: launchOptions.projectDirectory,
                                backendConfig: launchOptions.backendConfig,
                                backend: backend,
                                events: events)
    app.bootstrap()
    defer { app.shutdown() }

    let controller = EditorRootViewFactory.makeController()
    let registry = EditorRootViewFactory.makeRegistry(app: app)

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          backendConfig: launchOptions.backendConfig),
        backend: backend,
        events: events,
        onTick: { dt in app.tick(deltaTime: dt) }
    ) {
        EditorRootView(app: app, controller: controller, registry: registry)
    }

    // Save layout state on shutdown
    EditorRootViewFactory.saveDockLayout(controller)
}

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
