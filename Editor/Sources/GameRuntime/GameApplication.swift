import EditorCore
import EngineCore
import EngineKernel
import Foundation
import RHIWGPU
import RenderBackend

/// Lightweight game host for the standalone player.
///
/// Loads a scene from the most recent `GameSaveDocument` in the project
/// directory (slot 0), or falls back to the built-in preview scene if no
/// save exists. Drives simulation, physics and scripting each frame through
/// `EngineHost`; the render result surfaces via `InGameUIRegistry`.
///
/// Usage from the entry point:
/// ```swift
/// let app = try GameApplication(projectDirectory: "/path/to/project")
/// app.bootstrap()
/// try AppRuntime.run(..., onTick: { dt in app.tick(deltaTime: dt) }) { EmptyView() }
/// app.shutdown()
/// ```
@MainActor
public final class GameApplication: @unchecked Sendable {
    public let engine: EngineHost
    public let scene: EditorSceneAdapter

    private var _viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)

    public init(projectDirectory: String? = nil, backend: WGPUBackend? = nil) throws {
        let resolvedBackend = backend ?? WGPUBackend()
        let scene = EditorSceneAdapter()

        if let dir = projectDirectory {
            let url = GameSaveDocument.url(slot: 0, projectDirectory: dir)
            if let doc = try GameSaveDocument.read(from: url) {
                _ = scene.load(manifest: doc.manifest)
            }
        }

        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
        self.scene = scene
    }

    public var viewportDrawableSize: RenderDrawableSize { _viewportDrawableSize }

    public func setViewportDrawableSize(_ size: RenderDrawableSize) {
        guard _viewportDrawableSize != size else { return }
        _viewportDrawableSize = size
    }

    public func setRenderCompletionHandler(_ handler: (@Sendable (EngineRenderCompletion) -> Void)?) {
        engine.setRenderCompletionHandler(handler)
    }

    public func bootstrap() {
        engine.start(renderSurface: nil, enableViewportSurface: true)
        engine.queueRenderSettings(RenderSettings(
            stage: .r4LightingPBRShadow,
            enableShadows: true,
            enableOffscreenViewport: true
        ))
    }

    public func tick(deltaTime: Double) {
        scene.tickScene(deltaTime: deltaTime)
        engine.tick(
            deltaTime: deltaTime,
            inputEvents: [],
            drawableSize: _viewportDrawableSize,
            shouldRender: true,
            renderSceneOverride: scene.currentRenderScene()
        )
    }

    public func shutdown() {
        engine.shutdown()
    }
}
