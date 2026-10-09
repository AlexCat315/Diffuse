public enum ComponentDependencyError: Error, Sendable, Equatable {
    case unknownComponent(String)
    case missingRequirement(component: String, required: String)
    case cycle([String])
    case defaultUnavailable(String)
}

extension RuntimeWorld {
    /// Dependencies are insertion defaults: removing their owner leaves them in
    /// place, and inserting an owner never overwrites an existing dependency.
    mutating func ensureRequiredComponents(_ requirements: [ComponentSchema],
                                          for entity: EntityID) throws {
        let requiredIDs = Set(requirements.map(\.typeID))
        for schema in requirements {
            for other in schema.incompatibleWith {
                if requiredIDs.contains(other)
                    || componentRegistry[other].map({ $0.has(self, entity) }) == true {
                    throw ComponentEditError.incompatibleComponent(other)
                }
            }
        }
        for schema in requirements where !schema.has(self, entity) {
            schema.makeDefault(entity, &self)
            guard schema.has(self, entity) else {
                throw ComponentDependencyError.defaultUnavailable(schema.typeID)
            }
        }
    }

    /// Used by registry authoring flows so dependency failures leave no partial
    /// components or revision increments behind.
    mutating func makeDefaultComponent(_ schema: ComponentSchema, for entity: EntityID) throws {
        guard !schema.has(self, entity) else { return }
        var edited = self
        try edited.ensureRequiredComponents(componentRegistry.requiredSchemas(for: schema.typeID), for: entity)
        for other in schema.incompatibleWith {
            if let incompatible = componentRegistry[other], incompatible.has(edited, entity) {
                throw ComponentEditError.incompatibleComponent(other)
            }
        }
        schema.makeDefault(entity, &edited)
        guard schema.has(edited, entity) else { throw ComponentDependencyError.defaultUnavailable(schema.typeID) }
        self = edited
    }
}
