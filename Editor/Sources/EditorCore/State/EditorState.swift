import Foundation
import IntentRuntime

public enum PlaybackState: String, Codable, Sendable, Hashable {
    case stopped
    case playing
    case paused

    public func canTransition(to next: PlaybackState) -> Bool {
        switch (self, next) {
        case (.stopped, .playing),
             (.playing, .paused),
             (.playing, .stopped),
             (.paused, .playing),
             (.paused, .stopped):
            return true
        default:
            return false
        }
    }
}

public enum EditorWorkspaceMode: String, Codable, Sendable, Hashable {
    case level
    case scripting
    case modeling
    case animation

    public var isGameWorkspace: Bool { self == .level || self == .scripting }
    public var title: String {
        switch self {
        case .level: "Game Engine · Level Editing"
        case .scripting: "Game Engine · Script Development"
        case .modeling: "3D Film Engine · Modeling and Rendering"
        case .animation: "3D Film Engine · Animation"
        }
    }
}

public enum EditorLayoutPreset: String, Codable, Sendable, Hashable {
    case scriptingDefault
    case levelWorkbench
    case levelDefault
    case levelCinematics
    case modelingDefault
    case modelingSculpt
    case animationDefault
    case animationSequencer

    public var mode: EditorWorkspaceMode {
        switch self {
        case .scriptingDefault: return .scripting
        case .levelWorkbench, .levelDefault, .levelCinematics:
            return .level
        case .modelingDefault, .modelingSculpt:
            return .modeling
        case .animationDefault, .animationSequencer:
            return .animation
        }
    }

    public var title: String {
        switch self {
        case .scriptingDefault: return "Game: Scripting"
        case .levelWorkbench:
            return "Level: Workbench"
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
        case .scripting:
            return .scriptingDefault
        case .modeling:
            return .modelingDefault
        case .animation:
            return .animationDefault
        }
    }

    public static func presets(for mode: EditorWorkspaceMode) -> [EditorLayoutPreset] {
        switch mode {
        case .scripting: return [.scriptingDefault]
        case .level:
            return [.levelWorkbench, .levelDefault, .levelCinematics]
        case .modeling:
            return [.modelingDefault, .modelingSculpt]
        case .animation:
            return [.animationDefault, .animationSequencer]
        }
    }
}

public enum EditorGizmoMode: String, Codable, Sendable, Hashable {
    case none
    case boxSelect
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
    public var target: EditorIssueTarget?
    public var nextStep: String?

    public init(id: UInt64,
                severity: EditorConsoleSeverity = .info,
                message: String,
                detail: String? = nil, target: EditorIssueTarget? = nil,
                nextStep: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.detail = detail
        self.target = target
        self.nextStep = nextStep
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

public struct EditorPhysicsDebugOverlayOptions: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shapes = Self(rawValue: 1 << 0)
    public static let bounds = Self(rawValue: 1 << 1)
    public static let contacts = Self(rawValue: 1 << 2)
    public static let joints = Self(rawValue: 1 << 3)
    public static let characters = Self(rawValue: 1 << 4)
    public static let all: Self = [.shapes, .bounds, .contacts, .joints, .characters]
}

public enum EditorPhysicsDebugOverlayScope: String, Codable, Sendable, Equatable {
    case selected
    case scene
}

public struct EditorState: Codable, Sendable {
    public static let maxFrameStatsHistorySamples = 240
    public static let maxParticleDiagnosticsHistorySamples = 240

    public var selection = EditorSelectionState()
    public var document = EditorDocumentState()
    public var timing = EditorTimingState()
    public var workspace = EditorWorkspaceState()
    public var window = EditorWindowState()
    public var viewport = EditorViewportState()
    public var shadows = EditorShadowsState()
    public var snapping = EditorSnappingState()
    public var assistant = EditorAssistantState()
    public var output = EditorOutputState()
    public var navigation = EditorNavigationState()
    public var presentation = EditorPresentationState(themeMode: .dark, language: .system, revision: 0)
    public var vsyncMode: EditorVSyncMode = .enabled

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
        normalize()
    }

