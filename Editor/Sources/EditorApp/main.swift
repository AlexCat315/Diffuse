import Foundation
import EngineKernel
import EditorCore
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import RHIWGPU
import CardBattleRuntime

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()
    if launchOptions.validateInstall {
        let report = try EditorInstallValidator.validateEditorLayout()
        FileHandle.standardOutput.write(Data("\(report)\n".utf8))
        return
    }
    // The editor runs on the GuavaUICompose + AppRuntime stack. The GuavaKit
    // from-scratch rewrite served as the architecture blueprint for the
    // in-place runtime refactor and has been deleted
    // (docs/guavaui-inplace-architecture-refactor.md §5).
    try runLegacyEditor(launchOptions: launchOptions)
}

@MainActor
private func runLegacyEditor(launchOptions: EditorAppLaunchOptions) throws {
    // UI preferences (@AppStorage) live next to the shell-state/layout JSONs
    // in Application Support/Guava.
    AppStorageDefaults.store = FileAppStorageStore(
        url: FileAppStorageStore.defaultURL(appName: "Guava")
    )
    let backend = WGPUBackend(config: launchOptions.backendConfig)
    let events = PlatformEventBridge()
    let shellState = EditorRootViewFactory.loadShellState()

    let context = EditorLaunchContext(
        backendConfig: launchOptions.backendConfig,
        backend: backend,
        events: events,
        shellState: shellState
    )
    defer { context.shutdown() }

    if let dir = launchOptions.projectDirectory {
        try context.loadProject(directory: dir)
    }

    let inGameUIHost: InGameUIHost?
    if ProcessInfo.processInfo.environment["GUAVA_EDITOR_SAMPLE_HUD"] == "1" {
        let host = InGameUIHost(backend: backend)
        InGameUIRegistry.shared.provider = host

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
        inGameUIHost = host
    } else {
        InGameUIRegistry.shared.provider = nil
        inGameUIHost = nil
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
        backend: backend,
        events: events,
        onTick: { dt in
            context.tick(deltaTime: dt)
            if let inGameUIHost, context.bundle != nil {
                // HUD 布局用视口的逻辑尺寸；光栅化按窗口 content scale。
                let scale = max(1, ContentScaleHolder.current)
                let frame = EditorViewportDropTarget.frame
                let logicalW = Int((frame?.width ?? 1280).rounded())
                let logicalH = Int((frame?.height ?? 720).rounded())
                inGameUIHost.tick(width: logicalW, height: logicalH, contentScale: scale)
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
