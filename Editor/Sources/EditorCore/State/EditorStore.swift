import GuavaUICompose
import Foundation
import GuavaUIRuntime
import IntentRuntime

/// 编辑器状态的可观察容器。
///
/// 把 `EditorState` 与 `EditorReducer` 包成一个 store 风格的对象：
/// 调用方只通过 `dispatch(_:)` 改写状态，并通过 `subscribe(_:)` 监听变化。
/// `version` 单调递增，每次 dispatch 后 +1，UI 层用它驱动 `@State` 失效。
///
/// 与 `WorkspaceController` 同样的线程契约：所有 API 假设在主线程上调用，
/// 内部不加锁。`@unchecked Sendable` 仅用于穿过 nonisolated 闭包，
/// 调用方不应把这个对象交给后台线程。
public final class EditorStore: @unchecked Sendable {
    private enum ObservationKey: Hashable {
        case state
        case connected
        case selectedEntityID
        case selectedEntityIDs
        case playbackState
        case interactionMode
        case agentTasks
        case workspaceMode
        case activeLayoutPreset
        case sceneRevision
        case lastSavedSceneRevision
        case sceneRecoveryPending
        case pendingCloseRequest
        case frameIndex
        case frameTimingRevision
        case frameStats
        case frameStatsHistory
        case particleDiagnosticsHistory
        case viewportSurfaceRevision
        case viewportCameraRevision
        case windowFocused
        case windowMinimized
        case windowOccluded
        case shouldRender
        case gizmoMode
        case gizmoSpace
        case viewportShadingMode
        case viewportShadowsEnabled
        case viewportGridEnabled
        case viewportRenderScalePercent
        case viewportInteractionDownscaleEnabled
        case viewportRealtimeEnabled
        case physicsDebugOverlayOptions
        case physicsDebugOverlayScope
        case translateSnapEnabled
        case rotateSnapEnabled
        case scaleSnapEnabled
        case translateSnapStep
        case rotateSnapStepDegrees
        case scaleSnapStep
        case primarySelectBehavior
        case presentation
        case themeMode
        case language
        case uiRefreshRevision
        case vsyncMode
        case activeAssetDrag
        case inspectorCollapsedSectionIDs
        case pendingConfirmationRequest
        case aiSettings
        case capabilitySettings
        case pluginManagement
        case aiStatusMessage
        case aiWarnings
        case chatMessages
        case consoleEntries
        case commandPaletteVisible
        case scriptCaretLabel
        case workbench
    }

    private var scriptCaretLabels: [String: String] = [:]
    public func scriptCaretLabel(for documentID: String) -> String {
        read(.scriptCaretLabel, scriptCaretLabels[documentID] ?? "Ln 1, Col 1")
    }
    public func setScriptCaretLabel(_ label: String, for documentID: String) {
        guard scriptCaretLabels[documentID] != label else { return }
        scriptCaretLabels[documentID] = label
        invalidate([.scriptCaretLabel])
    }

    private var storage: EditorState
    private let registrar = ObservableStateRegistrar()

    public var state: EditorState {
        read(.state, storage)
    }

    public private(set) var version: UInt64 = 0

    public struct SubscriptionToken: Hashable, Sendable {
        let raw: UInt64
    }

