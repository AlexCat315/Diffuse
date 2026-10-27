public import CapabilityRuntime
public import Foundation

public struct PluginInputField: Codable, Sendable, Equatable {
    public var name: String
    public var type: PluginInputType
    public init(name: String, type: PluginInputType) { self.name = name; self.type = type }
}

/// Input metadata emitted by the TypeScript compiler, independent of executable exports.
public indirect enum PluginInputType: Codable, Sendable, Equatable {
    case bool, string, s32, f64
    case list(PluginInputType), option(PluginInputType)
    case record([PluginInputField]), enumeration([String]), oneOf([PluginInputType])
}
public struct PluginEntryContract: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONSchema
    public var inputType: PluginInputType
    public init(name: String, title: String, description: String, inputSchema: JSONSchema, inputType: PluginInputType) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.inputType = inputType
    }
}
public struct PluginContract: Codable, Sendable, Equatable {
    public var imports: [String]
    public var capabilityInputs: [PluginEntryContract]
    public init(imports: [String], capabilityInputs: [PluginEntryContract] = []) {
        self.imports = imports.sorted(); self.capabilityInputs = capabilityInputs.sorted { $0.name < $1.name }
    }
}
public enum PluginContractError: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceTooLarge, typeTooDeep
    case invalidCapabilityName(String), invalidFieldName(String), unsupportedType(String)
    public var description: String {
        switch self {
        case .sourceTooLarge: "capabilities.json exceeds 1 MiB"
        case .typeTooDeep: "capabilities.json types exceed maximum depth"
        case let .invalidCapabilityName(name): "Invalid entry point: \(name)"
        case let .invalidFieldName(name): "Invalid input field: \(name)"
        case let .unsupportedType(type): "Invalid plugin input type: \(type)"
        }
    }
}
