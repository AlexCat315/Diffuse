import Foundation
import SIMDCompat

// MARK: - JSON helpers

private func vec3ToJSON(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
private func vec4ToJSON(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
private func matrixToJSON(_ matrix: simd_float4x4) -> [Float] {
    [matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
     matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
     matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
     matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w]
}
private func jsonToMatrix(_ values: [Float]) -> simd_float4x4? {
    guard values.count == 16 else { return nil }
    return simd_float4x4(columns: (
        SIMD4<Float>(values[0], values[1], values[2], values[3]),
        SIMD4<Float>(values[4], values[5], values[6], values[7]),
        SIMD4<Float>(values[8], values[9], values[10], values[11]),
        SIMD4<Float>(values[12], values[13], values[14], values[15])
    ))
}
private func jsonToVec3(_ a: [Float]) -> SIMD3<Float>? {
    a.count == 3 ? SIMD3<Float>(a[0], a[1], a[2]) : nil
}
private func jsonToVec4(_ a: [Float]) -> SIMD4<Float>? {
    a.count == 4 ? SIMD4<Float>(a[0], a[1], a[2], a[3]) : nil
}
private func jsonToFloat(_ val: Any?) -> Float? {
    (val as? NSNumber).map { Float(truncating: $0) }
}
private func jsonToDouble(_ val: Any?) -> Double? {
    (val as? NSNumber).map { Double(truncating: $0) }
}
private func jsonToBool(_ val: Any?) -> Bool? { val as? Bool }
private func jsonToString(_ val: Any?) -> String? { val as? String }
private func jsonToInt(_ val: Any?) -> Int? { (val as? NSNumber).map { Int(truncating: $0) } }
private func jsonToDict(_ val: Any?) -> [String: Any]? { val as? [String: Any] }
private func jsonToArray(_ val: Any?) -> [Any]? { val as? [Any] }
private func jsonToStringFloatDict(_ val: Any?) -> [String: Float]? {
    guard let dict = val as? [String: Any] else { return nil }
    var out: [String: Float] = [:]
    for (key, value) in dict {
        if let number = value as? NSNumber {
            out[key] = Float(truncating: number)
        }
    }
    return out
}
private func jsonToFloatArray(_ val: Any?) -> [Float]? {
    (val as? [Any])?.compactMap { ($0 as? NSNumber).map { Float(truncating: $0) } }
}
private func encodeJSONValue<T: Encodable>(_ value: T) -> Any? {
    guard let data = try? JSONEncoder().encode(value) else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: data)
}
private func decodeJSONValue<T: Decodable>(_ value: Any?, as type: T.Type) -> T? {
    guard let value,
          JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value) else {
        return nil
    }
    return try? JSONDecoder().decode(type, from: data)
}

// MARK: - Scene save/load

public enum SceneSerializer {
    private static let currentVersion = 2

    /// Document version stamped into captured prefabs. Shares the scene format.
    static let prefabVersion = currentVersion

    // MARK: Save

    public static func serialize(_ scene: SceneRuntime) throws -> Data {
        let entities = scene.entities()
        var entityIndexMap: [EntityID: Int] = [:]
        for (i, entity) in entities.enumerated() {
            entityIndexMap[entity] = i
        }
        let entityList = entities.map { encodeEntity($0, in: scene, entityIndexMap: entityIndexMap) }
        let json: [String: Any] = ["version": currentVersion, "entities": entityList]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    /// Encodes one entity to a JSON dictionary. All entity cross-references (parent,
    /// constraint endpoints) are stored as positions within `entityIndexMap` rather than
    /// `EntityID`s, so the document is relocatable. References to entities outside the map
    /// (e.g. a constraint endpoint outside a captured prefab subtree) are dropped.
    static func encodeEntity(_ entity: EntityID, in scene: SceneRuntime, entityIndexMap: [EntityID: Int]) -> [String: Any] {
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

        // Components
        var comps: [String: Any] = [:]
        if let c = scene.component(RigidBody.self, for: entity) { comps["rigidbody"] = serializeRigidBody(c) }
        if let c = scene.component(Collider.self, for: entity) { comps["collider"] = serializeCollider(c) }
        if let c = scene.component(CharacterController.self, for: entity) { comps["characterController"] = serializeCharacterController(c) }
        if let c = scene.component(Vehicle.self, for: entity) { comps["vehicle"] = serializeVehicle(c) }
        if let c = scene.component(SoftBody.self, for: entity) { comps["softBody"] = serializeSoftBody(c) }
        if let c = scene.component(Cloth.self, for: entity) { comps["cloth"] = serializeCloth(c) }
        if let c = scene.component(SoftBodyMesh.self, for: entity) { comps["softBodyMesh"] = serializeSoftBodyMesh(c) }
        if let c = scene.component(Destructible.self, for: entity) { comps["destructible"] = serializeDestructible(c) }
        if let c = scene.component(Constraint.self, for: entity),
           let a = entityIndexMap[c.entityA], let b = entityIndexMap[c.entityB] {
            comps["constraint"] = serializeConstraint(c, entityA: a, entityB: b)
        }
        if let c = scene.component(Ragdoll.self, for: entity) {
            comps["ragdoll"] = serializeRagdoll(c, entityIndexMap: entityIndexMap)
        }
        if let c = scene.component(RenderMeshComponent.self, for: entity) { comps["renderMesh"] = serializeRenderMesh(c) }
        if let c = scene.component(RenderMaterialComponent.self, for: entity) { comps["renderMaterial"] = serializeRenderMaterial(c) }
        if let c = scene.component(AssetReferenceComponent.self, for: entity) { comps["assetReference"] = serializeAssetReference(c) }
        if let c = scene.component(ParticleEmitter.self, for: entity) { comps["particleEmitter"] = serializeParticleEmitter(c) }
        if let c = scene.component(CameraComponent.self, for: entity) { comps["camera"] = serializeCamera(c) }
        if let c = scene.component(LightComponent.self, for: entity) { comps["light"] = serializeLight(c) }
        if let c = scene.component(AudioSource.self, for: entity) { comps["audioSource"] = serializeAudioSource(c) }
        if let c = scene.component(AnimationPlayer.self, for: entity) { comps["animationPlayer"] = serializeAnimationPlayer(c) }
        if let c = scene.component(AnimationGraphPlayer.self, for: entity) { comps["animationGraphPlayer"] = serializeAnimationGraphPlayer(c) }
        if let c = scene.component(AudioListener.self, for: entity) { comps["audioListener"] = serializeAudioListener(c) }
        if !comps.isEmpty { obj["components"] = comps }

        return obj
    }

    // MARK: Load

    public static func deserialize(_ data: Data, into scene: inout SceneRuntime) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = jsonToArray(json["entities"])
        else { throw SceneSerializerError.invalidFormat }
        let version = jsonToInt(json["version"]) ?? 0
        guard version == currentVersion else {
            throw SceneSerializerError.unsupportedVersion(version)
        }
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
        if let c = jsonToDict(comps["characterController"]) { _ = scene.setComponent(deserializeCharacterController(c), for: entity) }
        if let c = jsonToDict(comps["vehicle"]) { _ = scene.setComponent(deserializeVehicle(c), for: entity) }
        if let c = jsonToDict(comps["softBody"]) { _ = scene.setComponent(deserializeSoftBody(c), for: entity) }
        if let c = jsonToDict(comps["cloth"]) { _ = scene.setComponent(deserializeCloth(c), for: entity) }
        if let c = jsonToDict(comps["softBodyMesh"]) { _ = scene.setComponent(deserializeSoftBodyMesh(c), for: entity) }
        if let c = jsonToDict(comps["destructible"]) { _ = scene.setComponent(deserializeDestructible(c), for: entity) }
        if let c = jsonToDict(comps["renderMesh"]) { _ = scene.setComponent(deserializeRenderMesh(c), for: entity) }
        if let c = jsonToDict(comps["renderMaterial"]) { _ = scene.setComponent(deserializeRenderMaterial(c), for: entity) }
        if let c = jsonToDict(comps["assetReference"]) { _ = scene.setComponent(deserializeAssetReference(c), for: entity) }
        if let c = jsonToDict(comps["particleEmitter"]) { _ = scene.setComponent(deserializeParticleEmitter(c), for: entity) }
        if let c = jsonToDict(comps["camera"]) { _ = scene.setComponent(deserializeCamera(c), for: entity) }
        if let c = jsonToDict(comps["light"]) { _ = scene.setComponent(deserializeLight(c), for: entity) }
        if let c = jsonToDict(comps["audioSource"]) { _ = scene.setComponent(deserializeAudioSource(c), for: entity) }
        if let c = jsonToDict(comps["animationPlayer"]) { _ = scene.setComponent(deserializeAnimationPlayer(c), for: entity) }
        if let c = jsonToDict(comps["animationGraphPlayer"]) { _ = scene.setComponent(deserializeAnimationGraphPlayer(c), for: entity) }
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

        // Deferred constraints: endpoints are list indices, resolved once all entities exist.
        // A constraint whose endpoints are missing (e.g. trimmed by a prefab subtree) is dropped.
        for (i, raw) in entities.enumerated() {
            guard let host = entityMap[i],
                  let obj = jsonToDict(raw),
                  let comps = jsonToDict(obj["components"]),
                  let cd = jsonToDict(comps["constraint"]),
                  let ai = jsonToInt(cd["entityA"]), let bi = jsonToInt(cd["entityB"]),
                  let a = entityMap[ai], let b = entityMap[bi]
            else { continue }
            _ = scene.setComponent(deserializeConstraint(cd, entityA: a, entityB: b), for: host)
        }

        // Deferred ragdolls: bone bodies and optional joint entities are remapped
        // through the same relocatable entity index table.
        for (i, raw) in entities.enumerated() {
            guard let host = entityMap[i],
                  let obj = jsonToDict(raw),
                  let comps = jsonToDict(obj["components"]),
                  let ragdoll = jsonToDict(comps["ragdoll"])
            else { continue }
            _ = scene.setComponent(
                deserializeRagdoll(ragdoll, entityMap: entityMap),
                for: host
            )
        }

        return entities.indices.compactMap { entityMap[$0] }
    }

