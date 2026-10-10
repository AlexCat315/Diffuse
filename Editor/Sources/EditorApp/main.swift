import Foundation
import EngineCore
import EngineKernel
import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import RHIWGPU
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
    if CommandLine.arguments.contains("--script-editor-demo") || ProcessInfo.processInfo.environment["GUAVA_SCRIPT_EDITOR_DEMO"] == "1" {
        try runScriptEditorDemo(backendConfig: launchOptions.backendConfig)
        return
    }
    if CommandLine.arguments.contains("--mcp-headless") {
        guard let directory = launchOptions.projectDirectory else {
            throw EditorProjectToolError("--mcp-headless requires --project-dir <directory>.")
        }
        let app = try EditorApplication(projectDirectory: directory)
        _ = app.openSceneManifest()
        if CommandLine.arguments.contains("--trust-project-scripts") {
            app.scriptWorkspace.setProjectTrusted(true)
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
        FileHandle.standardError.write(Data("Guava headless editor ready: \(directory)\n".utf8))
        RunLoop.main.run()
        return
    }
    // The editor runs on the GuavaUICompose + AppRuntime stack. The GuavaKit
    // from-scratch rewrite served as the architecture blueprint for the
    // in-place runtime refactor and has been deleted
    // (docs/guavaui-inplace-architecture-refactor.md §5).
    try runLegacyEditor(launchOptions: launchOptions)
}

private func requestedEditorRendererName() throws -> String {
    if let index = CommandLine.arguments.firstIndex(of: "--renderer") {
        guard CommandLine.arguments.indices.contains(index + 1) else {
            throw NSError(domain: "EditorApp", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "--renderer requires wgpu, native, metal, vulkan, or dx12."])
        }
        return CommandLine.arguments[index + 1].lowercased()
    }
    return ProcessInfo.processInfo.environment["GUAVA_RENDERER"]?.lowercased() ?? "native"
}

private func makeEditorRenderDevice(config: WGPUDeviceConfig) throws -> EngineRenderDevice {
    let requested = try requestedEditorRendererName()
    guard requested != "wgpu" else { return .wgpu(WGPUBackend(config: config)) }
    let api: GraphicsAPI
    switch requested {
    case "native":
        guard let platformAPI = NativeRHI.platformDefaultBackends.first else {
            throw NSError(domain: "EditorApp", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "NativeRHI has no backend for this platform."])
        }
        api = platformAPI
    case "metal": api = .metal
    case "vulkan": api = .vulkan
    case "dx12", "d3d12": api = .dx12
    default:
        throw NSError(domain: "EditorApp", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Unknown renderer '\(requested)'."])
    }
    let nativeConfig = DeviceConfig(preferredBackends: [api], enableValidation: true, framesInFlight: 3)
    return .native(try Device.make(nativeConfig))
}

@MainActor
private func runLegacyEditor(launchOptions: EditorAppLaunchOptions) throws {
    // UI preferences (@AppStorage) live next to the shell-state/layout JSONs
    // in Application Support/Guava.
    AppStorageDefaults.store = FileAppStorageStore(
        url: FileAppStorageStore.defaultURL(appName: "Guava")
    )
    let renderDevice = try makeEditorRenderDevice(config: launchOptions.backendConfig)
    let events = PlatformEventBridge()
    let shellState = EditorRootViewFactory.loadShellState()

    let context = EditorLaunchContext(
        backendConfig: launchOptions.backendConfig,
        renderDevice: renderDevice,
        events: events,
        shellState: shellState
    )
    defer { context.shutdown() }

    if let dir = launchOptions.projectDirectory {
        try context.loadProject(directory: dir)
    }

    let inGameUIHost: InGameUIHost
    switch renderDevice {
    case .wgpu(let backend): inGameUIHost = InGameUIHost(backend: backend)
    case .native(let device): inGameUIHost = try InGameUIHost(device: device)
    }
    InGameUIRegistry.shared.provider = inGameUIHost
    if ProcessInfo.processInfo.environment["GUAVA_EDITOR_SAMPLE_HUD"] == "1" {
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

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          // Surface clear = the theme canvas, so resize
                          // flicker and any uncovered sliver show the canvas
                          // instead of an off-palette dark blue.
                          clearColor: GPUColor(r: 0x1E / 255, g: 0x1F / 255, b: 0x22 / 255, a: 1),
                          backendConfig: launchOptions.backendConfig,
                          titleBarStyle: .hiddenInset,
                          // Editor chrome follows the active display refresh
                          // rate. Capping it at 60Hz makes every panel feel
                          // laggy on ProMotion / high-refresh displays even
                          // when the frame work itself is tiny. The expensive
                          // 3D viewport still renders on demand through
                          // EditorViewportRenderGate.
                          targetFrameRate: nil,
                          frameDrivePolicy: .eventDriven,
                          // FIFO present can block the main UI loop for multiple
                          // refresh intervals, which makes Inspector/DevTools
                          // input feel laggy. Mailbox keeps VSync-style pacing
                          // while letting the compositor consume the latest UI
                          // frame instead of back-pressuring the editor loop.
                          vsyncPresentMode: .mailbox),
        backend: renderDevice,
        events: events,
        onTick: { dt in
            context.tick(deltaTime: dt)
            if let bundle = context.bundle {
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
        onDisplayReady: { display in
            display.installNativeMenuBar(NativeMenuBar(appName: "GuavaNext Editor", menus: []))
            context.wireDisplay(display)
        }
    ) {
        EditorLaunchRoot(context: context)
    }
}

// MARK: - Entry

do {
    try runEditor()
} catch {
    FileHandle.standardError.write(Data("[EditorApp] startup failed: \(error)\n".utf8))
    exit(1)
}
