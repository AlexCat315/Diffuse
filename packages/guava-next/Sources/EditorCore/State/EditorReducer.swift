import Foundation

public enum EditorAction: Sendable {
    case setConnected(Bool)
    case setSelectedEntity(UInt64?)
    case setPlaybackState(PlaybackState)
    case setSceneRevision(UInt64)
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
        }
    }
}
