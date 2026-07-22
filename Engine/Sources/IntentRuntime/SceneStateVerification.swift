import SceneRuntime
import ScriptRuntime
import SIMDCompat

/// Host-owned authored-state snapshots used by post-apply verification.
public enum SceneColliderShapeVerificationState: Codable, Sendable, Equatable {
    case box(halfExtents: [Float], center: [Float])
    case sphere(radius: Float, center: [Float])
    case capsule(radius: Float, halfHeight: Float, center: [Float])
    case cylinder(radius: Float, halfHeight: Float, center: [Float])
    case heightField(resourceID: String?, center: [Float])
    case mesh(resourceID: String?, center: [Float])
    case convex(resourceID: String?, center: [Float])

    public init(_ shape: ColliderShape) {
        switch shape {
        case let .box(halfExtents, center):
            self = .box(halfExtents: halfExtents.verificationArray,
                        center: center.verificationArray)
        case let .sphere(radius, center):
            self = .sphere(radius: radius, center: center.verificationArray)
        case let .capsule(radius, halfHeight, center):
            self = .capsule(radius: radius,
                            halfHeight: halfHeight,
                            center: center.verificationArray)
        case let .cylinder(radius, halfHeight, center):
            self = .cylinder(radius: radius,
                             halfHeight: halfHeight,
                             center: center.verificationArray)
        case let .heightField(resourceID, center):
            self = .heightField(resourceID: resourceID, center: center.verificationArray)
        case let .mesh(resourceID, center):
            self = .mesh(resourceID: resourceID, center: center.verificationArray)
        case let .convex(resourceID, center):
            self = .convex(resourceID: resourceID, center: center.verificationArray)
        }
    }
}

public struct SceneAudioSourceVerificationState: Codable, Sendable, Equatable {
    public var clipName: String
    public var volume: Float
    public var pitch: Float
    public var loop: Bool
    public var playOnAwake: Bool
    public var spatialBlend: Float

    public init(_ source: AudioSource) {
        clipName = source.clipName
        volume = source.volume
        pitch = source.pitch
        loop = source.loop
        playOnAwake = source.playOnAwake
        spatialBlend = source.spatialBlend
    }
}

public struct SceneScriptBindingVerificationState: Codable, Sendable, Equatable {
    public var scriptHandle: UInt64
    public var isEnabled: Bool
    public var parametersJSON: String

    public init(_ binding: ScriptBinding) {
        scriptHandle = binding.script.rawValue
        isEnabled = binding.isEnabled
        parametersJSON = binding.parametersJSON
    }
}

public struct SceneAnimationPlayerVerificationState: Codable, Sendable, Equatable {
    public var clipName: String?
    public var speed: Float
    public var loop: Bool
    public var isPlaying: Bool
    public var time: Double

    public init(_ player: AnimationPlayer) {
        clipName = player.clipName
        speed = player.speed
        loop = player.loop
        isPlaying = player.isPlaying
        time = player.time
    }
}

