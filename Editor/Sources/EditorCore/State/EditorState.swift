import Foundation
import IntentRuntime

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

public enum EditorGizmoSpace: String, Codable, Sendable {
    case local
    case world
}

public enum EditorViewportShadingMode: String, Codable, Sendable {
    case lit
    case wireframe
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
    public var selectedEntityIDs: Set<UInt64>
    public var playbackState: PlaybackState
    public var sceneRevision: UInt64
    public var windowFocused: Bool
    public var windowMinimized: Bool
    public var windowOccluded: Bool
    public var gizmoMode: EditorGizmoMode
    public var gizmoSpace: EditorGizmoSpace
    public var viewportShadingMode: EditorViewportShadingMode
    public var translateSnapEnabled: Bool
    public var rotateSnapEnabled: Bool
    public var scaleSnapEnabled: Bool
    public var activeAssetDrag: EditorAssetDragPayload?
    public var inspectorCollapsedSectionIDs: Set<String>
    public var pendingConfirmationRequest: ConfirmationRequestBatch?
    public var aiStatusMessage: String?
    public var aiWarnings: [String]

    public init(
        connected: Bool = false,
        selectedEntityID: UInt64? = nil,
        selectedEntityIDs: Set<UInt64> = [],
        playbackState: PlaybackState = .stopped,
        sceneRevision: UInt64 = 0,
        windowFocused: Bool = true,
        windowMinimized: Bool = false,
        windowOccluded: Bool = false,
        gizmoMode: EditorGizmoMode = .translate,
        gizmoSpace: EditorGizmoSpace = .local,
        viewportShadingMode: EditorViewportShadingMode = .lit,
        translateSnapEnabled: Bool = false,
        rotateSnapEnabled: Bool = false,
        scaleSnapEnabled: Bool = false,
        activeAssetDrag: EditorAssetDragPayload? = nil,
        inspectorCollapsedSectionIDs: Set<String> = [],
        pendingConfirmationRequest: ConfirmationRequestBatch? = nil,
        aiStatusMessage: String? = nil,
        aiWarnings: [String] = []
    ) {
        self.connected = connected
        self.selectedEntityID = selectedEntityID
        self.selectedEntityIDs = selectedEntityIDs
        self.playbackState = playbackState
        self.sceneRevision = sceneRevision
        self.windowFocused = windowFocused
        self.windowMinimized = windowMinimized
        self.windowOccluded = windowOccluded
        self.gizmoMode = gizmoMode
        self.gizmoSpace = gizmoSpace
        self.viewportShadingMode = viewportShadingMode
        self.translateSnapEnabled = translateSnapEnabled
        self.rotateSnapEnabled = rotateSnapEnabled
        self.scaleSnapEnabled = scaleSnapEnabled
        self.activeAssetDrag = activeAssetDrag
        self.inspectorCollapsedSectionIDs = inspectorCollapsedSectionIDs
        self.pendingConfirmationRequest = pendingConfirmationRequest
        self.aiStatusMessage = aiStatusMessage
        self.aiWarnings = aiWarnings
    }

    public var shouldRender: Bool {
        !windowMinimized && !windowOccluded
    }
}
