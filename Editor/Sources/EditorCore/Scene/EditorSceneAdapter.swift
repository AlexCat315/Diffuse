import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneNode: Identifiable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let children: [EditorSceneNode]

    public init(id: UInt64,
                name: String,
                kind: String,
                children: [EditorSceneNode]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
    }
}

public struct EditorSceneEntitySummary {
    public let id: UInt64
    public let name: String
    public let kind: String

    public init(id: UInt64, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

private final class EditorSceneManifestParticleEmitterStorage: Codable, @unchecked Sendable, Equatable {
    let value: EditorSceneManifestParticleEmitter

    init(_ value: EditorSceneManifestParticleEmitter) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        self.value = try EditorSceneManifestParticleEmitter(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    static func == (lhs: EditorSceneManifestParticleEmitterStorage,
                    rhs: EditorSceneManifestParticleEmitterStorage) -> Bool {
        lhs.value == rhs.value
    }
}

public struct EditorSceneManifestNode: Codable, Sendable, Equatable {
    public let id: UInt64
    public let name: String
    public let kind: String
    public let localTransform: EditorSceneManifestMatrix?
    public let asset: EditorSceneManifestAssetReference?
    public let renderMesh: EditorSceneManifestRenderMesh?
    public let renderMaterial: EditorSceneManifestRenderMaterial?
    public let camera: EditorSceneManifestCamera?
    public let light: EditorSceneManifestLight?
    public let rigidBody: EditorSceneManifestRigidBody?
    public let collider: EditorSceneManifestCollider?
    public let constraint: EditorSceneManifestConstraint?
    public let script: EditorSceneManifestScript?
    public let audioSource: EditorSceneManifestAudioSource?
    public let animationPlayer: EditorSceneManifestAnimationPlayer?
    public let animationGraphPlayer: EditorSceneManifestAnimationGraphPlayer?
    private let particleEmitterStorage: EditorSceneManifestParticleEmitterStorage?
    public var particleEmitter: EditorSceneManifestParticleEmitter? {
        particleEmitterStorage?.value
    }
    public let children: [EditorSceneManifestNode]

    public init(id: UInt64,
                name: String,
                kind: String,
                localTransform: EditorSceneManifestMatrix? = nil,
                asset: EditorSceneManifestAssetReference? = nil,
                renderMesh: EditorSceneManifestRenderMesh? = nil,
                renderMaterial: EditorSceneManifestRenderMaterial? = nil,
                camera: EditorSceneManifestCamera? = nil,
                light: EditorSceneManifestLight? = nil,
                rigidBody: EditorSceneManifestRigidBody? = nil,
                collider: EditorSceneManifestCollider? = nil,
                constraint: EditorSceneManifestConstraint? = nil,
                script: EditorSceneManifestScript? = nil,
                audioSource: EditorSceneManifestAudioSource? = nil,
                animationPlayer: EditorSceneManifestAnimationPlayer? = nil,
                animationGraphPlayer: EditorSceneManifestAnimationGraphPlayer? = nil,
                particleEmitter: EditorSceneManifestParticleEmitter? = nil,
                children: [EditorSceneManifestNode] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localTransform = localTransform
        self.asset = asset
        self.renderMesh = renderMesh
        self.renderMaterial = renderMaterial
        self.camera = camera
        self.light = light
        self.rigidBody = rigidBody
        self.collider = collider
        self.constraint = constraint
        self.script = script
        self.audioSource = audioSource
        self.animationPlayer = animationPlayer
        self.animationGraphPlayer = animationGraphPlayer
        self.particleEmitterStorage = particleEmitter.map(EditorSceneManifestParticleEmitterStorage.init)
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, localTransform, asset, renderMesh, renderMaterial
        case camera, light, rigidBody, collider, constraint, script, audioSource
        case animationPlayer, animationGraphPlayer, particleEmitter, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UInt64.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.localTransform = try c.decodeIfPresent(EditorSceneManifestMatrix.self, forKey: .localTransform)
        self.asset = try c.decodeIfPresent(EditorSceneManifestAssetReference.self, forKey: .asset)
        self.renderMesh = try c.decodeIfPresent(EditorSceneManifestRenderMesh.self, forKey: .renderMesh)
        self.renderMaterial = try c.decodeIfPresent(EditorSceneManifestRenderMaterial.self, forKey: .renderMaterial)
        self.camera = try c.decodeIfPresent(EditorSceneManifestCamera.self, forKey: .camera)
        self.light = try c.decodeIfPresent(EditorSceneManifestLight.self, forKey: .light)
        self.rigidBody = try c.decodeIfPresent(EditorSceneManifestRigidBody.self, forKey: .rigidBody)
        self.collider = try c.decodeIfPresent(EditorSceneManifestCollider.self, forKey: .collider)
        self.constraint = try c.decodeIfPresent(EditorSceneManifestConstraint.self, forKey: .constraint)
        self.script = try c.decodeIfPresent(EditorSceneManifestScript.self, forKey: .script)
        self.audioSource = try c.decodeIfPresent(EditorSceneManifestAudioSource.self, forKey: .audioSource)
        self.animationPlayer = try c.decodeIfPresent(EditorSceneManifestAnimationPlayer.self, forKey: .animationPlayer)
        self.animationGraphPlayer = try c.decodeIfPresent(EditorSceneManifestAnimationGraphPlayer.self,
                                                          forKey: .animationGraphPlayer)
        self.particleEmitterStorage = try c.decodeIfPresent(EditorSceneManifestParticleEmitterStorage.self,
                                                            forKey: .particleEmitter)
        self.children = try c.decodeIfPresent([EditorSceneManifestNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(localTransform, forKey: .localTransform)
        try c.encodeIfPresent(asset, forKey: .asset)
        try c.encodeIfPresent(renderMesh, forKey: .renderMesh)
        try c.encodeIfPresent(renderMaterial, forKey: .renderMaterial)
        try c.encodeIfPresent(camera, forKey: .camera)
        try c.encodeIfPresent(light, forKey: .light)
        try c.encodeIfPresent(rigidBody, forKey: .rigidBody)
        try c.encodeIfPresent(collider, forKey: .collider)
        try c.encodeIfPresent(constraint, forKey: .constraint)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(audioSource, forKey: .audioSource)
        try c.encodeIfPresent(animationPlayer, forKey: .animationPlayer)
        try c.encodeIfPresent(animationGraphPlayer, forKey: .animationGraphPlayer)
        try c.encodeIfPresent(particleEmitterStorage, forKey: .particleEmitter)
        try c.encode(children, forKey: .children)
    }
}

public struct EditorSceneManifestPhysicsSettings: Codable, Sendable, Equatable {
    public let simulationMode: String
    public let backendKind: String
    public let gravity: EditorSceneManifestVector3
    public let fixedTimeStepSeconds: Double
    public let maxSubstepsPerFrame: Int
    public let allowSleep: Bool

    public init(_ settings: PhysicsSettingsResource) {
        self.simulationMode = settings.simulationMode.rawValue
        self.backendKind = settings.backendKind.rawValue
        self.gravity = EditorSceneManifestVector3(settings.gravity)
        self.fixedTimeStepSeconds = settings.fixedTimeStepSeconds
        self.maxSubstepsPerFrame = settings.maxSubstepsPerFrame
        self.allowSleep = settings.allowSleep
    }

    var settings: PhysicsSettingsResource {
        PhysicsSettingsResource(
            simulationMode: PhysicsSimulationMode(rawValue: simulationMode) ?? .off,
            backendKind: PhysicsBackendKind(rawValue: backendKind) ?? .none,
            gravity: gravity.simdValue,
            fixedTimeStepSeconds: fixedTimeStepSeconds,
            maxSubstepsPerFrame: maxSubstepsPerFrame,
            allowSleep: allowSleep
        )
    }
}

public struct EditorSceneManifestParticleScalability: Codable, Sendable, Equatable {
    public let emissionScale: Float
    public let burstScale: Float
    public let distanceEmissionScale: Float
    public let maxLiveParticleScale: Float

    public init(_ settings: ParticleScalabilityResource) {
        self.emissionScale = settings.emissionScale
        self.burstScale = settings.burstScale
        self.distanceEmissionScale = settings.distanceEmissionScale
        self.maxLiveParticleScale = settings.maxLiveParticleScale
    }

    var settings: ParticleScalabilityResource {
        ParticleScalabilityResource(emissionScale: emissionScale,
                                    burstScale: burstScale,
                                    distanceEmissionScale: distanceEmissionScale,
                                    maxLiveParticleScale: maxLiveParticleScale)
    }
}

public struct EditorSceneManifestParticleScalabilityPolicy: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let targetLiveParticles: Int
    public let targetSpawnedParticlesPerFrame: Int
    public let minimumScale: Float
    public let pressureStep: Float
    public let recoveryStep: Float

    public init(_ policy: ParticleScalabilityPolicyResource) {
        self.isEnabled = policy.isEnabled
        self.targetLiveParticles = policy.targetLiveParticles
        self.targetSpawnedParticlesPerFrame = policy.targetSpawnedParticlesPerFrame
        self.minimumScale = policy.minimumScale
        self.pressureStep = policy.pressureStep
        self.recoveryStep = policy.recoveryStep
    }

    var policy: ParticleScalabilityPolicyResource {
        ParticleScalabilityPolicyResource(isEnabled: isEnabled,
                                          targetLiveParticles: targetLiveParticles,
                                          targetSpawnedParticlesPerFrame: targetSpawnedParticlesPerFrame,
                                          minimumScale: minimumScale,
                                          pressureStep: pressureStep,
                                          recoveryStep: recoveryStep)
    }
}

public struct EditorSceneManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: UInt64
    public let entityCount: Int
    public let selectedEntityID: UInt64?
    public let sceneKind: String?
    public let physicsSettings: EditorSceneManifestPhysicsSettings?
    public let particleScalability: EditorSceneManifestParticleScalability?
    public let particleScalabilityPolicy: EditorSceneManifestParticleScalabilityPolicy?
    public let projectAssetCount: Int?
    public let lastModifiedAt: String?
    public let roots: [EditorSceneManifestNode]

    public init(schemaVersion: Int = 4,
                revision: UInt64,
                entityCount: Int,
                selectedEntityID: UInt64? = nil,
                sceneKind: String? = nil,
                physicsSettings: EditorSceneManifestPhysicsSettings? = nil,
                particleScalability: EditorSceneManifestParticleScalability? = nil,
                particleScalabilityPolicy: EditorSceneManifestParticleScalabilityPolicy? = nil,
                projectAssetCount: Int? = nil,
                lastModifiedAt: String? = nil,
                roots: [EditorSceneManifestNode]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
        self.sceneKind = sceneKind
        self.physicsSettings = physicsSettings
        self.particleScalability = particleScalability
        self.particleScalabilityPolicy = particleScalabilityPolicy
        self.projectAssetCount = projectAssetCount
        self.lastModifiedAt = lastModifiedAt
        self.roots = roots
    }
}

public struct EditorSceneManifestLoadResult: Sendable, Equatable {
    public let entityCount: Int
    public let selectedEntityID: UInt64?

    public init(entityCount: Int, selectedEntityID: UInt64?) {
        self.entityCount = entityCount
        self.selectedEntityID = selectedEntityID
    }
}

public struct EditorSceneManifestVector3: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }

    var simdValue: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

public struct EditorSceneManifestVector4: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(_ value: SIMD4<Float>) {
        self.init(x: value.x, y: value.y, z: value.z, w: value.w)
    }

    var simdValue: SIMD4<Float> {
        SIMD4<Float>(x, y, z, w)
    }
}

public struct EditorSceneManifestMatrix: Codable, Sendable, Equatable {
    public let rows: [Float]

    public init(rows: [Float]) {
        self.rows = rows
    }

    public init(_ matrix: simd_float4x4) {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2
        let c3 = matrix.columns.3
        self.rows = [
            c0.x, c1.x, c2.x, c3.x,
            c0.y, c1.y, c2.y, c3.y,
            c0.z, c1.z, c2.z, c3.z,
            c0.w, c1.w, c2.w, c3.w,
        ]
    }

    var simdValue: simd_float4x4? {
        guard rows.count == 16 else { return nil }
        return simd_float4x4(rows: [
            SIMD4<Float>(rows[0], rows[1], rows[2], rows[3]),
            SIMD4<Float>(rows[4], rows[5], rows[6], rows[7]),
            SIMD4<Float>(rows[8], rows[9], rows[10], rows[11]),
            SIMD4<Float>(rows[12], rows[13], rows[14], rows[15]),
        ])
    }

    var localTransform: LocalTransform? {
        simdValue.map(LocalTransform.init(matrix:))
    }
}

public struct EditorSceneManifestAssetReference: Codable, Sendable, Equatable {
    public let assetID: String
    public let name: String
    public let relativePath: String
    public let absolutePath: String
    public let kind: String
    public let meshIndex: Int

    public init(assetID: String,
                name: String,
                relativePath: String,
                absolutePath: String,
                kind: String,
                meshIndex: Int) {
        self.assetID = assetID
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.meshIndex = meshIndex
    }

    public init(_ component: AssetReferenceComponent) {
        self.init(assetID: component.assetID,
                  name: component.name,
                  relativePath: component.relativePath,
                  absolutePath: component.absolutePath,
                  kind: component.kind,
                  meshIndex: component.meshIndex)
    }

    var component: AssetReferenceComponent {
        AssetReferenceComponent(assetID: assetID,
                                name: name,
                                relativePath: relativePath,
                                absolutePath: absolutePath,
                                kind: kind,
                                meshIndex: meshIndex)
    }
}

public struct EditorSceneManifestRenderMesh: Codable, Sendable, Equatable {
    public let meshIndex: Int
    public let isVisible: Bool
    public let colorTint: EditorSceneManifestVector3?
    public let assetID: String?

    public init(meshIndex: Int,
                isVisible: Bool,
                colorTint: EditorSceneManifestVector3? = nil,
                assetID: String? = nil) {
        self.meshIndex = meshIndex
        self.isVisible = isVisible
        self.colorTint = colorTint
        self.assetID = assetID
    }

    public init(_ component: RenderMeshComponent) {
        self.init(meshIndex: component.meshIndex,
                  isVisible: component.isVisible,
                  colorTint: EditorSceneManifestVector3(component.colorTint),
                  assetID: component.assetID)
    }

    var component: RenderMeshComponent {
        RenderMeshComponent(meshIndex: meshIndex,
                            isVisible: isVisible,
                            colorTint: colorTint?.simdValue ?? SIMD3<Float>(1, 1, 1),
                            assetID: assetID)
    }
}

public struct EditorSceneManifestRenderMaterial: Codable, Sendable, Equatable {
    public let baseColorFactor: EditorSceneManifestVector4
    public let baseColorTextureIndex: Int?
    public let normalTextureIndex: Int?
    public let metallicFactor: Float
    public let roughnessFactor: Float
    public let emissiveFactor: EditorSceneManifestVector3

    public init(baseColorFactor: EditorSceneManifestVector4,
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float,
                roughnessFactor: Float,
                emissiveFactor: EditorSceneManifestVector3) {
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
        self.emissiveFactor = emissiveFactor
    }

    public init(_ component: RenderMaterialComponent) {
        self.init(baseColorFactor: EditorSceneManifestVector4(component.baseColorFactor),
                  baseColorTextureIndex: component.baseColorTextureIndex,
                  normalTextureIndex: component.normalTextureIndex,
                  metallicFactor: component.metallicFactor,
                  roughnessFactor: component.roughnessFactor,
                  emissiveFactor: EditorSceneManifestVector3(component.emissiveFactor))
    }

    var component: RenderMaterialComponent {
        RenderMaterialComponent(baseColorFactor: baseColorFactor.simdValue,
                                baseColorTextureIndex: baseColorTextureIndex,
                                normalTextureIndex: normalTextureIndex,
                                metallicFactor: metallicFactor,
                                roughnessFactor: roughnessFactor,
                                emissiveFactor: emissiveFactor.simdValue)
    }
}

public struct EditorSceneManifestCamera: Codable, Sendable, Equatable {
    public let target: EditorSceneManifestVector3
    public let up: EditorSceneManifestVector3
    public let fovYRadians: Float
    public let aspectRatio: Float
    public let near: Float
    public let far: Float
    public let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case target
        case up
        case fovYRadians
        case aspectRatio
        case near
        case far
        case isActive
    }

    public init(target: EditorSceneManifestVector3,
                up: EditorSceneManifestVector3,
                fovYRadians: Float,
                aspectRatio: Float = 1,
                near: Float,
                far: Float,
                isActive: Bool) {
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.aspectRatio = max(0.001, aspectRatio)
        self.near = near
        self.far = far
        self.isActive = isActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try c.decode(EditorSceneManifestVector3.self, forKey: .target),
                  up: try c.decode(EditorSceneManifestVector3.self, forKey: .up),
                  fovYRadians: try c.decode(Float.self, forKey: .fovYRadians),
                  aspectRatio: try c.decodeIfPresent(Float.self, forKey: .aspectRatio) ?? 1,
                  near: try c.decode(Float.self, forKey: .near),
                  far: try c.decode(Float.self, forKey: .far),
                  isActive: try c.decode(Bool.self, forKey: .isActive))
    }

    public init(_ component: CameraComponent) {
        self.init(target: EditorSceneManifestVector3(component.target),
                  up: EditorSceneManifestVector3(component.up),
                  fovYRadians: component.fovYRadians,
                  aspectRatio: component.aspectRatio,
                  near: component.near,
                  far: component.far,
                  isActive: component.isActive)
    }

    var component: CameraComponent {
        CameraComponent(target: target.simdValue,
                        up: up.simdValue,
                        fovYRadians: fovYRadians,
                        aspectRatio: aspectRatio,
                        near: near,
                        far: far,
                        isActive: isActive)
    }
}

public struct EditorSceneManifestLight: Codable, Sendable, Equatable {
    public let type: String
    public let color: EditorSceneManifestVector3
    public let intensity: Float
    public let range: Float
    public let spotInnerAngleDegrees: Float
    public let spotOuterAngleDegrees: Float

    public init(type: String,
                color: EditorSceneManifestVector3,
                intensity: Float,
                range: Float,
                spotInnerAngleDegrees: Float,
                spotOuterAngleDegrees: Float) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = range
        self.spotInnerAngleDegrees = spotInnerAngleDegrees
        self.spotOuterAngleDegrees = spotOuterAngleDegrees
    }

    public init(_ component: LightComponent) {
        self.init(type: component.type.rawValue,
                  color: EditorSceneManifestVector3(component.color),
                  intensity: component.intensity,
                  range: component.range,
                  spotInnerAngleDegrees: component.spotInnerAngleDegrees,
                  spotOuterAngleDegrees: component.spotOuterAngleDegrees)
    }

    var component: LightComponent {
        LightComponent(type: LightType(rawValue: type) ?? .directional,
                       color: color.simdValue,
                       intensity: intensity,
                       range: range,
                       spotInnerAngleDegrees: spotInnerAngleDegrees,
                       spotOuterAngleDegrees: spotOuterAngleDegrees)
    }
}

public struct EditorSceneManifestRigidBody: Codable, Sendable, Equatable {
    public let motionType: String
    public let mass: Float
    public let linearVelocity: EditorSceneManifestVector3
    public let angularVelocity: EditorSceneManifestVector3
    public let accumulatedForce: EditorSceneManifestVector3
    public let accumulatedTorque: EditorSceneManifestVector3
    public let gravityScale: Float
    public let linearDamping: Float
    public let angularDamping: Float
    public let allowSleep: Bool
    public let isSleeping: Bool

