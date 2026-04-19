import EngineCore
import RenderBackend
import PlatformShell

public final class EditorApplication {
    private let shell: any Shell
    private let engine: EngineHost
    private let renderer: any Renderer

    public init(shell: any Shell) {
        self.shell = shell
        self.engine = EngineHost(runtime: BridgedEngineRuntime())
        self.renderer = MetalPlaceholderRenderer()
    }

    public func bootstrap() {
        shell.initializeWindow(title: "GuavaNext Editor")
        engine.start()
        renderer.initialize()
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
