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
/// try AppRuntime.run(..., onTick: { dt in app.tick(deltaTime: dt) }) {
///     GamePlayerRootView(app: app)
/// }
/// app.shutdown()
/// ```
public final class GameApplication: @unchecked Sendable {
    public let engine: EngineHost
    public let scene: EditorSceneAdapter

    private var _viewportDrawableSize: RenderDrawableSize = .init(width: 1280, height: 720)
    private var _lastViewportSurface: ViewportSurfaceState = .init()
    private var _pendingInputEvents: [InputEvent] = []
    private var _frameIndex: UInt64 = 0

    /// Called on the main thread whenever the engine publishes a new viewport
    /// surface (i.e. a new rendered frame is ready). Used by the root view to
    /// trigger recomposition.
    public var onViewportSurfaceChanged: ((ViewportSurfaceState) -> Void)?

    public init(projectDirectory: String? = nil, backend: WGPUBackend? = nil) throws {
        let resolvedBackend = backend ?? WGPUBackend()
        let scene = EditorSceneAdapter()

        if let dir = projectDirectory {
            let assetListURL = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent("assets.json")
            let preferredMeshIndices: [String: Int]
            if let data = try? Data(contentsOf: assetListURL),
               let assetList = try? JSONDecoder().decode(ProjectExportAssetList.self, from: data) {
                preferredMeshIndices = assetList.assets.reduce(into: [:]) { result, asset in
                    if asset.meshIndex >= 2, result[asset.relativePath] == nil {
                        result[asset.relativePath] = asset.meshIndex
                    }
                }
            } else {
                preferredMeshIndices = [:]
            }
            _ = try EditorAssetCatalog.loadProject(at: dir,
                                                   preferredMeshIndices: preferredMeshIndices)
            ProjectRuntimeResources.configureAudioSearchPaths(at: dir)
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

    /// Enqueue a platform input event to be forwarded to the engine on the
    /// next `tick`. Call from the `onInputEvent` closure of `ViewportHost`.
    public func enqueueInput(_ event: InputEvent) {
        _pendingInputEvents.append(event)
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        engine.currentViewportSurfaceState()
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
        let events = _pendingInputEvents
        _pendingInputEvents.removeAll(keepingCapacity: true)

        _frameIndex &+= 1
        scene.tickScene(deltaTime: deltaTime,
                        frameIndex: _frameIndex,
                        inputEvents: events,
                        drivesAudio: true)
        engine.tick(
            deltaTime: deltaTime,
            inputEvents: events,
            drawableSize: _viewportDrawableSize,
            shouldRender: true,
            renderSceneOverride: scene.currentRenderScene(),
            sceneSnapshotOverride: scene.currentSceneSnapshot(),
            jointPaletteOverride: scene.currentJointPaletteMap(),
            inGameCanvasOverride: scene.currentInGameCanvas(),
            particleFeedbackHandler: scene.makeParticleSimulationFeedbackHandler()
        )

        let surface = engine.currentViewportSurfaceState()
        if surface != _lastViewportSurface {
            _lastViewportSurface = surface
            onViewportSurfaceChanged?(surface)
        }
    }

    public func shutdown() {
        engine.shutdown()
    }
}
