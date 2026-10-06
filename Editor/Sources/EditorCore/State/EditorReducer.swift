import Foundation
import IntentRuntime

public enum EditorAction: Sendable {
    case tickFrame(UInt64)  // dispatched every engine frame
    case setConnected(Bool)
    case setSelectedEntity(UInt64?)
    case setPrimarySelectedEntity(UInt64?)
    case setSelectedEntities(Set<UInt64>)
    case setPlaybackState(PlaybackState)
    case setWorkspaceMode(EditorWorkspaceMode)
    case setActiveLayoutPreset(EditorLayoutPreset)
    case setSceneRevision(UInt64)
    case markSceneSaved(UInt64)
    case markSceneUnsaved
    case setSceneRecoveryPending(Bool)
    case requestClose(EditorPendingCloseRequest)
    case dismissCloseRequest
    case setWindowFocused(Bool)
    case setWindowMinimized(Bool)
    case setWindowOccluded(Bool)
    case setGizmoMode(EditorGizmoMode)
    case setGizmoSpace(EditorGizmoSpace)
    case setViewportShadingMode(EditorViewportShadingMode)
    case setViewportShadowsEnabled(Bool)
    case setViewportGridEnabled(Bool)
    case viewportCameraChanged
    case setViewportRenderScalePercent(Int)
    case setViewportInteractionDownscale(Bool)
    case setViewportRealtime(Bool)
    case setPhysicsDebugOverlayOptions(EditorPhysicsDebugOverlayOptions)
    case setPhysicsDebugOverlayScope(EditorPhysicsDebugOverlayScope)
    case setTranslateSnapEnabled(Bool)
    case setRotateSnapEnabled(Bool)
    case setScaleSnapEnabled(Bool)
    case setTranslateSnapStep(Float)
    case setRotateSnapStepDegrees(Float)
    case setScaleSnapStep(Float)
    case setPrimarySelectBehavior(SelectionPrimaryModifierBehavior)
    case setThemeMode(EditorThemeMode)
    case setLanguage(EditorLanguage)
    case forceUIRefresh
    case setVSyncMode(EditorVSyncMode)
    case beginAssetDrag(EditorAssetDragPayload)
    case updateAssetDragCursor(x: Float, y: Float)
    case endAssetDrag
    case setInspectorSectionCollapsed(id: String, isCollapsed: Bool)
    case setInspectorSectionsCollapsed(ids: Set<String>, isCollapsed: Bool)
    case setPendingConfirmationRequest(ConfirmationRequestBatch?)
    case setAISettings(EditorAISettings)
    case setCapabilitySettings(EditorCapabilitySettings)
    case setPluginManagementState(EditorPluginManagementState)
    case setAIStatusMessage(String?)
    case setAIWarnings([String])
    case appendChatMessage(AIChatMessage)
    case updateChatMessage(id: String, assistantState: AIChatMessage.AssistantState)
    case clearChatHistory
    case appendConsoleMessage(String, severity: EditorConsoleSeverity = .info, detail: String? = nil,
                              target: EditorIssueTarget? = nil, nextStep: String? = nil)
    case setOperation(EditorOperation)
    case navigateToScript(EditorScriptNavigationRequest)
    case navigateToAsset(String?)
    case setInspectorSceneSettingsVisible(Bool)
    case setCommandPaletteQuery(String)
    case setOutputTab(EditorOutputTab)
    case setViewportMode(EditorViewportMode)
    case setGamePreviewResolution(EditorGamePreviewResolution)
    case setGamePreviewHUDEnabled(Bool)
    case setGamePreviewFocused(Bool)
    case clearConsole
    case setCommandPaletteVisible(Bool)
    case frameTimingUpdated
    /// Bump the viewport surface revision so only viewport subscribers pull
    /// the newest `currentViewportSurfaceState()`.
    case viewportSurfaceUpdated
    case updateFrameStats(EditorFrameStats)
    case updateParticleDiagnostics(EditorParticleDiagnosticsSample)
}

