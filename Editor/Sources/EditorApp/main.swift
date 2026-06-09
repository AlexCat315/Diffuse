import Foundation
import EngineKernel
import EditorCore
import GuavaUIApp
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
                          backendConfig: launchOptions.backendConfig,
                          titleBarStyle: .hiddenInset),
        backend: backend,
        events: events,
        onTick: { dt in
            context.tick(deltaTime: dt)
            if let bundle = context.bundle {
                let size = bundle.app.viewportDrawableSize
                inGameUIHost.tick(width: Int(size.width), height: Int(size.height))
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
