import Foundation

public enum PlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
}

public enum EditorGizmoMode: String, Codable, Sendable {
    case none
    case translate
    case rotate
    case scale
}

public struct EditorAssetDragPayload: Codable, Sendable, Equatable {
    public var assetID: String
    public var displayName: String
    public var kindLabel: String
    public var cursorX: Float
    public var cursorY: Float

    public init(assetID: String,
                displayName: String,
                kindLabel: String,
                cursorX: Float = 0,
                cursorY: Float = 0) {
        self.assetID = assetID
        self.displayName = displayName
        self.kindLabel = kindLabel
        self.cursorX = cursorX
        self.cursorY = cursorY
    }
}

public struct EditorState: Codable, Sendable {
    public var connected: Bool
    public var selectedEntityID: UInt64?
    public var playbackState: PlaybackState
    public var sceneRevision: UInt64
    public var windowFocused: Bool
    public var windowMinimized: Bool
    public var windowOccluded: Bool
    public var gizmoMode: EditorGizmoMode
    public var activeAssetDrag: EditorAssetDragPayload?

    public init(
        connected: Bool = false,
        selectedEntityID: UInt64? = nil,
        playbackState: PlaybackState = .stopped,
        sceneRevision: UInt64 = 0,
        windowFocused: Bool = true,
        windowMinimized: Bool = false,
        windowOccluded: Bool = false,
        gizmoMode: EditorGizmoMode = .translate,
        activeAssetDrag: EditorAssetDragPayload? = nil
    ) {
        self.connected = connected
        self.selectedEntityID = selectedEntityID
        self.playbackState = playbackState
        self.sceneRevision = sceneRevision
        self.windowFocused = windowFocused
        self.windowMinimized = windowMinimized
        self.windowOccluded = windowOccluded
        self.gizmoMode = gizmoMode
        self.activeAssetDrag = activeAssetDrag
    }

    public var shouldRender: Bool {
        !windowMinimized && !windowOccluded
    }
}