/// Exact, deterministic values checked after all transaction operations run.
/// A mismatch fails the transaction and restores the pre-transaction snapshots.
public enum SceneStateAssertion: Codable, Sendable, Equatable {
    case parent(entityID: UInt64, parentID: UInt64?)
    case localTransform(entityID: UInt64, matrix: [Float])
    case sceneName(entityID: UInt64, value: String)
    case rigidBodyMotionType(entityID: UInt64, value: String)
    case rigidBodyMass(entityID: UInt64, value: Float)
    case rigidBodyGravityScale(entityID: UInt64, value: Float)
    case rigidBodyAllowSleep(entityID: UInt64, value: Bool)
    case colliderPrimaryShape(entityID: UInt64,
                              value: SceneColliderShapeVerificationState)
    case colliderTrigger(entityID: UInt64, value: Bool)
    case colliderShapeType(entityID: UInt64, value: String)
    case colliderBoxHalfExtents(entityID: UInt64, value: [Float])
    case colliderSphereRadius(entityID: UInt64, value: Float)
    case colliderCapsuleRadius(entityID: UInt64, value: Float)
    case colliderCapsuleHalfHeight(entityID: UInt64, value: Float)
    case colliderFriction(entityID: UInt64, value: Float)
    case colliderRestitution(entityID: UInt64, value: Float)
    case colliderDensity(entityID: UInt64, value: Float)
    case colliderLayer(entityID: UInt64, value: UInt16)
    case colliderLayerMask(entityID: UInt64, value: UInt16)
    case constraintEnabled(entityID: UInt64, value: Bool)
    case lightType(entityID: UInt64, value: String)
    case lightColor(entityID: UInt64, value: [Float])
    case lightIntensity(entityID: UInt64, value: Float)
    case lightRange(entityID: UInt64, value: Float)
    case lightSpotInnerAngle(entityID: UInt64, value: Float)
    case lightSpotOuterAngle(entityID: UInt64, value: Float)
    case lightCastShadows(entityID: UInt64, value: Bool)
    case meshColor(entityID: UInt64, value: [Float])
    case meshVisibility(entityID: UInt64, value: Bool)
    case material(entityID: UInt64,
                  baseColor: [Float],
                  metallic: Float,
                  roughness: Float,
                  emissive: [Float])
    case scriptBindings(entityID: UInt64, value: [SceneScriptBindingVerificationState])
    case cameraTarget(entityID: UInt64, value: [Float])
    case cameraUp(entityID: UInt64, value: [Float])
    case cameraFOVRadians(entityID: UInt64, value: Float)
    case cameraAspectRatio(entityID: UInt64, value: Float)
    case cameraActive(entityID: UInt64, value: Bool)
    case audioSource(entityID: UInt64, value: SceneAudioSourceVerificationState)
    case animationPlayer(entityID: UInt64, value: SceneAnimationPlayerVerificationState)
    case audioListenerVolume(entityID: UInt64, value: Float)

