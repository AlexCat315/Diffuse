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

public enum EditorViewportShadingMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Full PBR.
    case lit
    /// Mesh edges drawn as an overlay over the lit surface (topology view).
    case wireframe
    /// Material albedo with ambient occlusion, no lighting (UE "Unlit").
    case unlit
    /// Raw base-color texture only (the albedo G-buffer).
    case baseColor
    /// Surface normal visualized as RGB.
    case normal
    /// Roughness channel as greyscale.
    case roughness
    /// Metallic channel as greyscale.
    case metallic

    /// Debug-view index handed to the mesh shader (`exposure_light_count.z`).
    /// `.wireframe` shades the surface normally (lit) and overlays edges, so it
    /// maps to the same shaded path as `.lit`.
    public var debugViewIndex: Int {
        switch self {
        case .lit, .wireframe: return 0
        case .unlit:           return 1
        case .baseColor:       return 2
        case .normal:          return 3
        case .roughness:       return 4
        case .metallic:        return 5
        }
    }
}

public enum EditorViewportShadowDebugMode: String, Codable, Sendable, CaseIterable, Hashable {
    case off
    case cascadeBands
}

public enum SelectionPrimaryModifierBehavior: String, Codable, Sendable, Hashable {
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

public enum EditorConsoleSeverity: String, Codable, Sendable, CaseIterable, Hashable {
    case info
    case warning
    case error
}

public struct EditorConsoleEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UInt64
    public var severity: EditorConsoleSeverity
    public var message: String
    public var detail: String?

