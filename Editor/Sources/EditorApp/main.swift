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

    let inGameUIHost = InGameUIHost(backend: backend)
    InGameUIRegistry.shared.provider = inGameUIHost

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
    inGameUIHost.setRootView(InGameBattleHUDView(model: hudModel))

    try AppRuntime.run(
        config: AppConfig(title: "GuavaNext Editor",
                          // Surface clear = the theme canvas, so resize
                          // flicker and any uncovered sliver show the canvas
                          // instead of an off-palette dark blue.
                          clearColor: GPUColor(r: 0x1E / 255, g: 0x1F / 255, b: 0x22 / 255, a: 1),
                          backendConfig: launchOptions.backendConfig,
                          titleBarStyle: .hiddenInset),
        backend: backend,
        events: events,
        onTick: { dt in
            context.tick(deltaTime: dt)
            if context.bundle != nil {
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
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