    private var subscribers: [SubscriptionToken: (EditorStore) -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    public init(state: EditorState = EditorState()) {
        self.storage = state
    }

    public func dispatch(_ action: EditorAction) {
        let previous = storage
        EditorReducer.reduce(state: &storage, action: action)
        guard action.notifiesSubscribers else { return }
        let keys = observationKeys(for: action, previous: previous, current: storage)
        guard !keys.isEmpty else { return }
        version &+= 1
        invalidate(keys)
        for handler in subscribers.values {
            handler(self)
        }
    }

    @discardableResult
    public func subscribe(_ handler: @escaping (EditorStore) -> Void) -> SubscriptionToken {
        nextSubscriberID &+= 1
        let token = SubscriptionToken(raw: nextSubscriberID)
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        subscribers.removeValue(forKey: token)
    }

    private func read<Value>(_ key: ObservationKey, _ value: Value) -> Value {
        registrar.access(AnyHashable(key))
        return value
    }

    private func invalidate(_ keys: Set<ObservationKey>) {
        for key in keys {
            registrar.invalidate(AnyHashable(key))
        }
    }

    private func observationKeys(for action: EditorAction,
                                 previous old: EditorState,
                                 current new: EditorState) -> Set<ObservationKey> {
        var keys: Set<ObservationKey> = []

        func mark<T: Equatable>(_ key: ObservationKey, _ oldValue: T, _ newValue: T) {
            if oldValue != newValue {
                keys.insert(key)
            }
        }

        switch action {
        case .setOperation, .navigateToScript, .navigateToAsset, .setInspectorSceneSettingsVisible, .setCommandPaletteQuery, .setOutputTab:
            keys.insert(.workbench)
        case .setViewportMode, .setGamePreviewResolution, .setGamePreviewHUDEnabled, .setGamePreviewFocused:
            keys.insert(.workbench)
        case .tickFrame:
            mark(.frameIndex, old.timing.frameIndex, new.timing.frameIndex)
        case .setConnected:
            mark(.connected, old.timing.connected, new.timing.connected)
        case .setSelectedEntity, .setPrimarySelectedEntity, .setSelectedEntities:
            mark(.selectedEntityID, old.selection.selectedEntityID, new.selection.selectedEntityID)
            mark(.selectedEntityIDs, old.selection.selectedEntityIDs, new.selection.selectedEntityIDs)
        case .setPlaybackState:
            mark(.playbackState, old.timing.playbackState, new.timing.playbackState)
        case .setInteractionMode:
            mark(.interactionMode, old.workspace.interactionMode, new.workspace.interactionMode)
        case .setAgentTasks:
            mark(.agentTasks, old.assistant.agentTasks, new.assistant.agentTasks)
        case .beginSceneDocument:
            keys.insert(.state)
        case .setWorkspaceMode:
            mark(.workspaceMode, old.workspace.mode, new.workspace.mode)
            mark(.activeLayoutPreset, old.workspace.layoutPreset, new.workspace.layoutPreset)
        case .setActiveLayoutPreset:
            mark(.activeLayoutPreset, old.workspace.layoutPreset, new.workspace.layoutPreset)
        case .setSceneRevision:
            mark(.sceneRevision, old.document.sceneRevision, new.document.sceneRevision)
        case .markSceneSaved, .markSceneUnsaved:
            mark(.lastSavedSceneRevision, old.document.lastSavedSceneRevision, new.document.lastSavedSceneRevision)
            mark(.sceneRecoveryPending, old.document.sceneRecoveryPending, new.document.sceneRecoveryPending)
        case .setSceneRecoveryPending:
            mark(.sceneRecoveryPending, old.document.sceneRecoveryPending, new.document.sceneRecoveryPending)
        case .requestClose, .dismissCloseRequest:
            mark(.pendingCloseRequest, old.document.pendingCloseRequest, new.document.pendingCloseRequest)
        case .setWindowFocused:
            mark(.windowFocused, old.window.focused, new.window.focused)
        case .setWindowMinimized:
            mark(.windowMinimized, old.window.minimized, new.window.minimized)
        case .setWindowOccluded:
            mark(.windowOccluded, old.window.occluded, new.window.occluded)
        case .setGizmoMode:
            mark(.gizmoMode, old.viewport.gizmoMode, new.viewport.gizmoMode)
        case .setGizmoSpace:
            mark(.gizmoSpace, old.viewport.gizmoSpace, new.viewport.gizmoSpace)
        case .setViewportShadingMode:
            mark(.viewportShadingMode, old.viewport.shadingMode, new.viewport.shadingMode)
        case .setViewportShadowsEnabled:
            mark(.viewportShadowsEnabled, old.shadows.enabled, new.shadows.enabled)
        case .setViewportGridEnabled:
            mark(.viewportGridEnabled, old.viewport.gridEnabled, new.viewport.gridEnabled)
        case .setViewportRenderScalePercent:
            mark(.viewportRenderScalePercent, old.viewport.renderScalePercent, new.viewport.renderScalePercent)
        case .setViewportInteractionDownscale:
            mark(.viewportInteractionDownscaleEnabled,
                 old.viewport.interactionDownscaleEnabled,
                 new.viewport.interactionDownscaleEnabled)
        case .setViewportRealtime:
            mark(.viewportRealtimeEnabled, old.viewport.realtimeEnabled, new.viewport.realtimeEnabled)
        case .setPhysicsDebugOverlayOptions:
            mark(.physicsDebugOverlayOptions,
                 old.viewport.physicsDebugOverlayOptions,
                 new.viewport.physicsDebugOverlayOptions)
        case .setPhysicsDebugOverlayScope:
            mark(.physicsDebugOverlayScope,
                 old.viewport.physicsDebugOverlayScope,
                 new.viewport.physicsDebugOverlayScope)
        case .setTranslateSnapEnabled:
            mark(.translateSnapEnabled, old.snapping.translateSnapEnabled, new.snapping.translateSnapEnabled)
        case .setRotateSnapEnabled:
            mark(.rotateSnapEnabled, old.snapping.rotateSnapEnabled, new.snapping.rotateSnapEnabled)
        case .setScaleSnapEnabled:
            mark(.scaleSnapEnabled, old.snapping.scaleSnapEnabled, new.snapping.scaleSnapEnabled)
        case .viewportCameraChanged:
            mark(.viewportCameraRevision, old.viewport.cameraRevision, new.viewport.cameraRevision)
        case .setTranslateSnapStep:
            mark(.translateSnapStep, old.snapping.translateSnapStep, new.snapping.translateSnapStep)
        case .setRotateSnapStepDegrees:
            mark(.rotateSnapStepDegrees, old.snapping.rotateSnapStepDegrees, new.snapping.rotateSnapStepDegrees)
        case .setScaleSnapStep:
            mark(.scaleSnapStep, old.snapping.scaleSnapStep, new.snapping.scaleSnapStep)
        case .setPrimarySelectBehavior:
            mark(.primarySelectBehavior, old.selection.primarySelectBehavior, new.selection.primarySelectBehavior)
        case .setThemeMode:
            mark(.presentation, old.presentation, new.presentation)
            mark(.themeMode, old.themeMode, new.themeMode)
            mark(.uiRefreshRevision, old.uiRefreshRevision, new.uiRefreshRevision)
        case .setLanguage:
            mark(.presentation, old.presentation, new.presentation)
            mark(.language, old.language, new.language)
            mark(.uiRefreshRevision, old.uiRefreshRevision, new.uiRefreshRevision)
        case .forceUIRefresh:
            mark(.presentation, old.presentation, new.presentation)
            mark(.uiRefreshRevision, old.uiRefreshRevision, new.uiRefreshRevision)
        case .setVSyncMode:
            mark(.vsyncMode, old.vsyncMode, new.vsyncMode)
        case .beginAssetDrag, .endAssetDrag:
            mark(.activeAssetDrag, old.navigation.activeAssetDrag, new.navigation.activeAssetDrag)
        case .updateAssetDragCursor:
            break
        case .setInspectorSectionCollapsed, .setInspectorSectionsCollapsed:
            mark(.inspectorCollapsedSectionIDs,
                 old.selection.inspectorCollapsedSectionIDs,
                 new.selection.inspectorCollapsedSectionIDs)
        case .setPendingConfirmationRequest:
            mark(.pendingConfirmationRequest,
                 old.assistant.pendingConfirmationRequest,
                 new.assistant.pendingConfirmationRequest)
        case .setAISettings:
            mark(.aiSettings, old.assistant.aiSettings, new.assistant.aiSettings)
        case .setCapabilitySettings:
            mark(.capabilitySettings, old.assistant.capabilitySettings, new.assistant.capabilitySettings)
        case .setPluginManagementState:
            mark(.pluginManagement, old.assistant.pluginManagement, new.assistant.pluginManagement)
        case .setAIStatusMessage:
            mark(.aiStatusMessage, old.assistant.aiStatusMessage, new.assistant.aiStatusMessage)
        case .setAIWarnings:
            mark(.aiWarnings, old.assistant.aiWarnings, new.assistant.aiWarnings)
        case .appendChatMessage, .updateChatMessage, .clearChatHistory:
            mark(.chatMessages, old.assistant.chatMessages, new.assistant.chatMessages)
        case .appendConsoleMessage, .clearConsole:
            mark(.consoleEntries, old.output.consoleEntries, new.output.consoleEntries)
        case .setCommandPaletteVisible:
            mark(.commandPaletteVisible, old.navigation.commandPaletteVisible, new.navigation.commandPaletteVisible)
        case .frameTimingUpdated:
            mark(.frameTimingRevision, old.timing.frameTimingRevision, new.timing.frameTimingRevision)
        case .viewportSurfaceUpdated:
            mark(.viewportSurfaceRevision, old.viewport.surfaceRevision, new.viewport.surfaceRevision)
        case .updateFrameStats:
            mark(.frameStats, old.timing.frameStats, new.timing.frameStats)
            mark(.frameStatsHistory, old.timing.frameStatsHistory, new.timing.frameStatsHistory)
        case .updateParticleDiagnostics:
            mark(.particleDiagnosticsHistory,
                 old.timing.particleDiagnosticsHistory,
                 new.timing.particleDiagnosticsHistory)
        }

        if old.shouldRender != new.shouldRender {
            keys.insert(.shouldRender)
        }
        if !keys.isEmpty && action.invalidatesWholeStateObservation {
            keys.insert(.state)
        }
        return keys
    }
}

extension EditorStore: _ObservableObject {
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        let token = subscribe { _ in handler() }
        return AnyHashable(token)
    }