    public init(id: UInt64,
                severity: EditorConsoleSeverity = .info,
                message: String,
                detail: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.detail = detail
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
    public static let maxFrameStatsHistorySamples = 240

    public var connected: Bool
    public var selectedEntityID: UInt64?
    public var selectedEntityIDs: Set<UInt64>
    public var playbackState: PlaybackState
    public var workspaceMode: EditorWorkspaceMode
    public var activeLayoutPreset: EditorLayoutPreset
    public var sceneRevision: UInt64
    /// `sceneRevision` captured at the last manifest save/load. The scene is
    /// "dirty" (unsaved edits) whenever the two diverge.
    public var lastSavedSceneRevision: UInt64
    /// A vetoed OS close/quit waiting on the user's save decision. Non-nil
    /// shows the unsaved-changes dialog; `windowID == nil` means app quit.
    public var pendingCloseRequest: EditorPendingCloseRequest?
    public var frameIndex: UInt64
    public var frameTimingRevision: UInt64
    public var frameStats: EditorFrameStats
    public var frameStatsHistory: [EditorFrameStatsHistorySample]
    public var viewportSurfaceRevision: UInt64
    public var windowFocused: Bool
    public var windowMinimized: Bool
    public var windowOccluded: Bool
    public var gizmoMode: EditorGizmoMode
    public var gizmoSpace: EditorGizmoSpace
    public var viewportShadingMode: EditorViewportShadingMode
    public var viewportShadowsEnabled: Bool
    public var viewportShadowMapResolution: UInt32
    public var viewportMaxShadowedDirectionalLights: Int
    public var viewportDirectionalCascadeCount: Int
    public var viewportDirectionalCascadeSplitLambda: Float
    public var viewportShadowDebugMode: EditorViewportShadowDebugMode
    /// Screen-percentage style render scale for the 3D viewport (100 = native
    /// pixels). The presentation size stays fixed; the engine renders
    /// `presentation × percent/100` and the composite quad rescales.
    public var viewportRenderScalePercent: Int
    /// Temporarily halve the render resolution during camera / gizmo drags.
    public var viewportInteractionDownscaleEnabled: Bool
    /// Escape hatch for on-demand viewport rendering: render every tick even
    /// when no packet input changed (Unreal's per-viewport "Realtime").
    public var viewportRealtimeEnabled: Bool
    public var translateSnapEnabled: Bool
    public var rotateSnapEnabled: Bool
    public var scaleSnapEnabled: Bool
    public var primarySelectBehavior: SelectionPrimaryModifierBehavior
    public var presentation: EditorPresentationState
    public var vsyncMode: EditorVSyncMode
    public var activeAssetDrag: EditorAssetDragPayload?
    public var inspectorCollapsedSectionIDs: Set<String>
    public var pendingConfirmationRequest: ConfirmationRequestBatch?
    public var aiSettings: EditorAISettings
    public var capabilitySettings: EditorCapabilitySettings
    public var aiStatusMessage: String?
    public var aiWarnings: [String]
    public var chatMessages: [AIChatMessage]
    public var consoleEntries: [EditorConsoleEntry]
    public var nextConsoleEntryID: UInt64
    public var commandPaletteVisible: Bool

    public init(
        connected: Bool = false,
        selectedEntityID: UInt64? = nil,
        selectedEntityIDs: Set<UInt64> = [],
        playbackState: PlaybackState = .stopped,
        workspaceMode: EditorWorkspaceMode = .level,
        activeLayoutPreset: EditorLayoutPreset = .levelDefault,
        sceneRevision: UInt64 = 0,
        lastSavedSceneRevision: UInt64 = 0,
        pendingCloseRequest: EditorPendingCloseRequest? = nil,
        frameIndex: UInt64 = 0,
        frameTimingRevision: UInt64 = 0,
        frameStats: EditorFrameStats = .init(),
        frameStatsHistory: [EditorFrameStatsHistorySample] = [],
        viewportSurfaceRevision: UInt64 = 0,
        windowFocused: Bool = true,
        windowMinimized: Bool = false,
        windowOccluded: Bool = false,
        gizmoMode: EditorGizmoMode = .translate,
        gizmoSpace: EditorGizmoSpace = .local,
        viewportShadingMode: EditorViewportShadingMode = .lit,
        viewportShadowsEnabled: Bool = true,
        viewportShadowMapResolution: UInt32 = 1024,
        viewportMaxShadowedDirectionalLights: Int = 1,
        viewportDirectionalCascadeCount: Int = 1,
        viewportDirectionalCascadeSplitLambda: Float = 0.55,
        viewportShadowDebugMode: EditorViewportShadowDebugMode = .off,
        viewportRenderScalePercent: Int = 100,
        viewportInteractionDownscaleEnabled: Bool = false,
        viewportRealtimeEnabled: Bool = false,
        translateSnapEnabled: Bool = false,
        rotateSnapEnabled: Bool = false,
        scaleSnapEnabled: Bool = false,
        primarySelectBehavior: SelectionPrimaryModifierBehavior = .subtract,
        themeMode: EditorThemeMode = .dark,
        language: EditorLanguage = .system,
        vsyncMode: EditorVSyncMode = .enabled,
        uiRefreshRevision: UInt64 = 0,
        activeAssetDrag: EditorAssetDragPayload? = nil,
        inspectorCollapsedSectionIDs: Set<String> = [],
        pendingConfirmationRequest: ConfirmationRequestBatch? = nil,
        aiSettings: EditorAISettings = .default,
        capabilitySettings: EditorCapabilitySettings = .default,
        aiStatusMessage: String? = nil,
        aiWarnings: [String] = [],
        chatMessages: [AIChatMessage] = [],
        consoleEntries: [EditorConsoleEntry] = [],
        nextConsoleEntryID: UInt64 = 1,
        commandPaletteVisible: Bool = false
    ) {
        self.connected = connected
        self.selectedEntityID = selectedEntityID
        self.selectedEntityIDs = selectedEntityIDs
        self.playbackState = playbackState
        self.workspaceMode = workspaceMode
        self.activeLayoutPreset = activeLayoutPreset
        self.sceneRevision = sceneRevision
        self.lastSavedSceneRevision = lastSavedSceneRevision
        self.pendingCloseRequest = pendingCloseRequest
        self.frameTimingRevision = frameTimingRevision
        self.viewportSurfaceRevision = viewportSurfaceRevision
        self.windowFocused = windowFocused
        self.windowMinimized = windowMinimized
        self.windowOccluded = windowOccluded
        self.gizmoMode = gizmoMode
        self.gizmoSpace = gizmoSpace
        self.viewportShadingMode = viewportShadingMode
        self.viewportShadowsEnabled = viewportShadowsEnabled
        self.viewportShadowMapResolution = Self.sanitizedShadowMapResolution(viewportShadowMapResolution)
        self.viewportMaxShadowedDirectionalLights = Self.sanitizedMaxShadowedDirectionalLights(viewportMaxShadowedDirectionalLights)
        self.viewportDirectionalCascadeCount = Self.sanitizedDirectionalCascadeCount(viewportDirectionalCascadeCount)
        self.viewportDirectionalCascadeSplitLambda = Self.sanitizedDirectionalCascadeSplitLambda(viewportDirectionalCascadeSplitLambda)
        self.viewportShadowDebugMode = viewportShadowDebugMode
        self.viewportRenderScalePercent = Self.sanitizedRenderScalePercent(viewportRenderScalePercent)
        self.viewportInteractionDownscaleEnabled = viewportInteractionDownscaleEnabled
        self.viewportRealtimeEnabled = viewportRealtimeEnabled
        self.translateSnapEnabled = translateSnapEnabled
        self.rotateSnapEnabled = rotateSnapEnabled
        self.scaleSnapEnabled = scaleSnapEnabled
        self.primarySelectBehavior = primarySelectBehavior
        self.presentation = EditorPresentationState(themeMode: themeMode,
                                                    language: language,
                                                    revision: uiRefreshRevision)
        self.vsyncMode = vsyncMode
        self.activeAssetDrag = activeAssetDrag
        self.inspectorCollapsedSectionIDs = inspectorCollapsedSectionIDs
        self.pendingConfirmationRequest = pendingConfirmationRequest
        self.aiSettings = aiSettings
        self.capabilitySettings = capabilitySettings
        self.aiStatusMessage = aiStatusMessage
        self.aiWarnings = aiWarnings
        self.chatMessages = chatMessages
        self.consoleEntries = consoleEntries
        self.nextConsoleEntryID = max(nextConsoleEntryID, (consoleEntries.map(\.id).max() ?? 0) &+ 1)
        self.frameIndex = frameIndex
        self.frameStats = frameStats
        self.frameStatsHistory = Array(frameStatsHistory.suffix(Self.maxFrameStatsHistorySamples))
        self.commandPaletteVisible = commandPaletteVisible
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
        case frameStats
        case viewportSurfaceRevision
        case windowFocused
        case windowMinimized
        case windowOccluded
        case gizmoMode
        case gizmoSpace
        case viewportShadingMode
        case viewportShadowsEnabled
        case viewportShadowMapResolution
        case viewportMaxShadowedDirectionalLights
        case viewportDirectionalCascadeCount
        case viewportDirectionalCascadeSplitLambda
        case viewportShadowDebugMode
        case viewportRenderScalePercent
        case viewportInteractionDownscaleEnabled
        case viewportRealtimeEnabled
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
        case capabilitySettings
        case aiStatusMessage
        case aiWarnings
        case consoleEntries
        case nextConsoleEntryID
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case cmdSelectBehavior
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let decodedPresentation = try c.decodeIfPresent(EditorPresentationState.self, forKey: .presentation)
        let legacyThemeMode = try c.decodeIfPresent(EditorThemeMode.self, forKey: .themeMode)
        let legacyLanguage = try c.decodeIfPresent(EditorLanguage.self, forKey: .language)
        let legacyRevision = try c.decodeIfPresent(UInt64.self, forKey: .uiRefreshRevision)
        let decodedPrimarySelectBehavior = try c.decodeIfPresent(
            SelectionPrimaryModifierBehavior.self,
            forKey: .primarySelectBehavior
        )
        let legacyPrimarySelectBehavior = try legacy.decodeIfPresent(
            SelectionPrimaryModifierBehavior.self,
            forKey: .cmdSelectBehavior
        )

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
            frameStats: try c.decodeIfPresent(EditorFrameStats.self, forKey: .frameStats) ?? .init(),
            viewportSurfaceRevision: try c.decodeIfPresent(UInt64.self, forKey: .viewportSurfaceRevision) ?? 0,
            windowFocused: try c.decodeIfPresent(Bool.self, forKey: .windowFocused) ?? true,
            windowMinimized: try c.decodeIfPresent(Bool.self, forKey: .windowMinimized) ?? false,
            windowOccluded: try c.decodeIfPresent(Bool.self, forKey: .windowOccluded) ?? false,
            gizmoMode: try c.decodeIfPresent(EditorGizmoMode.self, forKey: .gizmoMode) ?? .translate,
            gizmoSpace: try c.decodeIfPresent(EditorGizmoSpace.self, forKey: .gizmoSpace) ?? .local,
            viewportShadingMode: try c.decodeIfPresent(EditorViewportShadingMode.self, forKey: .viewportShadingMode) ?? .lit,
            viewportShadowsEnabled: try c.decodeIfPresent(Bool.self, forKey: .viewportShadowsEnabled) ?? true,
            viewportShadowMapResolution: try c.decodeIfPresent(UInt32.self, forKey: .viewportShadowMapResolution) ?? 1024,
            viewportMaxShadowedDirectionalLights: try c.decodeIfPresent(Int.self, forKey: .viewportMaxShadowedDirectionalLights) ?? 1,
            viewportDirectionalCascadeCount: try c.decodeIfPresent(Int.self, forKey: .viewportDirectionalCascadeCount) ?? 1,
            viewportDirectionalCascadeSplitLambda: try c.decodeIfPresent(Float.self, forKey: .viewportDirectionalCascadeSplitLambda) ?? 0.55,
            viewportShadowDebugMode: try c.decodeIfPresent(EditorViewportShadowDebugMode.self, forKey: .viewportShadowDebugMode) ?? .off,
            viewportRenderScalePercent: try c.decodeIfPresent(Int.self, forKey: .viewportRenderScalePercent) ?? 100,
            viewportInteractionDownscaleEnabled: try c.decodeIfPresent(Bool.self, forKey: .viewportInteractionDownscaleEnabled) ?? false,
            viewportRealtimeEnabled: try c.decodeIfPresent(Bool.self, forKey: .viewportRealtimeEnabled) ?? false,
            translateSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .translateSnapEnabled) ?? false,
            rotateSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .rotateSnapEnabled) ?? false,
            scaleSnapEnabled: try c.decodeIfPresent(Bool.self, forKey: .scaleSnapEnabled) ?? false,
            primarySelectBehavior: decodedPrimarySelectBehavior ?? legacyPrimarySelectBehavior ?? .subtract,
            themeMode: decodedPresentation?.themeMode ?? legacyThemeMode ?? .dark,
            language: decodedPresentation?.language ?? legacyLanguage ?? .system,
            vsyncMode: try c.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) ?? .enabled,
            uiRefreshRevision: decodedPresentation?.revision ?? legacyRevision ?? 0,
            activeAssetDrag: try c.decodeIfPresent(EditorAssetDragPayload.self, forKey: .activeAssetDrag),
            inspectorCollapsedSectionIDs: try c.decodeIfPresent(Set<String>.self, forKey: .inspectorCollapsedSectionIDs) ?? [],
            pendingConfirmationRequest: try c.decodeIfPresent(ConfirmationRequestBatch.self, forKey: .pendingConfirmationRequest),
            capabilitySettings: try c.decodeIfPresent(EditorCapabilitySettings.self,
                                                       forKey: .capabilitySettings) ?? .default,
            aiStatusMessage: try c.decodeIfPresent(String.self, forKey: .aiStatusMessage),
            aiWarnings: try c.decodeIfPresent([String].self, forKey: .aiWarnings) ?? [],
            consoleEntries: try c.decodeIfPresent([EditorConsoleEntry].self, forKey: .consoleEntries) ?? [],
            nextConsoleEntryID: try c.decodeIfPresent(UInt64.self, forKey: .nextConsoleEntryID) ?? 1
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
        try c.encode(frameStats, forKey: .frameStats)
        try c.encode(viewportSurfaceRevision, forKey: .viewportSurfaceRevision)
        try c.encode(windowFocused, forKey: .windowFocused)
        try c.encode(windowMinimized, forKey: .windowMinimized)
        try c.encode(windowOccluded, forKey: .windowOccluded)
        try c.encode(gizmoMode, forKey: .gizmoMode)
        try c.encode(gizmoSpace, forKey: .gizmoSpace)
        try c.encode(viewportShadingMode, forKey: .viewportShadingMode)
        try c.encode(viewportShadowsEnabled, forKey: .viewportShadowsEnabled)
        try c.encode(viewportShadowMapResolution, forKey: .viewportShadowMapResolution)
        try c.encode(viewportMaxShadowedDirectionalLights, forKey: .viewportMaxShadowedDirectionalLights)
        try c.encode(viewportDirectionalCascadeCount, forKey: .viewportDirectionalCascadeCount)
        try c.encode(viewportDirectionalCascadeSplitLambda, forKey: .viewportDirectionalCascadeSplitLambda)
        try c.encode(viewportShadowDebugMode, forKey: .viewportShadowDebugMode)
        try c.encode(viewportRenderScalePercent, forKey: .viewportRenderScalePercent)
        try c.encode(viewportInteractionDownscaleEnabled, forKey: .viewportInteractionDownscaleEnabled)
        try c.encode(viewportRealtimeEnabled, forKey: .viewportRealtimeEnabled)
        try c.encode(translateSnapEnabled, forKey: .translateSnapEnabled)
        try c.encode(rotateSnapEnabled, forKey: .rotateSnapEnabled)
        try c.encode(scaleSnapEnabled, forKey: .scaleSnapEnabled)
        try c.encode(primarySelectBehavior, forKey: .primarySelectBehavior)
        try c.encode(presentation, forKey: .presentation)
        try c.encode(themeMode, forKey: .themeMode)
        try c.encode(language, forKey: .language)
        try c.encode(uiRefreshRevision, forKey: .uiRefreshRevision)
        try c.encode(vsyncMode, forKey: .vsyncMode)
        try c.encodeIfPresent(activeAssetDrag, forKey: .activeAssetDrag)
        try c.encode(inspectorCollapsedSectionIDs, forKey: .inspectorCollapsedSectionIDs)
        try c.encodeIfPresent(pendingConfirmationRequest, forKey: .pendingConfirmationRequest)
        try c.encode(capabilitySettings, forKey: .capabilitySettings)
        try c.encodeIfPresent(aiStatusMessage, forKey: .aiStatusMessage)
        try c.encode(aiWarnings, forKey: .aiWarnings)
        try c.encode(consoleEntries, forKey: .consoleEntries)
        try c.encode(nextConsoleEntryID, forKey: .nextConsoleEntryID)
    }

    public static func sanitizedShadowMapResolution(_ value: UInt32) -> UInt32 {
        min(max(value, 128), 4096)
    }

    public static func sanitizedMaxShadowedDirectionalLights(_ value: Int) -> Int {
        min(max(value, 0), 4)
    }

    public static func sanitizedDirectionalCascadeCount(_ value: Int) -> Int {
        min(max(value, 1), 4)
    }

    public static func sanitizedDirectionalCascadeSplitLambda(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    public static func sanitizedRenderScalePercent(_ value: Int) -> Int {
        min(max(value, 25), 200)
    }

    mutating func appendFrameStatsHistory(_ stats: EditorFrameStats) {
        let sampleIndex = (frameStatsHistory.last?.sampleIndex ?? 0) &+ 1
        frameStatsHistory.append(
            EditorFrameStatsHistorySample(sampleIndex: sampleIndex,
                                          frameIndex: frameIndex,
                                          stats: stats)
        )
        if frameStatsHistory.count > Self.maxFrameStatsHistorySamples {
            frameStatsHistory.removeFirst(frameStatsHistory.count - Self.maxFrameStatsHistorySamples)
        }
    }
}