    public init(_ component: RigidBody) {
        self.motionType = component.motionType.rawValue
        self.mass = component.mass
        self.linearVelocity = EditorSceneManifestVector3(component.linearVelocity)
        self.angularVelocity = EditorSceneManifestVector3(component.angularVelocity)
        self.accumulatedForce = EditorSceneManifestVector3(component.accumulatedForce)
        self.accumulatedTorque = EditorSceneManifestVector3(component.accumulatedTorque)
        self.gravityScale = component.gravityScale
        self.linearDamping = component.linearDamping
        self.angularDamping = component.angularDamping
        self.allowSleep = component.allowSleep
        self.isSleeping = component.isSleeping
    }

    var component: RigidBody {
        RigidBody(motionType: RigidBodyMotionType(rawValue: motionType) ?? .dynamic,
                  mass: mass,
                  linearVelocity: linearVelocity.simdValue,
                  angularVelocity: angularVelocity.simdValue,
                  accumulatedForce: accumulatedForce.simdValue,
                  accumulatedTorque: accumulatedTorque.simdValue,
                  gravityScale: gravityScale,
                  linearDamping: linearDamping,
                  angularDamping: angularDamping,
                  allowSleep: allowSleep,
                  isSleeping: isSleeping)
    }
}

public struct EditorSceneManifestPhysicsMaterial: Codable, Sendable, Equatable {
    public let friction: Float
    public let restitution: Float
    public let density: Float

    public init(_ material: PhysicsMaterial) {
        self.friction = material.friction
        self.restitution = material.restitution
        self.density = material.density
    }

    var material: PhysicsMaterial {
        PhysicsMaterial(friction: friction, restitution: restitution, density: density)
    }
}

public struct EditorSceneManifestColliderShape: Codable, Sendable, Equatable {
    public let kind: String
    public let halfExtents: EditorSceneManifestVector3?
    public let radius: Float?
    public let halfHeight: Float?
    public let resourceID: String?
    public let center: EditorSceneManifestVector3

    public init(_ shape: ColliderShape) {
        switch shape {
        case let .box(halfExtents, center):
            self.kind = "box"
            self.halfExtents = EditorSceneManifestVector3(halfExtents)
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .sphere(radius, center):
            self.kind = "sphere"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = nil
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .capsule(radius, halfHeight, center):
            self.kind = "capsule"
            self.halfExtents = nil
            self.radius = radius
            self.halfHeight = halfHeight
            self.resourceID = nil
            self.center = EditorSceneManifestVector3(center)
        case let .mesh(resourceID, center):
            self.kind = "mesh"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        case let .convex(resourceID, center):
            self.kind = "convex"
            self.halfExtents = nil
            self.radius = nil
            self.halfHeight = nil
            self.resourceID = resourceID
            self.center = EditorSceneManifestVector3(center)
        }
    }

    var shape: ColliderShape {
        switch kind {
        case "box":
            return .box(halfExtents: halfExtents?.simdValue ?? SIMD3<Float>(0.5, 0.5, 0.5),
                        center: center.simdValue)
        case "sphere":
            return .sphere(radius: radius ?? 0.5, center: center.simdValue)
        case "capsule":
            return .capsule(radius: radius ?? 0.5,
                            halfHeight: halfHeight ?? 0.5,
                            center: center.simdValue)
        case "mesh":
            return .mesh(resourceID: resourceID, center: center.simdValue)
        case "convex":
            return .convex(resourceID: resourceID, center: center.simdValue)
        default:
            return .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: center.simdValue)
        }
    }
}

public struct EditorSceneManifestCollider: Codable, Sendable, Equatable {
    public let shape: EditorSceneManifestColliderShape
    public let isTrigger: Bool
    public let layerID: UInt16
    public let layerMask: UInt16
    public let material: EditorSceneManifestPhysicsMaterial

    public init(_ component: Collider) {
        self.shape = EditorSceneManifestColliderShape(component.shape)
        self.isTrigger = component.isTrigger
        self.layerID = component.layerID
        self.layerMask = component.layerMask
        self.material = EditorSceneManifestPhysicsMaterial(component.material)
    }

    var component: Collider {
        Collider(shape: shape.shape,
                 isTrigger: isTrigger,
                 layerID: layerID,
                 layerMask: layerMask,
                 material: material.material)
    }
}

public struct EditorSceneManifestConstraint: Codable, Sendable, Equatable {
    public let constraintType: String
    public let entityA: UInt64
    public let entityB: UInt64
    public let pivotA: EditorSceneManifestVector3
    public let pivotB: EditorSceneManifestVector3
    public let axisA: EditorSceneManifestVector3
    public let axisB: EditorSceneManifestVector3
    public let minLimit: Float
    public let maxLimit: Float
    public let isEnabled: Bool

    public init(_ component: Constraint) {
        self.constraintType = component.constraintType.rawValue
        self.entityA = component.entityA.rawValue
        self.entityB = component.entityB.rawValue
        self.pivotA = EditorSceneManifestVector3(component.pivotA)
        self.pivotB = EditorSceneManifestVector3(component.pivotB)
        self.axisA = EditorSceneManifestVector3(component.axisA)
        self.axisB = EditorSceneManifestVector3(component.axisB)
        self.minLimit = component.minLimit
        self.maxLimit = component.maxLimit
        self.isEnabled = component.isEnabled
    }

    func component(idMap: [UInt64: EntityID]) -> Constraint? {
        guard let mappedA = idMap[entityA],
              let mappedB = idMap[entityB]
        else { return nil }
        return Constraint(constraintType: ConstraintType(rawValue: constraintType) ?? .distance,
                          entityA: mappedA,
                          entityB: mappedB,
                          pivotA: pivotA.simdValue,
                          pivotB: pivotB.simdValue,
                          axisA: axisA.simdValue,
                          axisB: axisB.simdValue,
                          minLimit: minLimit,
                          maxLimit: maxLimit,
                          isEnabled: isEnabled)
    }
}

public struct EditorSceneManifestScriptBinding: Codable, Sendable, Equatable {
    public let script: UInt64
    public let isEnabled: Bool
    public let parametersJSON: String

    public init(_ binding: ScriptBinding) {
        self.script = binding.script.rawValue
        self.isEnabled = binding.isEnabled
        self.parametersJSON = binding.parametersJSON
    }

    var binding: ScriptBinding {
        ScriptBinding(ScriptHandle(rawValue: script),
                      isEnabled: isEnabled,
                      parametersJSON: parametersJSON)
    }
}

public struct EditorSceneManifestScript: Codable, Sendable, Equatable {
    public let bindings: [EditorSceneManifestScriptBinding]

    public init(_ component: ScriptComponent) {
        self.bindings = component.bindings.map(EditorSceneManifestScriptBinding.init)
    }

    var component: ScriptComponent {
        ScriptComponent(bindings: bindings.map(\.binding))
    }
}

public struct EditorSceneManifestAudioSource: Codable, Sendable, Equatable {
    public let clipName: String
    public let volume: Float
    public let pitch: Float
    public let loop: Bool
    public let playOnAwake: Bool
    public let spatialBlend: Float

    public init(_ component: AudioSource) {
        self.clipName = component.clipName
        self.volume = component.volume
        self.pitch = component.pitch
        self.loop = component.loop
        self.playOnAwake = component.playOnAwake
        self.spatialBlend = component.spatialBlend
    }

    var component: AudioSource {
        AudioSource(clipName: clipName, volume: volume, pitch: pitch,
                    loop: loop, playOnAwake: playOnAwake, spatialBlend: spatialBlend)
    }
}

public struct EditorSceneManifestAnimationPlayer: Codable, Sendable, Equatable {
    public let clipName: String?
    public let speed: Float
    public let loop: Bool
    public let isPlaying: Bool
    public let time: Double

    public init(_ component: AnimationPlayer) {
        self.clipName = component.clipName
        self.speed = component.speed
        self.loop = component.loop
        self.isPlaying = component.isPlaying
        self.time = component.time
    }

    var component: AnimationPlayer {
        AnimationPlayer(clipName: clipName, speed: speed, loop: loop,
                        isPlaying: isPlaying, time: time)
    }
}

public struct EditorSceneManifestAnimationGraphPlayer: Codable, Sendable, Equatable {
    public let graph: AnimationGraph
    public let parameters: [String: Float]
    public let activeState: String?
    public let previousState: String?
    public let activeTime: Double
    public let previousTime: Double
    public let transitionElapsed: Double
    public let transitionDuration: Double
    public let speed: Float
    public let isPlaying: Bool

    public init(_ component: AnimationGraphPlayer) {
        self.graph = component.graph
        self.parameters = component.parameters
        self.activeState = component.activeState
        self.previousState = component.previousState
        self.activeTime = component.activeTime
        self.previousTime = component.previousTime
        self.transitionElapsed = component.transitionElapsed
        self.transitionDuration = component.transitionDuration
        self.speed = component.speed
        self.isPlaying = component.isPlaying
    }

    var component: AnimationGraphPlayer {
        AnimationGraphPlayer(graph: graph,
                             parameters: parameters,
                             activeState: activeState,
                             previousState: previousState,
                             activeTime: activeTime,
                             previousTime: previousTime,
                             transitionElapsed: transitionElapsed,
                             transitionDuration: transitionDuration,
                             speed: speed,
                             isPlaying: isPlaying)
    }
}

public struct EditorSceneManifestParticleSubEmitter: Codable, Sendable, Equatable {
    public let trigger: ParticleSubEmitterTrigger
    public let burstCount: Int
    public let probability: Float
    public let maxDepth: Int
    public let inheritVelocity: Float
    public let lifetime: Float
    public let startVelocity: EditorSceneManifestVector3
    public let velocityRandomness: EditorSceneManifestVector3
    public let startSize: Float
    public let endSize: Float
    public let startColor: EditorSceneManifestVector4
    public let endColor: EditorSceneManifestVector4

    public init(_ rule: ParticleSubEmitter) {
        self.trigger = rule.trigger
        self.burstCount = rule.burstCount
        self.probability = rule.probability
        self.maxDepth = rule.maxDepth
        self.inheritVelocity = rule.inheritVelocity
        self.lifetime = rule.lifetime
        self.startVelocity = EditorSceneManifestVector3(rule.startVelocity)
        self.velocityRandomness = EditorSceneManifestVector3(rule.velocityRandomness)
        self.startSize = rule.startSize
        self.endSize = rule.endSize
        self.startColor = EditorSceneManifestVector4(rule.startColor)
        self.endColor = EditorSceneManifestVector4(rule.endColor)
    }

    var component: ParticleSubEmitter {
        ParticleSubEmitter(trigger: trigger,
                           burstCount: burstCount,
                           probability: probability,
                           maxDepth: maxDepth,
                           inheritVelocity: inheritVelocity,
                           lifetime: lifetime,
                           startVelocity: startVelocity.simdValue,
                           velocityRandomness: velocityRandomness.simdValue,
                           startSize: startSize,
                           endSize: endSize,
                           startColor: startColor.simdValue,
                           endColor: endColor.simdValue)
    }
}

public struct EditorSceneManifestParticleEmitter: Codable, Sendable, Equatable {
    public let isEmitting: Bool
    public let looping: Bool
    public let duration: Float
    public let prewarmTime: Float
    public let prewarmStep: Float
    public let emissionRate: Float
    public let emissionRateCurve: ParticleCurve
    public let distanceEmissionRate: Float
    public let distanceEmissionRateCurve: ParticleCurve
    public let burstCount: Int
    public let burstInterval: Float
    public let maxParticles: Int
    public let maxRenderedParticles: Int
    public let lifetime: Float
    public let lifetimeRandomness: Float
    public let subEmitterTrigger: ParticleSubEmitterTrigger
    public let subEmitterBurstCount: Int
    public let subEmitterProbability: Float
    public let subEmitterMaxDepth: Int
    public let subEmitterInheritVelocity: Float
    public let subEmitterLifetime: Float
    public let subEmitterStartVelocity: EditorSceneManifestVector3
    public let subEmitterVelocityRandomness: EditorSceneManifestVector3
    public let subEmitterStartSize: Float
    public let subEmitterEndSize: Float
    public let subEmitterStartColor: EditorSceneManifestVector4
    public let subEmitterEndColor: EditorSceneManifestVector4
    public let subEmitters: [EditorSceneManifestParticleSubEmitter]
    public let originOffset: EditorSceneManifestVector3
    public let spawnRadius: Float
    public let emissionShape: ParticleEmissionShape
    public let boxHalfExtents: EditorSceneManifestVector3
    public let coneRadius: Float
    public let coneHeight: Float
    public let startVelocity: EditorSceneManifestVector3
    public let velocityRandomness: EditorSceneManifestVector3
    public let velocityInheritance: Float
    public let gravity: EditorSceneManifestVector3
    public let noiseStrength: Float
    public let noiseScale: Float
    public let noiseSpeed: Float
    public let forceMode: ParticleForceMode
    public let forceCenter: EditorSceneManifestVector3
    public let forceAxis: EditorSceneManifestVector3
    public let forceRadius: Float
    public let forceStrength: Float
    public let forceFalloff: Float
    public let vectorFieldMode: ParticleVectorFieldMode
    public let vectorFieldDirection: EditorSceneManifestVector3
    public let vectorFieldStrength: Float
    public let vectorFieldScale: Float
    public let vectorFieldScrollSpeed: Float
    public let collisionMode: ParticleCollisionMode
    public let simulationSpace: ParticleSimulationSpace
    public let simulationBackend: ParticleSimulationBackend
    public let gpuSimulationWorkgroupSize: Int
    public let collisionPlaneY: Float
    public let collisionRestitution: Float
    public let collisionDamping: Float
    public let startSize: Float
    public let endSize: Float
    public let sizeRandomness: Float
    public let startRotation: Float
    public let rotationRandomness: Float
    public let angularVelocity: Float
    public let angularVelocityRandomness: Float
    public let sizeCurve: ParticleCurve
    public let startColor: EditorSceneManifestVector4
    public let endColor: EditorSceneManifestVector4
    public let colorCurve: ParticleCurve
    public let blendMode: ParticleBlendMode
    public let renderMode: ParticleRenderMode
    public let sortMode: ParticleSortMode
    public let ribbonWidthScale: Float
    public let ribbonTailWidthScale: Float
    public let ribbonTailAlphaScale: Float
    public let ribbonMaxSegmentLength: Float
    public let ribbonJoinOverlapScale: Float
    public let ribbonSmoothingSegments: Int
    public let ribbonTextureTiling: Float
    public let ribbonTextureOffset: Float
    public let renderAlignment: ParticleRenderAlignment
    public let velocityStretchScale: Float
    public let velocityStretchMax: Float
    public let maxRenderDistance: Float
    public let renderDistanceFadeRange: Float
    public let renderLODStartDistance: Float
    public let renderLODEndDistance: Float
    public let renderLODMinParticleScale: Float
    public let renderBoundsMode: ParticleRenderBoundsMode
    public let renderBoundsRadius: Float
    public let textureAssetID: String?
    public let texturePath: String?
    public let textureSheetColumns: Int
    public let textureSheetRows: Int
    public let textureSheetFrameCount: Int
    public let textureSheetFrameRate: Float
    public let textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode
    public let textureSheetStartFrame: Int
    public let textureSheetFrameRandomness: Int
    public let trailLength: Float
    public let trailSegments: Int
    public let trailEndSizeScale: Float
    public let trailEndAlphaScale: Float
    public let seed: UInt64
    public let moduleStack: ParticleModuleStack?

    public init(_ component: ParticleEmitter) {
        self.isEmitting = component.isEmitting
        self.looping = component.looping
        self.duration = component.duration
        self.prewarmTime = component.prewarmTime
        self.prewarmStep = component.prewarmStep
        self.emissionRate = component.emissionRate
        self.emissionRateCurve = component.emissionRateCurve
        self.distanceEmissionRate = component.distanceEmissionRate
        self.distanceEmissionRateCurve = component.distanceEmissionRateCurve
        self.burstCount = component.burstCount
        self.burstInterval = component.burstInterval
        self.maxParticles = component.maxParticles
        self.maxRenderedParticles = component.maxRenderedParticles
        self.lifetime = component.lifetime
        self.lifetimeRandomness = component.lifetimeRandomness
        self.subEmitterTrigger = component.subEmitterTrigger
        self.subEmitterBurstCount = component.subEmitterBurstCount
        self.subEmitterProbability = component.subEmitterProbability
        self.subEmitterMaxDepth = component.subEmitterMaxDepth
        self.subEmitterInheritVelocity = component.subEmitterInheritVelocity
        self.subEmitterLifetime = component.subEmitterLifetime
        self.subEmitterStartVelocity = EditorSceneManifestVector3(component.subEmitterStartVelocity)
        self.subEmitterVelocityRandomness = EditorSceneManifestVector3(component.subEmitterVelocityRandomness)
        self.subEmitterStartSize = component.subEmitterStartSize
        self.subEmitterEndSize = component.subEmitterEndSize
        self.subEmitterStartColor = EditorSceneManifestVector4(component.subEmitterStartColor)
        self.subEmitterEndColor = EditorSceneManifestVector4(component.subEmitterEndColor)
        self.subEmitters = component.subEmitters.map(EditorSceneManifestParticleSubEmitter.init)
        self.originOffset = EditorSceneManifestVector3(component.originOffset)
        self.spawnRadius = component.spawnRadius
        self.emissionShape = component.emissionShape
        self.boxHalfExtents = EditorSceneManifestVector3(component.boxHalfExtents)
        self.coneRadius = component.coneRadius
        self.coneHeight = component.coneHeight
        self.startVelocity = EditorSceneManifestVector3(component.startVelocity)
        self.velocityRandomness = EditorSceneManifestVector3(component.velocityRandomness)
        self.velocityInheritance = component.velocityInheritance
        self.gravity = EditorSceneManifestVector3(component.gravity)
        self.noiseStrength = component.noiseStrength
        self.noiseScale = component.noiseScale
        self.noiseSpeed = component.noiseSpeed
        self.forceMode = component.forceMode
        self.forceCenter = EditorSceneManifestVector3(component.forceCenter)
        self.forceAxis = EditorSceneManifestVector3(component.forceAxis)
        self.forceRadius = component.forceRadius
        self.forceStrength = component.forceStrength
        self.forceFalloff = component.forceFalloff
        self.vectorFieldMode = component.vectorFieldMode
        self.vectorFieldDirection = EditorSceneManifestVector3(component.vectorFieldDirection)
        self.vectorFieldStrength = component.vectorFieldStrength
        self.vectorFieldScale = component.vectorFieldScale
        self.vectorFieldScrollSpeed = component.vectorFieldScrollSpeed
        self.collisionMode = component.collisionMode
        self.simulationSpace = component.simulationSpace
        self.simulationBackend = component.simulationBackend
        self.gpuSimulationWorkgroupSize = component.gpuSimulationWorkgroupSize
        self.collisionPlaneY = component.collisionPlaneY
        self.collisionRestitution = component.collisionRestitution
        self.collisionDamping = component.collisionDamping
        self.startSize = component.startSize
        self.endSize = component.endSize
        self.sizeRandomness = component.sizeRandomness
        self.startRotation = component.startRotation
        self.rotationRandomness = component.rotationRandomness
        self.angularVelocity = component.angularVelocity
        self.angularVelocityRandomness = component.angularVelocityRandomness
        self.sizeCurve = component.sizeCurve
        self.startColor = EditorSceneManifestVector4(component.startColor)
        self.endColor = EditorSceneManifestVector4(component.endColor)
        self.colorCurve = component.colorCurve
        self.blendMode = component.blendMode
        self.renderMode = component.renderMode
        self.sortMode = component.sortMode
        self.ribbonWidthScale = component.ribbonWidthScale
        self.ribbonTailWidthScale = component.ribbonTailWidthScale
        self.ribbonTailAlphaScale = component.ribbonTailAlphaScale
        self.ribbonMaxSegmentLength = component.ribbonMaxSegmentLength
        self.ribbonJoinOverlapScale = component.ribbonJoinOverlapScale
        self.ribbonSmoothingSegments = component.ribbonSmoothingSegments
        self.ribbonTextureTiling = component.ribbonTextureTiling
        self.ribbonTextureOffset = component.ribbonTextureOffset
        self.renderAlignment = component.renderAlignment
        self.velocityStretchScale = component.velocityStretchScale
        self.velocityStretchMax = component.velocityStretchMax
        self.maxRenderDistance = component.maxRenderDistance
        self.renderDistanceFadeRange = component.renderDistanceFadeRange
        self.renderLODStartDistance = component.renderLODStartDistance
        self.renderLODEndDistance = component.renderLODEndDistance
        self.renderLODMinParticleScale = component.renderLODMinParticleScale
        self.renderBoundsMode = component.renderBoundsMode
        self.renderBoundsRadius = component.renderBoundsRadius
        self.textureAssetID = component.textureAssetID
        self.texturePath = component.texturePath
        self.textureSheetColumns = component.textureSheetColumns
        self.textureSheetRows = component.textureSheetRows
        self.textureSheetFrameCount = component.textureSheetFrameCount
        self.textureSheetFrameRate = component.textureSheetFrameRate
        self.textureSheetPlaybackMode = component.textureSheetPlaybackMode
        self.textureSheetStartFrame = component.textureSheetStartFrame
        self.textureSheetFrameRandomness = component.textureSheetFrameRandomness
        self.trailLength = component.trailLength
        self.trailSegments = component.trailSegments
        self.trailEndSizeScale = component.trailEndSizeScale
        self.trailEndAlphaScale = component.trailEndAlphaScale
        self.seed = component.seed
        self.moduleStack = component.moduleStack
    }

