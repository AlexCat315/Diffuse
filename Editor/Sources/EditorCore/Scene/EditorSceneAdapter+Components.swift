import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// Component types the editor can add to / remove from an entity through the inspector.
/// Excludes structural components (transform, hierarchy) and ones that need extra context
/// (Constraint references two entities), which are managed through dedicated flows.
public enum EditorComponentKind: String, CaseIterable, Sendable {
    case rigidBody
    case collider
    case characterController
    case vehicle
    case softBody
    case cloth
    case softBodyMesh
    case destructible
    case ragdoll
    case renderMesh
    case renderMaterial
    case camera
    case light
    case audioSource
    case audioListener
    case animationPlayer
    case animationGraphPlayer
    case particleEmitter
    case script

    public var displayName: String {
        switch self {
        case .rigidBody:       return "Rigid Body"
        case .collider:        return "Collider"
        case .characterController: return "Character Controller"
        case .vehicle:         return "Vehicle"
        case .softBody:        return "Soft Body"
        case .cloth:           return "Cloth"
        case .softBodyMesh:   return "Soft Body Mesh"
        case .destructible:   return "Destructible"
        case .ragdoll:         return "Ragdoll"
        case .renderMesh:      return "Render Mesh"
        case .renderMaterial:  return "Render Material"
        case .camera:          return "Camera"
        case .light:           return "Light"
        case .audioSource:     return "Audio Source"
        case .audioListener:   return "Audio Listener"
        case .animationPlayer: return "Animation Player"
        case .animationGraphPlayer: return "Animation Graph"
        case .particleEmitter: return "Particle Emitter"
        case .script:          return "Script"
        }
    }
}

extension EditorSceneAdapter {
    /// Whether `kind` is currently present on the entity.
    public func hasComponent(_ kind: EditorComponentKind, on rawID: UInt64) -> Bool {
        guard let entity = resolveEntity(rawID) else { return false }
        switch kind {
        case .rigidBody:       return scene.hasComponent(RigidBody.self, for: entity)
        case .collider:        return scene.hasComponent(Collider.self, for: entity)
        case .characterController: return scene.hasComponent(CharacterController.self, for: entity)
        case .vehicle:         return scene.hasComponent(Vehicle.self, for: entity)
        case .softBody:        return scene.hasComponent(SoftBody.self, for: entity)
        case .cloth:           return scene.hasComponent(Cloth.self, for: entity)
        case .softBodyMesh:   return scene.hasComponent(SoftBodyMesh.self, for: entity)
        case .destructible:   return scene.hasComponent(Destructible.self, for: entity)
        case .ragdoll:         return scene.hasComponent(Ragdoll.self, for: entity)
        case .renderMesh:      return scene.hasComponent(RenderMeshComponent.self, for: entity)
        case .renderMaterial:  return scene.hasComponent(RenderMaterialComponent.self, for: entity)
        case .camera:          return scene.hasComponent(CameraComponent.self, for: entity)
        case .light:           return scene.hasComponent(LightComponent.self, for: entity)
        case .audioSource:     return scene.hasComponent(AudioSource.self, for: entity)
        case .audioListener:   return scene.hasComponent(AudioListener.self, for: entity)
        case .animationPlayer: return scene.hasComponent(AnimationPlayer.self, for: entity)
        case .animationGraphPlayer: return scene.hasComponent(AnimationGraphPlayer.self, for: entity)
        case .particleEmitter: return scene.hasComponent(ParticleEmitter.self, for: entity)
        case .script:          return scene.hasComponent(ScriptComponent.self, for: entity)
        }
    }

    /// Component kinds present on the entity, in `EditorComponentKind.allCases` order.
    public func componentKinds(on rawID: UInt64) -> [EditorComponentKind] {
        EditorComponentKind.allCases.filter { hasComponent($0, on: rawID) }
    }

    /// Kinds that can still be added to the entity (those not already present).
    public func addableComponentKinds(on rawID: UInt64) -> [EditorComponentKind] {
        EditorComponentKind.allCases.filter { kind in
            canAddComponent(kind, to: rawID)
        }
    }

