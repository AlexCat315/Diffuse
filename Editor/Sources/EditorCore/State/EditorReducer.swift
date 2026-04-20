import Foundation

public enum EditorAction: Sendable {
    case setConnected(Bool)
    case setSelectedEntity(UInt64?)
    case setPlaybackState(PlaybackState)
    case setSceneRevision(UInt64)
    case setWindowFocused(Bool)
    case setWindowMinimized(Bool)
    case setWindowOccluded(Bool)
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
        }
    }
}