public struct EditorPendingCloseRequest: Equatable, Sendable {
    /// Window the OS asked to close; `nil` when the whole app is quitting.
    public var windowID: UInt32?

    public init(windowID: UInt32?) {
        self.windowID = windowID
    }
}

/// Frame timing and performance statistics for the Editor viewport.
///
/// Mirrors the data shown in Unreal Engine's "stat unit" panel:
/// - Frame time breakdown (frame rate, ms per frame)
/// - CPU phase timings (input, simulation, render prepare, render submit)
/// - GPU timings (submit + present)
/// - Render statistics (draw calls, pass count, etc.)
public struct EditorFrameStats: Sendable, Equatable, Codable {
    /// Total wall-clock time for the last completed frame in seconds.
    public var frameSeconds: Double
    /// Frames per second (1 / frameSeconds), 0 if frameSeconds is 0.
    public var fps: Double
    /// Total frame time in milliseconds.
    public var frameMs: Double

    // MARK: - CPU Phase Timings
    /// Time spent processing input events this frame (seconds).
    public var inputSeconds: Double
    /// Time spent in scene simulation this frame (seconds).
    public var simulationSeconds: Double
    /// Time spent preparing GPU render data this frame (seconds).
    public var renderPrepareSeconds: Double
    /// Time spent encoding and submitting GPU commands this frame (seconds).
    public var renderSubmitSeconds: Double

