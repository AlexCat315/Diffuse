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
    case setWindowFocused(Bool)
    case setWindowMinimized(Bool)
    case setWindowOccluded(Bool)
    case setGizmoMode(EditorGizmoMode)
    case setGizmoSpace(EditorGizmoSpace)
    case setViewportShadingMode(EditorViewportShadingMode)
    case setTranslateSnapEnabled(Bool)
    case setRotateSnapEnabled(Bool)
    case setScaleSnapEnabled(Bool)
    case setPrimarySelectBehavior(SelectionPrimaryModifierBehavior)
    case setThemeMode(EditorThemeMode)
    case setLanguage(EditorLanguage)
    case forceUIRefresh
    case setVSyncMode(EditorVSyncMode)
    case beginAssetDrag(EditorAssetDragPayload)
    case updateAssetDragCursor(x: Float, y: Float)
    case endAssetDrag
    case setInspectorSectionCollapsed(id: String, isCollapsed: Bool)
    case setPendingConfirmationRequest(ConfirmationRequestBatch?)
    case setAISettings(EditorAISettings)
    case setAIStatusMessage(String?)
    case setAIWarnings([String])
    case appendChatMessage(AIChatMessage)
    case updateChatMessage(id: String, assistantState: AIChatMessage.AssistantState)
    case clearChatHistory
    case appendConsoleMessage(String, severity: EditorConsoleSeverity = .info, detail: String? = nil)
    case clearConsole
    case setCommandPaletteVisible(Bool)
    case frameTimingUpdated
    /// Bump the viewport surface revision so only viewport subscribers pull
    /// the newest `currentViewportSurfaceState()`.
    case viewportSurfaceUpdated
}

public enum EditorReducer {
    public static func reduce(state: inout EditorState, action: EditorAction) {
        switch action {
        case let .setConnected(value):
            state.connected = value
        case let .setSelectedEntity(value):
            state.selectedEntityID = value
            if let entityID = value {
                state.selectedEntityIDs = [entityID]
            } else {
                state.selectedEntityIDs.removeAll(keepingCapacity: false)
            }

        case let .setPrimarySelectedEntity(value):
            state.selectedEntityID = value
            if let entityID = value {
                if !state.selectedEntityIDs.contains(entityID) {
                    state.selectedEntityIDs = [entityID]
                }
            } else {
                state.selectedEntityIDs.removeAll(keepingCapacity: false)
            }

        case let .setSelectedEntities(entityIDs):
            state.selectedEntityIDs = entityIDs
            if let current = state.selectedEntityID,
               entityIDs.contains(current) {
                state.selectedEntityID = current
            } else {
                state.selectedEntityID = entityIDs.sorted().first
            }
        case let .setPlaybackState(value):
            state.playbackState = value
        case let .setWorkspaceMode(mode):
            state.workspaceMode = mode
            state.activeLayoutPreset = .default(for: mode)
        case let .setActiveLayoutPreset(preset):
            if preset.mode == state.workspaceMode {
                state.activeLayoutPreset = preset
            }
        case let .setSceneRevision(value):
            state.sceneRevision = value
        case let .tickFrame(n):
            state.frameIndex = n
        case let .setWindowFocused(value):
            state.windowFocused = value
        case let .setWindowMinimized(value):
            state.windowMinimized = value
        case let .setWindowOccluded(value):
            state.windowOccluded = value
        case let .setGizmoMode(value):
            state.gizmoMode = value

        case let .setGizmoSpace(space):
            state.gizmoSpace = space

        case let .setViewportShadingMode(mode):
            state.viewportShadingMode = mode

        case let .setTranslateSnapEnabled(enabled):
            state.translateSnapEnabled = enabled

        case let .setRotateSnapEnabled(enabled):
            state.rotateSnapEnabled = enabled

        case let .setScaleSnapEnabled(enabled):
            state.scaleSnapEnabled = enabled
        case let .setPrimarySelectBehavior(behavior):
            state.primarySelectBehavior = behavior
        case let .setThemeMode(mode):
            state.presentation.setThemeMode(mode)
        case let .setLanguage(language):
            state.presentation.setLanguage(language)
        case .forceUIRefresh:
            state.presentation.forceRefresh()
        case let .setVSyncMode(mode):
            state.vsyncMode = mode
        case let .beginAssetDrag(payload):
            state.activeAssetDrag = payload
        case let .updateAssetDragCursor(x, y):
            if state.activeAssetDrag != nil {
                state.activeAssetDrag?.cursorX = x
                state.activeAssetDrag?.cursorY = y
            }
        case .endAssetDrag:
            state.activeAssetDrag = nil
        case let .setInspectorSectionCollapsed(id, isCollapsed):
            if isCollapsed {
                state.inspectorCollapsedSectionIDs.insert(id)
            } else {
                state.inspectorCollapsedSectionIDs.remove(id)
            }
        case let .setPendingConfirmationRequest(request):
            state.pendingConfirmationRequest = request
        case let .setAISettings(settings):
            state.aiSettings = settings
        case let .setAIStatusMessage(message):
            state.aiStatusMessage = message
        case let .setAIWarnings(warnings):
            state.aiWarnings = warnings
        case let .appendChatMessage(message):
            state.chatMessages.append(message)
        case let .updateChatMessage(id, assistantState):
            if let idx = state.chatMessages.firstIndex(where: { $0.id == id }) {
                state.chatMessages[idx].assistantState = assistantState
            }
        case .clearChatHistory:
            state.chatMessages.removeAll()
        case let .appendConsoleMessage(message, severity, detail):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            state.consoleEntries.append(
                EditorConsoleEntry(id: state.nextConsoleEntryID,
                                   severity: severity,
                                   message: trimmed,
                                   detail: detail)
            )
            state.nextConsoleEntryID &+= 1
            if state.consoleEntries.count > 200 {
                state.consoleEntries.removeFirst(state.consoleEntries.count - 200)
            }
        case .clearConsole:
            state.consoleEntries.removeAll(keepingCapacity: false)
        case let .setCommandPaletteVisible(visible):
            state.commandPaletteVisible = visible
        case .frameTimingUpdated:
            state.frameTimingRevision &+= 1
        case .viewportSurfaceUpdated:
            state.viewportSurfaceRevision &+= 1
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
}