    func failureDescription(in scene: SceneRuntime) -> String? {
        let entityID = targetEntityID
        let entity = EntityID(index: UInt32(entityID & 0xFFFF_FFFF),
                              generation: UInt32(entityID >> 32))
        guard scene.contains(entity) else { return "entity \(entityID) does not exist" }

        let matched: Bool
        switch self {
        case let .parent(_, expected):
            matched = scene.parent(of: entity)?.rawValue == expected
        case let .localTransform(_, expected):
            matched = scene.localTransform(for: entity)?.matrix.verificationArray == expected
        case let .sceneName(_, expected):
            matched = scene.component(SceneNameComponent.self, for: entity)?.value == expected
        case let .rigidBodyMotionType(_, expected):
            matched = scene.component(RigidBody.self, for: entity)?.motionType.rawValue == expected
        case let .rigidBodyMass(_, expected):
            matched = scene.component(RigidBody.self, for: entity)?.mass == expected
        case let .rigidBodyGravityScale(_, expected):
            matched = scene.component(RigidBody.self, for: entity)?.gravityScale == expected
        case let .rigidBodyAllowSleep(_, expected):
            matched = scene.component(RigidBody.self, for: entity)?.allowSleep == expected
        case let .colliderPrimaryShape(_, expected):
            if let shape = scene.component(Collider.self, for: entity)?.shape {
                matched = SceneColliderShapeVerificationState(shape) == expected
            } else {
                matched = false
            }
        case let .colliderTrigger(_, expected):
            matched = scene.component(Collider.self, for: entity)?.isTrigger == expected
        case let .colliderShapeType(_, expected):
            matched = scene.component(Collider.self, for: entity)?.shape.kind.rawValue == expected
        case let .colliderBoxHalfExtents(_, expected):
            guard case let .box(halfExtents, _)? = scene.component(Collider.self, for: entity)?.shape
            else { matched = false; break }
            matched = halfExtents.verificationArray == expected
        case let .colliderSphereRadius(_, expected):
            guard case let .sphere(radius, _)? = scene.component(Collider.self, for: entity)?.shape
            else { matched = false; break }
            matched = radius == expected
        case let .colliderCapsuleRadius(_, expected):
            guard case let .capsule(radius, _, _)? = scene.component(Collider.self, for: entity)?.shape
            else { matched = false; break }
            matched = radius == expected
        case let .colliderCapsuleHalfHeight(_, expected):
            guard case let .capsule(_, halfHeight, _)? = scene.component(Collider.self, for: entity)?.shape
            else { matched = false; break }
            matched = halfHeight == expected
        case let .colliderFriction(_, expected):
            matched = scene.component(Collider.self, for: entity)?.material.friction == expected
        case let .colliderRestitution(_, expected):
            matched = scene.component(Collider.self, for: entity)?.material.restitution == expected
        case let .colliderDensity(_, expected):
            matched = scene.component(Collider.self, for: entity)?.material.density == expected
        case let .colliderLayer(_, expected):
            matched = scene.component(Collider.self, for: entity)?.layerID == expected
        case let .colliderLayerMask(_, expected):
            matched = scene.component(Collider.self, for: entity)?.layerMask == expected
        case let .constraintEnabled(_, expected):
            matched = scene.component(Constraint.self, for: entity)?.isEnabled == expected
        case let .lightType(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.type.rawValue == expected
        case let .lightColor(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.color.verificationArray
                == expected
        case let .lightIntensity(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.intensity == expected
        case let .lightRange(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.range == expected
        case let .lightSpotInnerAngle(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees
                == expected
        case let .lightSpotOuterAngle(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees
                == expected
        case let .lightCastShadows(_, expected):
            matched = scene.component(LightComponent.self, for: entity)?.castShadows == expected
        case let .meshColor(_, expected):
            matched = scene.component(RenderMeshComponent.self, for: entity)?.colorTint
                .verificationArray == expected
        case let .meshVisibility(_, expected):
            matched = scene.component(RenderMeshComponent.self, for: entity)?.isVisible == expected
        case let .material(_, baseColor, metallic, roughness, emissive):
            guard let material = scene.component(RenderMaterialComponent.self, for: entity) else {
                matched = false; break
            }
            matched = material.baseColorFactor.verificationArray == baseColor
                && material.metallicFactor == metallic
                && material.roughnessFactor == roughness
                && material.emissiveFactor.verificationArray == emissive
        case let .scriptBindings(_, expected):
            matched = scene.component(ScriptComponent.self, for: entity)?.bindings
                .map(SceneScriptBindingVerificationState.init) == expected
        case let .cameraTarget(_, expected):
            matched = scene.component(CameraComponent.self, for: entity)?.target
                .verificationArray == expected
        case let .cameraUp(_, expected):
            matched = scene.component(CameraComponent.self, for: entity)?.up
                .verificationArray == expected
        case let .cameraFOVRadians(_, expected):
            matched = scene.component(CameraComponent.self, for: entity)?.fovYRadians == expected
        case let .cameraAspectRatio(_, expected):
            matched = scene.component(CameraComponent.self, for: entity)?.aspectRatio == expected
        case let .cameraActive(_, expected):
            matched = scene.component(CameraComponent.self, for: entity)?.isActive == expected
        case let .audioSource(_, expected):
            matched = scene.component(AudioSource.self, for: entity)
                .map(SceneAudioSourceVerificationState.init) == expected
        case let .animationPlayer(_, expected):
            matched = scene.component(AnimationPlayer.self, for: entity)
                .map(SceneAnimationPlayerVerificationState.init) == expected
        case let .audioListenerVolume(_, expected):
            matched = scene.component(AudioListener.self, for: entity)?.masterVolume == expected
        }
        return matched ? nil : "scene state did not match field '\(verificationKey)'"
    }

    private var targetEntityID: UInt64 {
        switch self {
        case let .parent(id, _), let .localTransform(id, _), let .sceneName(id, _),
             let .rigidBodyMotionType(id, _), let .rigidBodyMass(id, _),
             let .rigidBodyGravityScale(id, _), let .rigidBodyAllowSleep(id, _),
             let .colliderPrimaryShape(id, _),
             let .colliderTrigger(id, _), let .colliderShapeType(id, _),
             let .colliderBoxHalfExtents(id, _), let .colliderSphereRadius(id, _),
             let .colliderCapsuleRadius(id, _), let .colliderCapsuleHalfHeight(id, _),
             let .colliderFriction(id, _), let .colliderRestitution(id, _),
             let .colliderDensity(id, _), let .colliderLayer(id, _),
             let .colliderLayerMask(id, _), let .constraintEnabled(id, _),
             let .lightType(id, _), let .lightColor(id, _), let .lightIntensity(id, _),
             let .lightRange(id, _), let .lightSpotInnerAngle(id, _),
             let .lightSpotOuterAngle(id, _), let .lightCastShadows(id, _),
             let .meshColor(id, _), let .meshVisibility(id, _),
             let .scriptBindings(id, _), let .cameraTarget(id, _), let .cameraUp(id, _),
             let .cameraFOVRadians(id, _),
             let .cameraAspectRatio(id, _), let .cameraActive(id, _),
             let .audioSource(id, _), let .animationPlayer(id, _),
             let .audioListenerVolume(id, _):
            return id
        case let .material(id, _, _, _, _):
            return id
        }
    }

    var verificationKey: String {
        let field: String
        switch self {
        case .parent: field = "parent"
        case .localTransform: field = "localTransform"
        case .sceneName: field = "sceneName"
        case .rigidBodyMotionType: field = "rigidBody.motionType"
        case .rigidBodyMass: field = "rigidBody.mass"
        case .rigidBodyGravityScale: field = "rigidBody.gravityScale"
        case .rigidBodyAllowSleep: field = "rigidBody.allowSleep"
        case .colliderPrimaryShape: field = "collider.primaryShape"
        case .colliderTrigger: field = "collider.isTrigger"
        case .colliderShapeType: field = "collider.primaryShape.kind"
        case .colliderBoxHalfExtents: field = "collider.primaryShape.boxHalfExtents"
        case .colliderSphereRadius: field = "collider.primaryShape.sphereRadius"
        case .colliderCapsuleRadius: field = "collider.primaryShape.radius"
        case .colliderCapsuleHalfHeight: field = "collider.primaryShape.halfHeight"
        case .colliderFriction: field = "collider.friction"
        case .colliderRestitution: field = "collider.restitution"
        case .colliderDensity: field = "collider.density"
        case .colliderLayer: field = "collider.layer"
        case .colliderLayerMask: field = "collider.layerMask"
        case .constraintEnabled: field = "constraint.isEnabled"
        case .lightType: field = "light.type"
        case .lightColor: field = "light.color"
        case .lightIntensity: field = "light.intensity"
        case .lightRange: field = "light.range"
        case .lightSpotInnerAngle: field = "light.spotInner"
        case .lightSpotOuterAngle: field = "light.spotOuter"
        case .lightCastShadows: field = "light.castShadows"
        case .meshColor: field = "mesh.color"
        case .meshVisibility: field = "mesh.isVisible"
        case .material: field = "material"
        case .scriptBindings: field = "script.bindings"
        case .cameraTarget: field = "camera.target"
        case .cameraUp: field = "camera.up"
        case .cameraFOVRadians: field = "camera.fov"
        case .cameraAspectRatio: field = "camera.aspectRatio"
        case .cameraActive: field = "camera.isActive"
        case .audioSource: field = "audio.source"
        case .animationPlayer: field = "animation.player"
        case .audioListenerVolume: field = "audio.listenerVolume"
        }
        return "\(targetEntityID):\(field)"
    }

    /// A shape replacement makes detail assertions for the previous shape
    /// obsolete, while details emitted after this assertion still describe the
    /// replacement itself and remain active.
    var supersededVerificationKeys: Set<String> {
        switch self {
        case .colliderShapeType, .colliderPrimaryShape:
            return Set([
                "collider.primaryShape",
                "collider.primaryShape.boxHalfExtents",
                "collider.primaryShape.sphereRadius",
                "collider.primaryShape.radius",
                "collider.primaryShape.halfHeight",
            ].map { "\(targetEntityID):\($0)" })
        default:
            return []
        }
    }
}

extension TransactionVerificationAssertion {
    static func exactPostconditions(
        for operation: TransactionOperation
    ) -> [TransactionVerificationAssertion] {
        guard case let .scene(mutation) = operation else { return [] }
        var state: [SceneStateAssertion]
        switch mutation {
        case .spawnImportedMeshEntity, .spawnEmptyEntity, .spawnLightEntity, .spawnCameraEntity,
             .deleteEntity, .duplicateEntity, .duplicateEntityWithOffset:
            state = []
        case let .moveEntity(entityID, parentID, _):
            state = [.parent(entityID: entityID, parentID: parentID)]
        case let .setLocalTransform(entityID, transform):
            state = [.localTransform(entityID: entityID,
                                     matrix: transform.matrix.verificationArray)]
        case let .setSceneName(entityID, value):
            state = [.sceneName(entityID: entityID, value: value)]
        case let .setRigidBodyMotionType(entityID, value):
            state = [.rigidBodyMotionType(entityID: entityID, value: value.rawValue)]
        case let .setRigidBodyMass(entityID, value):
            state = [.rigidBodyMass(entityID: entityID, value: max(0, value))]
        case let .setRigidBodyGravityScale(entityID, value):
            state = [.rigidBodyGravityScale(entityID: entityID, value: value)]
        case let .setRigidBodyAllowSleep(entityID, value):
            state = [.rigidBodyAllowSleep(entityID: entityID, value: value)]
        case let .setRigidBody(entityID, body):
            state = [
                .rigidBodyMotionType(entityID: entityID, value: body.motionType.rawValue),
                .rigidBodyMass(entityID: entityID, value: body.mass),
                .rigidBodyGravityScale(entityID: entityID, value: body.gravityScale),
                .rigidBodyAllowSleep(entityID: entityID, value: body.allowSleep),
            ]
        case let .setCollider(entityID, collider):
            state = exactColliderShapePostconditions(entityID: entityID,
                                                     shape: collider.shape) + [
                .colliderTrigger(entityID: entityID, value: collider.isTrigger),
                .colliderFriction(entityID: entityID, value: collider.material.friction),
                .colliderRestitution(entityID: entityID,
                                     value: collider.material.restitution),
                .colliderDensity(entityID: entityID, value: collider.material.density),
                .colliderLayer(entityID: entityID, value: collider.layerID),
                .colliderLayerMask(entityID: entityID, value: collider.layerMask),
            ]
        case let .setColliderTrigger(entityID, value):
            state = [.colliderTrigger(entityID: entityID, value: value)]
        case let .setColliderShapeType(entityID, kind):
            state = [.colliderShapeType(entityID: entityID, value: kind.rawValue)]
        case let .setColliderShapeBoxHalfExtents(entityID, value):
            state = [.colliderBoxHalfExtents(entityID: entityID,
                                             value: value.verificationArray)]
        case let .setColliderShapeSphereRadius(entityID, value):
            state = [.colliderSphereRadius(entityID: entityID, value: value)]
        case let .setColliderShapeCapsuleRadius(entityID, value):
            state = [.colliderCapsuleRadius(entityID: entityID, value: value)]
        case let .setColliderShapeCapsuleHalfHeight(entityID, value):
            state = [.colliderCapsuleHalfHeight(entityID: entityID, value: value)]
        case let .setColliderMaterialFriction(entityID, value):
            state = [.colliderFriction(entityID: entityID, value: max(0, value))]
        case let .setColliderMaterialRestitution(entityID, value):
            state = [.colliderRestitution(entityID: entityID,
                                          value: max(0, min(value, 1)))]
        case let .setColliderMaterialDensity(entityID, value):
            state = [.colliderDensity(entityID: entityID, value: max(0, value))]
        case let .setColliderLayer(entityID, value):
            state = [.colliderLayer(entityID: entityID, value: value)]
        case let .setColliderLayerMask(entityID, value):
            state = [.colliderLayerMask(entityID: entityID, value: value)]
        case let .setConstraintEnabled(entityID, value):
            state = [.constraintEnabled(entityID: entityID, value: value)]
        case let .setLightType(entityID, value):
            state = [.lightType(entityID: entityID, value: value.rawValue)]
        case let .setLightColor(entityID, value):
            state = [.lightColor(entityID: entityID, value: value.verificationArray)]
        case let .setLightIntensity(entityID, value):
            state = [.lightIntensity(entityID: entityID, value: max(0, value))]
        case let .setLightRange(entityID, value):
            state = [.lightRange(entityID: entityID, value: max(0, value))]
        case let .setLightSpotInnerAngle(entityID, value):
            state = [.lightSpotInnerAngle(entityID: entityID,
                                          value: max(0, min(179, value)))]
        case let .setLightSpotOuterAngle(entityID, value):
            state = [.lightSpotOuterAngle(entityID: entityID,
                                          value: max(1, min(179, value)))]
        case let .setLightCastShadows(entityID, value):
            state = [.lightCastShadows(entityID: entityID, value: value)]
        case let .setMeshColorTint(entityID, value):
            let clamped = SIMD3(max(0, value.x), max(0, value.y), max(0, value.z))
            state = [.meshColor(entityID: entityID, value: clamped.verificationArray)]
        case let .setRenderMeshVisibility(entityID, value):
            state = [.meshVisibility(entityID: entityID, value: value)]
        case let .setRenderMaterialComponent(entityID, baseColor, metallic, roughness, emissive):
            let material = RenderMaterialComponent(baseColorFactor: baseColor,
                                                   metallicFactor: metallic,
                                                   roughnessFactor: roughness,
                                                   emissiveFactor: emissive)
            state = [.material(entityID: entityID,
                               baseColor: material.baseColorFactor.verificationArray,
                               metallic: material.metallicFactor,
                               roughness: material.roughnessFactor,
                               emissive: material.emissiveFactor.verificationArray)]
        case let .setScriptBindings(entityID, bindings):
            state = [.scriptBindings(entityID: entityID,
                                     value: bindings.map(SceneScriptBindingVerificationState.init))]
        case let .setCameraPose(entityID, transform, target, up):
            state = [
                .localTransform(entityID: entityID,
                                matrix: transform.matrix.verificationArray),
                .cameraTarget(entityID: entityID, value: target.verificationArray),
            ]
            if let up {
                state.append(.cameraUp(entityID: entityID, value: up.verificationArray))
            }
        case let .setCameraFOV(entityID, degrees):
            state = [.cameraFOVRadians(entityID: entityID, value: degrees * .pi / 180)]
        case let .setCameraAspectRatio(entityID, value):
            state = [.cameraAspectRatio(entityID: entityID, value: max(0.001, value))]
        case let .setCameraActive(entityID, value):
            state = [.cameraActive(entityID: entityID, value: value)]
        case let .setAudioSource(entityID, source):
            state = [.audioSource(entityID: entityID,
                                  value: SceneAudioSourceVerificationState(source))]
        case let .setAnimationPlayer(entityID, clipName, speed, loop, isPlaying):
            let player = AnimationPlayer(clipName: clipName,
                                         speed: speed,
                                         loop: loop,
                                         isPlaying: isPlaying)
            state = [.animationPlayer(entityID: entityID,
                                      value: SceneAnimationPlayerVerificationState(player))]
        case .setAnimationGraphPlayer, .setParticleEmitter:
            state = []
        case let .setAudioListener(entityID, volume):
            state = [.audioListenerVolume(entityID: entityID,
                                          value: max(0, min(volume, 1)))]
        }
        return state.map(TransactionVerificationAssertion.sceneState)
    }
}

private func exactColliderShapePostconditions(
    entityID: UInt64,
    shape: ColliderShape
) -> [SceneStateAssertion] {
    var result: [SceneStateAssertion] = [
        .colliderShapeType(entityID: entityID, value: shape.kind.rawValue),
    ]
    switch shape {
    case let .box(halfExtents, _):
        result.append(.colliderBoxHalfExtents(entityID: entityID,
                                              value: halfExtents.verificationArray))
    case let .sphere(radius, _):
        result.append(.colliderSphereRadius(entityID: entityID, value: radius))
    case let .capsule(radius, halfHeight, _):
        result.append(.colliderCapsuleRadius(entityID: entityID, value: radius))
        result.append(.colliderCapsuleHalfHeight(entityID: entityID, value: halfHeight))
    case .cylinder, .heightField, .mesh, .convex:
        result.append(.colliderPrimaryShape(
            entityID: entityID,
            value: SceneColliderShapeVerificationState(shape)
        ))
    }
    return result
}

private extension SIMD3 where Scalar == Float {
    var verificationArray: [Float] { [x, y, z] }
}

private extension SIMD4 where Scalar == Float {
    var verificationArray: [Float] { [x, y, z, w] }
}

private extension simd_float4x4 {
    var verificationArray: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w,
        ]
    }
}