    private mutating func normalize() {
        timing.normalize()
        viewport.normalize()
        shadows.normalize()
        snapping.normalize()
        output.normalize()
    }

    public var shouldRender: Bool { !window.minimized && !window.occluded }
    public var sceneDirty: Bool { document.sceneRecoveryPending || document.sceneRevision != document.lastSavedSceneRevision }
    public var themeMode: EditorThemeMode { presentation.themeMode }
    public var language: EditorLanguage { presentation.language }
    public var uiRefreshRevision: UInt64 { presentation.revision }

    private enum CodingKeys: String, CodingKey {
        case selection
        case document
        case timing
        case workspace
        case window
        case viewport
        case shadows
        case snapping
        case assistant
        case output
        case navigation
        case presentation, vsyncMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = try container.decodeIfPresent(EditorSelectionState.self, forKey: .selection) ?? selection
        document = try container.decodeIfPresent(EditorDocumentState.self, forKey: .document) ?? document
        timing = try container.decodeIfPresent(EditorTimingState.self, forKey: .timing) ?? timing
        workspace = try container.decodeIfPresent(EditorWorkspaceState.self, forKey: .workspace) ?? workspace
        window = try container.decodeIfPresent(EditorWindowState.self, forKey: .window) ?? window
        viewport = try container.decodeIfPresent(EditorViewportState.self, forKey: .viewport) ?? viewport
        shadows = try container.decodeIfPresent(EditorShadowsState.self, forKey: .shadows) ?? shadows
        snapping = try container.decodeIfPresent(EditorSnappingState.self, forKey: .snapping) ?? snapping
        assistant = try container.decodeIfPresent(EditorAssistantState.self, forKey: .assistant) ?? assistant
        output = try container.decodeIfPresent(EditorOutputState.self, forKey: .output) ?? output
        navigation = try container.decodeIfPresent(EditorNavigationState.self, forKey: .navigation) ?? navigation
        presentation = try container.decodeIfPresent(EditorPresentationState.self, forKey: .presentation) ?? presentation
        vsyncMode = try container.decodeIfPresent(EditorVSyncMode.self, forKey: .vsyncMode) ?? vsyncMode
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection, forKey: .selection)
        try container.encode(document, forKey: .document)
        try container.encode(timing, forKey: .timing)
        try container.encode(workspace, forKey: .workspace)
        try container.encode(window, forKey: .window)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(snapping, forKey: .snapping)
        try container.encode(assistant, forKey: .assistant)
        try container.encode(output, forKey: .output)
        try container.encode(navigation, forKey: .navigation)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(vsyncMode, forKey: .vsyncMode)
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
        let sampleIndex = (timing.frameStatsHistory.last?.sampleIndex ?? 0) &+ 1
        timing.frameStatsHistory.append(
            EditorFrameStatsHistorySample(sampleIndex: sampleIndex,
                                          frameIndex: timing.frameIndex,
                                          stats: stats)
        )
        if timing.frameStatsHistory.count > Self.maxFrameStatsHistorySamples {
            timing.frameStatsHistory.removeFirst(timing.frameStatsHistory.count - Self.maxFrameStatsHistorySamples)
        }
    }

    mutating func appendParticleDiagnosticsHistory(_ sample: EditorParticleDiagnosticsSample) {
        timing.particleDiagnosticsHistory.append(sample)
        if timing.particleDiagnosticsHistory.count > Self.maxParticleDiagnosticsHistorySamples {
            timing.particleDiagnosticsHistory.removeFirst(
                timing.particleDiagnosticsHistory.count - Self.maxParticleDiagnosticsHistorySamples
            )
        }
    }
}

public enum EditorPendingDocumentAction: Equatable, Sendable {
    case close
    case closeProject
    case newScene
    case openScene
}

public struct EditorPendingCloseRequest: Equatable, Sendable {
    public var action: EditorPendingDocumentAction
    /// Window the OS asked to close; `nil` when the whole app is quitting.
    public var windowID: UInt32?
    /// Scene selected by an Open dialog. Stored as a path to keep presentation
    /// state independent from any platform file-dialog type.
    public var documentPath: String?

