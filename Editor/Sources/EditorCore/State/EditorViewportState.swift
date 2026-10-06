import Foundation
import IntentRuntime

/// Owns the editor viewport state and its persistence defaults.
public struct EditorViewportState: Codable, Sendable {
    public var surfaceRevision: UInt64 = 0
    public var cameraRevision: UInt64 = 0
    public var gizmoMode: EditorGizmoMode = .translate
    public var gizmoSpace: EditorGizmoSpace = .local
    public var shadingMode: EditorViewportShadingMode = .lit
    public var gridEnabled: Bool = true
    public var renderScalePercent: Int = 100
    public var interactionDownscaleEnabled: Bool = false
    public var realtimeEnabled: Bool = false
    public var physicsDebugOverlayOptions: EditorPhysicsDebugOverlayOptions = .all
    public var physicsDebugOverlayScope: EditorPhysicsDebugOverlayScope = .selected
    public var mode: EditorViewportMode = .scene
    public var gamePreviewResolution: EditorGamePreviewResolution = .hd720
    public var gamePreviewHUDEnabled: Bool = true
    public var gamePreviewFocused: Bool = false

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceRevision
        case gizmoMode
        case gizmoSpace
        case shadingMode
        case gridEnabled
        case renderScalePercent
        case interactionDownscaleEnabled
        case realtimeEnabled
        case physicsDebugOverlayOptions
        case physicsDebugOverlayScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceRevision = try container.decodeIfPresent(UInt64.self, forKey: .surfaceRevision) ?? surfaceRevision
        gizmoMode = try container.decodeIfPresent(EditorGizmoMode.self, forKey: .gizmoMode) ?? gizmoMode
        gizmoSpace = try container.decodeIfPresent(EditorGizmoSpace.self, forKey: .gizmoSpace) ?? gizmoSpace
        shadingMode = try container.decodeIfPresent(EditorViewportShadingMode.self, forKey: .shadingMode) ?? shadingMode
        gridEnabled = try container.decodeIfPresent(Bool.self, forKey: .gridEnabled) ?? gridEnabled
        renderScalePercent = try container.decodeIfPresent(Int.self, forKey: .renderScalePercent) ?? renderScalePercent
        interactionDownscaleEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .interactionDownscaleEnabled)
            ?? interactionDownscaleEnabled
        realtimeEnabled = try container.decodeIfPresent(Bool.self, forKey: .realtimeEnabled) ?? realtimeEnabled
        physicsDebugOverlayOptions =
            try container.decodeIfPresent(EditorPhysicsDebugOverlayOptions.self, forKey: .physicsDebugOverlayOptions)
            ?? physicsDebugOverlayOptions
        physicsDebugOverlayScope =
            try container.decodeIfPresent(EditorPhysicsDebugOverlayScope.self, forKey: .physicsDebugOverlayScope)
            ?? physicsDebugOverlayScope
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(surfaceRevision, forKey: .surfaceRevision)
        try container.encode(gizmoMode, forKey: .gizmoMode)
        try container.encode(gizmoSpace, forKey: .gizmoSpace)
        try container.encode(shadingMode, forKey: .shadingMode)
        try container.encode(gridEnabled, forKey: .gridEnabled)
        try container.encode(renderScalePercent, forKey: .renderScalePercent)
        try container.encode(interactionDownscaleEnabled, forKey: .interactionDownscaleEnabled)
        try container.encode(realtimeEnabled, forKey: .realtimeEnabled)
        try container.encode(physicsDebugOverlayOptions, forKey: .physicsDebugOverlayOptions)
        try container.encode(physicsDebugOverlayScope, forKey: .physicsDebugOverlayScope)
    }

    mutating func normalize() {
        renderScalePercent = EditorState.sanitizedRenderScalePercent(renderScalePercent)
        physicsDebugOverlayOptions = physicsDebugOverlayOptions.intersection(.all)
    }
}
