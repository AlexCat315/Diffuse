import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestRagdollBone: Codable, Sendable, Equatable {
    public let boneName: String
    public let paletteIndex: Int
    public let bodyEntity: UInt64
    public let jointEntity: UInt64?
    public let bodyFromPalette: EditorSceneManifestMatrix
    public let simulatedMotionType: String
    public let isSimulationEnabled: Bool
    public let blendWeight: Float

    public init(_ bone: RagdollBoneMapping) {
        boneName = bone.boneName
        paletteIndex = bone.paletteIndex
        bodyEntity = bone.bodyEntity.rawValue
        jointEntity = bone.jointEntity?.rawValue
        bodyFromPalette = EditorSceneManifestMatrix(bone.bodyFromPalette)
        simulatedMotionType = bone.simulatedMotionType.rawValue
        isSimulationEnabled = bone.isSimulationEnabled
        blendWeight = bone.blendWeight
    }

    func component(idMap: [UInt64: EntityID]) -> RagdollBoneMapping? {
        guard let body = idMap[bodyEntity] else { return nil }
        return RagdollBoneMapping(
            boneName: boneName,
            paletteIndex: paletteIndex,
            bodyEntity: body,
            jointEntity: jointEntity.flatMap { idMap[$0] },
            bodyFromPalette: bodyFromPalette.simdValue ?? matrix_identity_float4x4,
            simulatedMotionType: RigidBodyMotionType(rawValue: simulatedMotionType) ?? .dynamic,
            isSimulationEnabled: isSimulationEnabled,
            blendWeight: blendWeight
        )
    }
}

public struct EditorSceneManifestRagdoll: Codable, Sendable, Equatable {
    public let mode: String
    public let blendWeight: Float
    public let isEnabled: Bool
    public let bones: [EditorSceneManifestRagdollBone]

    public init(_ component: Ragdoll) {
        mode = component.mode.rawValue
        blendWeight = component.blendWeight
        isEnabled = component.isEnabled
        bones = component.bones.map(EditorSceneManifestRagdollBone.init)
    }

    func component(idMap: [UInt64: EntityID]) -> Ragdoll {
        Ragdoll(
            mode: RagdollMode(rawValue: mode) ?? .animated,
            blendWeight: blendWeight,
            isEnabled: isEnabled,
            bones: bones.compactMap { $0.component(idMap: idMap) }
        )
    }
}
