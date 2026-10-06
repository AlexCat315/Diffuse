import Foundation
import IntentRuntime

/// Owns the editor shadows state and its persistence defaults.
public struct EditorShadowsState: Codable, Sendable {
    public var enabled: Bool = true
    public var mapResolution: UInt32 = 1024
    public var maxDirectionalLights: Int = 1
    public var cascadeCount: Int = 1
    public var cascadeSplitLambda: Float = 0.55
    public var debugMode: EditorViewportShadowDebugMode = .off

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case mapResolution
        case maxDirectionalLights
        case cascadeCount
        case cascadeSplitLambda
        case debugMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        mapResolution = try container.decodeIfPresent(UInt32.self, forKey: .mapResolution) ?? mapResolution
        maxDirectionalLights =
            try container.decodeIfPresent(Int.self, forKey: .maxDirectionalLights) ?? maxDirectionalLights
        cascadeCount = try container.decodeIfPresent(Int.self, forKey: .cascadeCount) ?? cascadeCount
        cascadeSplitLambda =
            try container.decodeIfPresent(Float.self, forKey: .cascadeSplitLambda) ?? cascadeSplitLambda
        debugMode = try container.decodeIfPresent(EditorViewportShadowDebugMode.self, forKey: .debugMode) ?? debugMode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mapResolution, forKey: .mapResolution)
        try container.encode(maxDirectionalLights, forKey: .maxDirectionalLights)
        try container.encode(cascadeCount, forKey: .cascadeCount)
        try container.encode(cascadeSplitLambda, forKey: .cascadeSplitLambda)
        try container.encode(debugMode, forKey: .debugMode)
    }

    mutating func normalize() {
        mapResolution = EditorState.sanitizedShadowMapResolution(mapResolution)
        maxDirectionalLights = EditorState.sanitizedMaxShadowedDirectionalLights(maxDirectionalLights)
        cascadeCount = EditorState.sanitizedDirectionalCascadeCount(cascadeCount)
        cascadeSplitLambda = EditorState.sanitizedDirectionalCascadeSplitLambda(cascadeSplitLambda)
    }
}
