import Foundation
import SIMDCompat

public enum RagdollMode: String, Sendable, Equatable {
    case animated
    case simulated
    case blended
}

/// Maps one rendered skin palette entry to a physics-body entity. `bodyFromPalette`
/// converts the palette-space bone transform to the desired rigid-body transform.
public struct RagdollBoneMapping: Sendable, Equatable {
    public var boneName: String
    public var paletteIndex: Int
    public var bodyEntity: EntityID
    public var jointEntity: EntityID?
    public var bodyFromPalette: simd_float4x4
    public var simulatedMotionType: RigidBodyMotionType
    public var isSimulationEnabled: Bool
    public var blendWeight: Float

    public init(
        boneName: String,
        paletteIndex: Int,
        bodyEntity: EntityID,
        jointEntity: EntityID? = nil,
        bodyFromPalette: simd_float4x4 = matrix_identity_float4x4,
        simulatedMotionType: RigidBodyMotionType = .dynamic,
        isSimulationEnabled: Bool = true,
        blendWeight: Float = 1
    ) {
        self.boneName = boneName
        self.paletteIndex = max(0, paletteIndex)
        self.bodyEntity = bodyEntity
        self.jointEntity = jointEntity
        self.bodyFromPalette = bodyFromPalette
        self.simulatedMotionType = simulatedMotionType
        self.isSimulationEnabled = isSimulationEnabled
        self.blendWeight = max(0, min(blendWeight, 1))
    }
}

/// Authored ragdoll mapping stored on the skinned-mesh/root entity.
public struct Ragdoll: RuntimeComponent, Sendable, Equatable {
    public var mode: RagdollMode
    public var blendWeight: Float
    public var isEnabled: Bool
    public var bones: [RagdollBoneMapping]

    public init(
        mode: RagdollMode = .animated,
        blendWeight: Float = 1,
        isEnabled: Bool = true,
        bones: [RagdollBoneMapping] = []
    ) {
        self.mode = mode
        self.blendWeight = max(0, min(blendWeight, 1))
        self.isEnabled = isEnabled
        self.bones = bones.sorted {
            if $0.paletteIndex != $1.paletteIndex { return $0.paletteIndex < $1.paletteIndex }
            return $0.bodyEntity.rawValue < $1.bodyEntity.rawValue
        }
    }
}

public struct RagdollBoneState: Sendable, Equatable {
    public var boneName: String
    public var paletteIndex: Int
    public var bodyEntity: EntityID
    public var worldTransform: WorldTransform
    public var isSimulated: Bool

    public init(boneName: String, paletteIndex: Int, bodyEntity: EntityID,
                worldTransform: WorldTransform, isSimulated: Bool) {
        self.boneName = boneName
        self.paletteIndex = paletteIndex
        self.bodyEntity = bodyEntity
        self.worldTransform = worldTransform
        self.isSimulated = isSimulated
    }
}

public struct RagdollState: Sendable, Equatable {
    public var entity: EntityID
    public var mode: RagdollMode
    public var bones: [RagdollBoneState]

    public init(entity: EntityID, mode: RagdollMode, bones: [RagdollBoneState]) {
        self.entity = entity
        self.mode = mode
        self.bones = bones
    }
}

public struct RagdollStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: RagdollState]

    public init(states: [EntityID: RagdollState] = [:]) {
        self.states = states
    }

    public static let empty = RagdollStateFrameResource()
}