    var component: ParticleEmitter {
        ParticleEmitter(isEmitting: isEmitting, looping: looping, duration: duration,
                        prewarmTime: prewarmTime,
                        prewarmStep: prewarmStep,
                        emissionRate: emissionRate,
                        emissionRateCurve: emissionRateCurve,
                        distanceEmissionRate: distanceEmissionRate,
                        distanceEmissionRateCurve: distanceEmissionRateCurve,
                        burstCount: burstCount, burstInterval: burstInterval,
                        maxParticles: maxParticles,
                        maxRenderedParticles: maxRenderedParticles,
                        lifetime: lifetime,
                        lifetimeRandomness: lifetimeRandomness,
                        subEmitterTrigger: subEmitterTrigger,
                        subEmitterBurstCount: subEmitterBurstCount,
                        subEmitterProbability: subEmitterProbability,
                        subEmitterMaxDepth: subEmitterMaxDepth,
                        subEmitterInheritVelocity: subEmitterInheritVelocity,
                        subEmitterLifetime: subEmitterLifetime,
                        subEmitterStartVelocity: subEmitterStartVelocity.simdValue,
                        subEmitterVelocityRandomness: subEmitterVelocityRandomness.simdValue,
                        subEmitterStartSize: subEmitterStartSize,
                        subEmitterEndSize: subEmitterEndSize,
                        subEmitterStartColor: subEmitterStartColor.simdValue,
                        subEmitterEndColor: subEmitterEndColor.simdValue,
                        subEmitters: subEmitters.map(\.component),
                        originOffset: originOffset.simdValue,
                        spawnRadius: spawnRadius, emissionShape: emissionShape,
                        boxHalfExtents: boxHalfExtents.simdValue,
                        coneRadius: coneRadius, coneHeight: coneHeight,
                        startVelocity: startVelocity.simdValue,
                        velocityRandomness: velocityRandomness.simdValue,
                        velocityInheritance: velocityInheritance,
                        gravity: gravity.simdValue,
                        noiseStrength: noiseStrength, noiseScale: noiseScale, noiseSpeed: noiseSpeed,
                        forceMode: forceMode,
                        forceCenter: forceCenter.simdValue,
                        forceAxis: forceAxis.simdValue,
                        forceRadius: forceRadius,
                        forceStrength: forceStrength,
                        forceFalloff: forceFalloff,
                        vectorFieldMode: vectorFieldMode,
                        vectorFieldDirection: vectorFieldDirection.simdValue,
                        vectorFieldStrength: vectorFieldStrength,
                        vectorFieldScale: vectorFieldScale,
                        vectorFieldScrollSpeed: vectorFieldScrollSpeed,
                        collisionMode: collisionMode, simulationSpace: simulationSpace,
                        simulationBackend: simulationBackend,
                        gpuSimulationWorkgroupSize: gpuSimulationWorkgroupSize,
                        collisionPlaneY: collisionPlaneY,
                        collisionRestitution: collisionRestitution, collisionDamping: collisionDamping,
                        startSize: startSize, endSize: endSize, sizeRandomness: sizeRandomness,
                        startRotation: startRotation, rotationRandomness: rotationRandomness,
                        angularVelocity: angularVelocity, angularVelocityRandomness: angularVelocityRandomness,
                        sizeCurve: sizeCurve,
                        startColor: startColor.simdValue, endColor: endColor.simdValue,
                        colorCurve: colorCurve, blendMode: blendMode,
                        renderMode: renderMode,
                        sortMode: sortMode,
                        ribbonWidthScale: ribbonWidthScale,
                        ribbonTailWidthScale: ribbonTailWidthScale,
                        ribbonTailAlphaScale: ribbonTailAlphaScale,
                        ribbonMaxSegmentLength: ribbonMaxSegmentLength,
                        ribbonJoinOverlapScale: ribbonJoinOverlapScale,
                        ribbonSmoothingSegments: ribbonSmoothingSegments,
                        ribbonTextureTiling: ribbonTextureTiling,
                        ribbonTextureOffset: ribbonTextureOffset,
                        renderAlignment: renderAlignment,
                        velocityStretchScale: velocityStretchScale,
                        velocityStretchMax: velocityStretchMax,
                        maxRenderDistance: maxRenderDistance,
                        renderDistanceFadeRange: renderDistanceFadeRange,
                        renderLODStartDistance: renderLODStartDistance,
                        renderLODEndDistance: renderLODEndDistance,
                        renderLODMinParticleScale: renderLODMinParticleScale,
                        renderBoundsMode: renderBoundsMode,
                        renderBoundsRadius: renderBoundsRadius,
                        textureAssetID: textureAssetID, texturePath: texturePath,
                        textureSheetColumns: textureSheetColumns,
                        textureSheetRows: textureSheetRows,
                        textureSheetFrameCount: textureSheetFrameCount,
                        textureSheetFrameRate: textureSheetFrameRate,
                        textureSheetPlaybackMode: textureSheetPlaybackMode,
                        textureSheetStartFrame: textureSheetStartFrame,
                        textureSheetFrameRandomness: textureSheetFrameRandomness,
                        trailLength: trailLength,
                        trailSegments: trailSegments,
                        trailEndSizeScale: trailEndSizeScale,
                        trailEndAlphaScale: trailEndAlphaScale,
                        seed: seed)
    }

    private enum CodingKeys: String, CodingKey {
        case isEmitting, looping, duration, prewarmTime, prewarmStep, emissionRate, emissionRateCurve
        case distanceEmissionRate, distanceEmissionRateCurve, burstCount, burstInterval
        case maxParticles, maxRenderedParticles, lifetime, lifetimeRandomness
        case subEmitterTrigger, subEmitterBurstCount, subEmitterProbability, subEmitterMaxDepth
        case subEmitterInheritVelocity, subEmitterLifetime
        case subEmitterStartVelocity, subEmitterVelocityRandomness
        case subEmitterStartSize, subEmitterEndSize, subEmitterStartColor, subEmitterEndColor
        case subEmitters
        case originOffset, spawnRadius, emissionShape, boxHalfExtents, coneRadius, coneHeight
        case startVelocity, velocityRandomness, velocityInheritance, gravity
        case noiseStrength, noiseScale, noiseSpeed
        case forceMode, forceCenter, forceAxis, forceRadius, forceStrength, forceFalloff
        case vectorFieldMode, vectorFieldDirection, vectorFieldStrength, vectorFieldScale, vectorFieldScrollSpeed
        case collisionMode, simulationSpace, simulationBackend, gpuSimulationWorkgroupSize
        case collisionPlaneY, collisionRestitution, collisionDamping
        case startSize, endSize, sizeRandomness
        case startRotation, rotationRandomness, angularVelocity, angularVelocityRandomness
        case sizeCurve, startColor, endColor, colorCurve, blendMode, renderMode, sortMode
        case ribbonWidthScale, ribbonTailWidthScale, ribbonTailAlphaScale, ribbonMaxSegmentLength
        case ribbonJoinOverlapScale, ribbonSmoothingSegments
        case ribbonTextureTiling, ribbonTextureOffset
        case renderAlignment, velocityStretchScale, velocityStretchMax
        case maxRenderDistance, renderDistanceFadeRange
        case renderLODStartDistance, renderLODEndDistance, renderLODMinParticleScale
        case renderBoundsMode, renderBoundsRadius
        case textureAssetID, texturePath
        case textureSheetColumns, textureSheetRows, textureSheetFrameCount, textureSheetFrameRate
        case textureSheetPlaybackMode, textureSheetStartFrame, textureSheetFrameRandomness
        case trailLength, trailSegments, trailEndSizeScale, trailEndAlphaScale, seed, moduleStack
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEmitting = try c.decodeIfPresent(Bool.self, forKey: .isEmitting) ?? true
        self.looping = try c.decodeIfPresent(Bool.self, forKey: .looping) ?? true
        self.duration = try c.decodeIfPresent(Float.self, forKey: .duration) ?? 0
        self.prewarmTime = try c.decodeIfPresent(Float.self, forKey: .prewarmTime) ?? 0
        self.prewarmStep = try c.decodeIfPresent(Float.self, forKey: .prewarmStep) ?? (1.0 / 30.0)
        self.emissionRate = try c.decodeIfPresent(Float.self, forKey: .emissionRate) ?? 10
        self.emissionRateCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .emissionRateCurve) ?? .constant(1)
        self.distanceEmissionRate = try c.decodeIfPresent(Float.self, forKey: .distanceEmissionRate) ?? 0
        self.distanceEmissionRateCurve = try c.decodeIfPresent(ParticleCurve.self,
                                                                forKey: .distanceEmissionRateCurve) ?? .constant(1)
        self.burstCount = try c.decodeIfPresent(Int.self, forKey: .burstCount) ?? 0
        self.burstInterval = try c.decodeIfPresent(Float.self, forKey: .burstInterval) ?? 0
        self.maxParticles = try c.decodeIfPresent(Int.self, forKey: .maxParticles) ?? 256
        self.maxRenderedParticles = try c.decodeIfPresent(Int.self, forKey: .maxRenderedParticles) ?? 0
        self.lifetime = try c.decodeIfPresent(Float.self, forKey: .lifetime) ?? 2
        self.lifetimeRandomness = try c.decodeIfPresent(Float.self, forKey: .lifetimeRandomness) ?? 0
        self.subEmitterTrigger = try c.decodeIfPresent(ParticleSubEmitterTrigger.self,
                                                        forKey: .subEmitterTrigger) ?? .none
        self.subEmitterBurstCount = try c.decodeIfPresent(Int.self, forKey: .subEmitterBurstCount) ?? 0
        self.subEmitterProbability = try c.decodeIfPresent(Float.self, forKey: .subEmitterProbability) ?? 1
        self.subEmitterMaxDepth = try c.decodeIfPresent(Int.self, forKey: .subEmitterMaxDepth) ?? 1
        self.subEmitterInheritVelocity = try c.decodeIfPresent(Float.self, forKey: .subEmitterInheritVelocity) ?? 0
        self.subEmitterLifetime = try c.decodeIfPresent(Float.self, forKey: .subEmitterLifetime) ?? 0.5
        self.subEmitterStartVelocity = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                              forKey: .subEmitterStartVelocity)
            ?? EditorSceneManifestVector3(.zero)
        self.subEmitterVelocityRandomness = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                                   forKey: .subEmitterVelocityRandomness)
            ?? EditorSceneManifestVector3(.zero)
        self.subEmitterStartSize = try c.decodeIfPresent(Float.self, forKey: .subEmitterStartSize) ?? 0.25
        self.subEmitterEndSize = try c.decodeIfPresent(Float.self, forKey: .subEmitterEndSize) ?? 0
        self.subEmitterStartColor = try c.decodeIfPresent(EditorSceneManifestVector4.self,
                                                           forKey: .subEmitterStartColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 1))
        self.subEmitterEndColor = try c.decodeIfPresent(EditorSceneManifestVector4.self,
                                                         forKey: .subEmitterEndColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 0))
        self.subEmitters = try c.decodeIfPresent([EditorSceneManifestParticleSubEmitter].self,
                                                  forKey: .subEmitters) ?? []
        self.originOffset = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .originOffset)
            ?? EditorSceneManifestVector3(.zero)
        self.spawnRadius = try c.decodeIfPresent(Float.self, forKey: .spawnRadius) ?? 0
        self.emissionShape = try c.decodeIfPresent(ParticleEmissionShape.self, forKey: .emissionShape) ?? .sphere
        self.boxHalfExtents = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .boxHalfExtents)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0.5, 0.5, 0.5))
        self.coneRadius = try c.decodeIfPresent(Float.self, forKey: .coneRadius) ?? 0.5
        self.coneHeight = try c.decodeIfPresent(Float.self, forKey: .coneHeight) ?? 1
        self.startVelocity = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .startVelocity)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.velocityRandomness = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .velocityRandomness)
            ?? EditorSceneManifestVector3(.zero)
        self.velocityInheritance = try c.decodeIfPresent(Float.self, forKey: .velocityInheritance) ?? 0
        self.gravity = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .gravity)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, -9.81, 0))
        self.noiseStrength = try c.decodeIfPresent(Float.self, forKey: .noiseStrength) ?? 0
        self.noiseScale = try c.decodeIfPresent(Float.self, forKey: .noiseScale) ?? 1
        self.noiseSpeed = try c.decodeIfPresent(Float.self, forKey: .noiseSpeed) ?? 1
        self.forceMode = try c.decodeIfPresent(ParticleForceMode.self, forKey: .forceMode) ?? .none
        self.forceCenter = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .forceCenter)
            ?? EditorSceneManifestVector3(.zero)
        self.forceAxis = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .forceAxis)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.forceRadius = try c.decodeIfPresent(Float.self, forKey: .forceRadius) ?? 0
        self.forceStrength = try c.decodeIfPresent(Float.self, forKey: .forceStrength) ?? 0
        self.forceFalloff = try c.decodeIfPresent(Float.self, forKey: .forceFalloff) ?? 1
        self.vectorFieldMode = try c.decodeIfPresent(ParticleVectorFieldMode.self, forKey: .vectorFieldMode) ?? .none
        self.vectorFieldDirection = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                           forKey: .vectorFieldDirection)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.vectorFieldStrength = try c.decodeIfPresent(Float.self, forKey: .vectorFieldStrength) ?? 0
        self.vectorFieldScale = try c.decodeIfPresent(Float.self, forKey: .vectorFieldScale) ?? 1
        self.vectorFieldScrollSpeed = try c.decodeIfPresent(Float.self, forKey: .vectorFieldScrollSpeed) ?? 0
        self.collisionMode = try c.decodeIfPresent(ParticleCollisionMode.self, forKey: .collisionMode) ?? .none
        self.simulationSpace = try c.decodeIfPresent(ParticleSimulationSpace.self, forKey: .simulationSpace) ?? .local
        self.simulationBackend = try c.decodeIfPresent(ParticleSimulationBackend.self,
                                                        forKey: .simulationBackend) ?? .cpu
        self.gpuSimulationWorkgroupSize = try c.decodeIfPresent(Int.self, forKey: .gpuSimulationWorkgroupSize) ?? 64
        self.collisionPlaneY = try c.decodeIfPresent(Float.self, forKey: .collisionPlaneY) ?? 0
        self.collisionRestitution = try c.decodeIfPresent(Float.self, forKey: .collisionRestitution) ?? 0.5
        self.collisionDamping = try c.decodeIfPresent(Float.self, forKey: .collisionDamping) ?? 0
        self.startSize = try c.decodeIfPresent(Float.self, forKey: .startSize) ?? 1
        self.endSize = try c.decodeIfPresent(Float.self, forKey: .endSize) ?? 0
        self.sizeRandomness = try c.decodeIfPresent(Float.self, forKey: .sizeRandomness) ?? 0
        self.startRotation = try c.decodeIfPresent(Float.self, forKey: .startRotation) ?? 0
        self.rotationRandomness = try c.decodeIfPresent(Float.self, forKey: .rotationRandomness) ?? 0
        self.angularVelocity = try c.decodeIfPresent(Float.self, forKey: .angularVelocity) ?? 0
        self.angularVelocityRandomness = try c.decodeIfPresent(Float.self, forKey: .angularVelocityRandomness) ?? 0
        self.sizeCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .sizeCurve) ?? .linear
        self.startColor = try c.decodeIfPresent(EditorSceneManifestVector4.self, forKey: .startColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 1))
        self.endColor = try c.decodeIfPresent(EditorSceneManifestVector4.self, forKey: .endColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 0))
        self.colorCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .colorCurve) ?? .linear
        self.blendMode = try c.decodeIfPresent(ParticleBlendMode.self, forKey: .blendMode) ?? .alpha
        self.renderMode = try c.decodeIfPresent(ParticleRenderMode.self, forKey: .renderMode) ?? .billboard
        self.sortMode = try c.decodeIfPresent(ParticleSortMode.self, forKey: .sortMode) ?? .distanceDescending
        self.ribbonWidthScale = try c.decodeIfPresent(Float.self, forKey: .ribbonWidthScale) ?? 1
        self.ribbonTailWidthScale = try c.decodeIfPresent(Float.self, forKey: .ribbonTailWidthScale) ?? 1
        self.ribbonTailAlphaScale = try c.decodeIfPresent(Float.self, forKey: .ribbonTailAlphaScale) ?? 1
        self.ribbonMaxSegmentLength = try c.decodeIfPresent(Float.self, forKey: .ribbonMaxSegmentLength) ?? 0
        self.ribbonJoinOverlapScale = try c.decodeIfPresent(Float.self, forKey: .ribbonJoinOverlapScale) ?? 0
        self.ribbonSmoothingSegments = try c.decodeIfPresent(Int.self, forKey: .ribbonSmoothingSegments) ?? 1
        self.ribbonTextureTiling = try c.decodeIfPresent(Float.self, forKey: .ribbonTextureTiling) ?? 0
        self.ribbonTextureOffset = try c.decodeIfPresent(Float.self, forKey: .ribbonTextureOffset) ?? 0
        self.renderAlignment = try c.decodeIfPresent(ParticleRenderAlignment.self,
                                                      forKey: .renderAlignment) ?? .billboard
        self.velocityStretchScale = try c.decodeIfPresent(Float.self, forKey: .velocityStretchScale) ?? 0
        self.velocityStretchMax = try c.decodeIfPresent(Float.self, forKey: .velocityStretchMax) ?? 8
        self.maxRenderDistance = try c.decodeIfPresent(Float.self, forKey: .maxRenderDistance) ?? 0
        self.renderDistanceFadeRange = try c.decodeIfPresent(Float.self, forKey: .renderDistanceFadeRange) ?? 0
        self.renderLODStartDistance = try c.decodeIfPresent(Float.self, forKey: .renderLODStartDistance) ?? 0
        self.renderLODEndDistance = try c.decodeIfPresent(Float.self, forKey: .renderLODEndDistance) ?? 0
        self.renderLODMinParticleScale = try c.decodeIfPresent(Float.self, forKey: .renderLODMinParticleScale) ?? 1
        self.renderBoundsRadius = try c.decodeIfPresent(Float.self, forKey: .renderBoundsRadius) ?? 0
        self.renderBoundsMode = try c.decodeIfPresent(ParticleRenderBoundsMode.self, forKey: .renderBoundsMode)
            ?? (renderBoundsRadius > 0 ? .manual : .disabled)
        self.textureAssetID = try c.decodeIfPresent(String.self, forKey: .textureAssetID)
        self.texturePath = try c.decodeIfPresent(String.self, forKey: .texturePath)
        self.textureSheetColumns = try c.decodeIfPresent(Int.self, forKey: .textureSheetColumns) ?? 1
        self.textureSheetRows = try c.decodeIfPresent(Int.self, forKey: .textureSheetRows) ?? 1
        self.textureSheetFrameCount = try c.decodeIfPresent(Int.self, forKey: .textureSheetFrameCount) ?? 1
        self.textureSheetFrameRate = try c.decodeIfPresent(Float.self, forKey: .textureSheetFrameRate) ?? 0
        self.textureSheetPlaybackMode = try c.decodeIfPresent(ParticleTextureSheetPlaybackMode.self,
                                                               forKey: .textureSheetPlaybackMode) ?? .automatic
        self.textureSheetStartFrame = try c.decodeIfPresent(Int.self, forKey: .textureSheetStartFrame) ?? 0
        self.textureSheetFrameRandomness = try c.decodeIfPresent(Int.self,
                                                                  forKey: .textureSheetFrameRandomness) ?? 0
        self.trailLength = try c.decodeIfPresent(Float.self, forKey: .trailLength) ?? 0
        self.trailSegments = try c.decodeIfPresent(Int.self, forKey: .trailSegments) ?? 0
        self.trailEndSizeScale = try c.decodeIfPresent(Float.self, forKey: .trailEndSizeScale) ?? 0.5
        self.trailEndAlphaScale = try c.decodeIfPresent(Float.self, forKey: .trailEndAlphaScale) ?? 0
        self.seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0x9E3779B9
        self.moduleStack = try c.decodeIfPresent(ParticleModuleStack.self, forKey: .moduleStack)
    }
}

