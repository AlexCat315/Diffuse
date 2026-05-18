import EngineKernel
import simd

/// Drives clip playback on an entity that has an `AssetReferenceComponent`.
public struct AnimationPlayer: RuntimeComponent, Sendable, Equatable {
    /// Name of the animation clip (matches `MeshAnimation.name`), or nil to use clip at index 0.
    public var clipName: String?
    public var speed: Float
    public var loop: Bool
    public var isPlaying: Bool
    /// Current playback time in seconds.
    public var time: Double

    public init(
        clipName: String? = nil,
        speed: Float = 1,
        loop: Bool = true,
        isPlaying: Bool = true,
        time: Double = 0
    ) {
        self.clipName = clipName
        self.speed = speed
        self.loop = loop
        self.isPlaying = isPlaying
        self.time = time
    }
}

/// Per-entity skinning matrix palette ready for the GPU vertex shader.
///
/// Index i = joint_palette[i] = nodeWorldMatrix[jointNodeIndex[i]] × inverseBindMatrix[i]
public struct JointPalette: Sendable {
    public var matrices: [simd_float4x4]

    public init(matrices: [simd_float4x4] = []) {
        self.matrices = matrices
    }

    public static var identity: JointPalette {
        JointPalette(matrices: [matrix_identity_float4x4])
    }
}

/// Scene-level resource mapping entity → JointPalette.
///
/// Written by `AnimationRuntime` each frame; read by the render backend when
/// building per-instance bind groups for skinned meshes.
public struct JointPaletteMap: Sendable {
    public var palettes: [EntityID: JointPalette]

    public init(palettes: [EntityID: JointPalette] = [:]) {
        self.palettes = palettes
    }

    public func palette(for entity: EntityID) -> JointPalette? {
        palettes[entity]
    }
}
