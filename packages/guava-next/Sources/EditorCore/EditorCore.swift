import EngineCore
import RenderBackend
import PlatformShell
import RHIWGPU
import Foundation

@MainActor
public final class EditorApplication {
    private let shell: any Shell
    private let engine: EngineHost
    private let renderer: any Renderer
    private(set) var state: EditorState
    private(set) var panelRegistry: PanelRegistry
    private(set) var dockLayout: DockLayout

    public init(shell: any Shell) {
        self.shell = shell
        let dylib = Self.locateWGPUDylib()
        let backend = WGPUBackend(config: .init(libraryPath: dylib))
        let host = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: backend)
        self.engine = host
        self.renderer = WGPURenderer(backend: host.wgpuBackend, shell: shell)
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

    public func queueViewportRenderSettings(_ settings: RenderSettings) {
        renderer.queueRenderSettings(settings)
    }

    public func currentRenderStats() -> RenderFrameStats {
        renderer.currentFrameStats()
    }

    private static func locateWGPUDylib() -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/vendor/wgpu/libwgpu_native.dylib",
            "\(cwd)/packages/guava-next/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/packages/guava-next/vendor/wgpu/libwgpu_native.dylib",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return "libwgpu_native.dylib"
    }
}
