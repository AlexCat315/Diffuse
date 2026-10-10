public enum ComponentCategory: String, CaseIterable, Codable, Sendable {
    case rendering, physics, gameplay, animation, audio, scripting, assets

    public var displayName: String {
        switch self {
        case .rendering: "Rendering"
        case .physics: "Physics"
        case .gameplay: "Gameplay"
        case .animation: "Animation"
        case .audio: "Audio"
        case .scripting: "Scripting"
        case .assets: "Assets"
        }
    }
}

public struct ComponentEncodeContext: Sendable {
    public var entityIndexMap: [EntityID: Int]
    public var purpose: Purpose = .authored

    public enum Purpose: Sendable { case authored, gameSave, transaction }

    public init(entityIndexMap: [EntityID: Int]) { self.entityIndexMap = entityIndexMap }
}

public struct ComponentDecodeContext: Sendable {
    public var entityMap: [Int: EntityID]

    public init(entityMap: [Int: EntityID]) { self.entityMap = entityMap }
}

/// One component's persistence and authoring operations. Closures are Sendable;
/// registrations belong to a world and copy with that world.
public struct ComponentSchema: Sendable {
    public let componentTypeID: ObjectIdentifier
    public let runtimeTypeName: String
    public let typeID: String
    public let displayName: String
    public let category: ComponentCategory
    public var requires: [String] = []
    public var incompatibleWith: [String] = []
    public var isUserAddable = true
    /// Structural values are registered for dependencies but keep their existing
    /// document fields instead of appearing in the component payload dictionary.
    public var isStructural = false
    public var inspection = ComponentInspection()
    public let has: @Sendable (RuntimeWorld, EntityID) -> Bool
    public let encode: @Sendable (RuntimeWorld, EntityID, inout ComponentEncodeContext) -> ComponentValue?
    public let decode: @Sendable (ComponentValue, EntityID, inout ComponentDecodeContext, inout RuntimeWorld) -> Void
    public var applyEdit: @Sendable (ComponentValue, EntityID, inout ComponentDecodeContext, inout RuntimeWorld) -> Void
    public var afterDuplicate: @Sendable (EntityID, inout RuntimeWorld) -> Void = { _, _ in }
    /// Canonicalizes accepted partial input before merging and codec validation.
    /// Full replacement and disk decoding remain exact and bypass this hook.
    public var normalizeChanges: (@Sendable (ComponentValue, ComponentValue) throws -> ComponentValue)?
    public var merge: @Sendable (ComponentValue, ComponentValue) throws -> ComponentValue = { try $0.merging($1) }
    public let makeDefault: @Sendable (EntityID, inout RuntimeWorld) -> Void
    public let remove: @Sendable (EntityID, inout RuntimeWorld) -> Void

    public init<Component: RuntimeComponent>(
        _ component: Component.Type,
        typeID: String,
        displayName: String,
        category: ComponentCategory,
        encode: @escaping @Sendable (RuntimeWorld, EntityID, inout ComponentEncodeContext) -> ComponentValue?,
        decode: @escaping @Sendable (ComponentValue, EntityID, inout ComponentDecodeContext, inout RuntimeWorld) -> Void,
        makeDefault: @escaping @Sendable (EntityID, inout RuntimeWorld) -> Void,
        configure: (inout ComponentSchema) -> Void = { _ in }
    ) {
        self.componentTypeID = ObjectIdentifier(component)
        self.runtimeTypeName = String(describing: component)
        self.typeID = typeID
        self.displayName = displayName
        self.category = category
        self.has = { $0.hasComponent(component, for: $1) }
        self.encode = encode
        self.decode = decode
        self.applyEdit = decode
        self.makeDefault = makeDefault
        self.remove = { entity, world in _ = world.removeComponent(component, from: entity) }
        configure(&self)
    }

    /// Adapts a value codec while preserving its existing JSON keys and defaults.
    init<Component: RuntimeComponent>(
        _ component: Component.Type,
        typeID: String,
        displayName: String,
        category: ComponentCategory,
        encode: @escaping @Sendable (Component) -> [String: Any],
        decode: @escaping @Sendable ([String: Any]) -> Component,
        makeDefault: (@Sendable (EntityID, inout RuntimeWorld) -> Void)? = nil,
        configure: (inout ComponentSchema) -> Void = { _ in }
    ) {
        self.init(component, typeID: typeID, displayName: displayName, category: category,
                  encode: { world, entity, context in
                      world.component(component, for: entity).map { ComponentValue(jsonObject: encode($0)) }
                  }, decode: { value, entity, context, world in
                      guard let dictionary = value.objectValue else { return }
                      _ = world.setComponent(decode(dictionary), for: entity)
                  }, makeDefault: makeDefault ?? { entity, world in
                      _ = world.setComponent(decode([:]), for: entity)
                  }, configure: configure)
    }
}