public struct EditorInspectorSection {
    public let id: String
    public let title: String
    public let fields: [EditorInspectorField]

    public init(id: String, title: String, fields: [EditorInspectorField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

public struct EditorInspectorField {
    public let id: String
    public let label: String
    public let value: EditorInspectorFieldValue

    public init(id: String, label: String, value: EditorInspectorFieldValue) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum EditorInspectorFieldValue {
    case readOnly(String)
    case text(Binding<String>)
    case bool(Binding<Bool>)
    case number(Binding<Float>)
    case constrainedNumber(Binding<Float>, min: Float?, max: Float?, step: Float?, showsStepper: Bool)
    case vector3(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>)
    case color(Binding<Color>)
    case json(Binding<String>, minHeight: Float)
    case lightType(Binding<LightType>)
    case rigidBodyMotion(Binding<RigidBodyMotionType>)
    case colliderShapeKind(Binding<ColliderShapeKind>)
    case particleEmissionShape(Binding<ParticleEmissionShape>)
    case particleCollisionMode(Binding<ParticleCollisionMode>)
    case particleSimulationSpace(Binding<ParticleSimulationSpace>)
    case particleSimulationBackend(Binding<ParticleSimulationBackend>)
    case particleCurve(Binding<ParticleCurve>)
    case particleBlendMode(Binding<ParticleBlendMode>)
    case particleRenderMode(Binding<ParticleRenderMode>)
    case particleSortMode(Binding<ParticleSortMode>)
    case particleTextureSheetPlaybackMode(Binding<ParticleTextureSheetPlaybackMode>)
    case particleRenderAlignment(Binding<ParticleRenderAlignment>)
    case particleRenderBoundsMode(Binding<ParticleRenderBoundsMode>)
    case particleForceMode(Binding<ParticleForceMode>)
    case particleVectorFieldMode(Binding<ParticleVectorFieldMode>)
    case particleSubEmitterTrigger(Binding<ParticleSubEmitterTrigger>)
    case particleSubEmitters(Binding<[ParticleSubEmitter]>)
    case particleModuleStack(ParticleModuleStack)
    case asset(Binding<EditorInspectorAssetRef?>, acceptedKinds: Set<String>, placeholder: String)
}

public struct EditorInspectorAssetRef: Sendable, Equatable {
    public let id: String
    public let name: String
    public let subtitle: String?
    public let kind: String
    public let previewPath: String?

    public init(id: String,
                name: String,
                subtitle: String? = nil,
                kind: String,
                previewPath: String? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.kind = kind
        self.previewPath = previewPath
    }
}

/// 主线程约定的编辑器场景适配层。底层数据来自 Swift `SceneRuntime`；
/// 面板只读取这里导出的树与属性 schema，不再依赖 stub 列表。
public final class EditorSceneAdapter: @unchecked Sendable {
    var scene = SceneRuntime()
    let transactionExecutor = TransactionExecutor()
    private var initialSelectionID: UInt64?
    private var initialExpandedIDs: Set<UInt64> = []
    let animationRuntime = AnimationRuntime()

    public var onRevisionChanged: ((UInt64) -> Void)?

    public init() {
        resetToPreviewScene(notify: false)
    }

    public func resetToPreviewScene() {
        resetToPreviewScene(notify: true)
    }

    private func resetToPreviewScene(notify: Bool) {
        scene = SceneRuntime()
        scene.bootstrapEditorPreviewScene()
        let defaults = scene.resource(SceneBootstrapDefaultsResource.self)
        initialSelectionID = defaults?.defaultSelection?.rawValue
        initialExpandedIDs = Set(defaults?.defaultExpanded.map(\ .rawValue) ?? [])
        if notify {
            notifyRevisionChanged()
        }
    }

    public var revision: UInt64 {
        scene.snapshot.revision
    }

    public var entityCount: Int {
        scene.snapshot.entityCount
    }

    /// True while any emitter is still emitting or has live particles. Under the
    /// event-driven frame policy an idle viewport stops ticking, which would
    /// freeze particle motion; the render gate uses this to keep driving frames
    /// while particles are alive and fall back to idle once they die out.
    public func hasActiveParticles() -> Bool {
        for entity in scene.entities(with: ParticleEmitter.self) {
            guard let emitter = scene.component(ParticleEmitter.self, for: entity) else { continue }
            if emitter.isEmitting || emitter.aliveCount > 0 { return true }
        }
        return false
    }

    public var defaultSelectionID: UInt64? {
        initialSelectionID
    }

    public var defaultExpandedEntityIDs: Set<UInt64> {
        initialExpandedIDs
    }

    public var roots: [EditorSceneNode] {
        scene.roots().map(buildNode)
    }

    public func manifest(selectedEntityID: UInt64? = nil) -> EditorSceneManifest {
        let selectedEntity = entity(from: selectedEntityID)
        let restoredSelection = selectedEntity.flatMap { scene.contains($0) ? $0.rawValue : nil }
        let physicsSettings = scene.resource(PhysicsSettingsResource.self)
            .map(EditorSceneManifestPhysicsSettings.init)
        let particleScalability = scene.resource(ParticleScalabilityResource.self)
            .map(EditorSceneManifestParticleScalability.init)
        let particleScalabilityPolicy = scene.resource(ParticleScalabilityPolicyResource.self)
            .map(EditorSceneManifestParticleScalabilityPolicy.init)
        let sceneKind = scene.resource(SceneKindComponent.self)?.value
        let assetCount = AssetRegistry.shared.entriesSnapshot().count
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let manifestRoots = scene.roots().map(manifestNode)
        return EditorSceneManifest(revision: revision,
                                   entityCount: entityCount,
                                   selectedEntityID: restoredSelection,
                                   sceneKind: sceneKind,
                                   physicsSettings: physicsSettings,
                                   particleScalability: particleScalability,
                                   particleScalabilityPolicy: particleScalabilityPolicy,
                                   projectAssetCount: assetCount > 0 ? assetCount : nil,
                                   lastModifiedAt: timestamp,
                                   roots: manifestRoots)
    }

    @discardableResult
    public func load(manifest: EditorSceneManifest, notify: Bool = true) -> EditorSceneManifestLoadResult {
        var restoredScene = SceneRuntime()
        var idMap: [UInt64: EntityID] = [:]

        @discardableResult
        func restoreNode(_ node: EditorSceneManifestNode) -> EntityID {
            let entity = restoredScene.createEntity()
            idMap[node.id] = entity
            _ = restoredScene.setComponent(SceneNameComponent(value: node.name), for: entity)
            _ = restoredScene.setComponent(SceneKindComponent(value: node.kind), for: entity)
            _ = restoredScene.setLocalTransform(node.localTransform?.localTransform ?? .identity,
                                                for: entity)
            if let asset = node.asset {
                _ = restoredScene.setComponent(asset.component, for: entity)
            }
            if let renderMesh = node.renderMesh {
                _ = restoredScene.setComponent(renderMesh.component, for: entity)
            }
            if let renderMaterial = node.renderMaterial {
                _ = restoredScene.setComponent(renderMaterial.component, for: entity)
            }
            if let camera = node.camera {
                _ = restoredScene.setComponent(camera.component, for: entity)
            }
            if let light = node.light {
                _ = restoredScene.setComponent(light.component, for: entity)
            }
            if let rigidBody = node.rigidBody {
                _ = restoredScene.setComponent(rigidBody.component, for: entity)
            }
            if let collider = node.collider {
                _ = restoredScene.setComponent(collider.component, for: entity)
            }
            if let script = node.script {
                _ = restoredScene.setComponent(script.component, for: entity)
            }
            if let audioSource = node.audioSource {
                _ = restoredScene.setComponent(audioSource.component, for: entity)
            }
            if let animationPlayer = node.animationPlayer {
                _ = restoredScene.setComponent(animationPlayer.component, for: entity)
            }
            if let animationGraphPlayer = node.animationGraphPlayer {
                _ = restoredScene.setComponent(animationGraphPlayer.component, for: entity)
            }
            if let particleEmitter = node.particleEmitter {
                _ = restoredScene.setComponent(particleEmitter.component, for: entity)
            }
            for child in node.children {
                let childEntity = restoreNode(child)
                _ = restoredScene.setParent(entity, for: childEntity)
            }
            return entity
        }

        func restoreConstraints(_ node: EditorSceneManifestNode) {
            if let entity = idMap[node.id],
               let constraint = node.constraint?.component(idMap: idMap) {
                _ = restoredScene.setComponent(constraint, for: entity)
            }
            for child in node.children {
                restoreConstraints(child)
            }
        }

        for root in manifest.roots {
            restoreNode(root)
        }
        for root in manifest.roots {
            restoreConstraints(root)
        }
        if let physicsSettings = manifest.physicsSettings {
            restoredScene.setResource(physicsSettings.settings)
        }
        if let particleScalability = manifest.particleScalability {
            restoredScene.setResource(particleScalability.settings)
        }
        if let particleScalabilityPolicy = manifest.particleScalabilityPolicy {
            restoredScene.setResource(particleScalabilityPolicy.policy)
        }
        rebuildMeshColliderResources(in: &restoredScene)
        restoredScene.propagateTransforms()

        scene = restoredScene
        initialSelectionID = manifest.selectedEntityID.flatMap { idMap[$0]?.rawValue }
            ?? scene.roots().first?.rawValue
        initialExpandedIDs = Set(scene.roots().map(\.rawValue))
        if notify {
            notifyRevisionChanged()
        }
        return EditorSceneManifestLoadResult(entityCount: entityCount,
                                             selectedEntityID: initialSelectionID)
    }

    @discardableResult
    public func moveEntity(_ entityID: UInt64,
                           to parentID: UInt64?,
                           at index: Int) -> TransactionApplyResult? {
        applySceneTransaction(intentVerb: "scene.move_entity",
                              summary: "Move entity in hierarchy",
                              targetRawIDs: [entityID],
                              mutations: [.moveEntity(entityID: entityID,
                                                      parentID: parentID,
                                                      index: index)])
    }

    public func entitySummary(id rawID: UInt64?) -> EditorSceneEntitySummary? {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return nil
        }
        return EditorSceneEntitySummary(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity)
        )
    }

    public func inspectorSections(for rawID: UInt64?) -> [EditorInspectorSection] {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return []
        }

        var sections: [EditorInspectorSection] = [
            generalSection(for: entity),
            hierarchySection(for: entity),
            particleScalabilitySection(),
        ]

        if let transformSection = transformSection(for: entity) {
            sections.append(transformSection)
        }
        if let rigidBodySection = rigidBodySection(for: entity) {
            sections.append(rigidBodySection)
        }
        if let colliderSection = colliderSection(for: entity) {
            sections.append(colliderSection)
        }
        if let constraintSection = constraintSection(for: entity) {
            sections.append(constraintSection)
        }
        if let lightSection = lightSection(for: entity) {
            sections.append(lightSection)
        }
        if let cameraSection = cameraSection(for: entity) {
            sections.append(cameraSection)
        }
        if let scriptSection = scriptSection(for: entity) {
            sections.append(scriptSection)
        }
        if let animationPlayerSection = animationPlayerSection(for: entity) {
            sections.append(animationPlayerSection)
        }
        if let animationGraphPlayerSection = animationGraphPlayerSection(for: entity) {
            sections.append(animationGraphPlayerSection)
        }
        if let audioSourceSection = audioSourceSection(for: entity) {
            sections.append(audioSourceSection)
        }
        if let audioListenerSection = audioListenerSection(for: entity) {
            sections.append(audioListenerSection)
        }
        if let particleEmitterSection = particleEmitterSection(for: entity) {
            sections.append(particleEmitterSection)
        }
        if let renderMeshSection = renderMeshSection(for: entity) {
            sections.append(renderMeshSection)
        }
        if let renderMaterialSection = renderMaterialSection(for: entity) {
            sections.append(renderMaterialSection)
        }

        return sections
    }

    private func buildNode(_ entity: EntityID) -> EditorSceneNode {
        EditorSceneNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            children: scene.children(of: entity).map(buildNode)
        )
    }

