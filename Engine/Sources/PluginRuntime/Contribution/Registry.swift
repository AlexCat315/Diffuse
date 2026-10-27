import Foundation

public struct ContributionPointID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.range(of: #"^cove\.[a-z][a-zA-Z0-9]*(?:\.[a-z][a-zA-Z0-9]*)*/v[1-9][0-9]*$"#,
                             options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let id = Self(rawValue: value) else {
            throw PluginManifestValidationError.invalidContribution(value)
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

/// Domains implement their own descriptor and validation. Plugin authors only
/// supply JSON and ordinary capability functions.
public protocol ContributionPointSpec: Sendable {
    associatedtype Descriptor: Codable & Sendable
    static var id: String { get }
    static func validate(_ descriptor: Descriptor, host: PluginHostPermissions) throws
    static func validateRuntime(_ descriptor: Descriptor, contract: PluginContract?) throws
}

extension ContributionPointSpec {
    public static func validateRuntime(_ descriptor: Descriptor, contract: PluginContract?) throws {}
}

public struct ContributionDescriptor: Codable, Sendable, Equatable {
    private var declarations: [String: PluginJSON] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        declarations = try decoder.singleValueContainer().decode([String: PluginJSON].self)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(declarations)
    }

    public var pointIDs: [String] { declarations.keys.sorted() }

    public func decode<Point: ContributionPointSpec>(_ point: Point.Type) throws -> [Point.Descriptor] {
        guard let value = declarations[Point.id] else { return [] }
        return try JSONDecoder().decode([Point.Descriptor].self, from: JSONEncoder().encode(value))
    }

    public mutating func set<Point: ContributionPointSpec>(_ point: Point.Type,
                                                          descriptors: [Point.Descriptor]) throws {
        declarations[Point.id] = try JSONDecoder().decode(PluginJSON.self,
                                                         from: JSONEncoder().encode(descriptors))
    }

    func validate(in registry: ContributionPointRegistry, host: PluginHostPermissions) throws {
        for id in pointIDs {
            guard ContributionPointID(rawValue: id) != nil, let point = registry.points[id] else {
                throw PluginManifestValidationError.invalidContribution(id)
            }
            if case let .array(values) = declarations[id] {
                guard values.count <= 256 else { throw PluginManifestValidationError.invalidContribution(id) }
                var identifiers = Set<String>()
                for value in values {
                    if case let .object(fields) = value, case let .string(identifier) = fields["id"],
                       !identifiers.insert(identifier).inserted {
                        throw PluginManifestValidationError.invalidContribution(id)
                    }
                }
            }
            try point.validate(self, host)
        }
    }

    func validateRuntime(_ contract: PluginContract?, in registry: ContributionPointRegistry = .standard) throws {
        for id in pointIDs {
            guard let point = registry.points[id] else {
                throw PluginManifestValidationError.invalidContribution(id)
            }
            try point.validateRuntime(self, contract)
        }
    }
}

public struct ContributionPointRegistry: Sendable {
    struct Point: Sendable {
        let validate: @Sendable (ContributionDescriptor, PluginHostPermissions) throws -> Void
        let validateRuntime: @Sendable (ContributionDescriptor, PluginContract?) throws -> Void
    }
    fileprivate var points: [String: Point] = [:]

    public init() {}

    public mutating func register<Spec: ContributionPointSpec>(_ spec: Spec.Type) throws {
        guard ContributionPointID(rawValue: Spec.id) != nil, points[Spec.id] == nil else {
            throw PluginManifestValidationError.invalidContribution(Spec.id)
        }
        points[Spec.id] = Point(validate: { contributions, host in
            for descriptor in try contributions.decode(spec) {
                try Spec.validate(descriptor, host: host)
            }
        }, validateRuntime: { contributions, contract in
            for descriptor in try contributions.decode(spec) {
                try Spec.validateRuntime(descriptor, contract: contract)
            }
        })
    }

    public static let standard: ContributionPointRegistry = {
        var registry = ContributionPointRegistry()
        try! registry.register(LanguageContributionPoint.self)
        try! registry.register(VersionControlContributionPoint.self)
        try! registry.register(TaskContributionPoint.self)
        try! registry.register(AIProviderContributionPoint.self)
        try! registry.register(AgentContributionPoint.self)
        try! registry.register(ThemeContributionPoint.self)
        try! registry.register(CommandContributionPoint.self)
        try! registry.register(PanelContributionPoint.self)
        try! registry.register(MenuContributionPoint.self)
        try! registry.register(ToolbarContributionPoint.self)
        try! registry.register(DocumentViewContributionPoint.self)
        try! registry.register(AIToolContributionPoint.self)
        try! registry.register(AIContextContributionPoint.self)
        try! registry.register(AIHarnessContributionPoint.self)
        try! registry.register(PluginServiceContributionPoint.self)
        try! registry.register(PluginExtensionPointContributionPoint.self)
        try! registry.register(PluginExtensionContributionPoint.self)
        return registry
    }()
}

enum ContributionValidation {
    static func identifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil
    }

    static func title(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 80
    }

    static func fileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil
    }
}