    /// Component kinds that can be added to every entity in a selection. This
    /// is the safe set presented by a production multi-selection inspector.
    public func addableComponentKinds(on rawIDs: Set<UInt64>) -> [EditorComponentKind] {
        guard !rawIDs.isEmpty else { return [] }
        return EditorComponentKind.allCases.filter { kind in
            rawIDs.contains { canAddComponent(kind, to: $0) }
                && rawIDs.allSatisfy { rawID in
                    !isEntityLocked(rawID)
                        && (hasComponent(kind, on: rawID)
                            || canAddComponent(kind, to: rawID))
                }
        }
    }

    /// Component kinds shared by every entity in a selection, in stable menu
    /// order. Removing from a multi-selection never partially succeeds.
    public func commonComponentKinds(on rawIDs: Set<UInt64>) -> [EditorComponentKind] {
        guard !rawIDs.isEmpty else { return [] }
        return EditorComponentKind.allCases.filter { kind in
            rawIDs.allSatisfy { hasComponent(kind, on: $0) }
        }
    }

    /// Adds a default-constructed component of `kind` to the entity. Returns false if the
    /// entity is unknown or already has that component (existing data is never overwritten).
    @discardableResult
    public func addComponent(_ kind: EditorComponentKind, to rawID: UInt64) -> Bool {
        addComponent(kind, to: [rawID])
    }

    /// Adds the same default component to a complete selection as one history
    /// operation. Validation happens before mutation, so a stale, locked, or
    /// incompatible member rejects the whole request.
    @discardableResult
    public func addComponent(_ kind: EditorComponentKind,
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

        for rawID in missingIDs {
            guard let entity = resolveEntity(rawID) else { return false }
            addComponentUnchecked(kind, to: entity)
        }
        notifyRevisionChanged()
        return true
    }

    private func canAddComponent(_ kind: EditorComponentKind,
                                 to rawID: UInt64) -> Bool {
        guard resolveEntity(rawID) != nil,
              !hasComponent(kind, on: rawID) else { return false }
        if kind == .cloth, hasComponent(.softBodyMesh, on: rawID) { return false }
        if kind == .softBodyMesh, hasComponent(.cloth, on: rawID) { return false }
        return true
    }

