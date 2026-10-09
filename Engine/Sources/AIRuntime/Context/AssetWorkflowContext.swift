import Foundation

/// Asset authoring does not imply a film sequence or interactive gameplay.
public struct AssetWorkflowContext: Sendable, Equatable, Codable {
    public var intent: String = "Create and render reusable 3D assets"

    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    var systemPromptSection: String {
        "Workflow: 3D asset creation\nAuthoring intent: \(intent)\nFocus on scene composition, materials, lighting and asset quality. Only use available capabilities; do not claim geometry, UV or rig editing tools that are not registered."
    }
}