    // MARK: - Component serializers

    private static func serializeRigidBody(_ c: RigidBody) -> [String: Any] {
        var d: [String: Any] = [
            "motionType": c.motionType.rawValue,
            "mass": c.mass,
            "massMode": c.massMode.rawValue,
            "linearDamping": c.linearDamping,
            "angularDamping": c.angularDamping,
            "gravityScale": c.gravityScale,
            "allowSleep": c.allowSleep,
            "continuousCollisionDetection": c.continuousCollisionDetection,
            "axisLocks": c.axisLocks.rawValue,
            "maxLinearVelocity": c.maxLinearVelocity,
            "maxAngularVelocity": c.maxAngularVelocity,
            "motionQuality": c.motionQuality.rawValue,
        ]
        if let centerOfMassOverride = c.centerOfMassOverride {
            d["centerOfMassOverride"] = vec3ToJSON(centerOfMassOverride)
        }
        if let inertiaDiagonalOverride = c.inertiaDiagonalOverride {
            d["inertiaDiagonalOverride"] = vec3ToJSON(inertiaDiagonalOverride)
        }
        if let target = c.kinematicTarget {
            d["kinematicTarget"] = [
                "position": vec3ToJSON(target.position),
                "rotation": vec4ToJSON(target.rotation),
            ]
        }
        return d
    }

    private static func deserializeRigidBody(_ d: [String: Any]) -> RigidBody {
        RigidBody(
            motionType: RigidBodyMotionType(rawValue: jsonToString(d["motionType"]) ?? "dynamic") ?? .dynamic,
            mass: jsonToFloat(d["mass"]) ?? 1,
            massMode: RigidBodyMassMode(rawValue: jsonToString(d["massMode"]) ?? "mass") ?? .mass,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            linearDamping: jsonToFloat(d["linearDamping"]) ?? 0.04,
            angularDamping: jsonToFloat(d["angularDamping"]) ?? 0.04,
            allowSleep: jsonToBool(d["allowSleep"]) ?? true,
            continuousCollisionDetection: jsonToBool(d["continuousCollisionDetection"]) ?? false,
            centerOfMassOverride: jsonToFloatArray(d["centerOfMassOverride"]).flatMap(jsonToVec3),
            inertiaDiagonalOverride: jsonToFloatArray(d["inertiaDiagonalOverride"]).flatMap(jsonToVec3),
            axisLocks: RigidBodyAxisLocks(rawValue: UInt8(jsonToInt(d["axisLocks"]) ?? 0)),
            maxLinearVelocity: jsonToFloat(d["maxLinearVelocity"]) ?? 500,
            maxAngularVelocity: jsonToFloat(d["maxAngularVelocity"]) ?? (0.25 * .pi * 60),
            motionQuality: RigidBodyMotionQuality(rawValue: jsonToString(d["motionQuality"]) ?? "discrete") ?? .discrete,
            kinematicTarget: jsonToDict(d["kinematicTarget"]).flatMap { target in
                guard let position = jsonToFloatArray(target["position"]).flatMap(jsonToVec3) else { return nil }
                let rotation = jsonToFloatArray(target["rotation"]).flatMap(jsonToVec4)
                    ?? SIMD4<Float>(0, 0, 0, 1)
                return PhysicsKinematicTarget(position: position, rotation: rotation)
            }
        )
    }