    private func manifestNode(_ entity: EntityID) -> EditorSceneManifestNode {
        let localTransform = scene.localTransform(for: entity).map { EditorSceneManifestMatrix($0.matrix) }
        let asset = scene.component(AssetReferenceComponent.self, for: entity)
            .map(EditorSceneManifestAssetReference.init)
        let renderMesh = scene.component(RenderMeshComponent.self, for: entity)
            .map(EditorSceneManifestRenderMesh.init)
        let renderMaterial = scene.component(RenderMaterialComponent.self, for: entity)
            .map(EditorSceneManifestRenderMaterial.init)
        let camera = scene.component(CameraComponent.self, for: entity)
            .map(EditorSceneManifestCamera.init)
        let light = scene.component(LightComponent.self, for: entity)
            .map(EditorSceneManifestLight.init)
        let rigidBody = scene.component(RigidBody.self, for: entity)
            .map(EditorSceneManifestRigidBody.init)
        let collider = scene.component(Collider.self, for: entity)
            .map(EditorSceneManifestCollider.init)
        let constraint = scene.component(Constraint.self, for: entity)
            .map(EditorSceneManifestConstraint.init)
        let script = scene.component(ScriptComponent.self, for: entity)
            .map(EditorSceneManifestScript.init)
        let audioSource = scene.component(AudioSource.self, for: entity)
            .map(EditorSceneManifestAudioSource.init)
        let animationPlayer = scene.component(AnimationPlayer.self, for: entity)
            .map(EditorSceneManifestAnimationPlayer.init)
        let animationGraphPlayer = scene.component(AnimationGraphPlayer.self, for: entity)
            .map(EditorSceneManifestAnimationGraphPlayer.init)
        let childIDs = scene.children(of: entity)
        var children: [EditorSceneManifestNode] = []
        children.reserveCapacity(childIDs.count)
        for child in childIDs {
            children.append(manifestNode(child))
        }
        let particleEmitter = scene.component(ParticleEmitter.self, for: entity)
            .map(EditorSceneManifestParticleEmitter.init)
        return EditorSceneManifestNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            localTransform: localTransform,
            asset: asset,
            renderMesh: renderMesh,
            renderMaterial: renderMaterial,
            camera: camera,
            light: light,
            rigidBody: rigidBody,
            collider: collider,
            constraint: constraint,
            script: script,
            audioSource: audioSource,
            animationPlayer: animationPlayer,
            animationGraphPlayer: animationGraphPlayer,
            particleEmitter: particleEmitter,
            children: children
        )
    }

    private func rebuildMeshColliderResources(in runtime: inout SceneRuntime) {
        var boundsResource = runtime.resource(MeshColliderBoundsResource.self) ?? MeshColliderBoundsResource()
        var geometryResource = runtime.resource(MeshColliderGeometryResource.self) ?? MeshColliderGeometryResource()
        var changedBounds = false
        var changedGeometry = false

        for entity in runtime.entities() {
            guard let asset = runtime.component(AssetReferenceComponent.self, for: entity),
                  let collider = runtime.component(Collider.self, for: entity),
                  case let .mesh(resourceID, _) = collider.shape,
                  let mesh = AssetRegistry.shared.meshAsset(for: asset.meshIndex) else {
                continue
            }

            let resolvedResourceID = resourceID ?? meshColliderResourceID(for: asset.meshIndex)
            let bounds = SpatialAABB(min: mesh.localBounds.min, max: mesh.localBounds.max)
            boundsResource.boundsByResourceID[resolvedResourceID] = bounds
            changedBounds = true

            if mesh.triangleCount > 0 {
                geometryResource.geometryByResourceID[resolvedResourceID] = MeshColliderGeometry(
                    positions: (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) },
                    triangleIndices: mesh.indices,
                    localBounds: bounds
                )
                changedGeometry = true
            }
        }

        if changedBounds {
            runtime.setResource(boundsResource)
        }
        if changedGeometry {
            runtime.setResource(geometryResource)
        }
    }

    private func generalSection(for entity: EntityID) -> EditorInspectorSection {
        EditorInspectorSection(
            id: "general",
            title: L("General"),
            fields: [
                EditorInspectorField(
                    id: "name",
                    label: L("Name"),
                    value: .text(nameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "kind",
                    label: L("Kind"),
                    value: .readOnly(displayKind(for: entity))
                ),
                EditorInspectorField(
                    id: "entity-id",
                    label: L("Entity ID"),
                    value: .readOnly(String(entity.rawValue))
                ),
            ]
        )
    }

    private func hierarchySection(for entity: EntityID) -> EditorInspectorSection {
        let parentLabel: String
        if let parent = scene.parent(of: entity) {
            parentLabel = displayName(for: parent)
        } else {
            parentLabel = L("Root")
        }

        return EditorInspectorSection(
            id: "hierarchy",
            title: L("Hierarchy"),
            fields: [
                EditorInspectorField(
                    id: "parent",
                    label: L("Parent"),
                    value: .readOnly(parentLabel)
                ),
                EditorInspectorField(
                    id: "children",
                    label: L("Children"),
                    value: .readOnly(String(scene.children(of: entity).count))
                ),
            ]
        )
    }

    private func transformSection(for entity: EntityID) -> EditorInspectorSection? {
        let local = scene.localTransform(for: entity)
        let world = scene.worldTransform(for: entity)
        guard local != nil || world != nil else { return nil }

        var fields: [EditorInspectorField] = []
        if local != nil {
            fields.append(
                EditorInspectorField(
                    id: "local-position",
                    label: L("Local Position"),
                    value: .vector3(x: localPositionBinding(for: entity, axis: \.x),
                                    y: localPositionBinding(for: entity, axis: \.y),
                                    z: localPositionBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-rotation",
                    label: L("Rotation"),
                    value: .vector3(x: localRotationBinding(for: entity, axis: \.x),
                                    y: localRotationBinding(for: entity, axis: \.y),
                                    z: localRotationBinding(for: entity, axis: \.z))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "local-scale",
                    label: L("Scale"),
                    value: .vector3(x: localScaleBinding(for: entity, axis: \.x),
                                    y: localScaleBinding(for: entity, axis: \.y),
                                    z: localScaleBinding(for: entity, axis: \.z))
                )
            )
        }
        if world != nil {
            let displayed = entityWorldPosition(entity.rawValue) ?? world!.translation
            fields.append(
                EditorInspectorField(
                    id: "world-position",
                    label: L("World Position"),
                    value: .readOnly(format(displayed))
                )
            )
        }

        return EditorInspectorSection(id: "transform", title: L("Transform"), fields: fields)
    }

    private func rigidBodySection(for entity: EntityID) -> EditorInspectorSection? {
        guard let body = scene.component(RigidBody.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "rigid-body",
            title: L("Rigid Body"),
            fields: [
                EditorInspectorField(
                    id: "motion",
                    label: L("Motion"),
                    value: .rigidBodyMotion(rigidBodyMotionBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mass",
                    label: L("Mass"),
                    value: .constrainedNumber(rigidBodyMassBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.5,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "gravity-scale",
                    label: L("Gravity"),
                    value: .constrainedNumber(rigidBodyGravityScaleBinding(for: entity),
                                              min: nil,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                ),
                EditorInspectorField(
                    id: "allow-sleep",
                    label: L("Allow Sleep"),
                    value: .bool(rigidBodyAllowSleepBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "sleeping",
                    label: L("Sleeping"),
                    value: .readOnly(body.isSleeping ? L("Yes") : L("No"))
                ),
            ]
        )
    }

    private func colliderSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let collider = scene.component(Collider.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "shape-kind",
                label: L("Shape"),
                value: .colliderShapeKind(colliderShapeKindBinding(for: entity))
            ),
        ]

        switch collider.shape {
        case .box:
            fields.append(
                EditorInspectorField(
                    id: "shape-box-extents",
                    label: L("Half Extents"),
                    value: .vector3(x: colliderBoxHalfExtentsBinding(for: entity, axis: \.x),
                                    y: colliderBoxHalfExtentsBinding(for: entity, axis: \.y),
                                    z: colliderBoxHalfExtentsBinding(for: entity, axis: \.z))
                )
            )
        case .sphere:
            fields.append(
                EditorInspectorField(
                    id: "shape-sphere-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderSphereRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .capsule:
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-radius",
                    label: L("Radius"),
                    value: .constrainedNumber(colliderCapsuleRadiusBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "shape-capsule-half-height",
                    label: L("Half Height"),
                    value: .constrainedNumber(colliderCapsuleHalfHeightBinding(for: entity),
                                              min: 0.01, max: nil, step: 0.1, showsStepper: true)
                )
            )
        case .mesh:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-mesh-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        case .convex:
            let resourceLabel = collider.shape.resourceID ?? L("(auto)")
            fields.append(
                EditorInspectorField(
                    id: "shape-convex-resource",
                    label: L("Resource"),
                    value: .readOnly(resourceLabel)
                )
            )
        }

        fields.append(
            EditorInspectorField(
                id: "trigger",
                label: L("Trigger"),
                value: .bool(colliderTriggerBinding(for: entity))
            )
        )

        fields.append(
            EditorInspectorField(
                id: "material-friction",
                label: L("Friction"),
                value: .constrainedNumber(colliderFrictionBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-restitution",
                label: L("Restitution"),
                value: .constrainedNumber(colliderRestitutionBinding(for: entity),
                                          min: 0, max: 1, step: 0.05, showsStepper: true)
            )
        )
        fields.append(
            EditorInspectorField(
                id: "material-density",
                label: L("Density"),
                value: .constrainedNumber(colliderDensityBinding(for: entity),
                                          min: 0, max: nil, step: 0.1, showsStepper: true)
            )
        )

        fields.append(
            EditorInspectorField(
                id: "layer",
                label: L("Layer"),
                value: .constrainedNumber(colliderLayerBinding(for: entity),
                                          min: 0, max: 65535, step: 1, showsStepper: true)
            )
        )

        return EditorInspectorSection(
            id: "collider",
            title: L("Collider"),
            fields: fields
        )
    }

    private func constraintSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let constraint = scene.component(Constraint.self, for: entity) else {
            return nil
        }

        return EditorInspectorSection(
            id: "constraint",
            title: L("Constraint"),
            fields: [
                EditorInspectorField(
                    id: "type",
                    label: L("Type"),
                    value: .readOnly(constraint.constraintType.rawValue)
                ),
                EditorInspectorField(
                    id: "entity-a",
                    label: L("Entity A"),
                    value: .readOnly(displayName(for: constraint.entityA))
                ),
                EditorInspectorField(
                    id: "entity-b",
                    label: L("Entity B"),
                    value: .readOnly(displayName(for: constraint.entityB))
                ),
                EditorInspectorField(
                    id: "limits",
                    label: L("Limits"),
                    value: .readOnly("\(format(constraint.minLimit)) ... \(format(constraint.maxLimit))")
                ),
                EditorInspectorField(
                    id: "enabled",
                    label: L("Enabled"),
                    value: .bool(constraintEnabledBinding(for: entity))
                ),
            ]
        )
    }

    private func lightSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let light = scene.component(LightComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = [
            EditorInspectorField(
                id: "type",
                label: L("Type"),
                value: .lightType(lightTypeBinding(for: entity))
            ),
            EditorInspectorField(
                id: "color",
                label: L("Color"),
                value: .color(lightColorBinding(for: entity))
            )
        ]

        switch light.type {
        case .directional:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .number(lightIntensityBinding(for: entity))
                )
            )
        case .point:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
        case .spot:
            fields.append(
                EditorInspectorField(
                    id: "intensity",
                    label: L("Intensity"),
                    value: .constrainedNumber(lightIntensityBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "range",
                    label: L("Range"),
                    value: .constrainedNumber(lightRangeBinding(for: entity),
                                              min: 0,
                                              max: nil,
                                              step: 0.1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-inner-angle",
                    label: L("Inner Angle"),
                    value: .constrainedNumber(lightSpotInnerAngleBinding(for: entity),
                                              min: 0,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-outer-angle",
                    label: L("Outer Angle"),
                    value: .constrainedNumber(lightSpotOuterAngleBinding(for: entity),
                                              min: 1,
                                              max: 179,
                                              step: 1,
                                              showsStepper: true)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "spot-cone-hint",
                    label: L("Cone"),
                    value: .readOnly("\(format(light.spotInnerAngleDegrees))掳 -> \(format(light.spotOuterAngleDegrees))掳")
                )
            )
        }

        return EditorInspectorSection(
            id: "light",
            title: L("Light"),
            fields: fields
        )
    }

    private func cameraSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(CameraComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "camera",
            title: L("Camera"),
            fields: [
                EditorInspectorField(
                    id: "camera-active",
                    label: L("Active"),
                    value: .bool(cameraActiveBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "camera-fov",
                    label: L("Field of View"),
                    value: .constrainedNumber(cameraFOVBinding(for: entity),
                                              min: 1, max: 179, step: 1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "camera-aspect",
                    label: L("Aspect Ratio"),
                    value: .constrainedNumber(cameraAspectBinding(for: entity),
                                              min: 0.1, max: 10, step: 0.01, showsStepper: true)
                ),
            ]
        )
    }

    private func cameraActiveBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(CameraComponent.self, for: entity)?.isActive ?? false
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity),
                      cam.isActive != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_active",
                                          summary: "Update camera active",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraActive(entityID: entity.rawValue, isActive: next)])
            }
        )
    }

    /// Field of view exposed in degrees; the component stores radians.
    private func cameraFOVBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                let radians = scene.component(CameraComponent.self, for: entity)?.fovYRadians ?? (.pi / 4)
                return radians * 180 / .pi
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity) else { return }
                let currentDegrees = cam.fovYRadians * 180 / .pi
                guard abs(currentDegrees - next) > 1e-4 else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_fov",
                                          summary: "Update camera field of view",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraFOV(entityID: entity.rawValue, fovYDegrees: next)])
            }
        )
    }

    private func cameraAspectBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(CameraComponent.self, for: entity)?.aspectRatio ?? 1
            },
            set: { [self] next in
                guard let cam = scene.component(CameraComponent.self, for: entity) else { return }
                let clamped = max(0.1, min(10, next))
                guard abs(cam.aspectRatio - clamped) > 1e-4 else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_camera_aspect_ratio",
                                          summary: "Update camera aspect ratio",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setCameraAspectRatio(entityID: entity.rawValue,
                                                                             aspectRatio: clamped)])
            }
        )
    }

    private func audioListenerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AudioListener.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "audio-listener",
            title: L("Audio Listener"),
            fields: [
                EditorInspectorField(
                    id: "audio-listener-volume",
                    label: L("Master Volume"),
                    value: .constrainedNumber(audioListenerVolumeBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
            ]
        )
    }

    private func audioListenerVolumeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioListener.self, for: entity)?.masterVolume ?? 1
            },
            set: { [self] next in
                guard let listener = scene.component(AudioListener.self, for: entity),
                      listener.masterVolume != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_audio_listener",
                                          summary: "Update audio listener volume",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioListener(entityID: entity.rawValue, masterVolume: next)])
            }
        )
    }

    private func particleScalabilitySection() -> EditorInspectorSection {
        let state = scene.resource(ParticleScalabilityStateResource.self) ?? .default
        return EditorInspectorSection(
            id: "particle-scalability",
            title: L("Particle Scalability"),
            fields: [
                EditorInspectorField(id: "particle-scale-emission", label: L("Emission Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.emissionScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-burst", label: L("Burst Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.burstScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-distance", label: L("Distance Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.distanceEmissionScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-scale-live-cap", label: L("Live Cap Scale"),
                                     value: .constrainedNumber(particleScalabilityFloatBinding(\.maxLiveParticleScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-enabled", label: L("Auto Scale"),
                                     value: .bool(particleScalabilityPolicyEnabledBinding())),
                EditorInspectorField(id: "particle-policy-target-live", label: L("Target Live"),
                                     value: .constrainedNumber(particleScalabilityPolicyIntBinding(\.targetLiveParticles),
                                                               min: 0, max: 1_000_000, step: 100, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-target-spawn", label: L("Target Spawn"),
                                     value: .constrainedNumber(particleScalabilityPolicyIntBinding(\.targetSpawnedParticlesPerFrame),
                                                               min: 0, max: 1_000_000, step: 10, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-min-scale", label: L("Minimum Scale"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.minimumScale),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-pressure-step", label: L("Pressure Step"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.pressureStep),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-recovery-step", label: L("Recovery Step"),
                                     value: .constrainedNumber(particleScalabilityPolicyFloatBinding(\.recoveryStep),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-policy-applied-scale", label: L("Applied Scale"),
                                     value: .readOnly(format(state.appliedScale))),
                EditorInspectorField(id: "particle-policy-pressure", label: L("Pressure"),
                                     value: .readOnly(format(state.pressure))),
                EditorInspectorField(id: "particle-policy-reason", label: L("Reason"),
                                     value: .readOnly(state.reason.rawValue)),
            ]
        )
    }

    private func updateParticleScalability(_ mutate: (inout ParticleScalabilityResource) -> Void) {
        var next = scene.resource(ParticleScalabilityResource.self) ?? .default
        mutate(&next)
        let sanitized = ParticleScalabilityResource(emissionScale: next.emissionScale,
                                                    burstScale: next.burstScale,
                                                    distanceEmissionScale: next.distanceEmissionScale,
                                                    maxLiveParticleScale: next.maxLiveParticleScale)
        guard scene.resource(ParticleScalabilityResource.self) != sanitized else { return }
        scene.setResource(sanitized)
        notifyRevisionChanged()
    }

    private func updateParticleScalabilityPolicy(_ mutate: (inout ParticleScalabilityPolicyResource) -> Void) {
        var next = scene.resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        mutate(&next)
        let sanitized = ParticleScalabilityPolicyResource(isEnabled: next.isEnabled,
                                                          targetLiveParticles: next.targetLiveParticles,
                                                          targetSpawnedParticlesPerFrame: next.targetSpawnedParticlesPerFrame,
                                                          minimumScale: next.minimumScale,
                                                          pressureStep: next.pressureStep,
                                                          recoveryStep: next.recoveryStep)
        guard scene.resource(ParticleScalabilityPolicyResource.self) != sanitized else { return }
        scene.setResource(sanitized)
        notifyRevisionChanged()
    }

    private func particleScalabilityFloatBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityResource, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityResource.self)?[keyPath: keyPath] ?? 1 },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityResource.self)?[keyPath: keyPath] != next else { return }
                updateParticleScalability { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleScalabilityPolicyEnabledBinding() -> Binding<Bool> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled ?? false },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityPolicyResource.self)?.isEnabled != next else { return }
                updateParticleScalabilityPolicy { $0.isEnabled = next }
            }
        )
    }

    private func particleScalabilityPolicyFloatBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityPolicyResource, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath]
                ?? ParticleScalabilityPolicyResource.disabled[keyPath: keyPath] },
            set: { [self] next in
                guard scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath] != next else { return }
                updateParticleScalabilityPolicy { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleScalabilityPolicyIntBinding(
        _ keyPath: WritableKeyPath<ParticleScalabilityPolicyResource, Int>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath]
                      ?? ParticleScalabilityPolicyResource.disabled[keyPath: keyPath])
            },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.resource(ParticleScalabilityPolicyResource.self)?[keyPath: keyPath] != value else { return }
                updateParticleScalabilityPolicy { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func particleEmitterSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let emitter = scene.component(ParticleEmitter.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "particle-emitter",
            title: L("Particle Emitter"),
            fields: [
                EditorInspectorField(id: "particle-module-stack", label: L("Modules"),
                                     value: .particleModuleStack(emitter.moduleStack)),
                EditorInspectorField(id: "particle-emitting", label: L("Emitting"),
                                     value: .bool(particleBoolBinding(for: entity, \.isEmitting,
                                                                      summary: "Toggle particle emitting"))),
                EditorInspectorField(id: "particle-looping", label: L("Looping"),
                                     value: .bool(particleBoolBinding(for: entity, \.looping,
                                                                      summary: "Toggle particle looping"))),
                EditorInspectorField(id: "particle-simulation-space", label: L("Space"),
                                     value: .particleSimulationSpace(particleSimulationSpaceBinding(for: entity))),
                EditorInspectorField(id: "particle-simulation-backend", label: L("Backend"),
                                     value: .particleSimulationBackend(particleSimulationBackendBinding(for: entity))),
                EditorInspectorField(id: "particle-gpu-workgroup-size", label: L("GPU Workgroup"),
                                     value: .constrainedNumber(particleIntBinding(for: entity,
                                                                                  \.gpuSimulationWorkgroupSize,
                                                                                  summary: "Update GPU particle workgroup size"),
                                                               min: 1,
                                                               max: Float(ParticleGPUSimulationPlan.maximumWorkgroupSize),
                                                               step: 1,
                                                               showsStepper: true)),
                EditorInspectorField(id: "particle-gpu-status", label: L("GPU Status"),
                                     value: .readOnly(particleGPUStatusLabel(for: entity))),
                EditorInspectorField(id: "particle-duration", label: L("Duration"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.duration,
                                                                                    summary: "Update particle duration"),
                                                               min: 0, max: 600, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-prewarm-time", label: L("Prewarm"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.prewarmTime,
                                                                                    summary: "Update particle prewarm"),
                                                               min: 0, max: 600, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-prewarm-step", label: L("Prewarm Step"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.prewarmStep,
                                                                                    summary: "Update particle prewarm step"),
                                                               min: 0.004, max: 1, step: 0.01, showsStepper: true)),
                EditorInspectorField(id: "particle-rate", label: L("Emission Rate"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.emissionRate,
                                                                                    summary: "Update emission rate"),
                                                               min: 0, max: 1000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-rate-curve", label: L("Rate Curve"),
                                     value: .particleCurve(particleCurveBinding(for: entity, \.emissionRateCurve,
                                                                                summary: "Update particle rate curve"))),
                EditorInspectorField(id: "particle-distance-rate", label: L("Rate over Distance"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.distanceEmissionRate,
                                                                                    summary: "Update distance emission rate"),
                                                               min: 0, max: 1000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-distance-rate-curve", label: L("Distance Curve"),
                                     value: .particleCurve(particleCurveBinding(for: entity, \.distanceEmissionRateCurve,
                                                                                summary: "Update particle distance rate curve"))),
                EditorInspectorField(id: "particle-burst-count", label: L("Burst Count"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.burstCount,
                                                                                  summary: "Update particle burst count"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-burst-interval", label: L("Burst Interval"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.burstInterval,
                                                                                    summary: "Update particle burst interval"),
                                                               min: 0, max: 60, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-max", label: L("Max Particles"),
                                     value: .constrainedNumber(particleMaxBinding(for: entity),
                                                               min: 0, max: 100_000, step: 16, showsStepper: true)),
                EditorInspectorField(id: "particle-max-rendered", label: L("Max Rendered"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.maxRenderedParticles,
                                                                                  summary: "Update max rendered particles"),
                                                               min: 0, max: 100_000, step: 16, showsStepper: true)),
                EditorInspectorField(id: "particle-lifetime", label: L("Lifetime"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.lifetime,
                                                                                    summary: "Update particle lifetime"),
                                                               min: 0, max: 60, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-trigger", label: L("Sub Emit"),
                                     value: .particleSubEmitterTrigger(particleSubEmitterTriggerBinding(for: entity))),
                EditorInspectorField(id: "particle-sub-emitter-burst", label: L("Sub Count"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.subEmitterBurstCount,
                                                                                  summary: "Update sub-emitter count"),
                                                               min: 0, max: 10_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-probability", label: L("Sub Chance"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity,
                                                                                    \.subEmitterProbability,
                                                                                    summary: "Update sub-emitter chance"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-depth", label: L("Sub Depth"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.subEmitterMaxDepth,
                                                                                  summary: "Update sub-emitter depth"),
                                                               min: 0, max: 16, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-inherit", label: L("Sub Inherit"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity,
                                                                                    \.subEmitterInheritVelocity,
                                                                                    summary: "Update sub-emitter inheritance"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-lifetime", label: L("Sub Lifetime"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.subEmitterLifetime,
                                                                                    summary: "Update sub-emitter lifetime"),
                                                               min: 0.0001, max: 60, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-velocity", label: L("Sub Velocity"),
                                     value: .vector3(x: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterStartVelocity,
                                                                               axis: 0,
                                                                               summary: "Update sub-emitter velocity"),
                                                     y: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterStartVelocity,
                                                                               axis: 1,
                                                                               summary: "Update sub-emitter velocity"),
                                                     z: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterStartVelocity,
                                                                               axis: 2,
                                                                               summary: "Update sub-emitter velocity"))),
                EditorInspectorField(id: "particle-sub-emitter-velocity-random", label: L("Sub Vel Random"),
                                     value: .vector3(x: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterVelocityRandomness,
                                                                               axis: 0,
                                                                               summary: "Update sub-emitter velocity randomness"),
                                                     y: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterVelocityRandomness,
                                                                               axis: 1,
                                                                               summary: "Update sub-emitter velocity randomness"),
                                                     z: particleVectorBinding(for: entity,
                                                                               keyPath: \.subEmitterVelocityRandomness,
                                                                               axis: 2,
                                                                               summary: "Update sub-emitter velocity randomness"))),
                EditorInspectorField(id: "particle-sub-emitter-start-size", label: L("Sub Start Size"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity,
                                                                                    \.subEmitterStartSize,
                                                                                    summary: "Update sub-emitter start size"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-end-size", label: L("Sub End Size"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity,
                                                                                    \.subEmitterEndSize,
                                                                                    summary: "Update sub-emitter end size"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-sub-emitter-start-color", label: L("Sub Start Color"),
                                     value: .color(particleSubEmitterColorBinding(for: entity, isStart: true))),
                EditorInspectorField(id: "particle-sub-emitter-end-color", label: L("Sub End Color"),
                                     value: .color(particleSubEmitterColorBinding(for: entity, isStart: false))),
                EditorInspectorField(id: "particle-sub-emitters", label: L("Sub Emitters"),
                                     value: .particleSubEmitters(particleSubEmittersBinding(for: entity))),
                EditorInspectorField(id: "particle-shape", label: L("Shape"),
                                     value: .particleEmissionShape(particleShapeBinding(for: entity))),
                EditorInspectorField(id: "particle-spawn-radius", label: L("Spawn Radius"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.spawnRadius,
                                                                                    summary: "Update spawn radius"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-box-extents", label: L("Box Extents"),
                                     value: .vector3(x: particleBoxExtentsBinding(for: entity, axis: 0),
                                                     y: particleBoxExtentsBinding(for: entity, axis: 1),
                                                     z: particleBoxExtentsBinding(for: entity, axis: 2))),
                EditorInspectorField(id: "particle-cone-radius", label: L("Cone Radius"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.coneRadius,
                                                                                    summary: "Update cone radius"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-cone-height", label: L("Cone Height"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.coneHeight,
                                                                                    summary: "Update cone height"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-start-size", label: L("Start Size"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.startSize,
                                                                                    summary: "Update start size"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-end-size", label: L("End Size"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.endSize,
                                                                                    summary: "Update end size"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-size-randomness", label: L("Size Random"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.sizeRandomness,
                                                                                    summary: "Update size randomness"),
                                                               min: 0, max: 4, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-rotation", label: L("Rotation"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.startRotation,
                                                                                    summary: "Update particle rotation"),
                                                               min: -1000, max: 1000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-rotation-randomness", label: L("Rot Random"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.rotationRandomness,
                                                                                    summary: "Update rotation randomness"),
                                                               min: 0, max: 1000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-angular-velocity", label: L("Spin"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.angularVelocity,
                                                                                    summary: "Update particle spin"),
                                                               min: -1000, max: 1000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-angular-velocity-randomness", label: L("Spin Random"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.angularVelocityRandomness,
                                                                                    summary: "Update spin randomness"),
                                                               min: 0, max: 1000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-velocity-inheritance", label: L("Velocity Inherit"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.velocityInheritance,
                                                                                    summary: "Update velocity inheritance"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-size-curve", label: L("Size Curve"),
                                     value: .particleCurve(particleCurveBinding(for: entity, \.sizeCurve,
                                                                                summary: "Update particle size curve"))),
                EditorInspectorField(id: "particle-gravity", label: L("Gravity"),
                                     value: .vector3(x: particleGravityBinding(for: entity, axis: 0),
                                                     y: particleGravityBinding(for: entity, axis: 1),
                                                     z: particleGravityBinding(for: entity, axis: 2))),
                EditorInspectorField(id: "particle-noise-strength", label: L("Noise Strength"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.noiseStrength,
                                                                                    summary: "Update particle noise strength"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-noise-scale", label: L("Noise Scale"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.noiseScale,
                                                                                    summary: "Update particle noise scale"),
                                                               min: 0.0001, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-noise-speed", label: L("Noise Speed"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.noiseSpeed,
                                                                                    summary: "Update particle noise speed"),
                                                               min: 0, max: 100, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-force-mode", label: L("Force"),
                                     value: .particleForceMode(particleForceModeBinding(for: entity))),
                EditorInspectorField(id: "particle-force-center", label: L("Force Center"),
                                     value: .vector3(x: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceCenter,
                                                                               axis: 0,
                                                                               summary: "Update particle force center"),
                                                     y: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceCenter,
                                                                               axis: 1,
                                                                               summary: "Update particle force center"),
                                                     z: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceCenter,
                                                                               axis: 2,
                                                                               summary: "Update particle force center"))),
                EditorInspectorField(id: "particle-force-axis", label: L("Force Axis"),
                                     value: .vector3(x: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceAxis,
                                                                               axis: 0,
                                                                               summary: "Update particle force axis"),
                                                     y: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceAxis,
                                                                               axis: 1,
                                                                               summary: "Update particle force axis"),
                                                     z: particleVectorBinding(for: entity,
                                                                               keyPath: \.forceAxis,
                                                                               axis: 2,
                                                                               summary: "Update particle force axis"))),
                EditorInspectorField(id: "particle-force-radius", label: L("Force Radius"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.forceRadius,
                                                                                    summary: "Update particle force radius"),
                                                               min: 0, max: 10_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-force-strength", label: L("Force Strength"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.forceStrength,
                                                                                    summary: "Update particle force strength"),
                                                               min: -10_000, max: 10_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-force-falloff", label: L("Force Falloff"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.forceFalloff,
                                                                                    summary: "Update particle force falloff"),
                                                               min: 0, max: 16, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-vector-field-mode", label: L("Vector Field"),
                                     value: .particleVectorFieldMode(particleVectorFieldModeBinding(for: entity))),
                EditorInspectorField(id: "particle-vector-field-direction", label: L("Field Direction"),
                                     value: .vector3(x: particleVectorBinding(for: entity,
                                                                               keyPath: \.vectorFieldDirection,
                                                                               axis: 0,
                                                                               summary: "Update vector field direction"),
                                                     y: particleVectorBinding(for: entity,
                                                                               keyPath: \.vectorFieldDirection,
                                                                               axis: 1,
                                                                               summary: "Update vector field direction"),
                                                     z: particleVectorBinding(for: entity,
                                                                               keyPath: \.vectorFieldDirection,
                                                                               axis: 2,
                                                                               summary: "Update vector field direction"))),
                EditorInspectorField(id: "particle-vector-field-strength", label: L("Field Strength"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.vectorFieldStrength,
                                                                                    summary: "Update vector field strength"),
                                                               min: -10_000, max: 10_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-vector-field-scale", label: L("Field Scale"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.vectorFieldScale,
                                                                                    summary: "Update vector field scale"),
                                                               min: 0.0001, max: 1_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-vector-field-scroll", label: L("Field Scroll"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.vectorFieldScrollSpeed,
                                                                                    summary: "Update vector field scroll"),
                                                               min: 0, max: 1_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-collision-mode", label: L("Collision"),
                                     value: .particleCollisionMode(particleCollisionModeBinding(for: entity))),
                EditorInspectorField(id: "particle-collision-plane-y", label: L("Plane Y"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.collisionPlaneY,
                                                                                    summary: "Update particle collision plane"),
                                                               min: -10_000, max: 10_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-collision-restitution", label: L("Restitution"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.collisionRestitution,
                                                                                    summary: "Update particle restitution"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-collision-damping", label: L("Damping"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.collisionDamping,
                                                                                    summary: "Update particle damping"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-start-color", label: L("Start Color"),
                                     value: .color(particleColorBinding(for: entity, isStart: true))),
                EditorInspectorField(id: "particle-end-color", label: L("End Color"),
                                     value: .color(particleColorBinding(for: entity, isStart: false))),
                EditorInspectorField(id: "particle-color-curve", label: L("Color Curve"),
                                     value: .particleCurve(particleCurveBinding(for: entity, \.colorCurve,
                                                                                summary: "Update particle color curve"))),
                EditorInspectorField(id: "particle-blend-mode", label: L("Blend"),
                                     value: .particleBlendMode(particleBlendModeBinding(for: entity))),
                EditorInspectorField(id: "particle-render-mode", label: L("Render Mode"),
                                     value: .particleRenderMode(particleRenderModeBinding(for: entity))),
                EditorInspectorField(id: "particle-sort-mode", label: L("Sort"),
                                     value: .particleSortMode(particleSortModeBinding(for: entity))),
                EditorInspectorField(id: "particle-ribbon-width-scale", label: L("Ribbon Width"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonWidthScale,
                                                                                    summary: "Update ribbon width"),
                                                               min: 0, max: 100, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-tail-width", label: L("Ribbon Tail Width"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonTailWidthScale,
                                                                                    summary: "Update ribbon tail width"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-tail-alpha", label: L("Ribbon Tail Alpha"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonTailAlphaScale,
                                                                                    summary: "Update ribbon tail alpha"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-max-segment", label: L("Ribbon Max Segment"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonMaxSegmentLength,
                                                                                    summary: "Update ribbon max segment"),
                                                               min: 0, max: 100_000, step: 0.1, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-join-overlap", label: L("Ribbon Join Overlap"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonJoinOverlapScale,
                                                                                    summary: "Update ribbon join overlap"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-smoothing", label: L("Ribbon Smoothing"),
                                     value: .constrainedNumber(particleClampedIntBinding(for: entity,
                                                                                         \.ribbonSmoothingSegments,
                                                                                         min: 1,
                                                                                         max: 16,
                                                                                         summary: "Update ribbon smoothing"),
                                                               min: 1, max: 16, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-uv-tiling", label: L("Ribbon UV Tiling"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonTextureTiling,
                                                                                    summary: "Update ribbon UV tiling"),
                                                               min: 0, max: 100, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-ribbon-uv-offset", label: L("Ribbon UV Offset"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.ribbonTextureOffset,
                                                                                    summary: "Update ribbon UV offset"),
                                                               min: -10_000, max: 10_000, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-render-alignment", label: L("Alignment"),
                                     value: .particleRenderAlignment(particleRenderAlignmentBinding(for: entity))),
                EditorInspectorField(id: "particle-velocity-stretch-scale", label: L("Velocity Stretch"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.velocityStretchScale,
                                                                                    summary: "Update velocity stretch"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-velocity-stretch-max", label: L("Max Stretch"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.velocityStretchMax,
                                                                                    summary: "Update max velocity stretch"),
                                                               min: 1, max: 100, step: 0.5, showsStepper: true)),
                EditorInspectorField(id: "particle-max-render-distance", label: L("Max Render Distance"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.maxRenderDistance,
                                                                                    summary: "Update particle render distance"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-render-distance-fade", label: L("Distance Fade"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.renderDistanceFadeRange,
                                                                                    summary: "Update particle distance fade"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-render-lod-start", label: L("LOD Start"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.renderLODStartDistance,
                                                                                    summary: "Update particle render LOD start"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-render-lod-end", label: L("LOD End"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.renderLODEndDistance,
                                                                                    summary: "Update particle render LOD end"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-render-lod-min-scale", label: L("LOD Min Scale"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.renderLODMinParticleScale,
                                                                                    summary: "Update particle render LOD scale"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-render-bounds-mode", label: L("Bounds Mode"),
                                     value: .particleRenderBoundsMode(particleRenderBoundsModeBinding(for: entity))),
                EditorInspectorField(id: "particle-render-bounds-radius", label: L("Manual Bounds"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.renderBoundsRadius,
                                                                                    summary: "Update particle render bounds"),
                                                               min: 0, max: 100_000, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-render-bounds-estimate", label: L("Auto Bounds"),
                                     value: .readOnly(format(scene.component(ParticleEmitter.self,
                                                                             for: entity)?
                                         .estimatedRenderBoundsRadius() ?? 0))),
                EditorInspectorField(id: "particle-texture", label: L("Texture"),
                                     value: .asset(particleTextureAssetBinding(for: entity),
                                                   acceptedKinds: [ImportableAssetKind.png.sceneKindLabel],
                                                   placeholder: L("Drop texture"))),
                EditorInspectorField(id: "particle-texture-sheet-columns", label: L("Sheet Columns"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.textureSheetColumns,
                                                                                  summary: "Update texture sheet columns"),
                                                               min: 1, max: 64, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-texture-sheet-rows", label: L("Sheet Rows"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.textureSheetRows,
                                                                                  summary: "Update texture sheet rows"),
                                                               min: 1, max: 64, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-texture-sheet-frames", label: L("Sheet Frames"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.textureSheetFrameCount,
                                                                                  summary: "Update texture sheet frames"),
                                                               min: 1, max: 4096, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-texture-sheet-fps", label: L("Sheet FPS"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.textureSheetFrameRate,
                                                                                    summary: "Update texture sheet FPS"),
                                                               min: 0, max: 240, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-texture-sheet-playback", label: L("Sheet Playback"),
                                     value: .particleTextureSheetPlaybackMode(
                                         particleTextureSheetPlaybackModeBinding(for: entity)
                                     )),
                EditorInspectorField(id: "particle-texture-sheet-start-frame", label: L("Sheet Start"),
                                     value: .constrainedNumber(particleIntBinding(for: entity,
                                                                                  \.textureSheetStartFrame,
                                                                                  summary: "Update texture sheet start frame"),
                                                               min: 0, max: 4095, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-texture-sheet-random", label: L("Sheet Random"),
                                     value: .constrainedNumber(particleIntBinding(for: entity,
                                                                                  \.textureSheetFrameRandomness,
                                                                                  summary: "Update texture sheet random frames"),
                                                               min: 0, max: 4095, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-trail-length", label: L("Trail Length"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.trailLength,
                                                                                    summary: "Update particle trail length"),
                                                               min: 0, max: 10, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-trail-segments", label: L("Trail Segments"),
                                     value: .constrainedNumber(particleIntBinding(for: entity, \.trailSegments,
                                                                                  summary: "Update particle trail segments"),
                                                               min: 0, max: 64, step: 1, showsStepper: true)),
                EditorInspectorField(id: "particle-trail-end-size", label: L("Trail End Size"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.trailEndSizeScale,
                                                                                    summary: "Update particle trail end size"),
                                                               min: 0, max: 4, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "particle-trail-end-alpha", label: L("Trail End Alpha"),
                                     value: .constrainedNumber(particleFloatBinding(for: entity, \.trailEndAlphaScale,
                                                                                    summary: "Update particle trail end alpha"),
                                                               min: 0, max: 1, step: 0.05, showsStepper: true)),
            ]
        )
    }

    private func particleGPUStatusLabel(for entity: EntityID) -> String {
        guard let emitter = scene.component(ParticleEmitter.self, for: entity) else {
            return L("No emitter")
        }
        let plan = emitter.gpuSimulationPlan
        switch plan.status {
        case .disabled:
            return L("CPU")
        case .supported:
            return "\(L("Supported")) (\(plan.dispatchWorkgroups)x\(plan.workgroupSize))"
        case .fallbackToCPU:
            return "\(L("CPU fallback")): \(particleGPUUnsupportedReasonList(plan.unsupportedReasons))"
        case .requiredButUnsupported:
            return "\(L("Unsupported")): \(particleGPUUnsupportedReasonList(plan.unsupportedReasons))"
        }
    }

    private func particleGPUUnsupportedReasonList(
        _ reasons: [ParticleGPUSimulationUnsupportedReason]
    ) -> String {
        guard !reasons.isEmpty else { return L("None") }
        return reasons.map(particleGPUUnsupportedReasonLabel).joined(separator: ", ")
    }

    private func particleGPUUnsupportedReasonLabel(
        _ reason: ParticleGPUSimulationUnsupportedReason
    ) -> String {
        switch reason {
        case .backendCPU:
            return L("CPU backend")
        case .noParticleCapacity:
            return L("no capacity")
        case .eventSubEmitters:
            return L("sub-emitters")
        case .distanceEmission:
            return L("distance emission")
        case .noise:
            return L("noise")
        case .forceFields:
            return L("force fields")
        case .collisions:
            return L("collisions")
        case .angularVelocity:
            return L("angular velocity")
        }
    }

    /// Applies `mutate` to a copy of the emitter and submits it as a whole-component update.
    private func updateParticleEmitter(_ entity: EntityID, summary: String,
                                       _ mutate: (inout ParticleEmitter) -> Void) {
        guard var emitter = scene.component(ParticleEmitter.self, for: entity) else { return }
        mutate(&emitter)
        _ = applySceneTransaction(intentVerb: "scene.set_particle_emitter",
                                  summary: summary,
                                  targetRawIDs: [entity.rawValue],
                                  mutations: [.setParticleEmitter(entityID: entity.rawValue, emitter: emitter)])
    }

    private func particleBoolBinding(for entity: EntityID,
                                     _ keyPath: WritableKeyPath<ParticleEmitter, Bool>,
                                     summary: String) -> Binding<Bool> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? false },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleFloatBinding(for entity: EntityID,
                                      _ keyPath: WritableKeyPath<ParticleEmitter, Float>,
                                      summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleMaxBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?.maxParticles ?? 0) },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.component(ParticleEmitter.self, for: entity)?.maxParticles != value else { return }
                updateParticleEmitter(entity, summary: "Update max particles") { $0.maxParticles = value }
            }
        )
    }

    private func particleIntBinding(for entity: EntityID,
                                    _ keyPath: WritableKeyPath<ParticleEmitter, Int>,
                                    summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? 0) },
            set: { [self] next in
                let value = max(0, Int(next.rounded()))
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != value else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func particleClampedIntBinding(for entity: EntityID,
                                           _ keyPath: WritableKeyPath<ParticleEmitter, Int>,
                                           min minimum: Int,
                                           max maximum: Int,
                                           summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in Float(scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? minimum) },
            set: { [self] next in
                let lower = min(minimum, maximum)
                let upper = max(minimum, maximum)
                let value = Swift.max(lower, Swift.min(upper, Int(next.rounded())))
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != value else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func particleShapeBinding(for entity: EntityID) -> Binding<ParticleEmissionShape> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.emissionShape ?? .sphere },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.emissionShape != next else { return }
                updateParticleEmitter(entity, summary: "Update particle emission shape") { $0.emissionShape = next }
            }
        )
    }

    private func particleBoxExtentsBinding(for entity: EntityID, axis: Int) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.boxHalfExtents[axis] ?? 0 },
            set: { [self] next in
                let value = max(0, next)
                guard scene.component(ParticleEmitter.self, for: entity)?.boxHalfExtents[axis] != value else { return }
                updateParticleEmitter(entity, summary: "Update particle box extents") { $0.boxHalfExtents[axis] = value }
            }
        )
    }

    private func particleCollisionModeBinding(for entity: EntityID) -> Binding<ParticleCollisionMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.collisionMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.collisionMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle collision mode") { $0.collisionMode = next }
            }
        )
    }

    private func particleForceModeBinding(for entity: EntityID) -> Binding<ParticleForceMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.forceMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.forceMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle force mode") { $0.forceMode = next }
            }
        )
    }

    private func particleVectorFieldModeBinding(for entity: EntityID) -> Binding<ParticleVectorFieldMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.vectorFieldMode ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.vectorFieldMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle vector field mode") {
                    $0.vectorFieldMode = next
                }
            }
        )
    }

    private func particleSubEmitterTriggerBinding(for entity: EntityID) -> Binding<ParticleSubEmitterTrigger> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.subEmitterTrigger ?? .none },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.subEmitterTrigger != next else { return }
                updateParticleEmitter(entity, summary: "Update sub-emitter trigger") { $0.subEmitterTrigger = next }
            }
        )
    }

    private func particleSubEmittersBinding(for entity: EntityID) -> Binding<[ParticleSubEmitter]> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.subEmitters ?? [] },
            set: { [self] next in
                let sanitized = next.map(sanitizedParticleSubEmitter)
                guard scene.component(ParticleEmitter.self, for: entity)?.subEmitters != sanitized else { return }
                updateParticleEmitter(entity, summary: "Update particle sub-emitters") {
                    $0.subEmitters = sanitized
                }
            }
        )
    }

    private func sanitizedParticleSubEmitter(_ rule: ParticleSubEmitter) -> ParticleSubEmitter {
        ParticleSubEmitter(trigger: rule.trigger,
                           burstCount: rule.burstCount,
                           probability: rule.probability,
                           maxDepth: rule.maxDepth,
                           inheritVelocity: rule.inheritVelocity,
                           lifetime: rule.lifetime,
                           startVelocity: rule.startVelocity,
                           velocityRandomness: rule.velocityRandomness,
                           startSize: rule.startSize,
                           endSize: rule.endSize,
                           startColor: rule.startColor,
                           endColor: rule.endColor)
    }

    private func particleVectorBinding(for entity: EntityID,
                                       keyPath: WritableKeyPath<ParticleEmitter, SIMD3<Float>>,
                                       axis: Int,
                                       summary: String) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath][axis] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath][axis] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath][axis] = next }
            }
        )
    }

    private func particleSimulationSpaceBinding(for entity: EntityID) -> Binding<ParticleSimulationSpace> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.simulationSpace ?? .local },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.simulationSpace != next else { return }
                updateParticleEmitter(entity, summary: "Update particle simulation space") { $0.simulationSpace = next }
            }
        )
    }

    private func particleSimulationBackendBinding(for entity: EntityID) -> Binding<ParticleSimulationBackend> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.simulationBackend ?? .cpu },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.simulationBackend != next else { return }
                updateParticleEmitter(entity, summary: "Update particle simulation backend") {
                    $0.simulationBackend = next
                }
            }
        )
    }

    private func particleCurveBinding(for entity: EntityID,
                                      _ keyPath: WritableKeyPath<ParticleEmitter, ParticleCurve>,
                                      summary: String) -> Binding<ParticleCurve> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] ?? .linear },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?[keyPath: keyPath] != next else { return }
                updateParticleEmitter(entity, summary: summary) { $0[keyPath: keyPath] = next }
            }
        )
    }

    private func particleBlendModeBinding(for entity: EntityID) -> Binding<ParticleBlendMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.blendMode ?? .alpha },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.blendMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle blend mode") { $0.blendMode = next }
            }
        )
    }

    private func particleRenderModeBinding(for entity: EntityID) -> Binding<ParticleRenderMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.renderMode ?? .billboard },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.renderMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render mode") { $0.renderMode = next }
            }
        )
    }

    private func particleSortModeBinding(for entity: EntityID) -> Binding<ParticleSortMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.sortMode ?? .distanceDescending },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.sortMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle sort mode") { $0.sortMode = next }
            }
        )
    }

    private func particleTextureSheetPlaybackModeBinding(
        for entity: EntityID
    ) -> Binding<ParticleTextureSheetPlaybackMode> {
        Binding(
            get: {
                [self] in scene.component(ParticleEmitter.self,
                                           for: entity)?.textureSheetPlaybackMode ?? .automatic
            },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self,
                                      for: entity)?.textureSheetPlaybackMode != next else { return }
                updateParticleEmitter(entity, summary: "Update texture sheet playback") {
                    $0.textureSheetPlaybackMode = next
                }
            }
        )
    }

    private func particleRenderAlignmentBinding(for entity: EntityID) -> Binding<ParticleRenderAlignment> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.renderAlignment ?? .billboard },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.renderAlignment != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render alignment") { $0.renderAlignment = next }
            }
        )
    }

    private func particleRenderBoundsModeBinding(for entity: EntityID) -> Binding<ParticleRenderBoundsMode> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.renderBoundsMode ?? .disabled },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.renderBoundsMode != next else { return }
                updateParticleEmitter(entity, summary: "Update particle render bounds mode") {
                    $0.renderBoundsMode = next
                }
            }
        )
    }

    private func particleTextureAssetBinding(for entity: EntityID) -> Binding<EditorInspectorAssetRef?> {
        Binding(
            get: { [self] in
                guard let emitter = scene.component(ParticleEmitter.self, for: entity) else { return nil }
                if let assetID = emitter.textureAssetID,
                   let asset = EditorAssetCatalog.asset(for: assetID) {
                    return EditorInspectorAssetRef(id: asset.id,
                                                   name: asset.name,
                                                   subtitle: asset.relativePath,
                                                   kind: asset.kind.sceneKindLabel,
                                                   previewPath: asset.kind.isTexture ? asset.absolutePath : nil)
                }
                if let texturePath = emitter.texturePath, !texturePath.isEmpty {
                    let url = URL(fileURLWithPath: texturePath)
                    return EditorInspectorAssetRef(id: emitter.textureAssetID ?? texturePath,
                                                   name: url.deletingPathExtension().lastPathComponent,
                                                   subtitle: texturePath,
                                                   kind: ImportableAssetKind.png.sceneKindLabel,
                                                   previewPath: texturePath)
                }
                return nil
            },
            set: { [self] next in
                guard let current = scene.component(ParticleEmitter.self, for: entity) else { return }
                let resolved: (assetID: String?, path: String?)
                if let next {
                    if let asset = EditorAssetCatalog.asset(for: next.id),
                       asset.kind.isTexture {
                        resolved = (asset.id, asset.absolutePath)
                    } else if next.kind == ImportableAssetKind.png.sceneKindLabel {
                        let path = next.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                        resolved = (next.id, path?.isEmpty == false ? path : nil)
                    } else {
                        return
                    }
                } else {
                    resolved = (nil, nil)
                }
                guard current.textureAssetID != resolved.assetID || current.texturePath != resolved.path else { return }
                updateParticleEmitter(entity, summary: "Update particle texture") {
                    $0.textureAssetID = resolved.assetID
                    $0.texturePath = resolved.path
                }
            }
        )
    }

    private func particleGravityBinding(for entity: EntityID, axis: Int) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(ParticleEmitter.self, for: entity)?.gravity[axis] ?? 0 },
            set: { [self] next in
                guard scene.component(ParticleEmitter.self, for: entity)?.gravity[axis] != next else { return }
                updateParticleEmitter(entity, summary: "Update particle gravity") { $0.gravity[axis] = next }
            }
        )
    }

    private func particleSubEmitterColorBinding(for entity: EntityID, isStart: Bool) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.subEmitterStartColor : $0.subEmitterEndColor }
                    ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                let v = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                     max(0, min(1, next.b)), max(0, min(1, next.a)))
                let current = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.subEmitterStartColor : $0.subEmitterEndColor }
                guard current != v else { return }
                updateParticleEmitter(entity, summary: "Update sub-emitter color") {
                    if isStart { $0.subEmitterStartColor = v } else { $0.subEmitterEndColor = v }
                }
            }
        )
    }

    private func particleColorBinding(for entity: EntityID, isStart: Bool) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.startColor : $0.endColor } ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                let v = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                     max(0, min(1, next.b)), max(0, min(1, next.a)))
                let current = scene.component(ParticleEmitter.self, for: entity)
                    .map { isStart ? $0.startColor : $0.endColor }
                guard current != v else { return }
                updateParticleEmitter(entity, summary: "Update particle color") {
                    if isStart { $0.startColor = v } else { $0.endColor = v }
                }
            }
        )
    }

    private func scriptSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let component = scene.component(ScriptComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = []
        for (index, binding) in component.bindings.enumerated() {
            let ordinal = index + 1
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-enabled",
                    label: String(format: L("Script %d"), ordinal),
                    value: .bool(scriptEnabledBinding(for: entity, index: index))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-handle",
                    label: L("Handle"),
                    value: .readOnly("#\(binding.script.rawValue)")
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-parameters",
                    label: L("Parameters"),
                    value: .json(scriptParametersBinding(for: entity, index: index), minHeight: 96)
                )
            )
        }

        if fields.isEmpty {
            fields.append(
                EditorInspectorField(
                    id: "script-empty",
                    label: L("Bindings"),
                    value: .readOnly(L("No scripts"))
                )
            )
        }

        return EditorInspectorSection(id: "scripts", title: L("Scripts"), fields: fields)
    }

    private func animationPlayerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AnimationPlayer.self, for: entity) else { return nil }

        return EditorInspectorSection(
            id: "animation-player",
            title: L("Animation Player"),
            fields: [
                EditorInspectorField(
                    id: "anim-clip",
                    label: L("Clip"),
                    value: .text(animationClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-speed",
                    label: L("Speed"),
                    value: .constrainedNumber(animationSpeedBinding(for: entity),
                                              min: 0, max: 10, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "anim-loop",
                    label: L("Loop"),
                    value: .bool(animationLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-playing",
                    label: L("Playing"),
                    value: .bool(animationIsPlayingBinding(for: entity))
                ),
            ]
        )
    }

    private func animationClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity) else { return }
                let clipName: String? = next.isEmpty ? nil : next
                guard player.clipName != clipName else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_clip",
                                          summary: "Update animation clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationSpeedBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.speed ?? 1
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.speed != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_speed",
                                          summary: "Update animation speed",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: next,
                                                                          loop: player.loop,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.loop ?? true
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.loop != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_loop",
                                          summary: "Update animation loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: next,
                                                                          isPlaying: player.isPlaying)])
            }
        )
    }

    private func animationIsPlayingBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationPlayer.self, for: entity)?.isPlaying ?? false
            },
            set: { [self] next in
                guard let player = scene.component(AnimationPlayer.self, for: entity),
                      player.isPlaying != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_animation_playing",
                                          summary: "Update animation playing state",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationPlayer(entityID: entity.rawValue,
                                                                          clipName: player.clipName,
                                                                          speed: player.speed,
                                                                          loop: player.loop,
                                                                          isPlaying: next)])
            }
        )
    }

    private func animationGraphPlayerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let player = scene.component(AnimationGraphPlayer.self, for: entity) else { return nil }
        let stateCount = player.graph.stateMachine.states.count
        let blendSpaceCount = player.graph.blendSpaces1D.count
        let activeState = player.activeState ?? player.graph.stateMachine.initialState
        let previousState = player.previousState ?? L("None")

        return EditorInspectorSection(
            id: "animation-graph-player",
            title: L("Animation Graph"),
            fields: [
                EditorInspectorField(
                    id: "anim-graph-summary",
                    label: L("Graph"),
                    value: .readOnly("\(stateCount) states, \(blendSpaceCount) blend spaces")
                ),
                EditorInspectorField(
                    id: "anim-graph-active",
                    label: L("Active"),
                    value: .readOnly(activeState.isEmpty ? L("None") : activeState)
                ),
                EditorInspectorField(
                    id: "anim-graph-previous",
                    label: L("Previous"),
                    value: .readOnly(previousState)
                ),
                EditorInspectorField(
                    id: "anim-graph-speed",
                    label: L("Speed"),
                    value: .constrainedNumber(animationGraphSpeedBinding(for: entity),
                                              min: 0, max: 10, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "anim-graph-playing",
                    label: L("Playing"),
                    value: .bool(animationGraphIsPlayingBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "anim-graph-definition",
                    label: L("Definition"),
                    value: .json(animationGraphDefinitionBinding(for: entity), minHeight: 160)
                ),
                EditorInspectorField(
                    id: "anim-graph-parameters",
                    label: L("Parameters"),
                    value: .json(animationGraphParametersBinding(for: entity), minHeight: 84)
                ),
            ]
        )
    }

    private func animationGraphDefinitionBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let graph = scene.component(AnimationGraphPlayer.self, for: entity)?.graph else {
                    return "{}"
                }
                return formatAnimationGraph(graph)
            },
            set: { [self] next in
                guard let graph = parseAnimationGraph(next),
                      var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.graph != graph else { return }
                player.graph = graph
                player.activeState = graph.stateMachine.initialState.isEmpty ? nil : graph.stateMachine.initialState
                player.previousState = nil
                player.activeTime = 0
                player.previousTime = 0
                player.transitionElapsed = 0
                player.transitionDuration = 0
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_definition",
                                          summary: "Update animation graph definition",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphSpeedBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AnimationGraphPlayer.self, for: entity)?.speed ?? 1
            },
            set: { [self] next in
                guard var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.speed != next else { return }
                player.speed = next
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_speed",
                                          summary: "Update animation graph speed",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphIsPlayingBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AnimationGraphPlayer.self, for: entity)?.isPlaying ?? false
            },
            set: { [self] next in
                guard var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.isPlaying != next else { return }
                player.isPlaying = next
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_playing",
                                          summary: "Update animation graph playing state",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func animationGraphParametersBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                formatAnimationGraphParameters(scene.component(AnimationGraphPlayer.self, for: entity)?.parameters ?? [:])
            },
            set: { [self] next in
                guard let parameters = parseAnimationGraphParameters(next),
                      var player = scene.component(AnimationGraphPlayer.self, for: entity),
                      player.parameters != parameters else { return }
                player.parameters = parameters
                _ = applySceneTransaction(intentVerb: "scene.set_animation_graph_parameters",
                                          summary: "Update animation graph parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAnimationGraphPlayer(entityID: entity.rawValue,
                                                                               player: player)])
            }
        )
    }

    private func formatAnimationGraph(_ graph: AnimationGraph) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(graph),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseAnimationGraph(_ text: String) -> AnimationGraph? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnimationGraph.self, from: data)
    }

    private func formatAnimationGraphParameters(_ parameters: [String: Float]) -> String {
        let object = Dictionary(uniqueKeysWithValues: parameters.keys.sorted().map { key in
            (key, parameters[key] ?? 0)
        })
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseAnimationGraphParameters(_ text: String) -> [String: Float]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var result: [String: Float] = [:]
        for (key, value) in object {
            guard let number = value as? NSNumber else { return nil }
            result[key] = Float(truncating: number)
        }
        return result
    }

    private func audioSourceSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(AudioSource.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "audio-source",
            title: L("Audio Source"),
            fields: [
                EditorInspectorField(
                    id: "audio-clip",
                    label: L("Clip"),
                    value: .text(audioClipNameBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-volume",
                    label: L("Volume"),
                    value: .constrainedNumber(audioVolumeBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-pitch",
                    label: L("Pitch"),
                    value: .constrainedNumber(audioPitchBinding(for: entity),
                                              min: 0.1, max: 3, step: 0.1, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "audio-loop",
                    label: L("Loop"),
                    value: .bool(audioLoopBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-play-on-awake",
                    label: L("Play on Awake"),
                    value: .bool(audioPlayOnAwakeBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "audio-spatial-blend",
                    label: L("Spatial Blend"),
                    value: .constrainedNumber(audioSpatialBlendBinding(for: entity),
                                              min: 0, max: 1, step: 0.1, showsStepper: true)
                ),
            ]
        )
    }

    private func audioClipNameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.clipName ?? ""
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.clipName != next else { return }
                source.clipName = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_clip",
                                          summary: "Update audio clip",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioVolumeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.volume ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.volume != next else { return }
                source.volume = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_volume",
                                          summary: "Update audio volume",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPitchBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.pitch ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.pitch != next else { return }
                source.pitch = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_pitch",
                                          summary: "Update audio pitch",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioLoopBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.loop ?? false
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.loop != next else { return }
                source.loop = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_loop",
                                          summary: "Update audio loop",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioPlayOnAwakeBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.playOnAwake ?? true
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.playOnAwake != next else { return }
                source.playOnAwake = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_play_on_awake",
                                          summary: "Update audio play on awake",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func audioSpatialBlendBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(AudioSource.self, for: entity)?.spatialBlend ?? 1
            },
            set: { [self] next in
                guard var source = scene.component(AudioSource.self, for: entity),
                      source.spatialBlend != next else { return }
                source.spatialBlend = next
                _ = applySceneTransaction(intentVerb: "scene.set_audio_spatial_blend",
                                          summary: "Update audio spatial blend",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setAudioSource(entityID: entity.rawValue, source: source)])
            }
        )
    }

    private func renderMeshSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(RenderMeshComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "render-mesh",
            title: L("Render Mesh"),
            fields: [
                EditorInspectorField(
                    id: "mesh-visible",
                    label: L("Visible"),
                    value: .bool(renderMeshVisibilityBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mesh-color-tint",
                    label: L("Color Tint"),
                    value: .color(renderMeshColorTintBinding(for: entity))
                ),
            ]
        )
    }

    private func renderMeshVisibilityBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RenderMeshComponent.self, for: entity)?.isVisible ?? true
            },
            set: { [self] next in
                guard let mesh = scene.component(RenderMeshComponent.self, for: entity),
                      mesh.isVisible != next else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_mesh_visibility",
                                          summary: "Update mesh visibility",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMeshVisibility(entityID: entity.rawValue, isVisible: next)])
            }
        )
    }

    private func renderMeshColorTintBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let tint = scene.component(RenderMeshComponent.self, for: entity)?.colorTint ?? SIMD3<Float>(1, 1, 1)
                return Color(r: tint.x, g: tint.y, b: tint.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(RenderMeshComponent.self, for: entity)?.colorTint != nextColor else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_mesh_color",
                                          summary: "Update mesh color tint",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setMeshColorTint(entityID: entity.rawValue, color: nextColor)])
            }
        )
    }

    private func renderMaterialSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(RenderMaterialComponent.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "render-material",
            title: L("Render Material"),
            fields: [
                EditorInspectorField(
                    id: "mat-base-color",
                    label: L("Base Color"),
                    value: .color(renderMaterialBaseColorBinding(for: entity))
                ),
                EditorInspectorField(
                    id: "mat-metallic",
                    label: L("Metallic"),
                    value: .constrainedNumber(renderMaterialMetallicBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "mat-roughness",
                    label: L("Roughness"),
                    value: .constrainedNumber(renderMaterialRoughnessBinding(for: entity),
                                              min: 0, max: 1, step: 0.05, showsStepper: true)
                ),
                EditorInspectorField(
                    id: "mat-emissive",
                    label: L("Emissive"),
                    value: .color(renderMaterialEmissiveBinding(for: entity))
                ),
            ]
        )
    }

    private func renderMaterialBaseColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let c = scene.component(RenderMaterialComponent.self, for: entity)?.baseColorFactor ?? SIMD4<Float>(1, 1, 1, 1)
                return Color(r: c.x, g: c.y, b: c.z, a: c.w)
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity) else { return }
                let nextColor = SIMD4<Float>(max(0, min(1, next.r)), max(0, min(1, next.g)),
                                             max(0, min(1, next.b)), max(0, min(1, next.a)))
                guard mat.baseColorFactor != nextColor else { return }
                mat.baseColorFactor = nextColor
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material base color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
            }
        )
    }

    private func renderMaterialMetallicBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RenderMaterialComponent.self, for: entity)?.metallicFactor ?? 0
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity),
                      mat.metallicFactor != next else { return }
                mat.metallicFactor = next
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material metallic",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
            }
        )
    }

    private func renderMaterialRoughnessBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RenderMaterialComponent.self, for: entity)?.roughnessFactor ?? 1
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity),
                      mat.roughnessFactor != next else { return }
                mat.roughnessFactor = next
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material roughness",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
            }
        )
    }

    private func renderMaterialEmissiveBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let e = scene.component(RenderMaterialComponent.self, for: entity)?.emissiveFactor ?? .zero
                return Color(r: e.x, g: e.y, b: e.z, a: 1)
            },
            set: { [self] next in
                guard var mat = scene.component(RenderMaterialComponent.self, for: entity) else { return }
                let nextEmissive = SIMD3<Float>(max(0, next.r), max(0, next.g), max(0, next.b))
                guard mat.emissiveFactor != nextEmissive else { return }
                mat.emissiveFactor = nextEmissive
                _ = applySceneTransaction(intentVerb: "scene.set_render_material",
                                          summary: "Update material emissive",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRenderMaterialComponent(
                                            entityID: entity.rawValue,
                                            baseColorFactor: mat.baseColorFactor,
                                            metallicFactor: mat.metallicFactor,
                                            roughnessFactor: mat.roughnessFactor,
                                            emissiveFactor: mat.emissiveFactor)])
            }
        )
    }

    private func lightTypeBinding(for entity: EntityID) -> Binding<LightType> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.type ?? .directional
            },
            set: { [self] next in
                guard scene.component(LightComponent.self, for: entity)?.type != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_type",
                                          summary: "Update light type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightType(entityID: entity.rawValue, type: next)])
            }
        )
    }

    private func nameBinding(for entity: EntityID) -> Binding<String> {
        Binding(
            get: { [self] in
                scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
            },
            set: { [self] next in
                let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? fallbackName(for: entity) : trimmed
                guard scene.component(SceneNameComponent.self, for: entity)?.value != value else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_name",
                                          summary: "Rename entity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setSceneName(entityID: entity.rawValue, value: value)])
            }
        )
    }

    private func rigidBodyAllowSleepBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.allowSleep ?? false
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.allowSleep != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_allow_sleep",
                                          summary: "Update rigid body sleep flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyAllowSleep(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMotionBinding(for entity: EntityID) -> Binding<RigidBodyMotionType> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.motionType ?? .dynamic
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.motionType != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_motion",
                                          summary: "Update rigid body motion type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMotionType(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func rigidBodyMassBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.mass ?? 0
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(RigidBody.self, for: entity)?.mass != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_mass",
                                          summary: "Update rigid body mass",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyMass(entityID: entity.rawValue, value: clamped)])
            }
        )
    }

    private func rigidBodyGravityScaleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(RigidBody.self, for: entity)?.gravityScale ?? 0
            },
            set: { [self] next in
                guard scene.component(RigidBody.self, for: entity)?.gravityScale != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_rigidbody_gravity_scale",
                                          summary: "Update rigid body gravity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setRigidBodyGravityScale(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderTriggerBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.isTrigger ?? false
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.isTrigger != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_trigger",
                                          summary: "Update collider trigger flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderTrigger(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func colliderShapeKindBinding(for entity: EntityID) -> Binding<ColliderShapeKind> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.shape.kind ?? .box
            },
            set: { [self] next in
                guard scene.component(Collider.self, for: entity)?.shape.kind != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_shape_type",
                                          summary: "Update collider shape type",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeType(entityID: entity.rawValue, kind: next)])
            }
        )
    }

    private func colliderBoxHalfExtentsBinding(for entity: EntityID,
                                                axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .box(he, _) = collider.shape {
                    return he[keyPath: axis]
                }
                return 0.5
            },
            set: { [self] next in
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .box(he, _) = collider.shape,
                      he[keyPath: axis] != next else { return }
                var newHE = he
                newHE[keyPath: axis] = max(0.01, next)
                _ = applySceneTransaction(intentVerb: "scene.set_collider_box_extents",
                                          summary: "Update collider box extents",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeBoxHalfExtents(entityID: entity.rawValue,
                                                                                      halfExtents: newHE)])
            }
        )
    }

    private func colliderSphereRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .sphere(r, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .sphere(r, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_sphere_radius",
                                          summary: "Update collider sphere radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeSphereRadius(entityID: entity.rawValue,
                                                                                    radius: clamped)])
            }
        )
    }

    private func colliderCapsuleRadiusBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(r, _, _) = collider.shape {
                    return r
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(r, _, _) = collider.shape,
                      r != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_radius",
                                          summary: "Update collider capsule radius",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleRadius(entityID: entity.rawValue,
                                                                                     radius: clamped)])
            }
        )
    }

    private func colliderCapsuleHalfHeightBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                if let collider = scene.component(Collider.self, for: entity),
                   case let .capsule(_, hh, _) = collider.shape {
                    return hh
                }
                return 0.5
            },
            set: { [self] next in
                let clamped = max(0.01, next)
                guard let collider = scene.component(Collider.self, for: entity),
                      case let .capsule(_, hh, _) = collider.shape,
                      hh != clamped else { return }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_capsule_half_height",
                                          summary: "Update collider capsule half height",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderShapeCapsuleHalfHeight(entityID: entity.rawValue,
                                                                                         halfHeight: clamped)])
            }
        )
    }

    private func colliderFrictionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.friction ?? 0.6
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.friction != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_friction",
                                          summary: "Update collider friction",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialFriction(entityID: entity.rawValue,
                                                                                   value: clamped)])
            }
        )
    }

    private func colliderRestitutionBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.restitution ?? 0
            },
            set: { [self] next in
                let clamped = max(0, min(next, 1))
                guard scene.component(Collider.self, for: entity)?.material.restitution != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_restitution",
                                          summary: "Update collider restitution",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialRestitution(entityID: entity.rawValue,
                                                                                      value: clamped)])
            }
        )
    }

    private func colliderDensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(Collider.self, for: entity)?.material.density ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(Collider.self, for: entity)?.material.density != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_density",
                                          summary: "Update collider density",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderMaterialDensity(entityID: entity.rawValue,
                                                                                  value: clamped)])
            }
        )
    }

    private func colliderLayerBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                Float(scene.component(Collider.self, for: entity)?.layerID ?? 0)
            },
            set: { [self] next in
                let clamped = UInt16(max(0, min(next, 65535)))
                guard scene.component(Collider.self, for: entity)?.layerID != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_collider_layer",
                                          summary: "Update collider layer",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setColliderLayer(entityID: entity.rawValue,
                                                                        layerID: clamped)])
            }
        )
    }

    private func constraintEnabledBinding(for entity: EntityID) -> Binding<Bool> {
        Binding(
            get: { [self] in
                scene.component(Constraint.self, for: entity)?.isEnabled ?? false
            },
            set: { [self] next in
                guard scene.component(Constraint.self, for: entity)?.isEnabled != next else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_constraint_enabled",
                                          summary: "Update constraint enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setConstraintEnabled(entityID: entity.rawValue, value: next)])
            }
        )
    }

    private func lightColorBinding(for entity: EntityID) -> Binding<Color> {
        Binding(
            get: { [self] in
                let linear = scene.component(LightComponent.self, for: entity)?.color ?? SIMD3<Float>(1, 1, 1)
                return Color(r: linear.x, g: linear.y, b: linear.z, a: 1)
            },
            set: { [self] next in
                let nextColor = SIMD3<Float>(
                    max(0, min(1, next.r)),
                    max(0, min(1, next.g)),
                    max(0, min(1, next.b))
                )
                guard scene.component(LightComponent.self, for: entity)?.color != nextColor else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_color",
                                          summary: "Update light color",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightColor(entityID: entity.rawValue, color: nextColor)])
            }
        )
    }

    private func lightIntensityBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.intensity ?? 1
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.intensity != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_intensity",
                                          summary: "Update light intensity",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightIntensity(entityID: entity.rawValue, intensity: clamped)])
            }
        )
    }

    private func lightRangeBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.range ?? 10
            },
            set: { [self] next in
                let clamped = max(0, next)
                guard scene.component(LightComponent.self, for: entity)?.range != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_range",
                                          summary: "Update light range",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightRange(entityID: entity.rawValue, range: clamped)])
            }
        )
    }

    private func lightSpotInnerAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees ?? 20
            },
            set: { [self] next in
                let currentOuter = scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
                let clamped = max(0, min(currentOuter, next))
                guard scene.component(LightComponent.self, for: entity)?.spotInnerAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_inner_angle",
                                          summary: "Update spotlight inner angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotInnerAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func lightSpotOuterAngleBinding(for entity: EntityID) -> Binding<Float> {
        Binding(
            get: { [self] in
                scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees ?? 30
            },
            set: { [self] next in
                let clamped = max(1, min(179, next))
                guard scene.component(LightComponent.self, for: entity)?.spotOuterAngleDegrees != clamped else {
                    return
                }
                _ = applySceneTransaction(intentVerb: "scene.set_light_spot_outer_angle",
                                          summary: "Update spotlight outer angle",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLightSpotOuterAngle(entityID: entity.rawValue, angleDegrees: clamped)])
            }
        )
    }

    private func scriptEnabledBinding(for entity: EntityID, index: Int) -> Binding<Bool> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return false }
                return bindings[index].isEnabled
            },
            set: { [self] next in
                guard var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].isEnabled != next
                else { return }
                bindings[index].isEnabled = next
                _ = applySceneTransaction(intentVerb: "scene.set_script_enabled",
                                          summary: "Update script enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func scriptParametersBinding(for entity: EntityID, index: Int) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return "{}" }
                return normalizedJSONCommitText(bindings[index].parametersJSON)
            },
            set: { [self] next in
                let normalized = normalizedJSONCommitText(next)
                guard isValidJSONDocument(normalized),
                      var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].parametersJSON != normalized
                else { return }
                bindings[index].parametersJSON = normalized
                _ = applySceneTransaction(intentVerb: "scene.set_script_parameters",
                                          summary: "Update script parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func publishRevision() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    func notifyRevisionChanged() {
        onRevisionChanged?(scene.snapshot.revision)
    }

    private func displayName(for entity: EntityID) -> String {
        scene.component(SceneNameComponent.self, for: entity)?.value ?? fallbackName(for: entity)
    }

    private func displayKind(for entity: EntityID) -> String {
        if let kind = scene.component(SceneKindComponent.self, for: entity)?.value {
            return kind
        }
        if scene.hasComponent(Constraint.self, for: entity) {
            return "Constraint"
        }
        if scene.hasComponent(RigidBody.self, for: entity) || scene.hasComponent(Collider.self, for: entity) {
            return "Physics Entity"
        }
        if scene.hasComponent(ScriptComponent.self, for: entity) {
            return "Scripted Entity"
        }
        return "Entity"
    }

    private func fallbackName(for entity: EntityID) -> String {
        "Entity \(entity.index)"
    }

    private func meshColliderResourceID(for meshIndex: Int) -> String {
        "meshIndex:\(meshIndex)"
    }

    private func describe(_ shape: ColliderShape) -> String {
        switch shape {
        case let .box(halfExtents, _):
            return "Box \(format(halfExtents * 2))"
        case let .sphere(radius, _):
            return "Sphere r=\(format(radius))"
        case let .capsule(radius, halfHeight, _):
            return "Capsule r=\(format(radius)) h=\(format(halfHeight * 2))"
        case let .mesh(resourceID, _):
            return resourceID.map { "Mesh \($0)" } ?? "Mesh"
        case let .convex(resourceID, _):
            return resourceID.map { "Convex \($0)" } ?? "Convex"
        }
    }

    private func format(_ value: SIMD3<Float>) -> String {
        "\(format(value.x)), \(format(value.y)), \(format(value.z))"
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func entity(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(rawValue: rawID)
    }

    // MARK: - Transform bindings

    private func localPositionBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let t = scene.localTransform(for: entity)?.translation ?? .zero
                return t[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                var translation = local.translation
                guard translation[keyPath: axis] != next else { return }
                translation[keyPath: axis] = next
                local.matrix.columns.3 = SIMD4<Float>(translation, 1)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity translation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localScaleBinding(for entity: EntityID,
                                   axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (_, scale) = decomposeRotationScale(m)
                return scale[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (rot, _) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                var scale = decomposeRotationScale(local.matrix).1
                guard scale[keyPath: axis] != next else { return }
                scale[keyPath: axis] = next
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity scale",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    private func localRotationBinding(for entity: EntityID,
                                      axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { [self] in
                let m = scene.localTransform(for: entity)?.matrix ?? matrix_identity_float4x4
                let (rot, _) = decomposeRotationScale(m)
                let euler = eulerXYZFromMatrix(rot)
                let deg = euler * (180.0 / .pi)
                return deg[keyPath: axis]
            },
            set: { [self] next in
                var local = scene.localTransform(for: entity) ?? LocalTransform()
                let (_, scale) = decomposeRotationScale(local.matrix)
                let translation = SIMD3<Float>(local.matrix.columns.3.x,
                                               local.matrix.columns.3.y,
                                               local.matrix.columns.3.z)
                let currentDegrees = eulerXYZFromMatrix(decomposeRotationScale(local.matrix).0) * (180.0 / .pi)
                guard currentDegrees[keyPath: axis] != next else { return }
                var degrees = currentDegrees
                degrees[keyPath: axis] = next
                let radians = degrees * (.pi / 180.0)
                let rot = matrixFromEulerXYZ(radians)
                local.matrix = composeMatrix(translation: translation, rotation: rot, scale: scale)
                _ = applySceneTransaction(intentVerb: "scene.set_local_transform",
                                          summary: "Update entity rotation",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setLocalTransform(entityID: entity.rawValue, transform: local)])
            }
        )
    }

    @discardableResult
    func applySceneTransaction(intentVerb: String,
                               summary: String,
                               targetRawIDs: [UInt64] = [],
                               mutations: [SceneMutation]) -> TransactionApplyResult? {
        let intent = IntentIR(verb: intentVerb,
                              summary: summary,
                              targetObjectIDs: targetRawIDs.map { "scene:\($0)" },
                              source: .human)
        let transaction = TransactionIR(intent: intent,
                                        summary: summary,
                                        operations: mutations.map(TransactionOperation.scene),
                                        baseRevisions: TransactionBaseRevisions(sceneRevision: scene.snapshot.revision),
                                        provenance: .authored)
        var context = TransactionExecutionContext(sceneRuntime: scene)
        guard let result = try? transactionExecutor.apply(transaction, to: &context),
              let updatedScene = context.sceneRuntime
        else {
            return nil
        }
        scene = updatedScene
        notifyRevisionChanged()
        return result
    }

}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(
            index: UInt32(rawValue & 0xFFFF_FFFF),
            generation: UInt32(rawValue >> 32)
        )
    }
}