    public func _unregisterObserver(_ tok: AnyHashable) {
        guard let token = tok.base as? SubscriptionToken else { return }
        unsubscribe(token)
    }
}

extension EditorStore {
    public var operations: [EditorOperation] { read(.workbench, storage.navigation.operations) }
    public var scriptNavigation: EditorScriptNavigationRequest? { read(.workbench, storage.navigation.scriptNavigation) }
    public var assetNavigationID: String? { read(.workbench, storage.navigation.assetNavigationID) }
    public var assetNavigationRevision: UInt64 { read(.workbench, storage.navigation.assetNavigationRevision) }
    public var inspectorSceneSettingsVisible: Bool { read(.workbench, storage.selection.inspectorSceneSettingsVisible) }
    public var commandPaletteQuery: TextBuffer { read(.workbench, storage.navigation.commandPaletteQuery) }
    public var outputTab: EditorOutputTab { read(.workbench, storage.output.outputTab) }
    public var viewportMode: EditorViewportMode { read(.workbench, storage.viewport.mode) }
    public var gamePreviewResolution: EditorGamePreviewResolution { read(.workbench, storage.viewport.gamePreviewResolution) }
    public var gamePreviewHUDEnabled: Bool { read(.workbench, storage.viewport.gamePreviewHUDEnabled) }
    public var gamePreviewFocused: Bool { read(.workbench, storage.viewport.gamePreviewFocused) }
    public var connected: Bool { read(.connected, storage.timing.connected) }
    public var selectedEntityID: UInt64? { read(.selectedEntityID, storage.selection.selectedEntityID) }
    public var selectedEntityIDs: Set<UInt64> { read(.selectedEntityIDs, storage.selection.selectedEntityIDs) }
    public var selectedEntityIDsCount: Int { read(.selectedEntityIDs, storage.selection.selectedEntityIDs.count) }
    public var sceneRevision: UInt64 { read(.sceneRevision, storage.document.sceneRevision) }
    public var lastSavedSceneRevision: UInt64 { read(.lastSavedSceneRevision, storage.document.lastSavedSceneRevision) }
    public var sceneRecoveryPending: Bool { read(.sceneRecoveryPending, storage.document.sceneRecoveryPending) }
    /// Unsaved scene edits or a recovered autosave exist.
    public var sceneDirty: Bool { sceneRecoveryPending || sceneRevision != lastSavedSceneRevision }
    public var pendingCloseRequest: EditorPendingCloseRequest? { read(.pendingCloseRequest, storage.document.pendingCloseRequest) }
    public var frameIndex: UInt64 { read(.frameIndex, storage.timing.frameIndex) }
    public var frameTimingRevision: UInt64 { read(.frameTimingRevision, storage.timing.frameTimingRevision) }
    public var frameStats: EditorFrameStats { read(.frameStats, storage.timing.frameStats) }
    public var frameStatsHistory: [EditorFrameStatsHistorySample] { read(.frameStatsHistory, storage.timing.frameStatsHistory) }
    public var particleDiagnosticsHistory: [EditorParticleDiagnosticsSample] {
        read(.particleDiagnosticsHistory, storage.timing.particleDiagnosticsHistory)
    }
    public var viewportSurfaceRevision: UInt64 { read(.viewportSurfaceRevision, storage.viewport.surfaceRevision) }
    public var viewportCameraRevision: UInt64 { read(.viewportCameraRevision, storage.viewport.cameraRevision) }
    public var windowFocused: Bool { read(.windowFocused, storage.window.focused) }
    public var windowMinimized: Bool { read(.windowMinimized, storage.window.minimized) }
    public var windowOccluded: Bool { read(.windowOccluded, storage.window.occluded) }
    public var shouldRender: Bool { read(.shouldRender, storage.shouldRender) }
    public var aiSettings: EditorAISettings { read(.aiSettings, storage.assistant.aiSettings) }
    public var capabilitySettings: EditorCapabilitySettings { read(.capabilitySettings, storage.assistant.capabilitySettings) }
    public var pluginManagement: EditorPluginManagementState {
        read(.pluginManagement, storage.assistant.pluginManagement)
    }
    public var aiStatusMessage: String? { read(.aiStatusMessage, storage.assistant.aiStatusMessage) }
    public var aiWarnings: [String] { read(.aiWarnings, storage.assistant.aiWarnings) }
    public var consoleEntries: [EditorConsoleEntry] { read(.consoleEntries, storage.output.consoleEntries) }
    public var latestConsoleEntry: EditorConsoleEntry? { read(.consoleEntries, storage.output.consoleEntries.last) }
    public var playbackState: PlaybackState { read(.playbackState, storage.timing.playbackState) }
    public var interactionMode: EditorInteractionMode { read(.interactionMode, storage.workspace.interactionMode) }
    public var agentTasks: [EditorAgentTask] { read(.agentTasks, storage.assistant.agentTasks) }
    public var workspaceMode: EditorWorkspaceMode { read(.workspaceMode, storage.workspace.mode) }
    public var activeLayoutPreset: EditorLayoutPreset { read(.activeLayoutPreset, storage.workspace.layoutPreset) }
    public var workspace: EditorWorkspaceState {
        registrar.access(AnyHashable(ObservationKey.workspaceMode))
        registrar.access(AnyHashable(ObservationKey.activeLayoutPreset))
        registrar.access(AnyHashable(ObservationKey.interactionMode))
        return storage.workspace
    }
    public var gizmoMode: EditorGizmoMode { read(.gizmoMode, storage.viewport.gizmoMode) }
    public var gizmoSpace: EditorGizmoSpace { read(.gizmoSpace, storage.viewport.gizmoSpace) }
    public var viewportShadingMode: EditorViewportShadingMode { read(.viewportShadingMode, storage.viewport.shadingMode) }
    public var viewportShadowsEnabled: Bool { read(.viewportShadowsEnabled, storage.shadows.enabled) }
    public var viewportGridEnabled: Bool { read(.viewportGridEnabled, storage.viewport.gridEnabled) }
    public var viewportRenderScalePercent: Int { read(.viewportRenderScalePercent, storage.viewport.renderScalePercent) }
    public var viewportInteractionDownscaleEnabled: Bool {
        read(.viewportInteractionDownscaleEnabled, storage.viewport.interactionDownscaleEnabled)
    }
    public var viewportRealtimeEnabled: Bool {
        read(.viewportRealtimeEnabled, storage.viewport.realtimeEnabled)
    }
    public var physicsDebugOverlayOptions: EditorPhysicsDebugOverlayOptions {
        read(.physicsDebugOverlayOptions, storage.viewport.physicsDebugOverlayOptions)
    }
    public var physicsDebugOverlayScope: EditorPhysicsDebugOverlayScope {
        read(.physicsDebugOverlayScope, storage.viewport.physicsDebugOverlayScope)
    }
    public var translateSnapEnabled: Bool { read(.translateSnapEnabled, storage.snapping.translateSnapEnabled) }
    public var rotateSnapEnabled: Bool { read(.rotateSnapEnabled, storage.snapping.rotateSnapEnabled) }
    public var scaleSnapEnabled: Bool { read(.scaleSnapEnabled, storage.snapping.scaleSnapEnabled) }
    public var translateSnapStep: Float { read(.translateSnapStep, storage.snapping.translateSnapStep) }
    public var rotateSnapStepDegrees: Float { read(.rotateSnapStepDegrees, storage.snapping.rotateSnapStepDegrees) }
    public var scaleSnapStep: Float { read(.scaleSnapStep, storage.snapping.scaleSnapStep) }
    public var primarySelectBehavior: SelectionPrimaryModifierBehavior { read(.primarySelectBehavior, storage.selection.primarySelectBehavior) }
    public var presentation: EditorPresentationState { read(.presentation, storage.presentation) }
    public var presentationRevision: UInt64 { read(.uiRefreshRevision, storage.presentation.revision) }
    public var themeMode: EditorThemeMode { read(.themeMode, storage.themeMode) }
    public var language: EditorLanguage { read(.language, storage.language) }
    public var uiRefreshRevision: UInt64 { read(.uiRefreshRevision, storage.uiRefreshRevision) }
    public var vsyncMode: EditorVSyncMode { read(.vsyncMode, storage.vsyncMode) }
    public var activeAssetDrag: EditorAssetDragPayload? { read(.activeAssetDrag, storage.navigation.activeAssetDrag) }
    public var inspectorCollapsedSectionIDs: Set<String> {
        read(.inspectorCollapsedSectionIDs, storage.selection.inspectorCollapsedSectionIDs)
    }
    public var pendingConfirmationRequest: ConfirmationRequestBatch? {
        read(.pendingConfirmationRequest, storage.assistant.pendingConfirmationRequest)
    }
    public var commandPaletteVisible: Bool { read(.commandPaletteVisible, storage.navigation.commandPaletteVisible) }
    public var chatMessages: [AIChatMessage] { read(.chatMessages, storage.assistant.chatMessages) }
}