public enum EditorReducer {
    public static func reduce(state: inout EditorState, action: EditorAction) {
        switch action {
        case let .setConnected(value):
            state.timing.connected = value
        case let .setSelectedEntity(value):
            state.selection.selectedEntityID = value
            if let entityID = value {
                state.selection.selectedEntityIDs = [entityID]
            } else {
                state.selection.selectedEntityIDs.removeAll(keepingCapacity: false)
            }

        case let .setPrimarySelectedEntity(value):
            state.selection.selectedEntityID = value
            if let entityID = value {
                if !state.selection.selectedEntityIDs.contains(entityID) {
                    state.selection.selectedEntityIDs = [entityID]
                }
            } else {
                state.selection.selectedEntityIDs.removeAll(keepingCapacity: false)
            }

        case let .setSelectedEntities(entityIDs):
            state.selection.selectedEntityIDs = entityIDs
            if let current = state.selection.selectedEntityID,
               entityIDs.contains(current) {
                state.selection.selectedEntityID = current
            } else {
                state.selection.selectedEntityID = entityIDs.sorted().first
            }
        case let .setPlaybackState(value):
            state.timing.playbackState = value
        case let .setWorkspaceMode(mode):
            state.workspace.mode = mode
            state.workspace.layoutPreset = .default(for: mode)
        case let .setActiveLayoutPreset(preset):
            if preset.mode == state.workspace.mode {
                state.workspace.layoutPreset = preset
            }
        case let .setSceneRevision(value):
            state.document.sceneRevision = value
        case let .markSceneSaved(revision):
            state.document.lastSavedSceneRevision = revision
            state.document.sceneRecoveryPending = false
        case .markSceneUnsaved:
            // A new empty document can have the same revision as the previous saved document.
            state.document.lastSavedSceneRevision = state.document.sceneRevision &- 1
        case let .setSceneRecoveryPending(pending):
            state.document.sceneRecoveryPending = pending
        case let .requestClose(request):
            state.document.pendingCloseRequest = request
        case .dismissCloseRequest:
            state.document.pendingCloseRequest = nil
        case let .tickFrame(n):
            state.timing.frameIndex = n
        case let .setWindowFocused(value):
            state.window.focused = value
        case let .setWindowMinimized(value):
            state.window.minimized = value
        case let .setWindowOccluded(value):
            state.window.occluded = value
        case let .setGizmoMode(value):
            state.viewport.gizmoMode = value

        case let .setGizmoSpace(space):
            state.viewport.gizmoSpace = space

        case let .setViewportShadingMode(mode):
            state.viewport.shadingMode = mode

        case let .setViewportShadowsEnabled(enabled):
            state.shadows.enabled = enabled

        case let .setViewportGridEnabled(enabled):
            state.viewport.gridEnabled = enabled

        case let .setViewportRenderScalePercent(percent):
            state.viewport.renderScalePercent = EditorState.sanitizedRenderScalePercent(percent)

        case let .setViewportInteractionDownscale(enabled):
            state.viewport.interactionDownscaleEnabled = enabled

        case let .setViewportRealtime(enabled):
            state.viewport.realtimeEnabled = enabled

        case let .setPhysicsDebugOverlayOptions(options):
            state.viewport.physicsDebugOverlayOptions = options.intersection(.all)

        case let .setPhysicsDebugOverlayScope(scope):
            state.viewport.physicsDebugOverlayScope = scope

        case let .setTranslateSnapEnabled(enabled):
            state.snapping.translateSnapEnabled = enabled

        case let .setRotateSnapEnabled(enabled):
            state.snapping.rotateSnapEnabled = enabled

        case let .setScaleSnapEnabled(enabled):
            state.snapping.scaleSnapEnabled = enabled

        case .viewportCameraChanged:
            state.viewport.cameraRevision &+= 1
        case let .setTranslateSnapStep(step):
            state.snapping.translateSnapStep = EditorState.sanitizedTranslateSnapStep(step)
        case let .setRotateSnapStepDegrees(step):
            state.snapping.rotateSnapStepDegrees = EditorState.sanitizedRotateSnapStep(step)
        case let .setScaleSnapStep(step):
            state.snapping.scaleSnapStep = EditorState.sanitizedScaleSnapStep(step)
        case let .setPrimarySelectBehavior(behavior):
            state.selection.primarySelectBehavior = behavior
        case let .setThemeMode(mode):
            state.presentation.setThemeMode(mode)
        case let .setLanguage(language):
            state.presentation.setLanguage(language)
        case .forceUIRefresh:
            state.presentation.forceRefresh()
        case let .setVSyncMode(mode):
            state.vsyncMode = mode
        case let .beginAssetDrag(payload):
            state.navigation.activeAssetDrag = payload
        case let .updateAssetDragCursor(x, y):
            if state.navigation.activeAssetDrag != nil {
                state.navigation.activeAssetDrag?.cursorX = x
                state.navigation.activeAssetDrag?.cursorY = y
            }
        case .endAssetDrag:
            state.navigation.activeAssetDrag = nil
        case let .setInspectorSectionCollapsed(id, isCollapsed):
            if isCollapsed {
                state.selection.inspectorCollapsedSectionIDs.insert(id)
            } else {
                state.selection.inspectorCollapsedSectionIDs.remove(id)
            }
        case let .setInspectorSectionsCollapsed(ids, isCollapsed):
            if isCollapsed {
                state.selection.inspectorCollapsedSectionIDs.formUnion(ids)
            } else {
                state.selection.inspectorCollapsedSectionIDs.subtract(ids)
            }
        case let .setPendingConfirmationRequest(request):
            state.assistant.pendingConfirmationRequest = request
        case let .setAISettings(settings):
            state.assistant.aiSettings = settings
        case let .setCapabilitySettings(settings):
            state.assistant.capabilitySettings = settings
        case let .setPluginManagementState(pluginManagement):
            state.assistant.pluginManagement = pluginManagement
        case let .setAIStatusMessage(message):
            state.assistant.aiStatusMessage = message
        case let .setAIWarnings(warnings):
            state.assistant.aiWarnings = warnings
        case let .appendChatMessage(message):
            state.assistant.chatMessages.append(message)
        case let .updateChatMessage(id, assistantState):
            if let idx = state.assistant.chatMessages.firstIndex(where: { $0.id == id }) {
                state.assistant.chatMessages[idx].assistantState = assistantState
            }
        case .clearChatHistory:
            state.assistant.chatMessages.removeAll()
        case let .setOperation(operation):
            state.navigation.operations.removeAll { $0.id == operation.id }
            state.navigation.operations.append(operation)
            if state.navigation.operations.count > 30 {
                if let oldest = state.navigation.operations.firstIndex(where: { $0.status != .running }) {
                    state.navigation.operations.remove(at: oldest)
                }
            }
        case let .navigateToScript(request):
            state.navigation.scriptNavigation = request
        case let .navigateToAsset(id):
            state.navigation.assetNavigationID = id
            state.navigation.assetNavigationRevision &+= 1
        case let .setInspectorSceneSettingsVisible(visible):
            state.selection.inspectorSceneSettingsVisible = visible
        case let .setCommandPaletteQuery(query):
            state.navigation.commandPaletteQuery = query
        case let .setOutputTab(tab):
            state.output.outputTab = tab
        case let .setViewportMode(mode):
            state.viewport.mode = mode
            state.viewport.gamePreviewFocused = false
        case let .setGamePreviewResolution(resolution):
            state.viewport.gamePreviewResolution = resolution
        case let .setGamePreviewHUDEnabled(enabled):
            state.viewport.gamePreviewHUDEnabled = enabled
        case let .setGamePreviewFocused(focused):
            state.viewport.gamePreviewFocused = focused
        case let .appendConsoleMessage(message, severity, detail, target, nextStep):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            state.output.consoleEntries.append(
                EditorConsoleEntry(id: state.output.nextConsoleEntryID,
                                   severity: severity,
                                   message: trimmed,
                                   detail: detail, target: target, nextStep: nextStep)
            )
            state.output.nextConsoleEntryID &+= 1
            if state.output.consoleEntries.count > 200 {
                state.output.consoleEntries.removeFirst(state.output.consoleEntries.count - 200)
            }
        case .clearConsole:
            state.output.consoleEntries.removeAll(keepingCapacity: false)
        case let .setCommandPaletteVisible(visible):
            state.navigation.commandPaletteVisible = visible
        case .frameTimingUpdated:
            state.timing.frameTimingRevision &+= 1
        case .viewportSurfaceUpdated:
            state.viewport.surfaceRevision &+= 1
        case let .updateFrameStats(stats):
            state.timing.frameStats = stats
            state.appendFrameStatsHistory(stats)
        case let .updateParticleDiagnostics(sample):
            state.appendParticleDiagnosticsHistory(sample)
        }
    }
}

extension EditorAction {
    var notifiesSubscribers: Bool {
        switch self {
        case .tickFrame, .updateAssetDragCursor:
            return false
        default:
            return true
        }
    }

    var invalidatesWholeStateObservation: Bool {
        switch self {
        case .frameTimingUpdated,
             .viewportSurfaceUpdated,
             .updateFrameStats,
             .updateParticleDiagnostics:
            return false
        default:
            return true
        }
    }
}
