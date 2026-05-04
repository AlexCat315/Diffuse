import Foundation

public struct AOVSpec: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let channelCount: Int
    public let description: String

    public init(id: String, name: String, channelCount: Int = 3, description: String = "") {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        self.description = description
    }
}

public final class AOVRegistry: @unchecked Sendable {
    private var specs: [AOVSpec] = []

    public init() {
        registerBuiltins()
    }

    public var allSpecs: [AOVSpec] { specs }

    public func register(_ spec: AOVSpec) {
        specs.removeAll { $0.id == spec.id }
        specs.append(spec)
    }

    public func spec(id: String) -> AOVSpec? {
        specs.first { $0.id == id }
    }

    public var totalChannelCount: Int {
        specs.reduce(0) { $0 + $1.channelCount }
    }

    private func registerBuiltins() {
        register(AOVSpec(id: "beauty",       name: "Beauty",        channelCount: 4, description: "Final shaded RGBA"))
        register(AOVSpec(id: "diffuse",      name: "Diffuse",       channelCount: 3, description: "Diffuse albedo"))
        register(AOVSpec(id: "specular",     name: "Specular",      channelCount: 3, description: "Specular reflection"))
        register(AOVSpec(id: "depth",        name: "Depth",         channelCount: 1, description: "World-space depth"))
        register(AOVSpec(id: "normal",       name: "Normal",        channelCount: 3, description: "World-space normals"))
        register(AOVSpec(id: "cryptomatte",  name: "Cryptomatte",   channelCount: 4, description: "Per-object matte IDs"))
        register(AOVSpec(id: "albedo",       name: "Albedo",        channelCount: 3, description: "Base color without lighting"))
        register(AOVSpec(id: "emission",     name: "Emission",      channelCount: 3, description: "Emissive contribution"))
        register(AOVSpec(id: "ambient_occlusion", name: "Ambient Occlusion", channelCount: 1, description: "AO factor"))
        register(AOVSpec(id: "motion_vector", name: "Motion Vector", channelCount: 2, description: "Screen-space motion"))
    }
}
