import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

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
