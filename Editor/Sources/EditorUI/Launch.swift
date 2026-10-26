import CoveLogging
import Foundation
import EngineCore
import EngineKernel
import EditorCore
import CoveUI
import CoveUIRuntime
import CoveUIWorkspace
import NativeRHI
import RenderBackend
import CardBattleRuntime

@MainActor
private final class HeadlessEditorDriver {
    let app: EditorApplication
    private var frameIndex: UInt64 = 0

    init(app: EditorApplication) { self.app = app }

    func approvePendingPreview() {
        if let request = app.store.state.assistant.pendingConfirmationRequest,
           request.questions.allSatisfy({ $0.severity != .destructive }) {
            app.acceptPendingConfirmation()
        }
    }

    func tick() {
        guard app.store.state.timing.playbackState == .playing else { return }
        frameIndex &+= 1
        app.scene.tickScene(deltaTime: 1.0 / 60.0, frameIndex: frameIndex, inputEvents: [], drivesAudio: false)
    }
}

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    if launchOptions.validateInstall {
        let report = try EditorInstallValidator.validateEditorLayout()
        FileHandle.standardOutput.write(Data("\(report)\n".utf8))
        return
    }
    if CommandLine.arguments.contains("--script-editor-demo") || ProcessInfo.processInfo.environment["COVE_SCRIPT_EDITOR_DEMO"] == "1" {
        try runScriptEditorDemo(backendConfig: launchOptions.backendConfig)
        return
    }
    if CommandLine.arguments.contains("--mcp-headless") {
        guard let directory = launchOptions.projectDirectory else {
            throw EditorProjectToolError("--mcp-headless requires --project-dir <directory>.")
        }
        let app = try EditorApplication(projectDirectory: directory)
        app.enableBundledPlugins()
        _ = app.openSceneManifest()
        if CommandLine.arguments.contains("--trust-project-scripts") {
            app.workstation.scripts.setProjectTrusted(true)
        }
        if EditorAppLaunchOptions.watchPluginPackagesRequested {
            app.startWatchingPluginPackages()
        }
        // Explicit local automation accepts reversible previews only.
        let driver = HeadlessEditorDriver(app: app)
        let approvalTimer: Timer?
        if CommandLine.arguments.contains("--approve-scene-edits") {
            let timer = Timer(timeInterval: 0.1, repeats: true) { @Sendable _ in
                MainActor.assumeIsolated { driver.approvePendingPreview() }
            }
            RunLoop.main.add(timer, forMode: .default)
            approvalTimer = timer
        } else { approvalTimer = nil }
        defer { approvalTimer?.invalidate() }
        let simulationTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { @Sendable _ in
            // Both timers are installed only on the main run loop, so these
            // synchronous callbacks can safely enter the editor's main actor.
            MainActor.assumeIsolated { driver.tick() }
        }
        RunLoop.main.add(simulationTimer, forMode: .default)
        defer { simulationTimer.invalidate() }
        defer { app.shutdown() }
        LogSystem.logger("com.cove.editor").info("Headless editor ready", metadata: ["project": "\(directory)"])
        RunLoop.main.run()
        return
    }
    // The editor runs on the CoveUICompose + Application stack. The CoveKit
    // from-scratch rewrite served as the architecture blueprint for the
    // in-place runtime refactor and has been deleted
    // (docs/coveui-inplace-architecture-refactor.md §5).
    try runLegacyEditor(launchOptions: launchOptions)
}

private func requestedEditorRendererName() throws -> String {
    if let index = CommandLine.arguments.firstIndex(of: "--renderer") {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw NSError(domain: "EditorApp", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "--renderer requires native, metal, vulkan, or dx12."])
        }
        return CommandLine.arguments[index + 1].lowercased()
    }
    return ProcessInfo.processInfo.environment["COVE_RENDERER"]?.lowercased() ?? "native"
}

