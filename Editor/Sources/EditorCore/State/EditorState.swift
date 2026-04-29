import Foundation
import IntentRuntime

public enum PlaybackState: String, Codable, Sendable, Hashable {
    case stopped
    case playing
    case paused
}

public enum EditorWorkspaceMode: String, Codable, Sendable, Hashable {
    case level
    case modeling
    case animation
}

public enum EditorLayoutPreset: String, Codable, Sendable, Hashable {
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

public enum EditorGizmoMode: String, Codable, Sendable, Hashable {
case none
    case translate
    case rotate
    case scale
}

public enum EditorGizmoSpace: String, Codable, Sendable, Hashable {
    case local
    case world
}

public enum EditorViewportShadingMode: String, Codable, Sendable, Hashable {
    case lit
    case wireframe
}

public enum SelectionCommandBehavior: String, Codable, Sendable, Hashable {
    case subtract
    case toggle
}

public enum EditorThemeMode: String, Codable, Sendable, CaseIterable, Hashable {
    case dark
    case light
}

public enum EditorLanguage: String, Codable, Sendable, CaseIterable, Hashable {
    case system
    case english
    case simplifiedChinese

    public var lprojName: String? {
        switch self {
        case .system:
            return Self.systemLprojName()
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    private static func systemLprojName() -> String {
        for identifier in Locale.preferredLanguages {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if normalized == "zh" || normalized.hasPrefix("zh-") {
                return "zh-Hans"
            }
            if normalized == "en" || normalized.hasPrefix("en-") {
                return "en"
            }
        }
        return "en"
    }
}

public enum EditorVSyncMode: String, Codable, Sendable, CaseIterable, Hashable {
    case enabled
    case disabled

    public var isEnabled: Bool {
        self == .enabled
    }

    public init(legacyFrameRateLimitRawValue rawValue: String) {
        switch rawValue {
        case "disabled":
            self = .disabled
        default:
            self = .enabled
        }
    }
}

public struct EditorAssetDragPayload: Codable, Sendable, Equatable, Hashable {
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
    public var frameIndex: UInt64
    public var frameTimingRevision: UInt64
    public var viewportSurfaceRevision: UInt64
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
    public var presentation: EditorPresentationState
    public var vsyncMode: EditorVSyncMode
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
        frameIndex: UInt64 = 0,
        frameTimingRevision: UInt64 = 0,
        viewportSurfaceRevision: UInt64 = 0,
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
        vsyncMode: EditorVSyncMode = .enabled,
        uiRefreshRevision: UInt64 = 0,
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
        self.frameTimingRevision = frameTimingRevision
        self.viewportSurfaceRevision = viewportSurfaceRevision
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
        self.presentation = EditorPresentationState(themeMode: themeMode,
                                                    language: language,
                                                    revision: uiRefreshRevision)
        self.vsyncMode = vsyncMode
        self.activeAssetDrag = activeAssetDrag
        self.inspectorCollapsedSectionIDs = inspectorCollapsedSectionIDs
        self.pendingConfirmationRequest = pendingConfirmationRequest
        self.aiStatusMessage = aiStatusMessage
        self.aiWarnings = aiWarnings
        self.frameIndex = frameIndex
    }

    public var shouldRender: Bool {
        !windowMinimized && !windowOccluded
    }

    public var themeMode: EditorThemeMode {
        presentation.themeMode
    }

    public var language: EditorLanguage {
        presentation.language
    }

    public var uiRefreshRevision: UInt64 {
        presentation.revision
    }

    private enum CodingKeys: String, CodingKey {
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
        case gizmoMode
        case gizmoSpace
        case viewportShadingMode
        case translateSnapEnabled
        case rotateSnapEnabled
        case scaleSnapEnabled
        case cmdSelectBehavior
        case presentation
        case themeMode
        case language
        case uiRefreshRevision
        case vsyncMode
        case activeAssetDrag
        case inspectorCollapsedSectionIDs
        case pendingConfirmationRequest
        case aiStatusMessage
        case aiWarnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPresentation = try c.decodeIfPresent(EditorPresentationState.self, forKey: .presentation)
        let legacyThemeMode = try c.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode)
        let legacyLanguage = try c.decodeIfPresent(EditorLanguage.self, forKey: .language)
        let legacyRevision = try c.decodeIfPresent(UInt64.self, forKey: .uiRefreshRevision)

        self.init(
            connected: try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false,
            selectedEntityID: try c.decodeIfPresent(UInt64.self, forKey: .selectedEntityID),
            selectedEntityIDs: try c.decodeIfPresent(Set<UInt64>.self, forKey: .selectedEntityIDs) ?? [],
            playbackState: try c.decodeIfPresent(PlaybackState.self, forKey: .playbackState) ?? .stopped,
            workspaceMode: try c.decodeIfPresent(EditorWorkspaceMode.self, forKey: .workspaceMode) ?? .level,
            activeLayoutPreset: try c.decodeIfPresent(EditorLayoutPreset.self, forKey: .activeLayoutPreset) ?? .levelDefault,
            sceneRevision: try c.decodeIfPresent(UInt64.self, forKey: .sceneRevision) ?? 0,
            frameIndex: try c.decodeIfPresent(UInt64.self, forKey: .frameIndex) ?? 0,
            frameTimingRevision: try c.decodeIfPresent(UInt64.self, forKey: .frameTimingRevision) ?? 0,
            viewportSurfaceRevision: try c.decodeIfPresent(UInt64.self, forKey: .viewportSurfaceRevision) ?? 0,
            windowFocused: try c.decodeIfPresent(Bool.self, forKey: .windowFocused) ?? true,
            windowMinimized: try c.decodeIfPresent(Bool.self, forKey: .windowMinimized) ?? false,
            windowOccluded: try c.decodeIfPresent(Bool.self, forKey: .windowOccluded) ?? false,
            gizmoMode: try c.decodeIfPresent(EditorGizmoMode.self, forKey: .gizmoMode) ?? .translate,
            gizmoSpace: try c.decodeIfPresent(EditorGizmoSpace.self, forKey: .gizmoSpace) ?? .local,
            viewportShadingMode: try c.decodeIfPresent(EditorViewportShadingMode.self, forKey: .viewportShadingMode) ?? .lit,
            translateSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .translateSnapEnabled) ?? false,
            rotateSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .rotateSnapEnabled) ?? false,
            scaleSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .scaleSnapEnabled) ?? false,
            cmdSelectBehavior: try c.decodeIfPresent(SelectionCommandBehavior.self, forKey: .cmdSelectBehavior) ?? .subtract,
            themeMode: decodedPresentation?.themeMode ?? legacyThemeMode ?? .dark,
            language: decodedPresentation?.language ?? legacyLanguage ?? .system,
            vsyncMode: try c.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) ?? .enabled,
            uiRefreshRevision: decodedPresentation?.revision ?? legacyRevision ?? 0,
            activeAssetDrag: try c.decodeIfPresent(EditorAssetDragPayload.self, forKey: .activeAssetDrag),
            inspectorCollapsedSectionIDs: try c.decodeIfPresent(Set<String>.self, forKey: .inspectorCollapsedSectionIDs) ?? [],
            pendingConfirmationRequest: try c.decodeIfPresent(ConfirmationRequestBatch.self, forKey: .pendingConfirmationRequest),
            aiStatusMessage: try c.decodeIfPresent(String.self, forKey: .aiStatusMessage),
            aiWarnings: try c.decodeIfPresent([String].self, forKey: .aiWarnings) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connected, forKey: .connected)
        try c.encodeIfPresent(selectedEntityID, forKey: .selectedEntityID)
        try c.encode(selectedEntityIDs, forKey: .selectedEntityIDs)
        try c.encode(playbackState, forKey: .playbackState)
        try c.encode(workspaceMode, forKey: .workspaceMode)
        try c.encode(activeLayoutPreset, forKey: .activeLayoutPreset)
        try c.encode(sceneRevision, forKey: .sceneRevision)
        try c.encode(frameIndex, forKey: .frameIndex)
        try c.encode(frameTimingRevision, forKey: .frameTimingRevision)
        try c.encode(viewportSurfaceRevision, forKey: .viewportSurfaceRevision)
        try c.encode(windowFocused, forKey: .windowFocused)
        try c.encode(windowMinimized, forKey: .windowMinimized)
        try c.encode(windowOccluded, forKey: .windowOccluded)
        try c.encode(gizmoMode, forKey: .gizmoMode)
        try c.encode(gizmoSpace, forKey: .gizmoSpace)
        try c.encode(viewportShadingMode, forKey: .viewportShadingMode)
        try c.encode(translateSnapEnabled, forKey: .translateSnapEnabled)
        try c.encode(rotateSnapEnabled, forKey: .rotateSnapEnabled)
        try c.encode(scaleSnapEnabled, forKey: .scaleSnapEnabled)
        try c.encode(cmdSelectBehavior, forKey: .cmdSelectBehavior)
        try c.encode(presentation, forKey: .presentation)
        try c.encode(themeMode, forKey: .themeMode)
        try c.encode(language, forKey: .language)
        try c.encode(uiRefreshRevision, forKey: .uiRefreshRevision)
        try c.encode(vsyncMode, forKey: .vsyncMode)
        try c.encodeIfPresent(activeAssetDrag, forKey: .activeAssetDrag)
        try c.encode(inspectorCollapsedSectionIDs, forKey: .inspectorCollapsedSectionIDs)
        try c.encodeIfPresent(pendingConfirmationRequest, forKey: .pendingConfirmationRequest)
        try c.encodeIfPresent(aiStatusMessage, forKey: .aiStatusMessage)
        try c.encode(aiWarnings, forKey: .aiWarnings)
    }
}
