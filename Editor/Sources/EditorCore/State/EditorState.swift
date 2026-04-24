import Foundation
import IntentRuntime

public enum PlaybackState: String, Codable, Sendable {
    case stopped
    case playing
    case paused
}

public enum EditorWorkspaceMode: String, Codable, Sendable {
    case level
    case modeling
    case animation
}

public enum EditorLayoutPreset: String, Codable, Sendable {
    case levelDefault
    case levelCinematics
    case modelingDefault
    case modelingSculpt
    case animationDefault
    case animationSequencer

    public var mode: EditorWorkspaceMode {
        switch self {
        case .levelDefault, .levelCinematics:
            return .level
        case .modelingDefault, .modelingSculpt:
            return .modeling
        case .animationDefault, .animationSequencer:
            return .animation
        }
    }

    public var title: String {
        switch self {
        case .levelDefault:
            return "Level: Default"
        case .levelCinematics:
            return "Level: Cinematics"
        case .modelingDefault:
            return "Modeling: Default"
        case .modelingSculpt:
            return "Modeling: Sculpt"
        case .animationDefault:
            return "Animation: Default"
        case .animationSequencer:
            return "Animation: Sequencer"
        }
    }

    public static func `default`(for mode: EditorWorkspaceMode) -> EditorLayoutPreset {
        switch mode {
        case .level:
            return .levelDefault
        case .modeling:
            return .modelingDefault
        case .animation:
            return .animationDefault
        }
    }

    public static func presets(for mode: EditorWorkspaceMode) -> [EditorLayoutPreset] {
        switch mode {
        case .level:
            return [.levelDefault, .levelCinematics]
        case .modeling:
            return [.modelingDefault, .modelingSculpt]
        case .animation:
            return [.animationDefault, .animationSequencer]
        }
    }
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

public enum SelectionCommandBehavior: String, Codable, Sendable {
    case subtract
    case toggle
}

public enum EditorThemeMode: String, Codable, Sendable, CaseIterable {
    case dark
    case light
}

public enum EditorLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case english
    case simplifiedChinese

    public var lprojName: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }
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
    public var workspaceMode: EditorWorkspaceMode
    public var activeLayoutPreset: EditorLayoutPreset
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
    public var cmdSelectBehavior: SelectionCommandBehavior
    public var themeMode: EditorThemeMode
    public var language: EditorLanguage
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
        workspaceMode: EditorWorkspaceMode = .level,
        activeLayoutPreset: EditorLayoutPreset = .levelDefault,
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
        cmdSelectBehavior: SelectionCommandBehavior = .subtract,
        themeMode: EditorThemeMode = .dark,
        language: EditorLanguage = .system,
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
        self.workspaceMode = workspaceMode
        self.activeLayoutPreset = activeLayoutPreset
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
        self.cmdSelectBehavior = cmdSelectBehavior
        self.themeMode = themeMode
        self.language = language
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
