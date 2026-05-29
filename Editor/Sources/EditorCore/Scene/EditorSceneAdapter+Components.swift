import SceneRuntime
import SIMDCompat

/// Component types the editor can add to / remove from an entity through the inspector.
/// Excludes structural components (transform, hierarchy) and ones that need extra context
/// (Constraint references two entities), which are managed through dedicated flows.
public enum EditorComponentKind: String, CaseIterable, Sendable {
    case rigidBody
    case collider
    case renderMesh
    case renderMaterial
    case camera
    case light
    case audioSource
    case audioListener
    case animationPlayer
    case particleEmitter

    public var displayName: String {
        switch self {
        case .rigidBody:       return "Rigid Body"
        case .collider:        return "Collider"
        case .renderMesh:      return "Render Mesh"
        case .renderMaterial:  return "Render Material"
        case .camera:          return "Camera"
        case .light:           return "Light"
        case .audioSource:     return "Audio Source"
        case .audioListener:   return "Audio Listener"
        case .animationPlayer: return "Animation Player"
        case .particleEmitter: return "Particle Emitter"
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
        case .renderMesh:      return scene.hasComponent(RenderMeshComponent.self, for: entity)
        case .renderMaterial:  return scene.hasComponent(RenderMaterialComponent.self, for: entity)
        case .camera:          return scene.hasComponent(CameraComponent.self, for: entity)
        case .light:           return scene.hasComponent(LightComponent.self, for: entity)
        case .audioSource:     return scene.hasComponent(AudioSource.self, for: entity)
        case .audioListener:   return scene.hasComponent(AudioListener.self, for: entity)
        case .animationPlayer: return scene.hasComponent(AnimationPlayer.self, for: entity)
        case .particleEmitter: return scene.hasComponent(ParticleEmitter.self, for: entity)
        }
    }

    /// Component kinds present on the entity, in `EditorComponentKind.allCases` order.
    public func componentKinds(on rawID: UInt64) -> [EditorComponentKind] {
        EditorComponentKind.allCases.filter { hasComponent($0, on: rawID) }
    }

    /// Kinds that can still be added to the entity (those not already present).
    public func addableComponentKinds(on rawID: UInt64) -> [EditorComponentKind] {
        EditorComponentKind.allCases.filter { !hasComponent($0, on: rawID) }
    }

    /// Adds a default-constructed component of `kind` to the entity. Returns false if the
    /// entity is unknown or already has that component (existing data is never overwritten).
    @discardableResult
    public func addComponent(_ kind: EditorComponentKind, to rawID: UInt64) -> Bool {
        guard let entity = resolveEntity(rawID), !hasComponent(kind, on: rawID) else { return false }
        switch kind {
        case .rigidBody:       _ = scene.setComponent(RigidBody(), for: entity)
        case .collider:        _ = scene.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)), for: entity)
        case .renderMesh:      _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        case .renderMaterial:  _ = scene.setComponent(RenderMaterialComponent(), for: entity)
        case .camera:          _ = scene.setComponent(CameraComponent(isActive: false), for: entity)
        case .light:           _ = scene.setComponent(LightComponent(), for: entity)
        case .audioSource:     _ = scene.setComponent(AudioSource(), for: entity)
        case .audioListener:   _ = scene.setComponent(AudioListener(), for: entity)
        case .animationPlayer: _ = scene.setComponent(AnimationPlayer(), for: entity)
        case .particleEmitter: _ = scene.setComponent(ParticleEmitter(), for: entity)
        }
        notifyRevisionChanged()
        return true
    }

    /// Removes `kind` from the entity. Returns false if the entity is unknown or did not
    /// carry that component.
    @discardableResult
    public func removeComponent(_ kind: EditorComponentKind, from rawID: UInt64) -> Bool {
        guard let entity = resolveEntity(rawID), hasComponent(kind, on: rawID) else { return false }
        switch kind {
        case .rigidBody:       _ = scene.removeComponent(RigidBody.self, from: entity)
        case .collider:        _ = scene.removeComponent(Collider.self, from: entity)
        case .renderMesh:      _ = scene.removeComponent(RenderMeshComponent.self, from: entity)
        case .renderMaterial:  _ = scene.removeComponent(RenderMaterialComponent.self, from: entity)
        case .camera:          _ = scene.removeComponent(CameraComponent.self, from: entity)
        case .light:           _ = scene.removeComponent(LightComponent.self, from: entity)
        case .audioSource:     _ = scene.removeComponent(AudioSource.self, from: entity)
        case .audioListener:   _ = scene.removeComponent(AudioListener.self, from: entity)
        case .animationPlayer: _ = scene.removeComponent(AnimationPlayer.self, from: entity)
        case .particleEmitter: _ = scene.removeComponent(ParticleEmitter.self, from: entity)
        }
        notifyRevisionChanged()
        return true
    }

    private func resolveEntity(_ rawID: UInt64) -> EntityID? {
        let entity = EntityID(index: UInt32(rawID & 0xFFFF_FFFF), generation: UInt32(rawID >> 32))
        return scene.contains(entity) ? entity : nil
    }
}
