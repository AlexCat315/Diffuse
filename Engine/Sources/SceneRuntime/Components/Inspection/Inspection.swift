import Foundation

public enum ComponentFieldKind: String, Codable, Sendable {
    case automatic, boolean, string, number, integer, vector3, color, json, options
}

public struct ComponentNumericPresentation: Codable, Sendable, Equatable {
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var maximumPath: [String]?
    /// Display value = stored value * scale (for example radians to degrees).
    public var scale: Double = 1
    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }
}

public struct ComponentColorPresentation: Codable, Sendable, Equatable {
    public var minimum: Double = 0
    /// RGB channel limit; nil permits HDR values. Alpha remains in 0...1.
    public var maximum: Double? = 1
    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }
}

public struct ComponentFieldVisibility: Codable, Sendable, Equatable {
    public let path: [String]
    public let values: [ComponentValue]
    public init(path: [String], values: [ComponentValue]) { self.path = path; self.values = values }
}

/// The control's stable ID is independent of the codec's string or numeric enum value.
public struct ComponentFieldChoice: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let value: ComponentValue

    public init(_ id: String, value: ComponentValue? = nil, label: String? = nil) {
        self.id = id
        self.label = label ?? ComponentFieldDescriptor.displayLabel(id)
        self.value = value ?? .string(id)
    }
}

/// Presentation metadata addresses the codec document, never a second copy of
/// the runtime model. Unspecified fields are inferred from that same document.
public struct ComponentFieldDescriptor: Codable, Sendable, Equatable {
    public let path: [String]
    public var id: String
    public var label: String
    public var kind: ComponentFieldKind = .automatic
    public var numeric = ComponentNumericPresentation()
    public var color = ComponentColorPresentation()
    /// Clearing a nullable string writes null; the codec may omit that key.
    public var isNullable = false
    public var choices: [ComponentFieldChoice] = []
    public var visibility: ComponentFieldVisibility?
    public var isReadOnly = false
    public var isAdvanced = false
    public var group: String?
    public var documentation: String?

    public init(_ path: [String], _ configure: (inout Self) -> Void = { _ in }) {
        self.path = path
        self.id = path.joined(separator: ".")
        self.label = Self.displayLabel(path.last ?? "Value")
        configure(&self)
    }

    public static func displayLabel(_ key: String) -> String {
        key.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }
}

public struct ComponentInspection: Codable, Sendable, Equatable {
    public var sectionID: String?
    public var fields: [ComponentFieldDescriptor] = []
    public var isReadOnly = false
    /// Keep inferred codec details accessible without crowding the main form.
    public var inferredFieldsAreAdvanced = false
    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    public func resolvedFields(for value: ComponentValue) -> [ComponentFieldDescriptor] {
        func infer(_ value: ComponentValue, path: [String]) -> [ComponentFieldDescriptor] {
            if case let .object(values) = value, !values.isEmpty {
                return values.keys.sorted().flatMap { infer(values[$0]!, path: path + [$0]) }
            }
            guard !path.isEmpty else { return [] }
            return [ComponentFieldDescriptor(path) { field in
                if path.count > 1 {
                    field.group = path.dropLast().map(ComponentFieldDescriptor.displayLabel).joined(separator: " / ")
                }
                switch value {
                case .bool: field.kind = .boolean
                case .string: field.kind = .string
                case .number: field.kind = .number
                case .signedInteger, .unsignedInteger: field.kind = .integer
                case let .array(values) where values.count == 3 && values.allSatisfy({ $0.numericValue != nil }):
                    field.kind = .vector3
                default: field.kind = .json
                }
            }]
        }
        let inferred = infer(value, path: [])
        let explicitPaths = fields.map(\.path)
        let resolved = fields.map { field in
            var resolved = field
            let inferredField = inferred.first { $0.path == field.path }
            if resolved.kind == .automatic {
                resolved.kind = inferredField?.kind ?? .json
            }
            resolved.group = resolved.group ?? inferredField?.group
            return resolved
        } + inferred.filter { field in
            !explicitPaths.contains { path in field.path.starts(with: path) }
        }.map { field in
            var field = field
            field.isAdvanced = inferredFieldsAreAdvanced
            return field
        }
        return resolved.map { field in
            var field = field
            field.isReadOnly = field.isReadOnly || isReadOnly
            return field
        }
    }
}

public struct ComponentDescription: Codable, Sendable, Equatable {
    public let typeID: String
    public let displayName: String
    public let category: ComponentCategory
    public let requires: [String]
    public let isUserAddable: Bool
    public let fields: [ComponentFieldDescriptor]
    public let defaults: ComponentValue?
}

public extension SceneRuntime {
    func componentDescriptions(typeID: String? = nil) -> [ComponentDescription] {
        var defaultsWorld = RuntimeWorld(componentRegistry: componentRegistry)
        let entity = defaultsWorld.createEntity()
        return componentRegistry.componentSchemas.filter { typeID == nil || $0.typeID == typeID }.map { schema in
            var world = defaultsWorld
            try? world.makeDefaultComponent(schema, for: entity)
            var context = ComponentEncodeContext(entityIndexMap: [entity: 0])
            let defaults = schema.encode(world, entity, &context)
            let sample = defaults ?? authoredInspectionSample(schema) ?? .object([:])
            return ComponentDescription(typeID: schema.typeID, displayName: schema.displayName,
                category: schema.category, requires: schema.requires, isUserAddable: schema.isUserAddable,
                fields: schema.inspection.resolvedFields(for: sample), defaults: defaults)
        }
    }

    private func authoredInspectionSample(_ schema: ComponentSchema) -> ComponentValue? {
        let entities = entities()
        var context = ComponentEncodeContext(entityIndexMap: Dictionary(uniqueKeysWithValues:
            entities.enumerated().map { ($0.element, $0.offset) }))
        return readWorld { world in
            for entity in entities {
                if let value = schema.encode(world, entity, &context) { return value }
            }
            return nil
        }
    }
}
