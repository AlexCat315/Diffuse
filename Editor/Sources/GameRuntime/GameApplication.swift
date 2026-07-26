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
    private let scriptCatalogMonitor: ProjectScriptCatalogMonitor?
    private var scriptCatalogReloadElapsed: Double = 0

    /// Called on the main thread whenever the engine publishes a new viewport
    /// surface (i.e. a new rendered frame is ready). Used by the root view to
    /// trigger recomposition.
    public var onViewportSurfaceChanged: ((ViewportSurfaceState) -> Void)?

    public init(projectDirectory: String? = nil, backend: WGPUBackend? = nil) throws {
        let resolvedBackend = backend ?? WGPUBackend()
        let scene = EditorSceneAdapter()
        var scriptMonitor: ProjectScriptCatalogMonitor?

        if let dir = projectDirectory {
            let projectURL = URL(fileURLWithPath: dir, isDirectory: true)
            let preferredMeshIndices = try GameProjectAssetIndexLoader.load(
                projectDirectory: projectURL
            )
            _ = try EditorAssetCatalog.loadProject(at: dir,
                                                   preferredMeshIndices: preferredMeshIndices)
            ProjectRuntimeResources.configureAudioSearchPaths(at: dir)
            if let manifest = try GameProjectSceneLoader.load(projectDirectory: projectURL) {
                let result = scene.load(manifest: manifest)
                if let error = result.error { throw error }
            }
            let monitor = ProjectScriptCatalogMonitor(projectDirectory: dir)
            scriptMonitor = monitor
            do {
                if let catalog = try monitor.loadIfChanged(force: true) {
                    let report = scene.applyProjectScriptCatalog(catalog)
                    Self.writeScriptCatalogReport(report, diagnostics: catalog.diagnostics)
                }
            } catch {
                _ = scene.applyProjectScriptCatalog(.builtIn)
                Self.writeStandardError("script catalog failed to load: \(error)")
            }
        } else {
            _ = scene.applyProjectScriptCatalog(.builtIn)
        }

        self.engine = EngineHost(runtime: BridgedEngineRuntime(), wgpuBackend: resolvedBackend)
        self.scene = scene
        self.scriptCatalogMonitor = scriptMonitor
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
        scriptCatalogReloadElapsed += max(0, deltaTime)
        if scriptCatalogReloadElapsed >= 1 {
            scriptCatalogReloadElapsed = 0
            reloadProjectScripts()
        }
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

    private func reloadProjectScripts() {
        guard let scriptCatalogMonitor else { return }
        do {
            guard let catalog = try scriptCatalogMonitor.loadIfChanged() else { return }
            let report = scene.applyProjectScriptCatalog(catalog)
            Self.writeScriptCatalogReport(report, diagnostics: catalog.diagnostics)
        } catch {
            Self.writeStandardError("script catalog reload failed: \(error)")
        }
    }

    private static func writeScriptCatalogReport(
        _ report: EditorScriptCatalogApplyReport,
        diagnostics: [ProjectScriptCatalogDiagnostic]
    ) {
        for diagnostic in diagnostics {
            writeStandardError("script catalog \(diagnostic.severity.rawValue): \(diagnostic.message)")
        }
        for binding in report.unresolvedBindings {
            writeStandardError("unresolved script binding: \(binding)")
        }
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data("[GuavaPlayer] \(message)\n".utf8))
    }
}
