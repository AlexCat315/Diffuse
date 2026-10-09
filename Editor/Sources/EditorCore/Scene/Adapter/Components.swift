import IntentRuntime
import SceneRuntime
import ScriptRuntime

extension EditorSceneAdapter {
    public func componentSchema(for typeID: String) -> ComponentSchema? {
        scene.componentRegistry[typeID]
    }

    public func componentDescriptions(typeID: String? = nil) -> [ComponentDescription] {
        scene.componentDescriptions(typeID: typeID)
    }

    /// Whether `kind` is currently present on the entity.
    public func hasComponent(_ kind: String, on rawID: UInt64) -> Bool {
        guard let entity = resolveEntity(rawID) else { return false }
        return scene.hasComponent(typeID: kind, for: entity)
    }

    public func componentTypeIDs(on rawID: UInt64) -> [String] {
        scene.componentRegistry.componentSchemas.filter { hasComponent($0.typeID, on: rawID) }.map(\.typeID)
    }

    public func addableComponentSchemas(on rawID: UInt64) -> [ComponentSchema] {
        scene.componentRegistry.schemas.filter { canAddComponent($0.typeID, to: rawID) }
    }

    public func addableComponentSchemas(on rawIDs: Set<UInt64>) -> [ComponentSchema] {
        guard !rawIDs.isEmpty else { return [] }
        return scene.componentRegistry.schemas.filter { schema in
            rawIDs.contains { canAddComponent(schema.typeID, to: $0) }
                && rawIDs.allSatisfy { rawID in
                    !isEntityLocked(rawID)
                        && (hasComponent(schema.typeID, on: rawID) || canAddComponent(schema.typeID, to: rawID))
                }
        }
    }

    public func commonComponentSchemas(on rawIDs: Set<UInt64>) -> [ComponentSchema] {
        guard !rawIDs.isEmpty else { return [] }
        return scene.componentRegistry.schemas.filter { schema in
            schema.isUserAddable && rawIDs.allSatisfy { hasComponent(schema.typeID, on: $0) }
        }
    }

    /// Adds a default-constructed component of `kind` to the entity. Returns false if the
    /// entity is unknown or already has that component (existing data is never overwritten).
    @discardableResult
    public func addComponent(_ kind: String, to rawID: UInt64) -> Bool {
        addComponent(kind, to: [rawID])
    }

    /// Adds the same default component to a complete selection as one history
    /// operation. Validation happens before mutation, so a stale, locked, or
    /// incompatible member rejects the whole request.
    @discardableResult
    public func addComponent(_ kind: String,
                             to rawIDs: Set<UInt64>) -> Bool {
        let orderedIDs = rawIDs.sorted()
        let missingIDs = orderedIDs.filter { !hasComponent(kind, on: $0) }
        guard isAuthoringEnabled,
              !orderedIDs.isEmpty,
              !missingIDs.isEmpty,
              orderedIDs.allSatisfy({ rawID in
                  !isEntityLocked(rawID)
                    && (hasComponent(kind, on: rawID)
                        || canAddComponent(kind, to: rawID))
              }) else { return false }

        scene.setResource(ScriptAuthoringDefaults(identifier: defaultScriptIdentifier))
        return applySceneTransaction(intentVerb: "scene.add_component", summary: "Add component",
            targetRawIDs: orderedIDs,
            mutations: missingIDs.map { .addComponent(entityID: $0, typeID: kind) }) != nil
    }

    private func canAddComponent(_ kind: String,
                                 to rawID: UInt64) -> Bool {
        guard resolveEntity(rawID) != nil,
              !hasComponent(kind, on: rawID) else { return false }
        guard let schema = scene.componentRegistry[kind], schema.isUserAddable else { return false }
        return !schema.incompatibleWith.contains { hasComponent($0, on: rawID) }
    }

    /// Removes `kind` from the entity. Returns false if the entity is unknown or did not
    /// carry that component.
    @discardableResult
    public func removeComponent(_ kind: String, from rawID: UInt64) -> Bool {
        removeComponent(kind, from: [rawID])
    }

    /// Removes a component from every selected entity as a single undo step.
    /// Every target must contain the component and be editable before any
    /// mutation is applied.
    @discardableResult
    public func removeComponent(_ kind: String,
                                from rawIDs: Set<UInt64>) -> Bool {
        let orderedIDs = rawIDs.sorted()
        guard isAuthoringEnabled,
              !orderedIDs.isEmpty,
              orderedIDs.allSatisfy({ rawID in
                  !isEntityLocked(rawID)
                    && resolveEntity(rawID) != nil
                    && hasComponent(kind, on: rawID)
              }) else { return false }
        return applySceneTransaction(intentVerb: "scene.remove_component_data", summary: "Remove component",
            targetRawIDs: orderedIDs,
            mutations: orderedIDs.map { .removeComponentData(entityID: $0, typeID: kind) }) != nil
    }

    /// Restores the selected component to its engine default on every target.
    /// Reset is deliberately atomic and undoable because it can discard many
    /// authored fields at once.
    @discardableResult
    public func resetComponent(_ kind: String,
                               on rawIDs: Set<UInt64>) -> Bool {
        let orderedIDs = rawIDs.sorted()
        guard isAuthoringEnabled,
              !orderedIDs.isEmpty,
              orderedIDs.allSatisfy({ rawID in
                  !isEntityLocked(rawID)
                    && resolveEntity(rawID) != nil
                    && hasComponent(kind, on: rawID)
              }) else { return false }
        scene.setResource(ScriptAuthoringDefaults(identifier: defaultScriptIdentifier))
        return applySceneTransaction(intentVerb: "scene.reset_component", summary: "Reset component",
            targetRawIDs: orderedIDs,
            mutations: orderedIDs.flatMap { id -> [SceneMutation] in
                [.removeComponentData(entityID: id, typeID: kind), .addComponent(entityID: id, typeID: kind)]
            }) != nil
    }

    @discardableResult
    public func resetComponent(_ kind: String,
                               on rawID: UInt64) -> Bool {
        resetComponent(kind, on: [rawID])
    }

    private func resolveEntity(_ rawID: UInt64) -> EntityID? {
        let entity = EntityID(index: UInt32(rawID & 0xFFFF_FFFF), generation: UInt32(rawID >> 32))
        return scene.contains(entity) ? entity : nil
    }

}
