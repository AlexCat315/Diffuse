import Foundation
import EngineKernel
import EditorCore
import GuavaUIApp
import GuavaUIRuntime
import GuavaUIWorkspace
import GuavaKit
import GuavaKitHost
import RHIWGPU
import CardBattleRuntime

@MainActor
private func runEditor() throws {
    let launchOptions = try EditorAppLaunchOptions.load()

    // --legacy flag switches the entire UI pipeline from legacy
    // GuavaUICompose + AppRuntime to the v2 GuavaKit runtime.
    if !launchOptions.useLegacy {
        try runGuavaKitEditor(launchOptions: launchOptions)
    } else {
        try runLegacyEditor(launchOptions: launchOptions)
    }
}

// MARK: - Legacy path (unchanged)

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

// MARK: - GuavaKit path

/// Comprehensive GuavaKit component showcase. Demonstrates every primitive
/// and modifier built so far in a layout that mimics a typical Editor panel.

@MainActor
private func runGuavaKitEditor(launchOptions: EditorAppLaunchOptions) throws {
    let app = GuavaKitHostApp(
        title: "GuavaNext Editor [GuavaKit]",
        width: 1280, height: 720
    )
    try app.run(root: EditorShell())
}

// MARK: - Entry

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
