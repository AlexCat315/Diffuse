import Darwin
import EditorCore
import GuavaUIApp

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    let app = EditorApplication(backendConfig: launchOptions.backendConfig)
    app.bootstrap()
    defer { app.shutdown() }

    let controller = EditorRootViewFactory.makeController()
    let registry = EditorRootViewFactory.makeRegistry(app: app)

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          backendConfig: launchOptions.backendConfig),
        onTick: { dt in app.tick(deltaTime: dt) }
    ) {
        EditorRootView(app: app, controller: controller, registry: registry)
    }
}

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
