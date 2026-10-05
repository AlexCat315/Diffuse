import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

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
    public let characterController: EditorSceneManifestCharacterController?
    public let vehicle: EditorSceneManifestVehicle?
    public let softBody: EditorSceneManifestSoftBody?
    public let cloth: EditorSceneManifestCloth?
    public let softBodyMesh: EditorSceneManifestSoftBodyMesh?
    public let destructible: EditorSceneManifestDestructible?
    public let ragdoll: EditorSceneManifestRagdoll?
    public let constraint: EditorSceneManifestConstraint?
    public let script: EditorSceneManifestScript?
    public let audioSource: EditorSceneManifestAudioSource?
    public let audioListener: EditorSceneManifestAudioListener?
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
                characterController: EditorSceneManifestCharacterController? = nil,
                vehicle: EditorSceneManifestVehicle? = nil,
                softBody: EditorSceneManifestSoftBody? = nil,
                cloth: EditorSceneManifestCloth? = nil,
                softBodyMesh: EditorSceneManifestSoftBodyMesh? = nil,
                destructible: EditorSceneManifestDestructible? = nil,
                ragdoll: EditorSceneManifestRagdoll? = nil,
                constraint: EditorSceneManifestConstraint? = nil,
                script: EditorSceneManifestScript? = nil,
                audioSource: EditorSceneManifestAudioSource? = nil,
                audioListener: EditorSceneManifestAudioListener? = nil,
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
        self.characterController = characterController
        self.vehicle = vehicle
        self.softBody = softBody
        self.cloth = cloth
        self.softBodyMesh = softBodyMesh
        self.destructible = destructible
        self.ragdoll = ragdoll
        self.constraint = constraint
        self.script = script
        self.audioSource = audioSource
        self.audioListener = audioListener
        self.animationPlayer = animationPlayer
        self.animationGraphPlayer = animationGraphPlayer
        self.particleEmitterStorage = particleEmitter.map(EditorSceneManifestParticleEmitterStorage.init)
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, localTransform, asset, renderMesh, renderMaterial
        case camera, light, rigidBody, collider, characterController, vehicle, softBody, cloth, softBodyMesh, destructible
        case ragdoll, constraint, script, audioSource, audioListener
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
        self.characterController = try c.decodeIfPresent(EditorSceneManifestCharacterController.self, forKey: .characterController)
        self.vehicle = try c.decodeIfPresent(EditorSceneManifestVehicle.self, forKey: .vehicle)
        self.softBody = try c.decodeIfPresent(EditorSceneManifestSoftBody.self, forKey: .softBody)
        self.cloth = try c.decodeIfPresent(EditorSceneManifestCloth.self, forKey: .cloth)
        self.softBodyMesh = try c.decodeIfPresent(EditorSceneManifestSoftBodyMesh.self, forKey: .softBodyMesh)
        self.destructible = try c.decodeIfPresent(EditorSceneManifestDestructible.self, forKey: .destructible)
        self.ragdoll = try c.decodeIfPresent(EditorSceneManifestRagdoll.self, forKey: .ragdoll)
        self.constraint = try c.decodeIfPresent(EditorSceneManifestConstraint.self, forKey: .constraint)
        self.script = try c.decodeIfPresent(EditorSceneManifestScript.self, forKey: .script)
        self.audioSource = try c.decodeIfPresent(EditorSceneManifestAudioSource.self, forKey: .audioSource)
        self.audioListener = try c.decodeIfPresent(EditorSceneManifestAudioListener.self, forKey: .audioListener)
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
        try c.encodeIfPresent(characterController, forKey: .characterController)
        try c.encodeIfPresent(vehicle, forKey: .vehicle)
        try c.encodeIfPresent(softBody, forKey: .softBody)
        try c.encodeIfPresent(cloth, forKey: .cloth)
        try c.encodeIfPresent(softBodyMesh, forKey: .softBodyMesh)
        try c.encodeIfPresent(destructible, forKey: .destructible)
        try c.encodeIfPresent(ragdoll, forKey: .ragdoll)
        try c.encodeIfPresent(constraint, forKey: .constraint)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encodeIfPresent(audioSource, forKey: .audioSource)
        try c.encodeIfPresent(audioListener, forKey: .audioListener)
        try c.encodeIfPresent(animationPlayer, forKey: .animationPlayer)
        try c.encodeIfPresent(animationGraphPlayer, forKey: .animationGraphPlayer)
        try c.encodeIfPresent(particleEmitterStorage, forKey: .particleEmitter)
        try c.encode(children, forKey: .children)
    }
}