    public init(action: EditorPendingDocumentAction = .close,
                windowID: UInt32? = nil,
                documentPath: String? = nil) {
        self.action = action
        self.windowID = windowID
        self.documentPath = documentPath
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

public struct EditorParticleDiagnosticsSample: Sendable, Equatable, Codable {
    public var sampleIndex: UInt64
    public var frameIndex: UInt64
    public var simulatedDeltaTime: Float
    public var emitterCount: Int
    public var activeEmitterCount: Int
    public var liveParticleCount: Int
    public var liveParticleLimit: Int
    public var requestedSpawnCount: Int
    public var spawnedParticleCount: Int
    public var droppedSpawnCount: Int
    public var capacityLimitedSpawnCount: Int
    public var spawnBudgetLimitedCount: Int
    public var spawnBudgetConsumedCount: Int
    public var spawnBudgetLimit: Int
    public var eventRequestedSpawnCount: Int
    public var eventDroppedSpawnCount: Int
    public var droppedReadbackEventCount: Int
    public var cpuRenderInstanceCount: Int
    public var gpuRenderInstanceCount: Int
    public var cpuBatchCount: Int
    public var gpuBatchCount: Int
    public var gpuSimulationParticleCount: Int
    public var gpuWorkgroupCount: Int
    public var gpuSortItemCount: Int
    public var gpuSortPaddedItemCount: Int

    public init(sampleIndex: UInt64,
                frameIndex: UInt64,
                simulatedDeltaTime: Float,
                emitterCount: Int,
                activeEmitterCount: Int,
                liveParticleCount: Int,
                liveParticleLimit: Int,
                requestedSpawnCount: Int,
                spawnedParticleCount: Int,
                droppedSpawnCount: Int,
                capacityLimitedSpawnCount: Int,
                spawnBudgetLimitedCount: Int,
                spawnBudgetConsumedCount: Int,
                spawnBudgetLimit: Int,
                eventRequestedSpawnCount: Int,
                eventDroppedSpawnCount: Int,
                droppedReadbackEventCount: Int,
                cpuRenderInstanceCount: Int,
                gpuRenderInstanceCount: Int,
                cpuBatchCount: Int,
                gpuBatchCount: Int,
                gpuSimulationParticleCount: Int,
                gpuWorkgroupCount: Int,
                gpuSortItemCount: Int,
                gpuSortPaddedItemCount: Int) {
        self.sampleIndex = sampleIndex
        self.frameIndex = frameIndex
        self.simulatedDeltaTime = simulatedDeltaTime
        self.emitterCount = max(0, emitterCount)
        self.activeEmitterCount = max(0, activeEmitterCount)
        self.liveParticleCount = max(0, liveParticleCount)
        self.liveParticleLimit = max(0, liveParticleLimit)
        self.requestedSpawnCount = max(0, requestedSpawnCount)
        self.spawnedParticleCount = max(0, spawnedParticleCount)
        self.droppedSpawnCount = max(0, droppedSpawnCount)
        self.capacityLimitedSpawnCount = max(0, capacityLimitedSpawnCount)
        self.spawnBudgetLimitedCount = max(0, spawnBudgetLimitedCount)
        self.spawnBudgetConsumedCount = max(0, spawnBudgetConsumedCount)
        self.spawnBudgetLimit = max(0, spawnBudgetLimit)
        self.eventRequestedSpawnCount = max(0, eventRequestedSpawnCount)
        self.eventDroppedSpawnCount = max(0, eventDroppedSpawnCount)
        self.droppedReadbackEventCount = max(0, droppedReadbackEventCount)
        self.cpuRenderInstanceCount = max(0, cpuRenderInstanceCount)
        self.gpuRenderInstanceCount = max(0, gpuRenderInstanceCount)
        self.cpuBatchCount = max(0, cpuBatchCount)
        self.gpuBatchCount = max(0, gpuBatchCount)
        self.gpuSimulationParticleCount = max(0, gpuSimulationParticleCount)
        self.gpuWorkgroupCount = max(0, gpuWorkgroupCount)
        self.gpuSortItemCount = max(0, gpuSortItemCount)
        self.gpuSortPaddedItemCount = max(0, gpuSortPaddedItemCount)
    }
}
