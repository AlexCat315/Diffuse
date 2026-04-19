import EngineCore
import RenderBackend
import PlatformShell

public final class EditorApplication {
    private let shell: any Shell
    private let engine: EngineHost
    private let renderer: any Renderer
    private(set) var state: EditorState
    private(set) var panelRegistry: PanelRegistry
    private(set) var dockLayout: DockLayout

    public init(shell: any Shell) {
        self.shell = shell
        self.engine = EngineHost(runtime: BridgedEngineRuntime())
        self.renderer = MetalPlaceholderRenderer()
        self.state = EditorState()

        let panels = [
            BasicPanelModel(id: "hierarchy", title: "Scene Hierarchy"),
            BasicPanelModel(id: "inspector", title: "Inspector"),
            BasicPanelModel(id: "viewport", title: "Viewport"),
            BasicPanelModel(id: "console", title: "Console"),
        ]
        self.panelRegistry = PanelRegistry(panels: panels)
        self.dockLayout = .default(panelIDs: panels.map(\ .id))
    }

    public func bootstrap() {
        shell.initializeWindow(title: "GuavaNext Editor")
        engine.start()
        renderer.initialize()
        EditorReducer.reduce(state: &state, action: .setConnected(true))
    }

    public func runMainLoop(iterations: Int) {
        for frame in 0..<iterations {
            shell.pollEvents()
            engine.tick(deltaTime: 1.0 / 60.0)
            renderer.renderFrame(frameIndex: frame)
        }
        shell.shutdown()
    }
}
