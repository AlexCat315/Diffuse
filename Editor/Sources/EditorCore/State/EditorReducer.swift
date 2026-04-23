import Foundation

public enum EditorAction: Sendable {
    case setConnected(Bool)
    case setSelectedEntity(UInt64?)
    case setPlaybackState(PlaybackState)
    case setSceneRevision(UInt64)
    case setWindowFocused(Bool)
    case setWindowMinimized(Bool)
    case setWindowOccluded(Bool)
    case setGizmoMode(EditorGizmoMode)
    case beginAssetDrag(EditorAssetDragPayload)
    case updateAssetDragCursor(x: Float, y: Float)
    case endAssetDrag
    case setInspectorSectionCollapsed(id: String, isCollapsed: Bool)
}

public enum EditorReducer {
    public static func reduce(state: inout EditorState, action: EditorAction) {
        switch action {
        case let .setConnected(value):
            state.connected = value
        case let .setSelectedEntity(value):
            state.selectedEntityID = value
        case let .setPlaybackState(value):
            state.playbackState = value
        case let .setSceneRevision(value):
            state.sceneRevision = value
        case let .setWindowFocused(value):
            state.windowFocused = value
        case let .setWindowMinimized(value):
            state.windowMinimized = value
        case let .setWindowOccluded(value):
            state.windowOccluded = value
        case let .setGizmoMode(value):
            state.gizmoMode = value
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
        }
    }
}
