import Foundation

public enum PlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
}

public struct EditorState: Codable, Sendable {
    public var connected: Bool
    public var selectedEntityID: UInt64?
    public var playbackState: PlaybackState
    public var sceneRevision: UInt64
    public var windowFocused: Bool
    public var windowMinimized: Bool
    public var windowOccluded: Bool

    public init(
        connected: Bool = false,
        selectedEntityID: UInt64? = nil,
        playbackState: PlaybackState = .stopped,
        sceneRevision: UInt64 = 0,
        windowFocused: Bool = true,
        windowMinimized: Bool = false,
        windowOccluded: Bool = false
    ) {
        self.connected = connected
        self.selectedEntityID = selectedEntityID
        self.playbackState = playbackState
        self.sceneRevision = sceneRevision
        self.windowFocused = windowFocused
        self.windowMinimized = windowMinimized
        self.windowOccluded = windowOccluded
    }

    public var shouldRender: Bool {
        !windowMinimized && !windowOccluded
    }
}