    private func addComponentUnchecked(_ kind: EditorComponentKind,
                                       to entity: EntityID) {
        switch kind {
        case .rigidBody:       _ = scene.setComponent(RigidBody(), for: entity)
        case .collider:        _ = scene.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)), for: entity)
        case .characterController: _ = scene.setComponent(CharacterController(), for: entity)
        case .vehicle:         _ = scene.setComponent(Vehicle(), for: entity)
        case .softBody:        _ = scene.setComponent(SoftBody(), for: entity)
        case .cloth:           _ = scene.setComponent(Cloth.fixedTopEdge(), for: entity)
        case .softBodyMesh:
            let resourceID = scene.component(AssetReferenceComponent.self, for: entity)
                .map { "meshIndex:\($0.meshIndex)" }
            _ = scene.setComponent(SoftBodyMesh(resourceID: resourceID), for: entity)
        case .destructible:   _ = scene.setComponent(Destructible(), for: entity)
        case .ragdoll:         _ = scene.setComponent(Ragdoll(), for: entity)
        case .renderMesh:      _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        case .renderMaterial:  _ = scene.setComponent(RenderMaterialComponent(), for: entity)
        case .camera:          _ = scene.setComponent(CameraComponent(isActive: false), for: entity)
        case .light:           _ = scene.setComponent(LightComponent(), for: entity)
        case .audioSource:     _ = scene.setComponent(AudioSource(), for: entity)
        case .audioListener:   _ = scene.setComponent(AudioListener(), for: entity)
        case .animationPlayer: _ = scene.setComponent(AnimationPlayer(), for: entity)
        case .animationGraphPlayer: _ = scene.setComponent(defaultAnimationGraphPlayer(), for: entity)
        case .particleEmitter: _ = scene.setComponent(ParticleEmitter(), for: entity)
        case .script:
            _ = scene.setComponent(
                ScriptComponent(ScriptBinding(identifier: defaultScriptIdentifier)),
                for: entity
            )
        }
    }

    /// Removes `kind` from the entity. Returns false if the entity is unknown or did not
    /// carry that component.
    @discardableResult
    public func removeComponent(_ kind: EditorComponentKind, from rawID: UInt64) -> Bool {
        removeComponent(kind, from: [rawID])
    }

    /// Removes a component from every selected entity as a single undo step.
    /// Every target must contain the component and be editable before any
    /// mutation is applied.
    @discardableResult
    public func removeComponent(_ kind: EditorComponentKind,
                                from rawIDs: Set<UInt64>) -> Bool {
        let orderedIDs = rawIDs.sorted()
        guard isAuthoringEnabled,
              !orderedIDs.isEmpty,
              orderedIDs.allSatisfy({ rawID in
                  !isEntityLocked(rawID)
                    && resolveEntity(rawID) != nil
                    && hasComponent(kind, on: rawID)
              }) else { return false }
        for rawID in orderedIDs {
            guard let entity = resolveEntity(rawID) else { return false }
            removeComponentUnchecked(kind, from: entity)
        }
        notifyRevisionChanged()
        return true
    }

    /// Restores the selected component to its engine default on every target.
    /// Reset is deliberately atomic and undoable because it can discard many
    /// authored fields at once.
    @discardableResult
    public func resetComponent(_ kind: EditorComponentKind,
                               on rawIDs: Set<UInt64>) -> Bool {
        let orderedIDs = rawIDs.sorted()
        guard isAuthoringEnabled,
              !orderedIDs.isEmpty,
              orderedIDs.allSatisfy({ rawID in
                  !isEntityLocked(rawID)
                    && resolveEntity(rawID) != nil
                    && hasComponent(kind, on: rawID)
              }) else { return false }
        for rawID in orderedIDs {
            guard let entity = resolveEntity(rawID) else { return false }
            removeComponentUnchecked(kind, from: entity)
            addComponentUnchecked(kind, to: entity)
        }
        notifyRevisionChanged()
        return true
    }

    @discardableResult
    public func resetComponent(_ kind: EditorComponentKind,
                               on rawID: UInt64) -> Bool {
        resetComponent(kind, on: [rawID])
    }

    private func removeComponentUnchecked(_ kind: EditorComponentKind,
                                          from entity: EntityID) {
        switch kind {
        case .rigidBody:       _ = scene.removeComponent(RigidBody.self, from: entity)
        case .collider:        _ = scene.removeComponent(Collider.self, from: entity)
        case .characterController: _ = scene.removeComponent(CharacterController.self, from: entity)
        case .vehicle:         _ = scene.removeComponent(Vehicle.self, from: entity)
        case .softBody:        _ = scene.removeComponent(SoftBody.self, from: entity)
        case .cloth:           _ = scene.removeComponent(Cloth.self, from: entity)
        case .softBodyMesh:   _ = scene.removeComponent(SoftBodyMesh.self, from: entity)
        case .destructible:   _ = scene.removeComponent(Destructible.self, from: entity)
        case .ragdoll:         _ = scene.removeComponent(Ragdoll.self, from: entity)
        case .renderMesh:      _ = scene.removeComponent(RenderMeshComponent.self, from: entity)
        case .renderMaterial:  _ = scene.removeComponent(RenderMaterialComponent.self, from: entity)
        case .camera:          _ = scene.removeComponent(CameraComponent.self, from: entity)
        case .light:           _ = scene.removeComponent(LightComponent.self, from: entity)
        case .audioSource:     _ = scene.removeComponent(AudioSource.self, from: entity)
        case .audioListener:   _ = scene.removeComponent(AudioListener.self, from: entity)
        case .animationPlayer: _ = scene.removeComponent(AnimationPlayer.self, from: entity)
        case .animationGraphPlayer: _ = scene.removeComponent(AnimationGraphPlayer.self, from: entity)
        case .particleEmitter: _ = scene.removeComponent(ParticleEmitter.self, from: entity)
        case .script:          _ = scene.removeComponent(ScriptComponent.self, from: entity)
        }
    }

    private func resolveEntity(_ rawID: UInt64) -> EntityID? {
        let entity = EntityID(index: UInt32(rawID & 0xFFFF_FFFF), generation: UInt32(rawID >> 32))
        return scene.contains(entity) ? entity : nil
    }

    private func defaultAnimationGraphPlayer() -> AnimationGraphPlayer {
        AnimationGraphPlayer(
            graph: AnimationGraph(
                stateMachine: AnimationStateMachine(
                    initialState: "Default",
                    states: [
                        AnimationState(name: "Default", motion: .clip(nil)),
                    ]
                )
            )
        )
    }
}
