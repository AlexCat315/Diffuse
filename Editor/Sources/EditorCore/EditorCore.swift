import EngineCore
import EngineKernel
import RenderBackend
import PlatformShell
import RHIWGPU
import Foundation

@MainActor
public final class EditorApplication {
    private let shell: any Shell
    private let engine: EngineHost
    private(set) var state: EditorState
    private(set) var panelRegistry: PanelRegistry
    private(set) var dockLayout: DockLayout
    public let inputState: InputState

    public init(shell: any Shell, backendConfig: WGPUDeviceConfig? = nil) {
        self.shell = shell
        var resolvedBackendConfig = backendConfig ?? .init()
        if resolvedBackendConfig.libraryPath == nil {
            resolvedBackendConfig.libraryPath = Self.locateWGPUDylib()
        }
        let backend = WGPUBackend(config: resolvedBackendConfig)
        let host = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: backend)
        self.engine = host
        self.state = EditorState()
        self.inputState = InputState()

        let panels = [
            BasicPanelModel(id: "hierarchy", title: "Scene Hierarchy"),
            BasicPanelModel(id: "inspector", title: "Inspector"),
            BasicPanelModel(id: "viewport", title: "Viewport"),
            BasicPanelModel(id: "console", title: "Console"),
        ]
        self.panelRegistry = PanelRegistry(panels: panels)
        self.dockLayout = .default(panelIDs: panels.map(\ .id))
    }

    public func bootstrap() throws {
        try shell.initializeWindow(title: "GuavaNext Editor")
        engine.start(renderSurface: shell.renderSurface.map(Self.describeRenderSurface))
        EditorReducer.reduce(state: &state, action: .setConnected(true))
    }

    public func runMainLoop(iterations: Int? = nil) {
        var frame = 0
        while shell.isRunning && (iterations.map { frame < $0 } ?? true) {
            let events = shell.pollEvents()
            dispatchEvents(events)
            engine.tick(
                deltaTime: 1.0 / 60.0,
                inputEvents: events,
                drawableSize: .init(width: shell.drawableSize.width, height: shell.drawableSize.height),
                shouldRender: state.shouldRender
            )
            frame += 1
        }
        engine.shutdown()
        shell.shutdown()
    }

    // MARK: - Event dispatch

    private func dispatchEvents(_ events: [InputEvent]) {
        inputState.process(events)

        for event in events {
            switch event {
            case .windowFocusGained:
                EditorReducer.reduce(state: &state, action: .setWindowFocused(true))
            case .windowFocusLost:
                EditorReducer.reduce(state: &state, action: .setWindowFocused(false))
            case .windowMinimized:
                EditorReducer.reduce(state: &state, action: .setWindowMinimized(true))
            case .windowRestored:
                EditorReducer.reduce(state: &state, action: .setWindowMinimized(false))
            case .windowOccluded:
                EditorReducer.reduce(state: &state, action: .setWindowOccluded(true))
            case .windowExposed:
                EditorReducer.reduce(state: &state, action: .setWindowOccluded(false))
            default:
                break
            }
        }
    }

    // MARK: - Render helpers

    public func queueViewportRenderSettings(_ settings: RenderSettings) {
        engine.queueRenderSettings(settings)
    }

    public func currentRenderStats() -> RenderFrameStats {
        engine.currentRenderStats()
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
    }

    private static func locateWGPUDylib() -> String {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/Engine/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/Engine/vendor/wgpu/libwgpu_native.dylib",
            "\(cwd)/vendor/wgpu/lib/libwgpu_native.dylib",
            "\(cwd)/vendor/wgpu/libwgpu_native.dylib",
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return "libwgpu_native.dylib"
    }

    private static func describeRenderSurface(_ surface: NativeRenderSurface) -> RenderSurfaceDescriptor {
        switch surface {
        case let .metalLayer(layer):
            return .metalLayer(layer)
        case let .win32Window(hwnd, hinstance):
            return .win32Window(hwnd: hwnd, hinstance: hinstance)
        case let .xlibWindow(display, window):
            return .xlibWindow(display: display, window: window)
        case let .waylandSurface(display, surface):
            return .waylandSurface(display: display, surface: surface)
        }
    }
}
