import Foundation

public struct ACESConfig: Sendable {
    public let configPreset: ACESConfigPreset
    public let workingSpace: ACESColorSpace
    public let displayTransform: ACESDisplayTransform
    public let viewTransform: ACESViewTransform

    public init(
        preset: ACESConfigPreset = .studio,
        workingSpace: ACESColorSpace = .acesCG,
        display: ACESDisplayTransform = .sRGB,
        view: ACESViewTransform = .unToneMapped
    ) {
        self.configPreset = preset
        self.workingSpace = workingSpace
        self.displayTransform = display
        self.viewTransform = view
    }

    public var colorPipelineDescription: String {
        "\(configPreset.rawValue) / \(workingSpace.rawValue) → " +
        "\(displayTransform.rawValue) (\(viewTransform.rawValue))"
    }
}

public enum ACESConfigPreset: String, Sendable, CaseIterable {
    case studio = "studio"         // ACES studio config subset
    case reference = "reference"   // Full ACES reference config
    case custom = "custom"
}

public enum ACESColorSpace: String, Sendable, CaseIterable {
    case acesCG    = "ACES - ACEScg"
    case aces2065  = "ACES - ACES2065-1"
    case acescct   = "ACEScct"
    case sceneLinear = "scene_linear"
}

public enum ACESDisplayTransform: String, Sendable, CaseIterable {
    case sRGB      = "sRGB"
    case rec709    = "Rec.709"
    case rec2020   = "Rec.2020"
    case p3DCI     = "P3-DCI"
    case p3D65     = "P3-D65"
}

public enum ACESViewTransform: String, Sendable, CaseIterable {
    case unToneMapped   = "Un-tone-mapped"
    case sdrVideo       = "SDR Video"
    case hdrVideo1000   = "HDR Video (1000 nits)"
    case hdrVideo4000   = "HDR Video (4000 nits)"
}