    // MARK: - GPU / Present
    /// Time spent in GPU submit + present this frame (seconds).
    public var gpuPresentSeconds: Double

    // MARK: - Render Stats
    public var drawCallCount: Int
    public var passCount: Int
    public var renderBundleCount: Int
    public var shadowedLightCount: Int
    public var shadowCascadeCount: Int
    public var shadowMapResolution: UInt32
    /// Time spent in CPU skybox encoding (nanoseconds).
    public var cpuSkyboxEncodeNS: UInt64
    /// Time spent in CPU base pass encoding (nanoseconds).
    public var cpuBaseEncodeNS: UInt64
    /// Time spent in CPU post-process encoding (nanoseconds).
    public var cpuPostProcessEncodeNS: UInt64

    public var cpuWorkSeconds: Double {
        inputSeconds + simulationSeconds + renderPrepareSeconds + renderSubmitSeconds
    }

    public var workSeconds: Double {
        cpuWorkSeconds + gpuPresentSeconds
    }

    public var workMs: Double {
        workSeconds * 1000
    }

    public var pacingGapSeconds: Double {
        max(0, frameSeconds - workSeconds)
    }

    public var pacingGapMs: Double {
        pacingGapSeconds * 1000
    }

    public var isFramePacingDominated: Bool {
        guard workSeconds > 0 else { return frameSeconds > 0.05 }
        return pacingGapSeconds > max(workSeconds, 1.0 / 60.0)
    }

