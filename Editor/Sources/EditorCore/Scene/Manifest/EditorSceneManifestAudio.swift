import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

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

public struct EditorSceneManifestAudioListener: Codable, Sendable, Equatable {
    public let masterVolume: Float

    public init(_ component: AudioListener) {
        self.masterVolume = component.masterVolume
    }

    var component: AudioListener {
        AudioListener(masterVolume: masterVolume)
    }
}