// MARK: - Transform decompose / compose

/// 把 4x4 本地矩阵分解成纯旋转 3x3 + per-axis 缩放向量。
/// 假设矩阵不含切变；如果有切变，缩放只取列长度近似。
private func decomposeRotationScale(_ m: simd_float4x4) -> (simd_float3x3, SIMD3<Float>) {
    let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    let sx = simd_length(c0)
    let sy = simd_length(c1)
    let sz = simd_length(c2)
    let r0 = sx > 1e-5 ? c0 / sx : SIMD3<Float>(1, 0, 0)
    let r1 = sy > 1e-5 ? c1 / sy : SIMD3<Float>(0, 1, 0)
    let r2 = sz > 1e-5 ? c2 / sz : SIMD3<Float>(0, 0, 1)
    return (simd_float3x3(columns: (r0, r1, r2)), SIMD3<Float>(sx, sy, sz))
}

private func composeMatrix(translation: SIMD3<Float>,
                           rotation: simd_float3x3,
                           scale: SIMD3<Float>) -> simd_float4x4 {
    let c0 = rotation.columns.0 * scale.x
    let c1 = rotation.columns.1 * scale.y
    let c2 = rotation.columns.2 * scale.z
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c0, 0)
    m.columns.1 = SIMD4<Float>(c1, 0)
    m.columns.2 = SIMD4<Float>(c2, 0)
    m.columns.3 = SIMD4<Float>(translation, 1)
    return m
}

