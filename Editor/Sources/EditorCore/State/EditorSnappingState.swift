import Foundation
import IntentRuntime

/// Owns the editor snapping state and its persistence defaults.
public struct EditorSnappingState: Codable, Sendable {
    public var translateSnapEnabled: Bool = false
    public var rotateSnapEnabled: Bool = false
    public var scaleSnapEnabled: Bool = false
    public var translateSnapStep: Float = 0.5
    public var rotateSnapStepDegrees: Float = 5
    public var scaleSnapStep: Float = 0.05

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case translateSnapEnabled
        case rotateSnapEnabled
        case scaleSnapEnabled
        case translateSnapStep
        case rotateSnapStepDegrees
        case scaleSnapStep
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translateSnapEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .translateSnapEnabled) ?? translateSnapEnabled
        rotateSnapEnabled = try container.decodeIfPresent(Bool.self, forKey: .rotateSnapEnabled) ?? rotateSnapEnabled
        scaleSnapEnabled = try container.decodeIfPresent(Bool.self, forKey: .scaleSnapEnabled) ?? scaleSnapEnabled
        translateSnapStep = try container.decodeIfPresent(Float.self, forKey: .translateSnapStep) ?? translateSnapStep
        rotateSnapStepDegrees =
            try container.decodeIfPresent(Float.self, forKey: .rotateSnapStepDegrees) ?? rotateSnapStepDegrees
        scaleSnapStep = try container.decodeIfPresent(Float.self, forKey: .scaleSnapStep) ?? scaleSnapStep
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(translateSnapEnabled, forKey: .translateSnapEnabled)
        try container.encode(rotateSnapEnabled, forKey: .rotateSnapEnabled)
        try container.encode(scaleSnapEnabled, forKey: .scaleSnapEnabled)
        try container.encode(translateSnapStep, forKey: .translateSnapStep)
        try container.encode(rotateSnapStepDegrees, forKey: .rotateSnapStepDegrees)
        try container.encode(scaleSnapStep, forKey: .scaleSnapStep)
    }

    mutating func normalize() {
        translateSnapStep = EditorState.sanitizedTranslateSnapStep(translateSnapStep)
        rotateSnapStepDegrees = EditorState.sanitizedRotateSnapStep(rotateSnapStepDegrees)
        scaleSnapStep = EditorState.sanitizedScaleSnapStep(scaleSnapStep)
    }
}
