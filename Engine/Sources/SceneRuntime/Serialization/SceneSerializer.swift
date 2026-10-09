import Foundation
import SIMDCompat

public enum SceneSerializer {
    private static let currentVersion = 3

    typealias SerializationPurpose = ComponentEncodeContext.Purpose

    /// Document version stamped into captured prefabs. Shares the scene format.
    static let prefabVersion = currentVersion

    // MARK: Save

    public static func serialize(_ scene: SceneRuntime) throws -> Data {
        try serialize(scene, purpose: .authored)
    }

    static func serializeGameState(_ scene: SceneRuntime) throws -> Data {
        try serialize(scene, purpose: .gameSave)
    }

    private static func serialize(
        _ scene: SceneRuntime,
        purpose: SerializationPurpose
    ) throws -> Data {
        let entities = scene.entities().filter { entity in
            purpose == .gameSave
                || (scene.component(DestructibleFragment.self, for: entity) == nil
                    && scene.component(DestructibleRetainedFragment.self, for: entity) == nil)
        }
        var entityIndexMap: [EntityID: Int] = [:]
        for (i, entity) in entities.enumerated() {
            entityIndexMap[entity] = i
        }
        let entityList = entities.map {
            encodeEntity(
                $0,
                in: scene,
                entityIndexMap: entityIndexMap,
                purpose: purpose
            )
        }
        let json: [String: Any] = ["version": currentVersion, "entities": entityList]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Encodes one entity to a JSON dictionary. All entity cross-references (parent,
    /// constraint endpoints) are stored as positions within `entityIndexMap` rather than
    /// `EntityID`s, so the document is relocatable. References to entities outside the map
    /// (e.g. a constraint endpoint outside a captured prefab subtree) are dropped.
    static func encodeEntity(
        _ entity: EntityID,
        in scene: SceneRuntime,
        entityIndexMap: [EntityID: Int],
        purpose: SerializationPurpose = .authored
    ) -> [String: Any] {
        var obj: [String: Any] = [:]

        // Name / kind
        if let name = scene.component(SceneNameComponent.self, for: entity) {
            obj["name"] = name.value
        }
        if let kind = scene.component(SceneKindComponent.self, for: entity) {
            obj["kind"] = kind.value
        }

        // Parent (store index, not EntityID)
        if let parentIndex = scene.component(Parent.self, for: entity).flatMap({ entityIndexMap[$0.entity] }) {
            obj["parent"] = parentIndex
        }

        // Transform — decompose into translation + rotation + scale
        if let t = scene.component(LocalTransform.self, for: entity) {
            let translation = SIMD3<Float>(t.matrix.columns.3.x, t.matrix.columns.3.y, t.matrix.columns.3.z)
            let c0 = SIMD3<Float>(t.matrix.columns.0.x, t.matrix.columns.0.y, t.matrix.columns.0.z)
            let c1 = SIMD3<Float>(t.matrix.columns.1.x, t.matrix.columns.1.y, t.matrix.columns.1.z)
            let c2 = SIMD3<Float>(t.matrix.columns.2.x, t.matrix.columns.2.y, t.matrix.columns.2.z)
            let sx = simd_length(c0); let sy = simd_length(c1); let sz = simd_length(c2)
            let r = simd_float3x3(columns: (c0 / (sx > 1e-6 ? sx : 1),
                                            c1 / (sy > 1e-6 ? sy : 1),
                                            c2 / (sz > 1e-6 ? sz : 1)))
            let quat = simd_quatf(r)
            obj["translation"] = vec3ToJSON(translation)
            obj["rotation"] = vec4ToJSON(quat.vector)
            obj["scale"] = vec3ToJSON(SIMD3<Float>(sx, sy, sz))
        }

        var context = ComponentEncodeContext(entityIndexMap: entityIndexMap)
        context.purpose = purpose
        let components = componentDocument(for: entity, in: scene, context: &context)
        var comps = Dictionary(uniqueKeysWithValues: components.map { ($0.type, $0.value.jsonObject) })
        let destructionRuntime = scene.resource(DestructionRuntimeStateResource.self)
        let destructionSource = destructionRuntime?.sources[entity]
        if purpose == .gameSave {
            if let destructionSource {
                comps["destructionRuntimeSource"] = serializeDestructionRuntimeSource(
                    destructionSource
                )
            }
            if let fragment = scene.component(DestructibleFragment.self, for: entity),
               let sourceIndex = entityIndexMap[fragment.sourceEntity] {
                comps["destructibleFragment"] = serializeDestructibleFragment(
                    fragment,
                    sourceIndex: sourceIndex,
                    entity: entity,
                    runtime: destructionRuntime
                )
            }
            if let retained = scene.component(DestructibleRetainedFragment.self, for: entity),
               let sourceIndex = entityIndexMap[retained.sourceEntity] {
                comps["destructibleRetainedFragment"] = [
                    "sourceEntity": sourceIndex,
                    "fragmentID": Int(retained.fragmentID),
                ]
            }
        }
        if !comps.isEmpty { obj["components"] = comps }

        return obj
    }

    /// The component representation shared by runtime and editor documents.
    /// Reference indices are supplied by the owning document, including prefab subsets.
    public static func componentDocument(
        for entity: EntityID, in scene: SceneRuntime, context: inout ComponentEncodeContext
    ) -> [ManifestComponent] {
        scene.readWorld { $0.componentRegistry.encode(entity, in: $0, context: &context) }
    }

    public static func applyComponentDocument(
        _ components: [ManifestComponent], to entity: EntityID,
        in scene: inout SceneRuntime, context: inout ComponentDecodeContext
    ) {
        let registry = scene.componentRegistry
        scene.withWorld { registry.decode(components, onto: entity, context: &context, in: &$0) }
    }

    // MARK: Load

    /// Deserializes authored entities into `scene` and returns the entities created by
    /// this document in document order. Returning the mapping lets serializers in
    /// higher-level modules restore their own components without guessing from the
    /// world's slot order (which is unsafe when the destination already has entities).
    @discardableResult
    public static func deserialize(_ data: Data, into scene: inout SceneRuntime) throws -> [EntityID] {
        try deserialize(data, into: &scene, restoreGameState: false)
    }

    @discardableResult
    static func deserializeGameState(_ data: Data, into scene: inout SceneRuntime) throws -> [EntityID] {
        try deserialize(data, into: &scene, restoreGameState: true)
    }

    private static func deserialize(
        _ data: Data,
        into scene: inout SceneRuntime,
        restoreGameState: Bool
    ) throws -> [EntityID] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = jsonToArray(json["entities"])
        else { throw SceneSerializerError.invalidFormat }
        // A partially decoded entity array cannot preserve document indices used by
        // parents, constraints, ragdolls, and higher-level component serializers.
        // Reject it instead of silently compacting the entity map and misattaching data.
        guard entities.allSatisfy({ jsonToDict($0) != nil }) else {
            throw SceneSerializerError.invalidFormat
        }
        let version = jsonToInt(json["version"]) ?? 0
        guard version == currentVersion else {
            throw SceneSerializerError.unsupportedVersion(version)
        }
        return loadEntities(entities, into: &scene, restoreGameState: restoreGameState)
    }

    private static func decodeEntityStructure(
        _ obj: [String: Any], onto entity: EntityID, in scene: inout RuntimeWorld
    ) {
        if let name = jsonToString(obj["name"]) {
            _ = scene.setComponent(SceneNameComponent(value: name), for: entity)
        }
        if let kind = jsonToString(obj["kind"]) {
            _ = scene.setComponent(SceneKindComponent(value: kind), for: entity)
        }

        let translation = jsonToFloatArray(obj["translation"]).flatMap(jsonToVec3) ?? .zero
        let rotationVec = jsonToFloatArray(obj["rotation"]).flatMap(jsonToVec4) ?? SIMD4<Float>(0, 0, 0, 1)
        let scale = jsonToFloatArray(obj["scale"]).flatMap(jsonToVec3) ?? SIMD3<Float>(repeating: 1)
        let quat = simd_quatf(vector: rotationVec)
        let m = simd_float4x4(quat)
        let s = simd_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
        var matrix = s * m
        matrix.columns.3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        _ = scene.setLocalTransform(LocalTransform(matrix: matrix), for: entity)
    }

    /// Creates every entity in `entities`, wires deferred parent links, and returns the
    /// created entities aligned to the input order (the index used by `parent` fields).
    @discardableResult
    static func loadEntities(
        _ entities: [Any],
        into scene: inout SceneRuntime,
        restoreGameState: Bool = false
    ) -> [EntityID] {
        scene.withWorld { loadEntities(entities, into: &$0, restoreGameState: restoreGameState) }
    }

    @discardableResult
    static func loadEntities(
        _ entities: [Any],
        into scene: inout RuntimeWorld,
        restoreGameState: Bool = false
    ) -> [EntityID] {
        // Allocate the complete map first. Every codec can resolve forward references
        // without component-specific deferred passes or assumptions about world slots.
        var entityMap: [Int: EntityID] = [:]
        for index in entities.indices where entities[index] is [String: Any] {
            entityMap[index] = scene.createEntity()
        }
        let registry = scene.componentRegistry
        var context = ComponentDecodeContext(entityMap: entityMap)
        for (index, raw) in entities.enumerated() {
            guard let entity = entityMap[index], let object = jsonToDict(raw) else { continue }
            decodeEntityStructure(object, onto: entity, in: &scene)
            let components = (jsonToDict(object["components"]) ?? [:]).map {
                ManifestComponent(type: $0.key, value: ComponentValue(jsonObject: $0.value))
            }
            registry.decode(components, onto: entity, context: &context, in: &scene)
        }
        for (index, raw) in entities.enumerated() {
            guard let entity = entityMap[index], let object = jsonToDict(raw),
                  let parentIndex = jsonToInt(object["parent"]), let parent = entityMap[parentIndex] else { continue }
            _ = scene.setParent(parent, for: entity)
        }

        if restoreGameState {
            restoreDestructionRuntimeState(
                from: entities,
                entityMap: entityMap,
                into: &scene
            )
        }

        return entities.indices.compactMap { entityMap[$0] }
    }
}

public enum SceneSerializerError: Error {
    case invalidFormat
    case unsupportedVersion(Int)
}
