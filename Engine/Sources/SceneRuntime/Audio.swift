import EngineKernel
import SIMDCompat

/// Component that drives audio playback on an entity.
public struct AudioSource: RuntimeComponent, Sendable, Equatable {
    /// Name of the audio clip asset (filename without extension, e.g. "footstep").
    public var clipName: String
    public var volume: Float
    public var pitch: Float
    public var loop: Bool
    /// Start playing automatically when the scene enters play mode.
    public var playOnAwake: Bool
    /// Spatial blend: 0 = fully 2D, 1 = fully 3D positional audio.
    public var spatialBlend: Float

    public init(
        clipName: String = "",
        volume: Float = 1,
        pitch: Float = 1,
        loop: Bool = false,
        playOnAwake: Bool = true,
        spatialBlend: Float = 1
    ) {
        self.clipName = clipName
        self.volume = volume
        self.pitch = pitch
        self.loop = loop
        self.playOnAwake = playOnAwake
        self.spatialBlend = spatialBlend
    }
}

/// Marks an entity as the audio listener for spatial audio.
/// Typically placed on the main camera entity. The audio system uses the
/// listener's world position for distance-based attenuation.
///
/// If no entity has this component, the listener defaults to world origin.
public struct AudioListener: RuntimeComponent, Sendable, Equatable {
    /// Optional per-listener volume multiplier (0…1).
    public var masterVolume: Float

    public init(masterVolume: Float = 1) {
        self.masterVolume = simd_clamp(masterVolume, 0, 1)
    }
}
