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

/// Comprehensive GuavaKit component showcase. Demonstrates every primitive
/// and modifier built so far in a layout that mimics a typical Editor panel.
private struct GuavaKitValidationView: GuavaKit.View {
    @GuavaKit.State var counter: Int = 0
    @GuavaKit.State var toggleOn: Bool = false
    @GuavaKit.State var sliderValue: Float = 0.5
    @GuavaKit.State var checked: Bool = false

    var body: some GuavaKit.View {
        GuavaKit.ScrollView(.column) {
            GuavaKit.Stack(.column, spacing: 16) {

                // ── Header ──
                GuavaKit.Text("GuavaKit v2 — Component Showcase",
                              color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 22)
                GuavaKit.Divider()

                // ── Text + Modifiers ──
                sectionHeader("Text & Modifiers")
                GuavaKit.Text("foregroundColor(.red) + fontSize(18)",
                              color: GuavaKit.Color(r: 0, g: 0, b: 0), fontSize: 16)
                    .foregroundColor(GuavaKit.Color(r: 1, g: 0.3, b: 0.3))
                    .fontSize(18)

                GuavaKit.Text("opacity(0.5) faded text",
                              color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 14)
                    .opacity(0.5)

                // ── Button + State ──
                sectionHeader("Button & @State")
                GuavaKit.Stack(.row, spacing: 12) {
                    GuavaKit.Button(action: { counter += 1 }) {
                        GuavaKit.Text("Clicked \(counter)", fontSize: 14)
                            .foregroundColor(GuavaKit.Color(r: 1, g: 1, b: 1))
                            .padding(12)
                            .background(GuavaKit.Color(r: 0.3, g: 0.6, b: 1))
                            .cornerRadius(6)
                    }
                    GuavaKit.Button(action: { counter = 0 }) {
                        GuavaKit.Text("Reset", fontSize: 14)
                            .foregroundColor(GuavaKit.Color(r: 0.8, g: 0.3, b: 0.3))
                            .padding(12)
                            .background(GuavaKit.Color(r: 0.2, g: 0.15, b: 0.15))
                            .cornerRadius(6)
                    }
                }

                // ── Toggle ──
                sectionHeader("Toggle")
                GuavaKit.Stack(.row, spacing: 10) {
                    GuavaKit.Toggle(isOn: toggleOn) { toggleOn = $0 }
                    GuavaKit.Text("Toggle: \(toggleOn ? "ON" : "OFF")",
                                  color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 14)
                }

                // ── Checkbox ──
                sectionHeader("Checkbox")
                GuavaKit.Stack(.row, spacing: 10) {
                    GuavaKit.Checkbox(isChecked: checked, onChange: { checked = $0 }) {
                        GuavaKit.Text("Check me", color: GuavaKit.Color(r: 1, g: 1, b: 1), fontSize: 14)
                    }
                }

                // ── Slider ──
                sectionHeader("Slider")
                GuavaKit.Text(String(format: "Value: %.2f", sliderValue),
                              color: GuavaKit.Color(r: 0.7, g: 0.7, b: 0.7), fontSize: 12)
                GuavaKit.Slider(value: sliderValue, in: 0...1) { sliderValue = $0 }

                // ── Image ──
                sectionHeader("Image")
                GuavaKit.Stack(.row, spacing: 8) {
                    GuavaKit.Image(width: 48, height: 48, tint: GuavaKit.Color(r: 0.3, g: 0.6, b: 1))
                        .cornerRadius(8)
                    GuavaKit.Image(width: 48, height: 48, tint: GuavaKit.Color(r: 1, g: 0.4, b: 0.3))
                        .cornerRadius(24)
                    GuavaKit.Image(width: 48, height: 48, tint: GuavaKit.Color(r: 0.3, g: 1, b: 0.4))
                        .cornerRadius(4)
                }

                // ── TextField ──
                sectionHeader("TextField")
                GuavaKit.TextField(text: "", placeholder: "Type here...")

                // ── ScrollView (nested) ──
                sectionHeader("Nested ScrollView")
                GuavaKit.ScrollView(.column) {
                    for i in 1...20 {
                        GuavaKit.Text("Item \(i) — scroll with mouse wheel",
                                      color: GuavaKit.Color(r: 0.6, g: 0.6, b: 0.7), fontSize: 12)
                        GuavaKit.Divider(color: GuavaKit.Color(r: 0.15, g: 0.15, b: 0.2))
                    }
                }

                // ── Spacer ──
                GuavaKit.Spacer()
                GuavaKit.Divider()
                GuavaKit.Text("Pipeline: SDL3 → EventAdapter → ViewGraph → Painter → DisplayListRenderer → wgpu",
                              color: GuavaKit.Color(r: 0.4, g: 0.4, b: 0.5), fontSize: 11)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some GuavaKit.View {
        GuavaKit.Text(title,
                      color: GuavaKit.Color(r: 0.5, g: 0.7, b: 1), fontSize: 11)
            .padding(.all(0))
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
