import Foundation
import SIMDCompat

// MARK: - JSON helpers

private func vec3ToJSON(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
private func vec4ToJSON(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
private func jsonToVec3(_ a: [Float]) -> SIMD3<Float>? {
    a.count == 3 ? SIMD3<Float>(a[0], a[1], a[2]) : nil
}
private func jsonToVec4(_ a: [Float]) -> SIMD4<Float>? {
    a.count == 4 ? SIMD4<Float>(a[0], a[1], a[2], a[3]) : nil
}
private func jsonToFloat(_ val: Any?) -> Float? {
    (val as? NSNumber).map { Float(truncating: $0) }
}
private func jsonToBool(_ val: Any?) -> Bool? { val as? Bool }
private func jsonToString(_ val: Any?) -> String? { val as? String }
private func jsonToInt(_ val: Any?) -> Int? { (val as? NSNumber).map { Int(truncating: $0) } }
private func jsonToDict(_ val: Any?) -> [String: Any]? { val as? [String: Any] }
private func jsonToArray(_ val: Any?) -> [Any]? { val as? [Any] }
private func jsonToFloatArray(_ val: Any?) -> [Float]? {
    (val as? [Any])?.compactMap { ($0 as? NSNumber).map { Float(truncating: $0) } }
}

// MARK: - Scene save/load

public enum SceneSerializer {
    private static let currentVersion = 1

    /// Document version stamped into captured prefabs. Shares the scene format.
    static let prefabVersion = currentVersion

    // MARK: Save

    public static func serialize(_ scene: SceneRuntime) throws -> Data {
        let entities = scene.entities()
        var entityIndexMap: [EntityID: Int] = [:]
        for (i, entity) in entities.enumerated() {
            entityIndexMap[entity] = i
        }
        let entityList = entities.map { entity -> [String: Any] in
            let parentIdx = scene.component(Parent.self, for: entity).flatMap { entityIndexMap[$0.entity] }
            return encodeEntity(entity, in: scene, parentIndex: parentIdx)
        }
        let json: [String: Any] = ["version": currentVersion, "entities": entityList]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Encodes one entity to a JSON dictionary. `parentIndex`, when non-nil, is the
    /// position of the parent within the encoded entity list (cross-references are by
    /// index, never `EntityID`, so the document is relocatable).
    static func encodeEntity(_ entity: EntityID, in scene: SceneRuntime, parentIndex: Int?) -> [String: Any] {
        var obj: [String: Any] = [:]

        // Name / kind
        if let name = scene.component(SceneNameComponent.self, for: entity) {
            obj["name"] = name.value
        }
        if let kind = scene.component(SceneKindComponent.self, for: entity) {
            obj["kind"] = kind.value
        }

        // Parent (store index, not EntityID)
        if let parentIndex { obj["parent"] = parentIndex }

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

        // Components
        var comps: [String: Any] = [:]
        if let c = scene.component(RigidBody.self, for: entity) { comps["rigidbody"] = serializeRigidBody(c) }
        if let c = scene.component(Collider.self, for: entity) { comps["collider"] = serializeCollider(c) }
        if let c = scene.component(RenderMeshComponent.self, for: entity) { comps["renderMesh"] = serializeRenderMesh(c) }
        if let c = scene.component(RenderMaterialComponent.self, for: entity) { comps["renderMaterial"] = serializeRenderMaterial(c) }
        if let c = scene.component(AssetReferenceComponent.self, for: entity) { comps["assetReference"] = serializeAssetReference(c) }
        if let c = scene.component(ParticleEmitter.self, for: entity) { comps["particleEmitter"] = serializeParticleEmitter(c) }
        if let c = scene.component(CameraComponent.self, for: entity) { comps["camera"] = serializeCamera(c) }
        if let c = scene.component(LightComponent.self, for: entity) { comps["light"] = serializeLight(c) }
        if let c = scene.component(AudioSource.self, for: entity) { comps["audioSource"] = serializeAudioSource(c) }
        if let c = scene.component(AnimationPlayer.self, for: entity) { comps["animationPlayer"] = serializeAnimationPlayer(c) }
        if let c = scene.component(AudioListener.self, for: entity) { comps["audioListener"] = serializeAudioListener(c) }
        if !comps.isEmpty { obj["components"] = comps }

        return obj
    }

    // MARK: Load

    public static func deserialize(_ data: Data, into scene: inout SceneRuntime) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = jsonToArray(json["entities"])
        else { throw SceneSerializerError.invalidFormat }
        _ = loadEntities(entities, into: &scene)
    }

    /// Creates one entity from a JSON dictionary and applies its transform and components.
    /// Parent wiring is the caller's responsibility (entities must exist first).
    @discardableResult
    static func decodeEntity(_ obj: [String: Any], into scene: inout SceneRuntime) -> EntityID {
        let entity = scene.createEntity()

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

        guard let comps = jsonToDict(obj["components"]) else { return entity }
        if let c = jsonToDict(comps["rigidbody"]) { _ = scene.setComponent(deserializeRigidBody(c), for: entity) }
        if let c = jsonToDict(comps["collider"]) { _ = scene.setComponent(deserializeCollider(c), for: entity) }
        if let c = jsonToDict(comps["renderMesh"]) { _ = scene.setComponent(deserializeRenderMesh(c), for: entity) }
        if let c = jsonToDict(comps["renderMaterial"]) { _ = scene.setComponent(deserializeRenderMaterial(c), for: entity) }
        if let c = jsonToDict(comps["assetReference"]) { _ = scene.setComponent(deserializeAssetReference(c), for: entity) }
        if let c = jsonToDict(comps["particleEmitter"]) { _ = scene.setComponent(deserializeParticleEmitter(c), for: entity) }
        if let c = jsonToDict(comps["camera"]) { _ = scene.setComponent(deserializeCamera(c), for: entity) }
        if let c = jsonToDict(comps["light"]) { _ = scene.setComponent(deserializeLight(c), for: entity) }
        if let c = jsonToDict(comps["audioSource"]) { _ = scene.setComponent(deserializeAudioSource(c), for: entity) }
        if let c = jsonToDict(comps["animationPlayer"]) { _ = scene.setComponent(deserializeAnimationPlayer(c), for: entity) }
        if let c = jsonToDict(comps["audioListener"]) { _ = scene.setComponent(deserializeAudioListener(c), for: entity) }
        return entity
    }

    /// Creates every entity in `entities`, wires deferred parent links, and returns the
    /// created entities aligned to the input order (the index used by `parent` fields).
    @discardableResult
    static func loadEntities(_ entities: [Any], into scene: inout SceneRuntime) -> [EntityID] {
        var entityMap: [Int: EntityID] = [:]
        var pendingParents: [(child: EntityID, parentIdx: Int)] = []

        for (i, raw) in entities.enumerated() {
            guard let obj = jsonToDict(raw) else { continue }
            let entity = decodeEntity(obj, into: &scene)
            entityMap[i] = entity
            if let parentIdx = jsonToInt(obj["parent"]) {
                pendingParents.append((entity, parentIdx))
            }
        }

        for (child, parentIdx) in pendingParents {
            if let parent = entityMap[parentIdx] {
                _ = scene.setParent(parent, for: child)
            }
        }

        return entities.indices.compactMap { entityMap[$0] }
    }

    // MARK: - Component serializers

    private static func serializeRigidBody(_ c: RigidBody) -> [String: Any] {
        [
            "motionType": c.motionType.rawValue,
            "mass": c.mass,
            "linearDamping": c.linearDamping,
            "angularDamping": c.angularDamping,
            "gravityScale": c.gravityScale,
            "allowSleep": c.allowSleep,
        ]
    }

    private static func deserializeRigidBody(_ d: [String: Any]) -> RigidBody {
        RigidBody(
            motionType: RigidBodyMotionType(rawValue: jsonToString(d["motionType"]) ?? "dynamic") ?? .dynamic,
            mass: jsonToFloat(d["mass"]) ?? 1,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            linearDamping: jsonToFloat(d["linearDamping"]) ?? 0.04,
            angularDamping: jsonToFloat(d["angularDamping"]) ?? 0.04,
            allowSleep: jsonToBool(d["allowSleep"]) ?? true
        )
    }

    private static func serializeCollider(_ c: Collider) -> [String: Any] {
        var d: [String: Any] = [
            "isTrigger": c.isTrigger,
            "layerID": c.layerID,
            "layerMask": c.layerMask,
            "friction": c.material.friction,
            "restitution": c.material.restitution,
        ]
        switch c.shape {
        case let .box(he, center):
            d["shape"] = "box"
            d["halfExtents"] = vec3ToJSON(he)
            d["center"] = vec3ToJSON(center)
        case let .sphere(radius, center):
            d["shape"] = "sphere"
            d["radius"] = radius
            d["center"] = vec3ToJSON(center)
        case let .capsule(radius, halfHeight, center):
            d["shape"] = "capsule"
            d["radius"] = radius
            d["halfHeight"] = halfHeight
            d["center"] = vec3ToJSON(center)
        case let .mesh(resourceID, center):
            d["shape"] = "mesh"
            d["resourceID"] = resourceID ?? ""
            d["center"] = vec3ToJSON(center)
        case let .convex(resourceID, center):
            d["shape"] = "convex"
            d["resourceID"] = resourceID ?? ""
            d["center"] = vec3ToJSON(center)
        }
        return d
    }

    private static func deserializeCollider(_ d: [String: Any]) -> Collider {
        let center = jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero
        let shape: ColliderShape
        switch jsonToString(d["shape"]) ?? "box" {
        case "sphere":
            shape = .sphere(radius: jsonToFloat(d["radius"]) ?? 0.5, center: center)
        case "capsule":
            shape = .capsule(radius: jsonToFloat(d["radius"]) ?? 0.5,
                           halfHeight: jsonToFloat(d["halfHeight"]) ?? 1, center: center)
        case "mesh":
            shape = .mesh(resourceID: jsonToString(d["resourceID"]), center: center)
        case "convex":
            shape = .convex(resourceID: jsonToString(d["resourceID"]), center: center)
        default:
            let he = jsonToFloatArray(d["halfExtents"]).flatMap(jsonToVec3) ?? SIMD3<Float>(repeating: 0.5)
            shape = .box(halfExtents: he, center: center)
        }
        return Collider(
            shape: shape,
            isTrigger: jsonToBool(d["isTrigger"]) ?? false,
            layerID: UInt16(jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(jsonToInt(d["layerMask"]) ?? Int(UInt16.max)),
            material: PhysicsMaterial(
                friction: jsonToFloat(d["friction"]) ?? 0.6,
                restitution: jsonToFloat(d["restitution"]) ?? 0
            )
        )
    }

    private static func serializeRenderMesh(_ c: RenderMeshComponent) -> [String: Any] {
        var d: [String: Any] = ["meshIndex": c.meshIndex, "isVisible": c.isVisible]
        d["colorTint"] = vec3ToJSON(c.colorTint)
        if let aid = c.assetID { d["assetID"] = aid }
        return d
    }

    private static func deserializeRenderMesh(_ d: [String: Any]) -> RenderMeshComponent {
        RenderMeshComponent(
            meshIndex: jsonToInt(d["meshIndex"]) ?? 0,
            isVisible: jsonToBool(d["isVisible"]) ?? true,
            colorTint: jsonToFloatArray(d["colorTint"]).flatMap(jsonToVec3) ?? SIMD3<Float>(1, 1, 1),
            assetID: jsonToString(d["assetID"])
        )
    }

    private static func serializeCamera(_ c: CameraComponent) -> [String: Any] {
        [
            "isActive": c.isActive,
            "fovYRadians": c.fovYRadians,
            "near": c.near,
            "far": c.far,
            "target": vec3ToJSON(c.target),
            "up": vec3ToJSON(c.up),
        ]
    }

    private static func deserializeCamera(_ d: [String: Any]) -> CameraComponent {
        CameraComponent(
            target: jsonToFloatArray(d["target"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            up: jsonToFloatArray(d["up"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            fovYRadians: jsonToFloat(d["fovYRadians"]) ?? 1.0,
            near: jsonToFloat(d["near"]) ?? 0.1,
            far: jsonToFloat(d["far"]) ?? 1000,
            isActive: jsonToBool(d["isActive"]) ?? false
        )
    }

    private static func serializeLight(_ c: LightComponent) -> [String: Any] {
        [
            "type": c.type.rawValue,
            "color": vec3ToJSON(c.color),
            "intensity": c.intensity,
            "range": c.range,
            "spotInnerAngleDegrees": c.spotInnerAngleDegrees,
            "spotOuterAngleDegrees": c.spotOuterAngleDegrees,
            "castShadows": c.castShadows,
        ]
    }

    private static func deserializeLight(_ d: [String: Any]) -> LightComponent {
        LightComponent(
            type: LightType(rawValue: jsonToString(d["type"]) ?? "point") ?? .point,
            color: jsonToFloatArray(d["color"]).flatMap(jsonToVec3) ?? SIMD3<Float>(1, 1, 1),
            intensity: jsonToFloat(d["intensity"]) ?? 1,
            range: jsonToFloat(d["range"]) ?? 10,
            spotInnerAngleDegrees: jsonToFloat(d["spotInnerAngleDegrees"]) ?? 30,
            spotOuterAngleDegrees: jsonToFloat(d["spotOuterAngleDegrees"]) ?? 45,
            castShadows: jsonToBool(d["castShadows"]) ?? false
        )
    }

    private static func serializeAudioSource(_ c: AudioSource) -> [String: Any] {
        [
            "clipName": c.clipName,
            "volume": c.volume,
            "pitch": c.pitch,
            "loop": c.loop,
            "playOnAwake": c.playOnAwake,
            "spatialBlend": c.spatialBlend,
        ]
    }

    private static func deserializeAudioSource(_ d: [String: Any]) -> AudioSource {
        AudioSource(
            clipName: jsonToString(d["clipName"]) ?? "",
            volume: jsonToFloat(d["volume"]) ?? 1,
            pitch: jsonToFloat(d["pitch"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? false,
            playOnAwake: jsonToBool(d["playOnAwake"]) ?? true,
            spatialBlend: jsonToFloat(d["spatialBlend"]) ?? 1
        )
    }

    private static func serializeAnimationPlayer(_ c: AnimationPlayer) -> [String: Any] {
        var d: [String: Any] = ["isPlaying": c.isPlaying, "loop": c.loop, "speed": c.speed, "time": c.time]
        if let name = c.clipName { d["clipName"] = name }
        return d
    }

    private static func deserializeAnimationPlayer(_ d: [String: Any]) -> AnimationPlayer {
        AnimationPlayer(
            clipName: jsonToString(d["clipName"]),
            speed: jsonToFloat(d["speed"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? true,
            isPlaying: jsonToBool(d["isPlaying"]) ?? true,
            time: (d["time"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private static func serializeAudioListener(_ c: AudioListener) -> [String: Any] {
        ["masterVolume": c.masterVolume]
    }

    private static func deserializeAudioListener(_ d: [String: Any]) -> AudioListener {
        AudioListener(masterVolume: jsonToFloat(d["masterVolume"]) ?? 1)
    }

    private static func serializeRenderMaterial(_ c: RenderMaterialComponent) -> [String: Any] {
        var d: [String: Any] = [
            "baseColorFactor": vec4ToJSON(c.baseColorFactor),
            "metallicFactor": c.metallicFactor,
            "roughnessFactor": c.roughnessFactor,
            "emissiveFactor": vec3ToJSON(c.emissiveFactor),
        ]
        if let i = c.baseColorTextureIndex { d["baseColorTextureIndex"] = i }
        if let i = c.normalTextureIndex { d["normalTextureIndex"] = i }
        return d
    }

    private static func deserializeRenderMaterial(_ d: [String: Any]) -> RenderMaterialComponent {
        RenderMaterialComponent(
            baseColorFactor: jsonToFloatArray(d["baseColorFactor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            baseColorTextureIndex: jsonToInt(d["baseColorTextureIndex"]),
            normalTextureIndex: jsonToInt(d["normalTextureIndex"]),
            metallicFactor: jsonToFloat(d["metallicFactor"]) ?? 0,
            roughnessFactor: jsonToFloat(d["roughnessFactor"]) ?? 1,
            emissiveFactor: jsonToFloatArray(d["emissiveFactor"]).flatMap(jsonToVec3) ?? .zero
        )
    }

    private static func serializeAssetReference(_ c: AssetReferenceComponent) -> [String: Any] {
        [
            "assetID": c.assetID,
            "name": c.name,
            "relativePath": c.relativePath,
            "absolutePath": c.absolutePath,
            "kind": c.kind,
            "meshIndex": c.meshIndex,
        ]
    }

    private static func deserializeAssetReference(_ d: [String: Any]) -> AssetReferenceComponent {
        AssetReferenceComponent(
            assetID: jsonToString(d["assetID"]) ?? "",
            name: jsonToString(d["name"]) ?? "",
            relativePath: jsonToString(d["relativePath"]) ?? "",
            absolutePath: jsonToString(d["absolutePath"]) ?? "",
            kind: jsonToString(d["kind"]) ?? "",
            meshIndex: jsonToInt(d["meshIndex"]) ?? 0
        )
    }

    /// Serializes a particle emitter's configuration only — the live particle pool is
    /// transient runtime state and is not persisted.
    private static func serializeParticleEmitter(_ c: ParticleEmitter) -> [String: Any] {
        [
            "isEmitting": c.isEmitting,
            "looping": c.looping,
            "emissionRate": c.emissionRate,
            "maxParticles": c.maxParticles,
            "lifetime": c.lifetime,
            "lifetimeRandomness": c.lifetimeRandomness,
            "originOffset": vec3ToJSON(c.originOffset),
            "spawnRadius": c.spawnRadius,
            "startVelocity": vec3ToJSON(c.startVelocity),
            "velocityRandomness": vec3ToJSON(c.velocityRandomness),
            "gravity": vec3ToJSON(c.gravity),
            "startSize": c.startSize,
            "endSize": c.endSize,
            "startColor": vec4ToJSON(c.startColor),
            "endColor": vec4ToJSON(c.endColor),
            "seed": Int(bitPattern: UInt(c.seed)),
        ]
    }

    private static func deserializeParticleEmitter(_ d: [String: Any]) -> ParticleEmitter {
        ParticleEmitter(
            isEmitting: jsonToBool(d["isEmitting"]) ?? true,
            looping: jsonToBool(d["looping"]) ?? true,
            emissionRate: jsonToFloat(d["emissionRate"]) ?? 10,
            maxParticles: jsonToInt(d["maxParticles"]) ?? 256,
            lifetime: jsonToFloat(d["lifetime"]) ?? 2,
            lifetimeRandomness: jsonToFloat(d["lifetimeRandomness"]) ?? 0,
            originOffset: jsonToFloatArray(d["originOffset"]).flatMap(jsonToVec3) ?? .zero,
            spawnRadius: jsonToFloat(d["spawnRadius"]) ?? 0,
            startVelocity: jsonToFloatArray(d["startVelocity"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            velocityRandomness: jsonToFloatArray(d["velocityRandomness"]).flatMap(jsonToVec3) ?? .zero,
            gravity: jsonToFloatArray(d["gravity"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, -9.81, 0),
            startSize: jsonToFloat(d["startSize"]) ?? 1,
            endSize: jsonToFloat(d["endSize"]) ?? 0,
            startColor: jsonToFloatArray(d["startColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            endColor: jsonToFloatArray(d["endColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 0),
            seed: UInt64(bitPattern: Int64(jsonToInt(d["seed"]) ?? 0))
        )
    }
}

public enum SceneSerializerError: Error {
    case invalidFormat
    case unsupportedVersion(Int)
}