private func makeEditorRenderDevice(config: DeviceConfig) throws -> Device {
    let requested = try requestedEditorRendererName()
    let api: GraphicsAPI
    switch requested {
    case "native": return try Device.make(config)
    case "metal": api = .metal
    case "vulkan": api = .vulkan
    case "dx12", "d3d12": api = .dx12
    default:
        throw NSError(domain: "EditorApp", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown renderer '\(requested)'."])
    }
    var nativeConfig = config
    nativeConfig.preferredBackends = [api]
    return try Device.make(nativeConfig)
}

@MainActor
private func runLegacyEditor(launchOptions: EditorAppLaunchOptions) throws {
    // UI preferences (@AppStorage) live next to the shell-state/layout JSONs
    // in Application Support/Cove.
    AppStorageDefaults.store = FileAppStorageStore(
        url: FileAppStorageStore.defaultURL(appName: "Cove")
    )
    let renderDevice = try makeEditorRenderDevice(config: launchOptions.backendConfig)
    let events = PlatformEventBridge()
    let shellState = EditorRootViewFactory.loadShellState()

    let inGameUIHost = try InGameUIHost(device: renderDevice)
    let context = EditorLaunchContext(
        renderDevice: renderDevice,
        inGameUI: inGameUIHost,
        events: events,
        shellState: shellState
    )
    defer { context.shutdown() }

    try context.restoreProjects(front: launchOptions.projectDirectory)

    if ProcessInfo.processInfo.environment["COVE_EDITOR_SAMPLE_HUD"] == "1" {
        let host = inGameUIHost

        let initialBattleState = BattleStateMachine.reduce(
            BattleSampleFactory.makeThreeKingdomsDuel(),
            command: .startPlayerTurn(drawCount: 4)
        )
        let hudModel = BattleHUDModel(
            snapshot: BattleHUDSnapshot.make(from: initialBattleState, playerID: .player)
                ?? BattleHUDSnapshot(phase: .setup, turn: 0, energy: 0, maxEnergy: 0,
                                     health: 0, maxHealth: 0,
                                     opponentHealth: 0, opponentMaxHealth: 0,
                                     hand: [], skills: [])
        )
        host.setRootView(InGameBattleHUDView(model: hudModel))
    }

    try Application.run(
        config: ApplicationConfiguration(title: "Diffuse") {
            $0.rendering.clearColor = SIMD4(0x1E / 255, 0x1F / 255, 0x22 / 255, 1)
            $0.window.titleBarStyle = .hiddenInset
        },
        backend: renderDevice,
        events: events,
        onTick: { dt in
            context.tick(deltaTime: dt)
            if let bundle = context.bundle, bundle.app.store.shouldRender {
                // Fixed game resolutions simulate the same HUD pixel layout
                // across desktop content scales; Fit Window uses logical points.
                let store = bundle.app.store
                let fixed = store.viewportMode == .game ? store.gamePreviewResolution.size : nil
                let scale = fixed == nil ? max(1, ContentScaleHolder.current) : 1
                let frame = EditorViewportDropTarget.frame
                let logicalW = fixed.map { Int($0.width) } ?? Int((frame?.width ?? 1280).rounded())
                let logicalH = fixed.map { Int($0.height) } ?? Int((frame?.height ?? 720).rounded())
                inGameUIHost.tick(width: logicalW, height: logicalH, contentScale: scale,
                                  canvas: store.viewportMode == .game && store.gamePreviewHUDEnabled
                                    ? bundle.app.scene.currentInGameCanvas() : InGameCanvas())
            }
        },
        onDisplayReady: { display in context.wireDisplay(display) },
        onDiagnosticsReady: { context.wireDiagnostics($0) }
    ) {
        EditorLaunchRoot(context: context)
    }
}

/// Runs the editor's graphical or headless launch mode from a thin executable.
@MainActor
public enum EditorLauncher {
    public static func run() {
        do {
            var logging = LoggingConfiguration(); try logging.applyEnvironment()
            try LogSystem.bootstrap(application: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, configuration: logging)
            defer { LogSystem.flush() }
            try runEditor()
        }
        catch {
            LogSystem.logger("com.cove.editor").error("Editor startup failed", metadata: ["error": "\(error)"])
            LogSystem.flush()
            exit(1)
        }
    }
}
