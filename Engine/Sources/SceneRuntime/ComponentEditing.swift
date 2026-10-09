public extension SceneRuntime {
    func hasComponent(typeID: String, for entity: EntityID) -> Bool {
        guard let schema = componentRegistry[typeID] else { return false }
        return readWorld { schema.has($0, entity) }
    }

    mutating func duplicateComponentData(from source: EntityID, to destination: EntityID) {
        let components = componentRegistry.componentSchemas.compactMap { schema in
            componentData(schema.typeID, for: source).map { ManifestComponent(type: schema.typeID, value: $0) }
        }
        var references = Dictionary(uniqueKeysWithValues:
            entities().map { (Int(bitPattern: UInt($0.rawValue)), $0) })
        references[Int(bitPattern: UInt(source.rawValue))] = destination
        var context = ComponentDecodeContext(entityMap: references)
        withWorld { world in
            for component in components {
                guard let schema = world.componentRegistry[component.type] else { continue }
                schema.decode(component.value, destination, &context, &world)
                schema.afterDuplicate(destination, &world)
            }
        }
    }

    /// Transaction documents refer to generation-qualified entity IDs, independent
    /// of traversal order. The signed bit pattern also preserves IDs above Int.max.
    func componentData(_ typeID: String, for entity: EntityID) -> ComponentValue? {
        guard let schema = componentRegistry[typeID] else { return nil }
        var context = ComponentEncodeContext(entityIndexMap: Dictionary(uniqueKeysWithValues:
            entities().map { ($0, Int(bitPattern: UInt($0.rawValue))) }))
        context.purpose = .transaction
        return readWorld { schema.encode($0, entity, &context) }
    }

    mutating func setComponentData(_ value: ComponentValue, typeID: String,
                                  for entity: EntityID, mode: ComponentWriteMode = .replace) throws {
        guard let schema = componentRegistry[typeID] else { throw ComponentEditError.unknownType(typeID) }
        guard value.isFiniteJSON else { throw ComponentEditError.invalidValue(typeID) }
        let previous = componentData(typeID, for: entity)
        if mode == .merge, previous == nil { throw ComponentEditError.missingComponent(typeID) }
        let data = mode == .merge ? try schema.merge(previous!, value) : value
        var context = ComponentDecodeContext(entityMap: Dictionary(uniqueKeysWithValues:
            entities().map { (Int(bitPattern: UInt($0.rawValue)), $0) }))
        var edited = self
        try edited.withWorld { world in
            try world.ensureRequiredComponents(world.componentRegistry.requiredSchemas(for: typeID), for: entity)
            for other in schema.incompatibleWith {
                if let otherSchema = world.componentRegistry[other], otherSchema.has(world, entity) {
                    throw ComponentEditError.incompatibleComponent(other)
                }
            }
            schema.applyEdit(data, entity, &context, &world)
            guard schema.has(world, entity) else { throw ComponentEditError.invalidValue(typeID) }
        }
        guard edited.componentData(typeID, for: entity)?.containsFields(value) == true else {
            throw ComponentEditError.invalidValue(typeID)
        }
        self = edited
    }

    mutating func addComponent(typeID: String, for entity: EntityID) throws {
        guard let schema = componentRegistry[typeID] else { throw ComponentEditError.unknownType(typeID) }
        try withWorld { world in
            try world.makeDefaultComponent(schema, for: entity)
        }
    }

    mutating func removeComponentData(typeID: String, for entity: EntityID) throws {
        guard let schema = componentRegistry[typeID] else { throw ComponentEditError.unknownType(typeID) }
        try withWorld { world in
            guard schema.has(world, entity) else { throw ComponentEditError.missingComponent(typeID) }
            schema.remove(entity, &world)
        }
    }
}
