import Foundation

/// A reusable entity template captured from a scene subtree (a root plus all of its
/// descendants, with their transforms and components). Prefabs are stored as the same
/// relocatable JSON document the scene serializer produces, so they round-trip to disk
/// as assets and can be instantiated any number of times into any scene.
public struct Prefab: Sendable, Equatable {
    /// Serialized subtree. Entity 0 is always the prefab root; `parent` cross-references
    /// stay inside the subtree, so the captured root has no parent of its own.
    public let data: Data

    public init(data: Data) { self.data = data }

    /// Captures the subtree rooted at `root` (root + descendants, depth-first) into a prefab.
    /// Returns `nil` if `root` is not part of `scene` or is a runtime destruction fragment.
    public static func capture(from scene: SceneRuntime, root: EntityID) throws -> Prefab? {
        guard scene.contains(root),
              scene.component(DestructibleFragment.self, for: root) == nil,
              scene.component(DestructibleRetainedFragment.self, for: root) == nil
        else { return nil }

        var ordered: [EntityID] = []
        func visit(_ entity: EntityID) {
            guard scene.component(DestructibleFragment.self, for: entity) == nil,
                  scene.component(DestructibleRetainedFragment.self, for: entity) == nil
            else { return }
            ordered.append(entity)
            for child in scene.children(of: entity) { visit(child) }
        }
        visit(root)

        var indexMap: [EntityID: Int] = [:]
        for (i, entity) in ordered.enumerated() { indexMap[entity] = i }

        // Cross-references (parent, constraint endpoints) outside the captured subtree are
        // dropped automatically since they are absent from `indexMap`.
        let entityList = ordered.map { SceneSerializer.encodeEntity($0, in: scene, entityIndexMap: indexMap) }

        let json: [String: Any] = ["version": SceneSerializer.prefabVersion, "entities": entityList]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return Prefab(data: data)
    }

    /// Instantiates the prefab into `scene`, returning the new root entity (or `nil` if the
    /// prefab is empty). When `parent` is given the new root is attached beneath it; when
    /// `transform` is given it overrides the captured root transform (Unity-style placement).
    @discardableResult
    public func instantiate(into scene: inout SceneRuntime,
                            parent: EntityID? = nil,
                            transform: LocalTransform? = nil) throws -> EntityID? {
        try instantiateEntities(into: &scene, parent: parent, transform: transform).first
    }

    /// Returns the full document-order mapping for higher-level component serializers.
    public func instantiateEntities(into scene: inout SceneRuntime,
                                    parent: EntityID? = nil,
                                    transform: LocalTransform? = nil) throws -> [EntityID] {
        try scene.withWorld {
            try instantiateEntities(into: &$0, parent: parent, transform: transform)
        }
    }

    func instantiateEntities(into scene: inout RuntimeWorld,
                             parent: EntityID? = nil,
                             transform: LocalTransform? = nil) throws -> [EntityID] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = jsonToArrayValue(json["entities"]),
              entities.allSatisfy({ $0 is [String: Any] }),
              parent.map({ scene.contains($0) }) ?? true
        else { throw SceneSerializerError.invalidFormat }
        let version = (json["version"] as? NSNumber)?.intValue ?? 0
        guard version == SceneSerializer.prefabVersion else {
            throw SceneSerializerError.unsupportedVersion(version)
        }

        let created = SceneSerializer.loadEntities(entities, into: &scene)
        guard let root = created.first else { return [] }

        if let transform { _ = scene.setLocalTransform(transform, for: root) }
        if let parent { _ = scene.setParent(parent, for: root) }
        return created
    }
}

private func jsonToArrayValue(_ value: Any?) -> [Any]? { value as? [Any] }
