import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// 主线程约定的编辑器场景适配层。底层数据来自 Swift `SceneRuntime`；
/// 面板只读取这里导出的树与属性 schema，不再依赖 stub 列表。
public final class EditorSceneAdapter: @unchecked Sendable {
    var scene: SceneRuntime {
        didSet { scene.setScriptDriver(scriptRuntime) }
    }
    // Navigation is session state, independent of authored game cameras.
    var editorViewportCamera = RenderCamera.fallbackPerspective
    public private(set) var usesEditorViewportCamera = false
    public var onViewportCameraChanged: (() -> Void)?

    public func setEditorViewportCameraEnabled(_ enabled: Bool) {
        guard usesEditorViewportCamera != enabled else { return }
        usesEditorViewportCamera = enabled
        onViewportCameraChanged?()
    }
    let transactionExecutor = TransactionExecutor()
    var initialSelectionID: UInt64?
    var initialExpandedIDs: Set<UInt64> = []
    public let scriptRuntime = ScriptRuntime()
    var scriptCatalogEntries: [ProjectScriptCatalogEntry] = []
    var managedScriptIdentifiers: Set<String> = []
    var dynamicScriptDisplayNames: [String: String] = [:]
    var dynamicScriptAliases: [String: String] = [:]
    let particleFeedback = ParticleFeedbackInbox()
    public var inspectorRenderers: EditorInspectorRendererRegistry
    let editHistory = EditorSceneEditHistory()
    public private(set) var isAuthoringEnabled = true

    public var onRevisionChanged: ((UInt64) -> Void)?
    public var onTransactionError: ((String) -> Void)?

    public func setAuthoringEnabled(_ isEnabled: Bool) {
        isAuthoringEnabled = isEnabled
        if !isEnabled {
            endInteractiveEditHistoryGroup()
        }
    }

    public init(seedPreviewScene: Bool = true, componentRegistry: ComponentRegistry = .builtIn,
                inspectorRenderers: EditorInspectorRendererRegistry = .builtIn) {
        self.inspectorRenderers = inspectorRenderers
        var registry = componentRegistry
        registry.registerScriptCodec()
        scene = SceneRuntime(componentRegistry: registry)
        if seedPreviewScene { scene.bootstrapEditorPreviewScene() }
        scene.setResource(InputActionMap.guavaDefault)
        scene.setScriptDriver(scriptRuntime)
        let defaults = scene.resource(SceneBootstrapDefaultsResource.self)
        initialSelectionID = defaults?.defaultSelection?.rawValue
        initialExpandedIDs = Set(defaults?.defaultExpanded.map(\ .rawValue) ?? [])
        editHistory.reset(to: scene)
    }

    public func resetToPreviewScene() {
        resetToPreviewScene(notify: true)
    }

    private func resetToPreviewScene(notify: Bool) {
        scene = SceneRuntime(componentRegistry: scene.componentRegistry)
        scene.bootstrapEditorPreviewScene()
        scene.setResource(InputActionMap.guavaDefault)
        scriptRuntime.reset()
        scene.setScriptDriver(scriptRuntime)
        invalidateParticleFeedback()
        let defaults = scene.resource(SceneBootstrapDefaultsResource.self)
        initialSelectionID = defaults?.defaultSelection?.rawValue
        initialExpandedIDs = Set(defaults?.defaultExpanded.map(\ .rawValue) ?? [])
        resetEditHistory()
        if notify {
            notifyRevisionChanged(recordHistory: false)
        }
    }

    public var revision: UInt64 {
        scene.snapshot.revision
    }

    public var entityCount: Int {
        scene.snapshot.entityCount
    }

    /// True while any emitter can still emit or has live particles. The editor
    /// consults this only while realtime preview or playback is active; ordinary
    /// inspector/devtools work should not keep the scene simulation running.
    public func hasActiveParticles() -> Bool {
        for entity in scene.entities(with: ParticleEmitter.self) {
            guard let emitter = scene.component(ParticleEmitter.self, for: entity) else { continue }
            if emitter.isEmissionActive || emitter.aliveCount > 0 { return true }
        }
        return false
    }

    public var defaultSelectionID: UInt64? {
        initialSelectionID
    }

    public var defaultExpandedEntityIDs: Set<UInt64> {
        initialExpandedIDs
    }

    func invalidateParticleFeedback() {
        particleFeedback.invalidate()
    }
}
