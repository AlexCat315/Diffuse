// Central catalog of all RuntimeComponent types used across SceneRuntime.
// Each component type is defined in its domain file; this file provides
// discovery metadata for editor inspectors, serialization, and debugging.

/// Identifies a component type at runtime without knowing the generic parameter.
public struct ComponentTypeID: Hashable, Sendable {
    public let name: String
    public let metatype: ObjectIdentifier

    public init<C: RuntimeComponent>(_ type: C.Type) {
        self.name = String(describing: type)
        self.metatype = ObjectIdentifier(type)
    }
}

public enum ComponentCatalog {
    /// All RuntimeComponent types registered in the system, keyed by their
    /// metatype identifier. Editor inspectors use this to discover which
    /// components an entity carries and to render the appropriate property
    /// grid for each.
    ///
    /// To register a new component type, add it to `allKnown` below.
    public static let allKnown: [ComponentTypeID] = [
        // Spatial
        ComponentTypeID(LocalTransform.self),
        ComponentTypeID(WorldTransform.self),

        // Hierarchy
        ComponentTypeID(Parent.self),
        ComponentTypeID(Children.self),

        // Physics
        ComponentTypeID(RigidBody.self),
        ComponentTypeID(Collider.self),
        ComponentTypeID(Constraint.self),

        // Scene metadata
        ComponentTypeID(SceneNameComponent.self),
        ComponentTypeID(SceneKindComponent.self),
        ComponentTypeID(AssetReferenceComponent.self),

        // Rendering
        ComponentTypeID(RenderMeshComponent.self),
        ComponentTypeID(RenderMaterialComponent.self),
        ComponentTypeID(CameraComponent.self),
        ComponentTypeID(LightComponent.self),

        // Audio
        ComponentTypeID(AudioSource.self),

        // Animation
        ComponentTypeID(AnimationPlayer.self),
    ]

    /// Number of registered component types.
    public static var count: Int { allKnown.count }

    /// Returns the `ComponentTypeID` for a given component type, if registered.
    public static func id<C: RuntimeComponent>(of type: C.Type) -> ComponentTypeID? {
        allKnown.first { $0.metatype == ObjectIdentifier(type) }
    }

    /// Names of all registered components, sorted.
    public static var componentNames: [String] {
        allKnown.map(\.name).sorted()
    }
}
