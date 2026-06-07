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

    // --guava-kit flag switches the entire UI pipeline from legacy
    // GuavaUICompose + AppRuntime to the v2 GuavaKit runtime.
    if launchOptions.useGuavaKit {
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

/// Minimal GuavaKit root view for validating the end-to-end pipeline inside
/// the Editor process. Replace with a proper Editor shell once parity is
/// reached (Architecture.md step 7).
private struct GuavaKitValidationView: GuavaKit.View {
    @GuavaKit.State var counter: Int = 0

    var body: some GuavaKit.View {
        GuavaKit.Stack(.column, spacing: 12) {
            GuavaKit.Text("GuavaKit v2 Runtime",
                          color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 24)

            GuavaKit.Text("Pipeline: SDL3 → EventAdapter → ViewGraph → Painter → DisplayListRenderer → wgpu",
                          color: GuavaKit.Color(r: 0.7, g: 0.7, b: 0.7), fontSize: 13)

            GuavaKit.Stack(.row, spacing: 8) {
                GuavaKit.Text("Counter: \(counter)",
                              color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 18)

                GuavaKit.Button(action: { counter += 1 }) {
                    GuavaKit.Element(width: 32, height: 32,
                                     color: GuavaKit.Color(r: 0.3, g: 0.6, b: 1))
                }
            }
        }
    }
}

@MainActor
private func runGuavaKitEditor(launchOptions: EditorAppLaunchOptions) throws {
    let app = GuavaKitHostApp(
        title: "GuavaNext Editor [GuavaKit]",
        width: 1280, height: 720
    )
    try app.run(root: GuavaKitValidationView())
}

// MARK: - Entry

do {
    try runEditor()
} catch {
    fputs("[EditorApp] startup failed: \(error)\n", stderr)
    exit(1)
}