    private static func serializeCollider(_ c: Collider) -> [String: Any] {
        var d: [String: Any] = [
            "isTrigger": c.isTrigger,
            "layerID": c.layerID,
            "layerMask": c.layerMask,
            "friction": c.material.friction,
            "restitution": c.material.restitution,
            "density": c.material.density,
        ]
        d["shapes"] = c.shapes.map { instance in
            var encoded = serializeColliderShape(instance.shape)
            encoded["localPosition"] = vec3ToJSON(instance.localPosition)
            encoded["localRotation"] = vec4ToJSON(instance.localRotation)
            encoded["localScale"] = vec3ToJSON(instance.localScale)
            return encoded
        }
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
        case let .cylinder(radius, halfHeight, center):
            d["shape"] = "cylinder"
            d["radius"] = radius
            d["halfHeight"] = halfHeight
            d["center"] = vec3ToJSON(center)
        case let .heightField(resourceID, center):
            d["shape"] = "heightField"
            d["resourceID"] = resourceID ?? ""
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

    private static func serializeColliderShape(_ shape: ColliderShape) -> [String: Any] {
        var d: [String: Any] = ["center": vec3ToJSON(shape.center)]
        switch shape {
        case let .box(halfExtents, _):
            d["shape"] = "box"; d["halfExtents"] = vec3ToJSON(halfExtents)
        case let .sphere(radius, _):
            d["shape"] = "sphere"; d["radius"] = radius
        case let .capsule(radius, halfHeight, _):
            d["shape"] = "capsule"; d["radius"] = radius; d["halfHeight"] = halfHeight
        case let .cylinder(radius, halfHeight, _):
            d["shape"] = "cylinder"; d["radius"] = radius; d["halfHeight"] = halfHeight
        case let .heightField(resourceID, _):
            d["shape"] = "heightField"; d["resourceID"] = resourceID ?? ""
        case let .mesh(resourceID, _):
            d["shape"] = "mesh"; d["resourceID"] = resourceID ?? ""
        case let .convex(resourceID, _):
            d["shape"] = "convex"; d["resourceID"] = resourceID ?? ""
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
        case "cylinder":
            shape = .cylinder(radius: jsonToFloat(d["radius"]) ?? 0.5,
                              halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                              center: center)
        case "heightField":
            shape = .heightField(resourceID: jsonToString(d["resourceID"]), center: center)
        case "mesh":
            shape = .mesh(resourceID: jsonToString(d["resourceID"]), center: center)
        case "convex":
            shape = .convex(resourceID: jsonToString(d["resourceID"]), center: center)
        default:
            let he = jsonToFloatArray(d["halfExtents"]).flatMap(jsonToVec3) ?? SIMD3<Float>(repeating: 0.5)
            shape = .box(halfExtents: he, center: center)
        }
        let instances = jsonToArray(d["shapes"])?.compactMap { value -> ColliderShapeInstance? in
            guard let encoded = jsonToDict(value) else { return nil }
            let localPosition = jsonToFloatArray(encoded["localPosition"]).flatMap(jsonToVec3) ?? .zero
            let localRotation = jsonToFloatArray(encoded["localRotation"]).flatMap(jsonToVec4)
                ?? SIMD4<Float>(0, 0, 0, 1)
            let localScale = jsonToFloatArray(encoded["localScale"]).flatMap(jsonToVec3)
                ?? SIMD3<Float>(repeating: 1)
            return ColliderShapeInstance(
                shape: deserializeColliderShape(encoded),
                localPosition: localPosition,
                localRotation: localRotation,
                localScale: localScale
            )
        }
        return Collider(
            shapes: instances ?? [ColliderShapeInstance(shape: shape)],
            isTrigger: jsonToBool(d["isTrigger"]) ?? false,
            layerID: UInt16(jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(jsonToInt(d["layerMask"]) ?? Int(UInt16.max)),
            material: PhysicsMaterial(
                friction: jsonToFloat(d["friction"]) ?? 0.6,
                restitution: jsonToFloat(d["restitution"]) ?? 0,
                density: jsonToFloat(d["density"]) ?? 1
            )
        )
    }

    private static func deserializeColliderShape(_ d: [String: Any]) -> ColliderShape {
        let center = jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero
        switch jsonToString(d["shape"]) ?? "box" {
        case "sphere": return .sphere(radius: jsonToFloat(d["radius"]) ?? 0.5, center: center)
        case "capsule": return .capsule(radius: jsonToFloat(d["radius"]) ?? 0.5,
                                         halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                                         center: center)
        case "cylinder": return .cylinder(radius: jsonToFloat(d["radius"]) ?? 0.5,
                                            halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                                            center: center)
        case "heightField": return .heightField(resourceID: jsonToString(d["resourceID"]), center: center)
        case "mesh": return .mesh(resourceID: jsonToString(d["resourceID"]), center: center)
        case "convex": return .convex(resourceID: jsonToString(d["resourceID"]), center: center)
        default:
            return .box(
                halfExtents: jsonToFloatArray(d["halfExtents"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(repeating: 0.5),
                center: center
            )
        }
    }

    private static func serializeCharacterController(_ c: CharacterController) -> [String: Any] {
        [
            "radius": c.radius,
            "standingHalfHeight": c.standingHalfHeight,
            "crouchingHalfHeight": c.crouchingHalfHeight,
            "center": vec3ToJSON(c.center),
            "maxSlopeDegrees": c.maxSlopeDegrees,
            "stepHeight": c.stepHeight,
            "skinWidth": c.skinWidth,
            "mass": c.mass,
            "maxStrength": c.maxStrength,
            "gravityScale": c.gravityScale,
            "layerID": c.layerID,
            "layerMask": c.layerMask,
        ]
    }

    private static func deserializeCharacterController(_ d: [String: Any]) -> CharacterController {
        CharacterController(
            radius: jsonToFloat(d["radius"]) ?? 0.4,
            standingHalfHeight: jsonToFloat(d["standingHalfHeight"]) ?? 0.6,
            crouchingHalfHeight: jsonToFloat(d["crouchingHalfHeight"]) ?? 0.25,
            center: jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero,
            maxSlopeDegrees: jsonToFloat(d["maxSlopeDegrees"]) ?? 50,
            stepHeight: jsonToFloat(d["stepHeight"]) ?? 0.4,
            skinWidth: jsonToFloat(d["skinWidth"]) ?? 0.02,
            mass: jsonToFloat(d["mass"]) ?? 70,
            maxStrength: jsonToFloat(d["maxStrength"]) ?? 100,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            layerID: UInt16(jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(jsonToInt(d["layerMask"]) ?? Int(UInt16.max))
        )
    }

    private static func serializeVehicle(_ vehicle: Vehicle) -> [String: Any] {
        let controller: [String: Any]
        switch vehicle.controller {
        case .wheeled:
            controller = ["kind": VehicleControllerKind.wheeled.rawValue]
        case let .tracked(configuration):
            func serializeTrack(_ track: VehicleTrackConfiguration) -> [String: Any] {
                [
                    "drivenWheel": track.drivenWheel,
                    "wheels": track.wheels,
                    "inertia": track.inertia,
                    "angularDamping": track.angularDamping,
                    "maxBrakeTorque": track.maxBrakeTorque,
                    "differentialRatio": track.differentialRatio,
                ]
            }
            controller = [
                "kind": VehicleControllerKind.tracked.rawValue,
                "leftTrack": serializeTrack(configuration.leftTrack),
                "rightTrack": serializeTrack(configuration.rightTrack),
                "longitudinalFriction": configuration.longitudinalFriction,
                "lateralFriction": configuration.lateralFriction,
            ]
        case let .motorcycle(configuration):
            controller = [
                "kind": VehicleControllerKind.motorcycle.rawValue,
                "maxLeanAngle": configuration.maxLeanAngle,
                "leanSpringConstant": configuration.leanSpringConstant,
                "leanSpringDamping": configuration.leanSpringDamping,
                "leanSpringIntegrationCoefficient": configuration.leanSpringIntegrationCoefficient,
                "leanSpringIntegrationCoefficientDecay": configuration.leanSpringIntegrationCoefficientDecay,
                "leanSmoothingFactor": configuration.leanSmoothingFactor,
                "isLeanControllerEnabled": configuration.isLeanControllerEnabled,
                "isLeanSteeringLimitEnabled": configuration.isLeanSteeringLimitEnabled,
            ]
        }
        return [
            "isEnabled": vehicle.isEnabled,
            "controller": controller,
            "up": vec3ToJSON(vehicle.up),
            "forward": vec3ToJSON(vehicle.forward),
            "maxPitchRollAngle": vehicle.maxPitchRollAngle,
            "engine": [
                "maxTorque": vehicle.engine.maxTorque,
                "minRPM": vehicle.engine.minRPM,
                "maxRPM": vehicle.engine.maxRPM,
                "inertia": vehicle.engine.inertia,
                "angularDamping": vehicle.engine.angularDamping,
            ],
            "transmission": [
                "mode": vehicle.transmission.mode.rawValue,
                "gearRatios": vehicle.transmission.gearRatios,
                "reverseGearRatios": vehicle.transmission.reverseGearRatios,
                "switchTime": vehicle.transmission.switchTime,
                "clutchReleaseTime": vehicle.transmission.clutchReleaseTime,
                "switchLatency": vehicle.transmission.switchLatency,
                "shiftUpRPM": vehicle.transmission.shiftUpRPM,
                "shiftDownRPM": vehicle.transmission.shiftDownRPM,
                "clutchStrength": vehicle.transmission.clutchStrength,
            ],
            "wheels": vehicle.wheels.map { wheel in
                [
                    "position": vec3ToJSON(wheel.position),
                    "suspensionDirection": vec3ToJSON(wheel.suspensionDirection),
                    "steeringAxis": vec3ToJSON(wheel.steeringAxis),
                    "wheelUp": vec3ToJSON(wheel.wheelUp),
                    "wheelForward": vec3ToJSON(wheel.wheelForward),
                    "suspensionMinLength": wheel.suspensionMinLength,
                    "suspensionMaxLength": wheel.suspensionMaxLength,
                    "suspensionPreloadLength": wheel.suspensionPreloadLength,
                    "suspensionFrequency": wheel.suspensionFrequency,
                    "suspensionDamping": wheel.suspensionDamping,
                    "radius": wheel.radius,
                    "width": wheel.width,
                    "inertia": wheel.inertia,
                    "angularDamping": wheel.angularDamping,
                    "maxSteerAngle": wheel.maxSteerAngle,
                    "maxBrakeTorque": wheel.maxBrakeTorque,
                    "maxHandBrakeTorque": wheel.maxHandBrakeTorque,
                ] as [String: Any]
            },
            "differentials": vehicle.differentials.map { differential in
                [
                    "leftWheel": differential.leftWheel,
                    "rightWheel": differential.rightWheel,
                    "differentialRatio": differential.differentialRatio,
                    "leftRightSplit": differential.leftRightSplit,
                    "limitedSlipRatio": differential.limitedSlipRatio,
                    "engineTorqueRatio": differential.engineTorqueRatio,
                ] as [String: Any]
            },
            "antiRollBars": vehicle.antiRollBars.map { bar in
                [
                    "leftWheel": bar.leftWheel,
                    "rightWheel": bar.rightWheel,
                    "stiffness": bar.stiffness,
                ] as [String: Any]
            },
        ]
    }

    private static func deserializeVehicle(_ d: [String: Any]) -> Vehicle {
        let defaultVehicle = Vehicle()
        let controllerDictionary = jsonToDict(d["controller"])
        let engineDictionary = jsonToDict(d["engine"])
        let transmissionDictionary = jsonToDict(d["transmission"])
        let wheels = jsonToArray(d["wheels"])?.compactMap { raw -> VehicleWheelConfiguration? in
            guard let wheel = jsonToDict(raw) else { return nil }
            return VehicleWheelConfiguration(
                position: jsonToFloatArray(wheel["position"]).flatMap(jsonToVec3) ?? .zero,
                suspensionDirection: jsonToFloatArray(wheel["suspensionDirection"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, -1, 0),
                steeringAxis: jsonToFloatArray(wheel["steeringAxis"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 1, 0),
                wheelUp: jsonToFloatArray(wheel["wheelUp"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 1, 0),
                wheelForward: jsonToFloatArray(wheel["wheelForward"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 0, 1),
                suspensionMinLength: jsonToFloat(wheel["suspensionMinLength"]) ?? 0.2,
                suspensionMaxLength: jsonToFloat(wheel["suspensionMaxLength"]) ?? 0.5,
                suspensionPreloadLength: jsonToFloat(wheel["suspensionPreloadLength"]) ?? 0,
                suspensionFrequency: jsonToFloat(wheel["suspensionFrequency"]) ?? 1.5,
                suspensionDamping: jsonToFloat(wheel["suspensionDamping"]) ?? 0.5,
                radius: jsonToFloat(wheel["radius"]) ?? 0.35,
                width: jsonToFloat(wheel["width"]) ?? 0.2,
                inertia: jsonToFloat(wheel["inertia"]) ?? 0.9,
                angularDamping: jsonToFloat(wheel["angularDamping"]) ?? 0.2,
                maxSteerAngle: jsonToFloat(wheel["maxSteerAngle"]) ?? 0,
                maxBrakeTorque: jsonToFloat(wheel["maxBrakeTorque"]) ?? 1_500,
                maxHandBrakeTorque: jsonToFloat(wheel["maxHandBrakeTorque"]) ?? 0
            )
        } ?? defaultVehicle.wheels
        let differentials = jsonToArray(d["differentials"])?.compactMap { raw -> VehicleDifferentialConfiguration? in
            guard let differential = jsonToDict(raw),
                  let left = jsonToInt(differential["leftWheel"]),
                  let right = jsonToInt(differential["rightWheel"])
            else { return nil }
            return VehicleDifferentialConfiguration(
                leftWheel: left,
                rightWheel: right,
                differentialRatio: jsonToFloat(differential["differentialRatio"]) ?? 3.42,
                leftRightSplit: jsonToFloat(differential["leftRightSplit"]) ?? 0.5,
                limitedSlipRatio: jsonToFloat(differential["limitedSlipRatio"]) ?? 1.4,
                engineTorqueRatio: jsonToFloat(differential["engineTorqueRatio"]) ?? 1
            )
        } ?? defaultVehicle.differentials
        let antiRollBars = jsonToArray(d["antiRollBars"])?.compactMap { raw -> VehicleAntiRollBarConfiguration? in
            guard let bar = jsonToDict(raw),
                  let left = jsonToInt(bar["leftWheel"]),
                  let right = jsonToInt(bar["rightWheel"])
            else { return nil }
            return VehicleAntiRollBarConfiguration(
                leftWheel: left,
                rightWheel: right,
                stiffness: jsonToFloat(bar["stiffness"]) ?? 1_000
            )
        } ?? defaultVehicle.antiRollBars
        let engine = VehicleEngineConfiguration(
            maxTorque: jsonToFloat(engineDictionary?["maxTorque"]) ?? 500,
            minRPM: jsonToFloat(engineDictionary?["minRPM"]) ?? 1_000,
            maxRPM: jsonToFloat(engineDictionary?["maxRPM"]) ?? 6_000,
            inertia: jsonToFloat(engineDictionary?["inertia"]) ?? 0.5,
            angularDamping: jsonToFloat(engineDictionary?["angularDamping"]) ?? 0.2
        )
        let transmission = VehicleTransmissionConfiguration(
            mode: VehicleTransmissionMode(
                rawValue: UInt8(clamping: jsonToInt(transmissionDictionary?["mode"]) ?? 0)
            ) ?? .automatic,
            gearRatios: jsonToFloatArray(transmissionDictionary?["gearRatios"]) ?? [2.66, 1.78, 1.3, 1, 0.74],
            reverseGearRatios: jsonToFloatArray(transmissionDictionary?["reverseGearRatios"]) ?? [-2.9],
            switchTime: jsonToFloat(transmissionDictionary?["switchTime"]) ?? 0.5,
            clutchReleaseTime: jsonToFloat(transmissionDictionary?["clutchReleaseTime"]) ?? 0.3,
            switchLatency: jsonToFloat(transmissionDictionary?["switchLatency"]) ?? 0.5,
            shiftUpRPM: jsonToFloat(transmissionDictionary?["shiftUpRPM"]) ?? 4_000,
            shiftDownRPM: jsonToFloat(transmissionDictionary?["shiftDownRPM"]) ?? 2_000,
            clutchStrength: jsonToFloat(transmissionDictionary?["clutchStrength"]) ?? 10
        )
        let controller: VehicleControllerConfiguration
        switch VehicleControllerKind(
            rawValue: UInt8(clamping: jsonToInt(controllerDictionary?["kind"]) ?? 0)
        ) ?? .wheeled {
        case .wheeled:
            controller = .wheeled
        case .tracked:
            func deserializeTrack(
                _ dictionary: [String: Any]?,
                fallback: VehicleTrackConfiguration
            ) -> VehicleTrackConfiguration {
                guard let dictionary else { return fallback }
                return VehicleTrackConfiguration(
                    drivenWheel: jsonToInt(dictionary["drivenWheel"]) ?? fallback.drivenWheel,
                    wheels: (jsonToArray(dictionary["wheels"]) ?? []).compactMap(jsonToInt),
                    inertia: jsonToFloat(dictionary["inertia"]) ?? fallback.inertia,
                    angularDamping: jsonToFloat(dictionary["angularDamping"]) ?? fallback.angularDamping,
                    maxBrakeTorque: jsonToFloat(dictionary["maxBrakeTorque"]) ?? fallback.maxBrakeTorque,
                    differentialRatio: jsonToFloat(dictionary["differentialRatio"])
                        ?? fallback.differentialRatio
                )
            }
            let defaults = Vehicle.tracked()
            let fallback: TrackedVehicleConfiguration
            if case let .tracked(value) = defaults.controller {
                fallback = value
            } else {
                preconditionFailure("Vehicle.tracked() must use a tracked controller")
            }
            controller = .tracked(TrackedVehicleConfiguration(
                leftTrack: deserializeTrack(
                    jsonToDict(controllerDictionary?["leftTrack"]), fallback: fallback.leftTrack
                ),
                rightTrack: deserializeTrack(
                    jsonToDict(controllerDictionary?["rightTrack"]), fallback: fallback.rightTrack
                ),
                longitudinalFriction: jsonToFloat(controllerDictionary?["longitudinalFriction"])
                    ?? fallback.longitudinalFriction,
                lateralFriction: jsonToFloat(controllerDictionary?["lateralFriction"])
                    ?? fallback.lateralFriction
            ))
        case .motorcycle:
            controller = .motorcycle(MotorcycleVehicleConfiguration(
                maxLeanAngle: jsonToFloat(controllerDictionary?["maxLeanAngle"]) ?? .pi / 4,
                leanSpringConstant: jsonToFloat(controllerDictionary?["leanSpringConstant"]) ?? 5_000,
                leanSpringDamping: jsonToFloat(controllerDictionary?["leanSpringDamping"]) ?? 1_000,
                leanSpringIntegrationCoefficient:
                    jsonToFloat(controllerDictionary?["leanSpringIntegrationCoefficient"]) ?? 0,
                leanSpringIntegrationCoefficientDecay:
                    jsonToFloat(controllerDictionary?["leanSpringIntegrationCoefficientDecay"]) ?? 4,
                leanSmoothingFactor: jsonToFloat(controllerDictionary?["leanSmoothingFactor"]) ?? 0.8,
                isLeanControllerEnabled:
                    jsonToBool(controllerDictionary?["isLeanControllerEnabled"]) ?? true,
                isLeanSteeringLimitEnabled:
                    jsonToBool(controllerDictionary?["isLeanSteeringLimitEnabled"]) ?? true
            ))
        }
        return Vehicle(
            controller: controller,
            wheels: wheels,
            differentials: differentials,
            antiRollBars: antiRollBars,
            engine: engine,
            transmission: transmission,
            up: jsonToFloatArray(d["up"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            forward: jsonToFloatArray(d["forward"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 0, 1),
            maxPitchRollAngle: jsonToFloat(d["maxPitchRollAngle"]) ?? .pi,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
        )
    }

    private static func serializeSoftBody(_ body: SoftBody) -> [String: Any] {
        [
            "vertexMass": body.vertexMass,
            "pressure": body.pressure,
            "linearDamping": body.linearDamping,
            "friction": body.friction,
            "restitution": body.restitution,
            "gravityScale": body.gravityScale,
            "vertexRadius": body.vertexRadius,
            "solverIterations": body.solverIterations,
            "maxLinearVelocity": body.maxLinearVelocity,
            "layerID": body.layerID,
            "layerMask": body.layerMask,
            "allowSleep": body.allowSleep,
            "facesDoubleSided": body.facesDoubleSided,
            "selfCollision": body.selfCollision,
            "isEnabled": body.isEnabled,
        ]
    }

    private static func deserializeSoftBody(_ d: [String: Any]) -> SoftBody {
        SoftBody(
            vertexMass: jsonToFloat(d["vertexMass"]) ?? 1,
            pressure: jsonToFloat(d["pressure"]) ?? 0,
            linearDamping: jsonToFloat(d["linearDamping"]) ?? 0.1,
            friction: jsonToFloat(d["friction"]) ?? 0.2,
            restitution: jsonToFloat(d["restitution"]) ?? 0,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            vertexRadius: jsonToFloat(d["vertexRadius"]) ?? 0.02,
            solverIterations: jsonToInt(d["solverIterations"]) ?? 5,
            maxLinearVelocity: jsonToFloat(d["maxLinearVelocity"]) ?? 500,
            layerID: UInt16(clamping: jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(clamping: jsonToInt(d["layerMask"]) ?? Int(UInt16.max)),
            allowSleep: jsonToBool(d["allowSleep"]) ?? true,
            facesDoubleSided: jsonToBool(d["facesDoubleSided"]) ?? true,
            selfCollision: jsonToBool(d["selfCollision"]) ?? false,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
        )
    }

    private static func serializeCloth(_ cloth: Cloth) -> [String: Any] {
        [
            "gridSizeX": cloth.gridSizeX,
            "gridSizeZ": cloth.gridSizeZ,
            "spacing": cloth.spacing,
            "fixedVertexIndices": cloth.fixedVertexIndices,
            "compliance": cloth.compliance,
            "shearCompliance": cloth.shearCompliance,
            "bendCompliance": cloth.bendCompliance,
            "bendType": cloth.bendType.rawValue,
        ]
    }

    private static func deserializeCloth(_ d: [String: Any]) -> Cloth {
        Cloth(
            gridSizeX: jsonToInt(d["gridSizeX"]) ?? 16,
            gridSizeZ: jsonToInt(d["gridSizeZ"]) ?? 16,
            spacing: jsonToFloat(d["spacing"]) ?? 0.2,
            fixedVertexIndices: (jsonToArray(d["fixedVertexIndices"]) ?? []).compactMap(jsonToInt),
            compliance: jsonToFloat(d["compliance"]) ?? 1.0e-5,
            shearCompliance: jsonToFloat(d["shearCompliance"]) ?? 1.0e-5,
            bendCompliance: jsonToFloat(d["bendCompliance"]) ?? 1.0e-5,
            bendType: ClothBendType(
                rawValue: UInt8(clamping: jsonToInt(d["bendType"]) ?? 1)
            ) ?? .distance
        )
    }

    private static func serializeSoftBodyMesh(_ mesh: SoftBodyMesh) -> [String: Any] {
        var result: [String: Any] = [
            "fixedVertexIndices": mesh.fixedVertexIndices,
            "compliance": mesh.compliance,
            "shearCompliance": mesh.shearCompliance,
            "bendCompliance": mesh.bendCompliance,
            "volumeCompliance": mesh.volumeCompliance,
            "bendType": mesh.bendType.rawValue,
        ]
        if let resourceID = mesh.resourceID {
            result["resourceID"] = resourceID
        }
        return result
    }

    private static func deserializeSoftBodyMesh(_ d: [String: Any]) -> SoftBodyMesh {
        SoftBodyMesh(
            resourceID: jsonToString(d["resourceID"]),
            fixedVertexIndices: (jsonToArray(d["fixedVertexIndices"]) ?? []).compactMap(jsonToInt),
            compliance: jsonToFloat(d["compliance"]) ?? 1.0e-5,
            shearCompliance: jsonToFloat(d["shearCompliance"]) ?? 1.0e-5,
            bendCompliance: jsonToFloat(d["bendCompliance"]) ?? 1.0e-5,
            volumeCompliance: jsonToFloat(d["volumeCompliance"]) ?? 1.0e-6,
            bendType: ClothBendType(
                rawValue: UInt8(clamping: jsonToInt(d["bendType"]) ?? 2)
            ) ?? .dihedral
        )
    }

    private static func serializeDestructible(_ destructible: Destructible) -> [String: Any] {
        [
            "assetResourceID": destructible.assetResourceID,
            "damageThreshold": destructible.damageThreshold,
            "impulseThreshold": destructible.impulseThreshold,
            "fragmentBudget": destructible.fragmentBudget,
            "maximumFragmentLifetimeSeconds": destructible.maximumFragmentLifetimeSeconds,
            "sleepingRecycleDelaySeconds": destructible.sleepingRecycleDelaySeconds,
            "separationImpulse": destructible.separationImpulse,
            "isEnabled": destructible.isEnabled,
        ]
    }

    private static func deserializeDestructible(_ d: [String: Any]) -> Destructible {
        Destructible(
            assetResourceID: jsonToString(d["assetResourceID"]) ?? "",
            damageThreshold: jsonToFloat(d["damageThreshold"]) ?? 100,
            impulseThreshold: jsonToFloat(d["impulseThreshold"]) ?? 10,
            fragmentBudget: jsonToInt(d["fragmentBudget"]) ?? 256,
            maximumFragmentLifetimeSeconds: jsonToFloat(d["maximumFragmentLifetimeSeconds"]) ?? 30,
            sleepingRecycleDelaySeconds: jsonToFloat(d["sleepingRecycleDelaySeconds"]) ?? 5,
            separationImpulse: jsonToFloat(d["separationImpulse"]) ?? 0.05,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
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
            "aspectRatio": c.aspectRatio,
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
            aspectRatio: jsonToFloat(d["aspectRatio"]) ?? 1,
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

    private static func serializeAnimationGraphPlayer(_ c: AnimationGraphPlayer) -> [String: Any] {
        var d: [String: Any] = [
            "graph": serializeAnimationGraph(c.graph),
            "parameters": c.parameters,
            "activeTime": c.activeTime,
            "previousTime": c.previousTime,
            "transitionElapsed": c.transitionElapsed,
            "transitionDuration": c.transitionDuration,
            "speed": c.speed,
            "isPlaying": c.isPlaying,
        ]
        if let activeState = c.activeState { d["activeState"] = activeState }
        if let previousState = c.previousState { d["previousState"] = previousState }
        return d
    }

    private static func deserializeAnimationGraphPlayer(_ d: [String: Any]) -> AnimationGraphPlayer {
        AnimationGraphPlayer(
            graph: jsonToDict(d["graph"]).map(deserializeAnimationGraph)
                ?? AnimationGraph(stateMachine: AnimationStateMachine(initialState: "", states: [])),
            parameters: jsonToStringFloatDict(d["parameters"]) ?? [:],
            activeState: jsonToString(d["activeState"]),
            previousState: jsonToString(d["previousState"]),
            activeTime: jsonToDouble(d["activeTime"]) ?? 0,
            previousTime: jsonToDouble(d["previousTime"]) ?? 0,
            transitionElapsed: jsonToDouble(d["transitionElapsed"]) ?? 0,
            transitionDuration: jsonToDouble(d["transitionDuration"]) ?? 0,
            speed: jsonToFloat(d["speed"]) ?? 1,
            isPlaying: jsonToBool(d["isPlaying"]) ?? true
        )
    }

    private static func serializeAnimationGraph(_ graph: AnimationGraph) -> [String: Any] {
        [
            "blendSpaces1D": graph.blendSpaces1D.map(serializeAnimationBlendSpace1D),
            "stateMachine": serializeAnimationStateMachine(graph.stateMachine),
        ]
    }

    private static func deserializeAnimationGraph(_ d: [String: Any]) -> AnimationGraph {
        AnimationGraph(
            blendSpaces1D: jsonToArray(d["blendSpaces1D"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationBlendSpace1D)
            } ?? [],
            stateMachine: jsonToDict(d["stateMachine"]).map(deserializeAnimationStateMachine)
                ?? AnimationStateMachine(initialState: "", states: [])
        )
    }

    private static func serializeAnimationBlendSpace1D(_ blendSpace: AnimationBlendSpace1D) -> [String: Any] {
        [
            "name": blendSpace.name,
            "parameter": blendSpace.parameter,
            "samples": blendSpace.samples.map(serializeAnimationBlendSample1D),
        ]
    }

    private static func deserializeAnimationBlendSpace1D(_ d: [String: Any]) -> AnimationBlendSpace1D {
        AnimationBlendSpace1D(
            name: jsonToString(d["name"]) ?? "",
            parameter: jsonToString(d["parameter"]) ?? "",
            samples: jsonToArray(d["samples"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationBlendSample1D)
            } ?? []
        )
    }

    private static func serializeAnimationBlendSample1D(_ sample: AnimationBlendSample1D) -> [String: Any] {
        var d: [String: Any] = ["threshold": sample.threshold]
        if let clipName = sample.clipName { d["clipName"] = clipName }
        return d
    }

    private static func deserializeAnimationBlendSample1D(_ d: [String: Any]) -> AnimationBlendSample1D {
        AnimationBlendSample1D(
            clipName: jsonToString(d["clipName"]),
            threshold: jsonToFloat(d["threshold"]) ?? 0
        )
    }

    private static func serializeAnimationStateMachine(_ stateMachine: AnimationStateMachine) -> [String: Any] {
        [
            "initialState": stateMachine.initialState,
            "states": stateMachine.states.map(serializeAnimationState),
            "transitions": stateMachine.transitions.map(serializeAnimationTransition),
        ]
    }

    private static func deserializeAnimationStateMachine(_ d: [String: Any]) -> AnimationStateMachine {
        AnimationStateMachine(
            initialState: jsonToString(d["initialState"]) ?? "",
            states: jsonToArray(d["states"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationState)
            } ?? [],
            transitions: jsonToArray(d["transitions"])?.compactMap {
                jsonToDict($0).map(deserializeAnimationTransition)
            } ?? []
        )
    }

    private static func serializeAnimationState(_ state: AnimationState) -> [String: Any] {
        [
            "name": state.name,
            "motion": serializeAnimationMotion(state.motion),
            "speed": state.speed,
            "loop": state.loop,
        ]
    }

    private static func deserializeAnimationState(_ d: [String: Any]) -> AnimationState {
        AnimationState(
            name: jsonToString(d["name"]) ?? "",
            motion: jsonToDict(d["motion"]).map(deserializeAnimationMotion) ?? .clip(nil),
            speed: jsonToFloat(d["speed"]) ?? 1,
            loop: jsonToBool(d["loop"]) ?? true
        )
    }

    private static func serializeAnimationMotion(_ motion: AnimationMotion) -> [String: Any] {
        switch motion {
        case let .clip(clipName):
            var d: [String: Any] = ["type": "clip"]
            if let clipName { d["clipName"] = clipName }
            return d
        case let .blendSpace1D(name):
            return ["type": "blendSpace1D", "name": name]
        }
    }

    private static func deserializeAnimationMotion(_ d: [String: Any]) -> AnimationMotion {
        switch jsonToString(d["type"]) {
        case "blendSpace1D":
            return .blendSpace1D(jsonToString(d["name"]) ?? "")
        default:
            return .clip(jsonToString(d["clipName"]))
        }
    }

    private static func serializeAnimationTransition(_ transition: AnimationTransition) -> [String: Any] {
        [
            "from": transition.from,
            "to": transition.to,
            "parameter": transition.parameter,
            "comparison": transition.comparison.rawValue,
            "threshold": transition.threshold,
            "duration": transition.duration,
        ]
    }

    private static func deserializeAnimationTransition(_ d: [String: Any]) -> AnimationTransition {
        AnimationTransition(
            from: jsonToString(d["from"]) ?? "",
            to: jsonToString(d["to"]) ?? "",
            parameter: jsonToString(d["parameter"]) ?? "",
            comparison: AnimationTransitionComparison(rawValue: jsonToString(d["comparison"]) ?? "")
                ?? .greaterThan,
            threshold: jsonToFloat(d["threshold"]) ?? 0,
            duration: jsonToDouble(d["duration"]) ?? 0
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

    /// Serializes a physics constraint. Endpoints are passed as resolved list indices
    /// (computed by the caller from the entity index map).
    private static func serializeConstraint(_ c: Constraint, entityA: Int, entityB: Int) -> [String: Any] {
        var result: [String: Any] = [
            "type": c.constraintType.rawValue,
            "entityA": entityA,
            "entityB": entityB,
            "pivotA": vec3ToJSON(c.pivotA),
            "pivotB": vec3ToJSON(c.pivotB),
            "axisA": vec3ToJSON(c.axisA),
            "axisB": vec3ToJSON(c.axisB),
            "minLimit": c.minLimit,
            "maxLimit": c.maxLimit,
            "isEnabled": c.isEnabled,
            "breakForce": c.breakForce,
            "breakTorque": c.breakTorque,
        ]
        func storeSpring(_ spring: PhysicsJointSpring) {
            result["springFrequency"] = spring.frequency
            result["springDamping"] = spring.damping
        }
        func storeMotor(_ motor: PhysicsJointMotor, prefix: String = "motor") {
            result["\(prefix)Mode"] = motor.mode.rawValue
            result["\(prefix)TargetPosition"] = motor.targetPosition
            result["\(prefix)TargetVelocity"] = motor.targetVelocity
            result["\(prefix)MaxForce"] = motor.maxForce
        }
        switch c.configuration {
        case .point, .fixed:
            break
        case let .distance(value):
            storeSpring(value.spring)
        case let .hinge(value):
            storeSpring(value.spring); storeMotor(value.motor)
        case let .slider(value):
            storeSpring(value.spring); storeMotor(value.motor)
        case let .cone(value):
            result["halfConeAngle"] = value.halfConeAngle
            storeSpring(value.spring)
        case let .sixDOF(value):
            result["linearMinimum"] = vec3ToJSON(value.linearMinimum)
            result["linearMaximum"] = vec3ToJSON(value.linearMaximum)
            result["angularMinimum"] = vec3ToJSON(value.angularMinimum)
            result["angularMaximum"] = vec3ToJSON(value.angularMaximum)
            storeSpring(value.spring)
            storeMotor(value.linearMotor)
            storeMotor(value.angularMotor, prefix: "angularMotor")
        }
        return result
    }

    private static func deserializeConstraint(_ d: [String: Any], entityA: EntityID, entityB: EntityID) -> Constraint {
        let kind = PhysicsJointKind(rawValue: jsonToString(d["type"]) ?? "pointToPoint") ?? .pointToPoint
        let axisA = jsonToFloatArray(d["axisA"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0)
        let axisB = jsonToFloatArray(d["axisB"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0)
        let minimum = jsonToFloat(d["minLimit"]) ?? 0
        let maximum = jsonToFloat(d["maxLimit"]) ?? 0
        let spring = PhysicsJointSpring(
            frequency: jsonToFloat(d["springFrequency"]) ?? 0,
            damping: jsonToFloat(d["springDamping"]) ?? 0
        )
        func motor(prefix: String = "motor") -> PhysicsJointMotor {
            PhysicsJointMotor(
                mode: PhysicsJointMotorMode(rawValue: jsonToString(d["\(prefix)Mode"]) ?? "disabled") ?? .disabled,
                targetPosition: jsonToFloat(d["\(prefix)TargetPosition"]) ?? 0,
                targetVelocity: jsonToFloat(d["\(prefix)TargetVelocity"]) ?? 0,
                maxForce: jsonToFloat(d["\(prefix)MaxForce"]) ?? .greatestFiniteMagnitude
            )
        }
        let configuration: PhysicsJointConfiguration
        switch kind {
        case .pointToPoint:
            configuration = .point
        case .fixed:
            configuration = .fixed(axisA: axisA, axisB: axisB)
        case .distance:
            configuration = .distance(DistanceJointConfiguration(
                minimumDistance: minimum, maximumDistance: maximum, spring: spring))
        case .hinge:
            configuration = .hinge(HingeJointConfiguration(
                axisA: axisA, axisB: axisB, minimumAngle: minimum, maximumAngle: maximum,
                motor: motor(), spring: spring))
        case .slider:
            configuration = .slider(SliderJointConfiguration(
                axisA: axisA, axisB: axisB, minimumDistance: minimum, maximumDistance: maximum,
                motor: motor(), spring: spring))
        case .cone:
            configuration = .cone(ConeJointConfiguration(
                twistAxisA: axisA, twistAxisB: axisB,
                halfConeAngle: jsonToFloat(d["halfConeAngle"]) ?? .pi / 4,
                minimumTwistAngle: minimum, maximumTwistAngle: maximum, spring: spring))
        case .sixDOF:
            configuration = .sixDOF(SixDOFJointConfiguration(
                axisA: axisA,
                axisB: axisB,
                linearMinimum: jsonToFloatArray(d["linearMinimum"]).flatMap(jsonToVec3) ?? .zero,
                linearMaximum: jsonToFloatArray(d["linearMaximum"]).flatMap(jsonToVec3) ?? .zero,
                angularMinimum: jsonToFloatArray(d["angularMinimum"]).flatMap(jsonToVec3) ?? .zero,
                angularMaximum: jsonToFloatArray(d["angularMaximum"]).flatMap(jsonToVec3) ?? .zero,
                linearMotor: motor(),
                angularMotor: motor(prefix: "angularMotor"),
                spring: spring
            ))
        }
        return Constraint(
            configuration: configuration,
            entityA: entityA,
            entityB: entityB,
            pivotA: jsonToFloatArray(d["pivotA"]).flatMap(jsonToVec3) ?? .zero,
            pivotB: jsonToFloatArray(d["pivotB"]).flatMap(jsonToVec3) ?? .zero,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true,
            breakForce: jsonToFloat(d["breakForce"]) ?? .greatestFiniteMagnitude,
            breakTorque: jsonToFloat(d["breakTorque"]) ?? .greatestFiniteMagnitude
        )
    }

    private static func serializeRagdoll(
        _ ragdoll: Ragdoll,
        entityIndexMap: [EntityID: Int]
    ) -> [String: Any] {
        let bones: [[String: Any]] = ragdoll.bones.compactMap { bone in
            guard let body = entityIndexMap[bone.bodyEntity] else { return nil }
            var result: [String: Any] = [
                "boneName": bone.boneName,
                "paletteIndex": bone.paletteIndex,
                "bodyEntity": body,
                "bodyFromPalette": matrixToJSON(bone.bodyFromPalette),
                "simulatedMotionType": bone.simulatedMotionType.rawValue,
                "isSimulationEnabled": bone.isSimulationEnabled,
                "blendWeight": bone.blendWeight,
            ]
            if let jointEntity = bone.jointEntity.flatMap({ entityIndexMap[$0] }) {
                result["jointEntity"] = jointEntity
            }
            return result
        }
        return [
            "mode": ragdoll.mode.rawValue,
            "blendWeight": ragdoll.blendWeight,
            "isEnabled": ragdoll.isEnabled,
            "bones": bones,
        ]
    }

    private static func deserializeRagdoll(
        _ dictionary: [String: Any],
        entityMap: [Int: EntityID]
    ) -> Ragdoll {
        let bones = (jsonToArray(dictionary["bones"]) ?? []).compactMap { raw -> RagdollBoneMapping? in
            guard let bone = jsonToDict(raw),
                  let bodyIndex = jsonToInt(bone["bodyEntity"]),
                  let bodyEntity = entityMap[bodyIndex]
            else { return nil }
            let jointEntity = jsonToInt(bone["jointEntity"]).flatMap { entityMap[$0] }
            return RagdollBoneMapping(
                boneName: jsonToString(bone["boneName"]) ?? "",
                paletteIndex: jsonToInt(bone["paletteIndex"]) ?? 0,
                bodyEntity: bodyEntity,
                jointEntity: jointEntity,
                bodyFromPalette: jsonToFloatArray(bone["bodyFromPalette"]).flatMap(jsonToMatrix)
                    ?? matrix_identity_float4x4,
                simulatedMotionType: RigidBodyMotionType(
                    rawValue: jsonToString(bone["simulatedMotionType"]) ?? "dynamic"
                ) ?? .dynamic,
                isSimulationEnabled: jsonToBool(bone["isSimulationEnabled"]) ?? true,
                blendWeight: jsonToFloat(bone["blendWeight"]) ?? 1
            )
        }
        return Ragdoll(
            mode: RagdollMode(rawValue: jsonToString(dictionary["mode"]) ?? "animated") ?? .animated,
            blendWeight: jsonToFloat(dictionary["blendWeight"]) ?? 1,
            isEnabled: jsonToBool(dictionary["isEnabled"]) ?? true,
            bones: bones
        )
    }

    /// Serializes a particle emitter's configuration only — the live particle pool is
    /// transient runtime state and is not persisted.
    private static func serializeParticleEmitter(_ c: ParticleEmitter) -> [String: Any] {
        var d: [String: Any] = [
            "isEmitting": c.isEmitting,
            "looping": c.looping,
            "duration": c.duration,
            "simulationSpeed": c.simulationSpeed,
            "prewarmTime": c.prewarmTime,
            "prewarmStep": c.prewarmStep,
            "emissionRate": c.emissionRate,
            "emissionRateCurve": serializeParticleCurve(c.emissionRateCurve),
            "distanceEmissionRate": c.distanceEmissionRate,
            "distanceEmissionRateCurve": serializeParticleCurve(c.distanceEmissionRateCurve),
            "burstCount": c.burstCount,
            "burstInterval": c.burstInterval,
            "maxParticles": c.maxParticles,
            "maxSpawnedParticlesPerFrame": c.maxSpawnedParticlesPerFrame,
            "maxRenderedParticles": c.maxRenderedParticles,
            "lifetime": c.lifetime,
            "lifetimeRandomness": c.lifetimeRandomness,
            "subEmitterTrigger": c.subEmitterTrigger.rawValue,
            "subEmitterBurstCount": c.subEmitterBurstCount,
            "subEmitterProbability": c.subEmitterProbability,
            "subEmitterMaxDepth": c.subEmitterMaxDepth,
            "subEmitterInheritVelocity": c.subEmitterInheritVelocity,
            "subEmitterLifetime": c.subEmitterLifetime,
            "subEmitterStartVelocity": vec3ToJSON(c.subEmitterStartVelocity),
            "subEmitterVelocityRandomness": vec3ToJSON(c.subEmitterVelocityRandomness),
            "subEmitterStartSize": c.subEmitterStartSize,
            "subEmitterEndSize": c.subEmitterEndSize,
            "subEmitterStartColor": vec4ToJSON(c.subEmitterStartColor),
            "subEmitterEndColor": vec4ToJSON(c.subEmitterEndColor),
            "subEmitters": c.subEmitters.map(serializeParticleSubEmitter),
            "originOffset": vec3ToJSON(c.originOffset),
            "spawnRadius": c.spawnRadius,
            "emissionShape": c.emissionShape.rawValue,
            "boxHalfExtents": vec3ToJSON(c.boxHalfExtents),
            "coneRadius": c.coneRadius,
            "coneHeight": c.coneHeight,
            "startVelocity": vec3ToJSON(c.startVelocity),
            "velocityRandomness": vec3ToJSON(c.velocityRandomness),
            "velocityInheritance": c.velocityInheritance,
            "gravity": vec3ToJSON(c.gravity),
            "noiseStrength": c.noiseStrength,
            "noiseScale": c.noiseScale,
            "noiseSpeed": c.noiseSpeed,
            "forceMode": c.forceMode.rawValue,
            "forceCenter": vec3ToJSON(c.forceCenter),
            "forceAxis": vec3ToJSON(c.forceAxis),
            "forceRadius": c.forceRadius,
            "forceStrength": c.forceStrength,
            "forceFalloff": c.forceFalloff,
            "vectorFieldMode": c.vectorFieldMode.rawValue,
            "vectorFieldDirection": vec3ToJSON(c.vectorFieldDirection),
            "vectorFieldStrength": c.vectorFieldStrength,
            "vectorFieldScale": c.vectorFieldScale,
            "vectorFieldScrollSpeed": c.vectorFieldScrollSpeed,
            "collisionMode": c.collisionMode.rawValue,
            "simulationSpace": c.simulationSpace.rawValue,
            "simulationBackend": c.simulationBackend.rawValue,
            "gpuSimulationWorkgroupSize": c.gpuSimulationWorkgroupSize,
            "collisionPlaneY": c.collisionPlaneY,
            "collisionRestitution": c.collisionRestitution,
            "collisionDamping": c.collisionDamping,
            "startSize": c.startSize,
            "endSize": c.endSize,
            "sizeRandomness": c.sizeRandomness,
            "startRotation": c.startRotation,
            "rotationRandomness": c.rotationRandomness,
            "angularVelocity": c.angularVelocity,
            "angularVelocityRandomness": c.angularVelocityRandomness,
            "sizeCurve": serializeParticleCurve(c.sizeCurve),
            "startColor": vec4ToJSON(c.startColor),
            "endColor": vec4ToJSON(c.endColor),
            "colorCurve": serializeParticleCurve(c.colorCurve),
            "blendMode": c.blendMode.rawValue,
            "renderMode": c.renderMode.rawValue,
            "sortMode": c.sortMode.rawValue,
            "renderSortPriority": c.renderSortPriority,
            "ribbonWidthScale": c.ribbonWidthScale,
            "ribbonTailWidthScale": c.ribbonTailWidthScale,
            "ribbonTailAlphaScale": c.ribbonTailAlphaScale,
            "ribbonMaxSegmentLength": c.ribbonMaxSegmentLength,
            "ribbonJoinOverlapScale": c.ribbonJoinOverlapScale,
            "ribbonSmoothingSegments": c.ribbonSmoothingSegments,
            "ribbonTextureTiling": c.ribbonTextureTiling,
            "ribbonTextureOffset": c.ribbonTextureOffset,
            "renderAlignment": c.renderAlignment.rawValue,
            "velocityStretchScale": c.velocityStretchScale,
            "velocityStretchMax": c.velocityStretchMax,
            "maxRenderDistance": c.maxRenderDistance,
            "renderDistanceFadeRange": c.renderDistanceFadeRange,
            "renderLODStartDistance": c.renderLODStartDistance,
            "renderLODEndDistance": c.renderLODEndDistance,
            "renderLODMinParticleScale": c.renderLODMinParticleScale,
            "renderBoundsMode": c.renderBoundsMode.rawValue,
            "renderBoundsRadius": c.renderBoundsRadius,
            "textureSheetColumns": c.textureSheetColumns,
            "textureSheetRows": c.textureSheetRows,
            "textureSheetFrameCount": c.textureSheetFrameCount,
            "textureSheetFrameRate": c.textureSheetFrameRate,
            "textureSheetPlaybackMode": c.textureSheetPlaybackMode.rawValue,
            "textureSheetStartFrame": c.textureSheetStartFrame,
            "textureSheetFrameRandomness": c.textureSheetFrameRandomness,
            "trailLength": c.trailLength,
            "trailSegments": c.trailSegments,
            "trailEndSizeScale": c.trailEndSizeScale,
            "trailEndAlphaScale": c.trailEndAlphaScale,
            "seed": Int(bitPattern: UInt(c.seed)),
        ]
        if let textureAssetID = c.textureAssetID {
            d["textureAssetID"] = textureAssetID
        }
        if let texturePath = c.texturePath {
            d["texturePath"] = texturePath
        }
        if let moduleStack = encodeJSONValue(c.moduleStack) {
            d["moduleStack"] = moduleStack
        }
        return d
    }

    private static func deserializeParticleEmitter(_ d: [String: Any]) -> ParticleEmitter {
        let renderBoundsRadius = jsonToFloat(d["renderBoundsRadius"]) ?? 0
        let renderBoundsMode = ParticleRenderBoundsMode(rawValue: jsonToString(d["renderBoundsMode"]) ?? "")
            ?? (renderBoundsRadius > 0 ? .manual : .disabled)
        var emitter = ParticleEmitter(
            isEmitting: jsonToBool(d["isEmitting"]) ?? true,
            looping: jsonToBool(d["looping"]) ?? true,
            duration: jsonToFloat(d["duration"]) ?? 0,
            simulationSpeed: jsonToFloat(d["simulationSpeed"]) ?? 1,
            prewarmTime: jsonToFloat(d["prewarmTime"]) ?? 0,
            prewarmStep: jsonToFloat(d["prewarmStep"]) ?? (1.0 / 30.0),
            emissionRate: jsonToFloat(d["emissionRate"]) ?? 10,
            emissionRateCurve: deserializeParticleCurve(d["emissionRateCurve"], default: .constant(1)),
            distanceEmissionRate: jsonToFloat(d["distanceEmissionRate"]) ?? 0,
            distanceEmissionRateCurve: deserializeParticleCurve(d["distanceEmissionRateCurve"], default: .constant(1)),
            burstCount: jsonToInt(d["burstCount"]) ?? 0,
            burstInterval: jsonToFloat(d["burstInterval"]) ?? 0,
            maxParticles: jsonToInt(d["maxParticles"]) ?? 256,
            maxSpawnedParticlesPerFrame: jsonToInt(d["maxSpawnedParticlesPerFrame"]) ?? 0,
            maxRenderedParticles: jsonToInt(d["maxRenderedParticles"]) ?? 0,
            lifetime: jsonToFloat(d["lifetime"]) ?? 2,
            lifetimeRandomness: jsonToFloat(d["lifetimeRandomness"]) ?? 0,
            subEmitterTrigger: ParticleSubEmitterTrigger(rawValue: jsonToString(d["subEmitterTrigger"]) ?? "none") ?? .none,
            subEmitterBurstCount: jsonToInt(d["subEmitterBurstCount"]) ?? 0,
            subEmitterProbability: jsonToFloat(d["subEmitterProbability"]) ?? 1,
            subEmitterMaxDepth: jsonToInt(d["subEmitterMaxDepth"]) ?? 1,
            subEmitterInheritVelocity: jsonToFloat(d["subEmitterInheritVelocity"]) ?? 0,
            subEmitterLifetime: jsonToFloat(d["subEmitterLifetime"]) ?? 0.5,
            subEmitterStartVelocity: jsonToFloatArray(d["subEmitterStartVelocity"]).flatMap(jsonToVec3) ?? .zero,
            subEmitterVelocityRandomness: jsonToFloatArray(d["subEmitterVelocityRandomness"]).flatMap(jsonToVec3) ?? .zero,
            subEmitterStartSize: jsonToFloat(d["subEmitterStartSize"]) ?? 0.25,
            subEmitterEndSize: jsonToFloat(d["subEmitterEndSize"]) ?? 0,
            subEmitterStartColor: jsonToFloatArray(d["subEmitterStartColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            subEmitterEndColor: jsonToFloatArray(d["subEmitterEndColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 0),
            subEmitters: jsonToArray(d["subEmitters"])?.compactMap {
                jsonToDict($0).map(deserializeParticleSubEmitter)
            } ?? [],
            originOffset: jsonToFloatArray(d["originOffset"]).flatMap(jsonToVec3) ?? .zero,
            spawnRadius: jsonToFloat(d["spawnRadius"]) ?? 0,
            emissionShape: ParticleEmissionShape(rawValue: jsonToString(d["emissionShape"]) ?? "sphere") ?? .sphere,
            boxHalfExtents: jsonToFloatArray(d["boxHalfExtents"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0.5, 0.5, 0.5),
            coneRadius: jsonToFloat(d["coneRadius"]) ?? 0.5,
            coneHeight: jsonToFloat(d["coneHeight"]) ?? 1,
            startVelocity: jsonToFloatArray(d["startVelocity"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            velocityRandomness: jsonToFloatArray(d["velocityRandomness"]).flatMap(jsonToVec3) ?? .zero,
            velocityInheritance: jsonToFloat(d["velocityInheritance"]) ?? 0,
            gravity: jsonToFloatArray(d["gravity"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, -9.81, 0),
            noiseStrength: jsonToFloat(d["noiseStrength"]) ?? 0,
            noiseScale: jsonToFloat(d["noiseScale"]) ?? 1,
            noiseSpeed: jsonToFloat(d["noiseSpeed"]) ?? 1,
            forceMode: ParticleForceMode(rawValue: jsonToString(d["forceMode"]) ?? "none") ?? .none,
            forceCenter: jsonToFloatArray(d["forceCenter"]).flatMap(jsonToVec3) ?? .zero,
            forceAxis: jsonToFloatArray(d["forceAxis"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            forceRadius: jsonToFloat(d["forceRadius"]) ?? 0,
            forceStrength: jsonToFloat(d["forceStrength"]) ?? 0,
            forceFalloff: jsonToFloat(d["forceFalloff"]) ?? 1,
            vectorFieldMode: ParticleVectorFieldMode(rawValue: jsonToString(d["vectorFieldMode"]) ?? "none") ?? .none,
            vectorFieldDirection: jsonToFloatArray(d["vectorFieldDirection"]).flatMap(jsonToVec3)
                ?? SIMD3<Float>(0, 1, 0),
            vectorFieldStrength: jsonToFloat(d["vectorFieldStrength"]) ?? 0,
            vectorFieldScale: jsonToFloat(d["vectorFieldScale"]) ?? 1,
            vectorFieldScrollSpeed: jsonToFloat(d["vectorFieldScrollSpeed"]) ?? 0,
            collisionMode: ParticleCollisionMode(rawValue: jsonToString(d["collisionMode"]) ?? "none") ?? .none,
            simulationSpace: ParticleSimulationSpace(rawValue: jsonToString(d["simulationSpace"]) ?? "local") ?? .local,
            simulationBackend: ParticleSimulationBackend(rawValue: jsonToString(d["simulationBackend"]) ?? "cpu") ?? .cpu,
            gpuSimulationWorkgroupSize: jsonToInt(d["gpuSimulationWorkgroupSize"]) ?? 64,
            collisionPlaneY: jsonToFloat(d["collisionPlaneY"]) ?? 0,
            collisionRestitution: jsonToFloat(d["collisionRestitution"]) ?? 0.5,
            collisionDamping: jsonToFloat(d["collisionDamping"]) ?? 0,
            startSize: jsonToFloat(d["startSize"]) ?? 1,
            endSize: jsonToFloat(d["endSize"]) ?? 0,
            sizeRandomness: jsonToFloat(d["sizeRandomness"]) ?? 0,
            startRotation: jsonToFloat(d["startRotation"]) ?? 0,
            rotationRandomness: jsonToFloat(d["rotationRandomness"]) ?? 0,
            angularVelocity: jsonToFloat(d["angularVelocity"]) ?? 0,
            angularVelocityRandomness: jsonToFloat(d["angularVelocityRandomness"]) ?? 0,
            sizeCurve: deserializeParticleCurve(d["sizeCurve"]),
            startColor: jsonToFloatArray(d["startColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            endColor: jsonToFloatArray(d["endColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 0),
            colorCurve: deserializeParticleCurve(d["colorCurve"]),
            blendMode: ParticleBlendMode(rawValue: jsonToString(d["blendMode"]) ?? "alpha") ?? .alpha,
            renderMode: ParticleRenderMode(rawValue: jsonToString(d["renderMode"]) ?? "billboard") ?? .billboard,
            sortMode: ParticleSortMode(rawValue: jsonToString(d["sortMode"]) ?? "distanceDescending") ?? .distanceDescending,
            renderSortPriority: jsonToInt(d["renderSortPriority"]) ?? 0,
            ribbonWidthScale: jsonToFloat(d["ribbonWidthScale"]) ?? 1,
            ribbonTailWidthScale: jsonToFloat(d["ribbonTailWidthScale"]) ?? 1,
            ribbonTailAlphaScale: jsonToFloat(d["ribbonTailAlphaScale"]) ?? 1,
            ribbonMaxSegmentLength: jsonToFloat(d["ribbonMaxSegmentLength"]) ?? 0,
            ribbonJoinOverlapScale: jsonToFloat(d["ribbonJoinOverlapScale"]) ?? 0,
            ribbonSmoothingSegments: jsonToInt(d["ribbonSmoothingSegments"]) ?? 1,
            ribbonTextureTiling: jsonToFloat(d["ribbonTextureTiling"]) ?? 0,
            ribbonTextureOffset: jsonToFloat(d["ribbonTextureOffset"]) ?? 0,
            renderAlignment: ParticleRenderAlignment(rawValue: jsonToString(d["renderAlignment"]) ?? "billboard") ?? .billboard,
            velocityStretchScale: jsonToFloat(d["velocityStretchScale"]) ?? 0,
            velocityStretchMax: jsonToFloat(d["velocityStretchMax"]) ?? 8,
            maxRenderDistance: jsonToFloat(d["maxRenderDistance"]) ?? 0,
            renderDistanceFadeRange: jsonToFloat(d["renderDistanceFadeRange"]) ?? 0,
            renderLODStartDistance: jsonToFloat(d["renderLODStartDistance"]) ?? 0,
            renderLODEndDistance: jsonToFloat(d["renderLODEndDistance"]) ?? 0,
            renderLODMinParticleScale: jsonToFloat(d["renderLODMinParticleScale"]) ?? 1,
            renderBoundsMode: renderBoundsMode,
            renderBoundsRadius: renderBoundsRadius,
            textureAssetID: jsonToString(d["textureAssetID"]),
            texturePath: jsonToString(d["texturePath"]),
            textureSheetColumns: jsonToInt(d["textureSheetColumns"]) ?? 1,
            textureSheetRows: jsonToInt(d["textureSheetRows"]) ?? 1,
            textureSheetFrameCount: jsonToInt(d["textureSheetFrameCount"]) ?? 1,
            textureSheetFrameRate: jsonToFloat(d["textureSheetFrameRate"]) ?? 0,
            textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode(
                rawValue: jsonToString(d["textureSheetPlaybackMode"]) ?? "automatic"
            ) ?? .automatic,
            textureSheetStartFrame: jsonToInt(d["textureSheetStartFrame"]) ?? 0,
            textureSheetFrameRandomness: jsonToInt(d["textureSheetFrameRandomness"]) ?? 0,
            trailLength: jsonToFloat(d["trailLength"]) ?? 0,
            trailSegments: jsonToInt(d["trailSegments"]) ?? 0,
            trailEndSizeScale: jsonToFloat(d["trailEndSizeScale"]) ?? 0.5,
            trailEndAlphaScale: jsonToFloat(d["trailEndAlphaScale"]) ?? 0,
            seed: UInt64(bitPattern: Int64(jsonToInt(d["seed"]) ?? 0))
        )
        if let moduleStack = decodeJSONValue(d["moduleStack"], as: ParticleModuleStack.self) {
            emitter.apply(moduleStack)
        }
        return emitter
    }

    private static func serializeParticleSubEmitter(_ c: ParticleSubEmitter) -> [String: Any] {
        [
            "trigger": c.trigger.rawValue,
            "burstCount": c.burstCount,
            "probability": c.probability,
            "maxDepth": c.maxDepth,
            "inheritVelocity": c.inheritVelocity,
            "lifetime": c.lifetime,
            "startVelocity": vec3ToJSON(c.startVelocity),
            "velocityRandomness": vec3ToJSON(c.velocityRandomness),
            "startSize": c.startSize,
            "endSize": c.endSize,
            "startColor": vec4ToJSON(c.startColor),
            "endColor": vec4ToJSON(c.endColor),
        ]
    }

    private static func deserializeParticleSubEmitter(_ d: [String: Any]) -> ParticleSubEmitter {
        ParticleSubEmitter(
            trigger: ParticleSubEmitterTrigger(rawValue: jsonToString(d["trigger"]) ?? "none") ?? .none,
            burstCount: jsonToInt(d["burstCount"]) ?? 0,
            probability: jsonToFloat(d["probability"]) ?? 1,
            maxDepth: jsonToInt(d["maxDepth"]) ?? 1,
            inheritVelocity: jsonToFloat(d["inheritVelocity"]) ?? 0,
            lifetime: jsonToFloat(d["lifetime"]) ?? 0.5,
            startVelocity: jsonToFloatArray(d["startVelocity"]).flatMap(jsonToVec3) ?? .zero,
            velocityRandomness: jsonToFloatArray(d["velocityRandomness"]).flatMap(jsonToVec3) ?? .zero,
            startSize: jsonToFloat(d["startSize"]) ?? 0.25,
            endSize: jsonToFloat(d["endSize"]) ?? 0,
            startColor: jsonToFloatArray(d["startColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 1),
            endColor: jsonToFloatArray(d["endColor"]).flatMap(jsonToVec4) ?? SIMD4<Float>(1, 1, 1, 0)
        )
    }

    private static func serializeParticleCurve(_ curve: ParticleCurve) -> Any {
        switch curve {
        case .constant(let value):
            return [
                "type": curve.rawValue,
                "value": value,
            ]
        case .linear, .easeIn, .easeOut, .easeInOut:
            return curve.rawValue
        case .keyframes(let keyframes):
            return [
                "type": curve.rawValue,
                "keyframes": keyframes.map {
                    [
                        "time": $0.time,
                        "value": $0.value,
                    ]
                },
            ]
        }
    }

    private static func deserializeParticleCurve(_ value: Any?, default defaultCurve: ParticleCurve = .linear) -> ParticleCurve {
        if let raw = jsonToString(value) {
            return ParticleCurve(rawValue: raw) ?? defaultCurve
        }
        guard let dict = jsonToDict(value) else {
            return defaultCurve
        }
        let type = jsonToString(dict["type"]) ?? "linear"
        if type == "constant" {
            return .constant(jsonToFloat(dict["value"]) ?? 1)
        }
        guard type == "keyframes" else {
            return ParticleCurve(rawValue: type) ?? defaultCurve
        }
        let keyframes = (dict["keyframes"] as? [[String: Any]] ?? []).compactMap { frame -> ParticleCurveKeyframe? in
            guard let time = jsonToFloat(frame["time"]),
                  let value = jsonToFloat(frame["value"])
            else {
                return nil
            }
            return ParticleCurveKeyframe(time: time, value: value)
        }
        return .keyframes(keyframes)
    }
}

public enum SceneSerializerError: Error {
    case invalidFormat
    case unsupportedVersion(Int)
}
