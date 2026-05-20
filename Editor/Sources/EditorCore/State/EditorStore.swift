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
        case workspaceMode
        case activeLayoutPreset
        case sceneRevision
        case frameIndex
        case frameTimingRevision
        case viewportSurfaceRevision
        case windowFocused
        case windowMinimized
        case windowOccluded
        case shouldRender
        case gizmoMode
        case gizmoSpace
        case viewportShadingMode
        case viewportShadowsEnabled
        case translateSnapEnabled
        case rotateSnapEnabled
        case scaleSnapEnabled
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
        case aiStatusMessage
        case aiWarnings
        case chatMessages
        case consoleEntries
        case commandPaletteVisible
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
        case .tickFrame:
            mark(.frameIndex, old.frameIndex, new.frameIndex)
        case .setConnected:
            mark(.connected, old.connected, new.connected)
        case .setSelectedEntity, .setPrimarySelectedEntity, .setSelectedEntities:
            mark(.selectedEntityID, old.selectedEntityID, new.selectedEntityID)
            mark(.selectedEntityIDs, old.selectedEntityIDs, new.selectedEntityIDs)
        case .setPlaybackState:
            mark(.playbackState, old.playbackState, new.playbackState)
        case .setWorkspaceMode:
            mark(.workspaceMode, old.workspaceMode, new.workspaceMode)
            mark(.activeLayoutPreset, old.activeLayoutPreset, new.activeLayoutPreset)
        case .setActiveLayoutPreset:
            mark(.activeLayoutPreset, old.activeLayoutPreset, new.activeLayoutPreset)
        case .setSceneRevision:
            mark(.sceneRevision, old.sceneRevision, new.sceneRevision)
        case .setWindowFocused:
            mark(.windowFocused, old.windowFocused, new.windowFocused)
        case .setWindowMinimized:
            mark(.windowMinimized, old.windowMinimized, new.windowMinimized)
        case .setWindowOccluded:
            mark(.windowOccluded, old.windowOccluded, new.windowOccluded)
        case .setGizmoMode:
            mark(.gizmoMode, old.gizmoMode, new.gizmoMode)
        case .setGizmoSpace:
            mark(.gizmoSpace, old.gizmoSpace, new.gizmoSpace)
        case .setViewportShadingMode:
            mark(.viewportShadingMode, old.viewportShadingMode, new.viewportShadingMode)
        case .setViewportShadowsEnabled:
            mark(.viewportShadowsEnabled, old.viewportShadowsEnabled, new.viewportShadowsEnabled)
        case .setTranslateSnapEnabled:
            mark(.translateSnapEnabled, old.translateSnapEnabled, new.translateSnapEnabled)
        case .setRotateSnapEnabled:
            mark(.rotateSnapEnabled, old.rotateSnapEnabled, new.rotateSnapEnabled)
        case .setScaleSnapEnabled:
            mark(.scaleSnapEnabled, old.scaleSnapEnabled, new.scaleSnapEnabled)
        case .setPrimarySelectBehavior:
            mark(.primarySelectBehavior, old.primarySelectBehavior, new.primarySelectBehavior)
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
            mark(.activeAssetDrag, old.activeAssetDrag, new.activeAssetDrag)
        case .updateAssetDragCursor:
            break
        case .setInspectorSectionCollapsed:
            mark(.inspectorCollapsedSectionIDs,
                 old.inspectorCollapsedSectionIDs,
                 new.inspectorCollapsedSectionIDs)
        case .setPendingConfirmationRequest:
            mark(.pendingConfirmationRequest,
                 old.pendingConfirmationRequest,
                 new.pendingConfirmationRequest)
        case .setAISettings:
            mark(.aiSettings, old.aiSettings, new.aiSettings)
        case .setCapabilitySettings:
            mark(.capabilitySettings, old.capabilitySettings, new.capabilitySettings)
        case .setAIStatusMessage:
            mark(.aiStatusMessage, old.aiStatusMessage, new.aiStatusMessage)
        case .setAIWarnings:
            mark(.aiWarnings, old.aiWarnings, new.aiWarnings)
        case .appendChatMessage, .updateChatMessage, .clearChatHistory:
            mark(.chatMessages, old.chatMessages, new.chatMessages)
        case .appendConsoleMessage, .clearConsole:
            mark(.consoleEntries, old.consoleEntries, new.consoleEntries)
        case .setCommandPaletteVisible:
            mark(.commandPaletteVisible, old.commandPaletteVisible, new.commandPaletteVisible)
        case .frameTimingUpdated:
            mark(.frameTimingRevision, old.frameTimingRevision, new.frameTimingRevision)
        case .viewportSurfaceUpdated:
            mark(.viewportSurfaceRevision, old.viewportSurfaceRevision, new.viewportSurfaceRevision)
        }

        if old.shouldRender != new.shouldRender {
            keys.insert(.shouldRender)
        }
        if !keys.isEmpty {
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
    public var connected: Bool { read(.connected, storage.connected) }
    public var selectedEntityID: UInt64? { read(.selectedEntityID, storage.selectedEntityID) }
    public var selectedEntityIDs: Set<UInt64> { read(.selectedEntityIDs, storage.selectedEntityIDs) }
    public var selectedEntityIDsCount: Int { read(.selectedEntityIDs, storage.selectedEntityIDs.count) }
    public var sceneRevision: UInt64 { read(.sceneRevision, storage.sceneRevision) }
    public var frameIndex: UInt64 { read(.frameIndex, storage.frameIndex) }
    public var frameTimingRevision: UInt64 { read(.frameTimingRevision, storage.frameTimingRevision) }
    public var viewportSurfaceRevision: UInt64 { read(.viewportSurfaceRevision, storage.viewportSurfaceRevision) }
    public var windowFocused: Bool { read(.windowFocused, storage.windowFocused) }
    public var windowMinimized: Bool { read(.windowMinimized, storage.windowMinimized) }
    public var windowOccluded: Bool { read(.windowOccluded, storage.windowOccluded) }
    public var shouldRender: Bool { read(.shouldRender, storage.shouldRender) }
    public var aiSettings: EditorAISettings { read(.aiSettings, storage.aiSettings) }
    public var capabilitySettings: EditorCapabilitySettings { read(.capabilitySettings, storage.capabilitySettings) }
    public var aiStatusMessage: String? { read(.aiStatusMessage, storage.aiStatusMessage) }
    public var aiWarnings: [String] { read(.aiWarnings, storage.aiWarnings) }
    public var consoleEntries: [EditorConsoleEntry] { read(.consoleEntries, storage.consoleEntries) }
    public var latestConsoleEntry: EditorConsoleEntry? { read(.consoleEntries, storage.consoleEntries.last) }
    public var playbackState: PlaybackState { read(.playbackState, storage.playbackState) }
    public var workspaceMode: EditorWorkspaceMode { read(.workspaceMode, storage.workspaceMode) }
    public var activeLayoutPreset: EditorLayoutPreset { read(.activeLayoutPreset, storage.activeLayoutPreset) }
    public var gizmoMode: EditorGizmoMode { read(.gizmoMode, storage.gizmoMode) }
    public var gizmoSpace: EditorGizmoSpace { read(.gizmoSpace, storage.gizmoSpace) }
    public var viewportShadingMode: EditorViewportShadingMode { read(.viewportShadingMode, storage.viewportShadingMode) }
    public var viewportShadowsEnabled: Bool { read(.viewportShadowsEnabled, storage.viewportShadowsEnabled) }
    public var translateSnapEnabled: Bool { read(.translateSnapEnabled, storage.translateSnapEnabled) }
    public var rotateSnapEnabled: Bool { read(.rotateSnapEnabled, storage.rotateSnapEnabled) }
    public var scaleSnapEnabled: Bool { read(.scaleSnapEnabled, storage.scaleSnapEnabled) }
    public var primarySelectBehavior: SelectionPrimaryModifierBehavior { read(.primarySelectBehavior, storage.primarySelectBehavior) }
    public var presentation: EditorPresentationState { read(.presentation, storage.presentation) }
    public var presentationRevision: UInt64 { read(.uiRefreshRevision, storage.presentation.revision) }
    public var themeMode: EditorThemeMode { read(.themeMode, storage.themeMode) }
    public var language: EditorLanguage { read(.language, storage.language) }
    public var uiRefreshRevision: UInt64 { read(.uiRefreshRevision, storage.uiRefreshRevision) }
    public var vsyncMode: EditorVSyncMode { read(.vsyncMode, storage.vsyncMode) }
    public var activeAssetDrag: EditorAssetDragPayload? { read(.activeAssetDrag, storage.activeAssetDrag) }
    public var inspectorCollapsedSectionIDs: Set<String> {
        read(.inspectorCollapsedSectionIDs, storage.inspectorCollapsedSectionIDs)
    }
    public var pendingConfirmationRequest: ConfirmationRequestBatch? {
        read(.pendingConfirmationRequest, storage.pendingConfirmationRequest)
    }
    public var commandPaletteVisible: Bool { read(.commandPaletteVisible, storage.commandPaletteVisible) }
    public var chatMessages: [AIChatMessage] { read(.chatMessages, storage.chatMessages) }
}