    public var workFPS: Double {
        workSeconds > 0 ? 1.0 / workSeconds : 0
    }

    public init(
        frameSeconds: Double = 0,
        inputSeconds: Double = 0,
        simulationSeconds: Double = 0,
        renderPrepareSeconds: Double = 0,
        renderSubmitSeconds: Double = 0,
        gpuPresentSeconds: Double = 0,
        drawCallCount: Int = 0,
        passCount: Int = 0,
        renderBundleCount: Int = 0,
        shadowedLightCount: Int = 0,
        shadowCascadeCount: Int = 0,
        shadowMapResolution: UInt32 = 0,
        cpuSkyboxEncodeNS: UInt64 = 0,
        cpuBaseEncodeNS: UInt64 = 0,
        cpuPostProcessEncodeNS: UInt64 = 0
    ) {
        self.frameSeconds = frameSeconds
        self.fps = frameSeconds > 0 ? 1.0 / frameSeconds : 0
        self.frameMs = frameSeconds * 1000
        self.inputSeconds = inputSeconds
        self.simulationSeconds = simulationSeconds
        self.renderPrepareSeconds = renderPrepareSeconds
        self.renderSubmitSeconds = renderSubmitSeconds
        self.gpuPresentSeconds = gpuPresentSeconds
        self.drawCallCount = drawCallCount
        self.passCount = passCount
        self.renderBundleCount = renderBundleCount
        self.shadowedLightCount = shadowedLightCount
        self.shadowCascadeCount = shadowCascadeCount
        self.shadowMapResolution = shadowMapResolution
        self.cpuSkyboxEncodeNS = cpuSkyboxEncodeNS
        self.cpuBaseEncodeNS = cpuBaseEncodeNS
        self.cpuPostProcessEncodeNS = cpuPostProcessEncodeNS
    }
}

public struct EditorFrameStatsHistorySample: Sendable, Equatable, Codable {
    public var sampleIndex: UInt64
    public var frameIndex: UInt64
    public var stats: EditorFrameStats

    public init(sampleIndex: UInt64,
                frameIndex: UInt64,
                stats: EditorFrameStats) {
        self.sampleIndex = sampleIndex
        self.frameIndex = frameIndex
        self.stats = stats
    }
}