private func normalizedJSONCommitText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "{}" : trimmed
}

private func isValidJSONDocument(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    do {
        _ = try JSONSerialization.jsonObject(with: data)
        return true
    } catch {
        return false
    }
}

/// 从 3x3 旋转矩阵提取 Euler XYZ（intrinsic 顺序：R = Rx * Ry * Rz）。
/// 这里 simd 是 column-major：m[c][r] 等价数学约定 R[r][c]。
private func eulerXYZFromMatrix(_ m: simd_float3x3) -> SIMD3<Float> {
    // R[r][c] = m.columns[c][r]
    let r02 = m.columns.2.x // R[0][2]
    let r12 = m.columns.2.y // R[1][2]
    let r22 = m.columns.2.z // R[2][2]
    let r00 = m.columns.0.x // R[0][0]
    let r01 = m.columns.1.x // R[0][1]

    let sy = max(-1, min(1, r02))
    let y = asinf(sy)
    let cy = cosf(y)
    let x: Float
    let z: Float
    if abs(cy) > 1e-4 {
        x = atan2f(-r12, r22)
        z = atan2f(-r01, r00)
    } else {
        // gimbal lock: 设 z = 0 解 x。
        x = atan2f(m.columns.0.y, m.columns.1.y) // atan2(R[1][0], R[1][1])
        z = 0
    }
    return SIMD3<Float>(x, y, z)
}

/// 从 Euler XYZ（弧度，intrinsic）合成 3x3 旋转矩阵：R = Rx * Ry * Rz。
private func matrixFromEulerXYZ(_ e: SIMD3<Float>) -> simd_float3x3 {
    let cx = cosf(e.x), sx = sinf(e.x)
    let cy = cosf(e.y), sy = sinf(e.y)
    let cz = cosf(e.z), sz = sinf(e.z)

    // R = Rx * Ry * Rz
    // 逐项展开
    let r00 = cy * cz
    let r01 = -cy * sz
    let r02 = sy
    let r10 = sx * sy * cz + cx * sz
    let r11 = -sx * sy * sz + cx * cz
    let r12 = -sx * cy
    let r20 = -cx * sy * cz + sx * sz
    let r21 = cx * sy * sz + sx * cz
    let r22 = cx * cy

    // simd column-major: columns[c][r] = R[r][c]
    return simd_float3x3(columns: (
        SIMD3<Float>(r00, r10, r20),
        SIMD3<Float>(r01, r11, r21),
        SIMD3<Float>(r02, r12, r22)
    ))
}