/// A value-owned registry. A scene may add module codecs without changing other
/// scenes, tests, or concurrent serializers. Duplicate IDs are programmer errors.
public struct ComponentRegistry: Sendable {
    public private(set) var schemas: [ComponentSchema] = []
    private var requiredSchemasByType: [ObjectIdentifier: Result<[ComponentSchema], ComponentDependencyError>] = [:]

    public init() {}

    public mutating func register(_ schema: ComponentSchema) {
        precondition(!schema.typeID.isEmpty && self[schema.typeID] == nil,
                     "Duplicate or empty component type ID: \(schema.typeID)")
        precondition(!schemas.contains { $0.componentTypeID == schema.componentTypeID },
                     "Duplicate runtime component type: \(schema.runtimeTypeName)")
        schemas.append(schema)
        // Forward declarations are allowed during registration. Rebuild plans so
        // a later registration can satisfy an earlier schema's requirements.
        requiredSchemasByType = Dictionary(uniqueKeysWithValues: schemas.map { schema in
            (schema.componentTypeID, Result { () throws(ComponentDependencyError) in
                try resolveRequirements(for: schema)
            })
        })
    }

    public subscript(typeID: String) -> ComponentSchema? { schemas.first { $0.typeID == typeID } }

    public func schema<Component: RuntimeComponent>(for type: Component.Type) -> ComponentSchema? {
        schemas.first { $0.componentTypeID == ObjectIdentifier(type) }
    }

    public var componentSchemas: [ComponentSchema] { schemas.filter { !$0.isStructural } }

    public func validateRequirements() throws {
        for schema in schemas { _ = try requiredSchemas(for: schema.typeID) }
    }

    /// Dependencies in default-construction order, excluding the requested owner.
    public func requiredSchemas(for typeID: String) throws -> [ComponentSchema] {
        guard let schema = self[typeID] else { throw ComponentDependencyError.unknownComponent(typeID) }
        return try requiredSchemasByType[schema.componentTypeID]!.get()
    }

    func requiredSchemas<Component: RuntimeComponent>(for type: Component.Type) throws -> [ComponentSchema] {
        try requiredSchemasByType[ObjectIdentifier(type)]?.get() ?? []
    }

    public func encode(_ entity: EntityID, in world: RuntimeWorld,
                       context: inout ComponentEncodeContext) -> [ManifestComponent] {
        componentSchemas.compactMap { schema in
            schema.encode(world, entity, &context).map { ManifestComponent(type: schema.typeID, value: $0) }
        }
    }

    public func decode(_ components: [ManifestComponent], onto entity: EntityID,
                       context: inout ComponentDecodeContext, in world: inout RuntimeWorld) {
        let values = Dictionary(components.map { ($0.type, $0.value) }, uniquingKeysWith: { _, last in last })
        var decoded: Set<String> = []
        // Decode explicitly authored dependencies before their owners. Otherwise
        // an owner's required default could read a dependency's temporary default
        // rather than the value supplied by this document.
        for schema in componentSchemas {
            guard values[schema.typeID] != nil else { continue }
            for candidate in ((try? requiredSchemas(for: schema.typeID)) ?? []) + [schema]
                where !candidate.isStructural {
                guard let value = values[candidate.typeID], decoded.insert(candidate.typeID).inserted else { continue }
                candidate.decode(value, entity, &context, &world)
            }
        }
    }

    private func resolveRequirements(for root: ComponentSchema) throws(ComponentDependencyError) -> [ComponentSchema] {
        var result: [ComponentSchema] = []
        var visited: Set<String> = []
        var path: [String] = []
        func visit(_ schema: ComponentSchema) throws(ComponentDependencyError) {
            if let index = path.firstIndex(of: schema.typeID) {
                throw ComponentDependencyError.cycle(Array(path[index...]) + [schema.typeID])
            }
            guard !visited.contains(schema.typeID) else { return }
            path.append(schema.typeID)
            for typeID in schema.requires {
                guard let required = self[typeID] else {
                    throw ComponentDependencyError.missingRequirement(component: schema.typeID, required: typeID)
                }
                try visit(required)
            }
            path.removeLast()
            visited.insert(schema.typeID)
            if schema.typeID != root.typeID { result.append(schema) }
        }
        try visit(root)
        return result
    }
}
