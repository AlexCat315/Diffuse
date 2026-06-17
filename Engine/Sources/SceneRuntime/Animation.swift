import EngineKernel
import SIMDCompat

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

/// A named 1D blend space. Samples are ordered by `threshold` at evaluation time,
/// so authoring code can append points without pre-sorting.
public struct AnimationBlendSpace1D: Sendable, Equatable {
    public var name: String
    public var parameter: String
    public var samples: [AnimationBlendSample1D]

    public init(name: String,
                parameter: String,
                samples: [AnimationBlendSample1D]) {
        self.name = name
        self.parameter = parameter
        self.samples = samples
    }
}

public struct AnimationBlendSample1D: Sendable, Equatable {
    public var clipName: String?
    public var threshold: Float

    public init(clipName: String?, threshold: Float) {
        self.clipName = clipName
        self.threshold = threshold
    }
}

public enum AnimationMotion: Sendable, Equatable {
    case clip(String?)
    case blendSpace1D(String)
}

public struct AnimationState: Sendable, Equatable {
    public var name: String
    public var motion: AnimationMotion
    public var speed: Float
    public var loop: Bool

    public init(name: String,
                motion: AnimationMotion,
                speed: Float = 1,
                loop: Bool = true) {
        self.name = name
        self.motion = motion
        self.speed = speed
        self.loop = loop
    }
}

public enum AnimationTransitionComparison: String, Sendable, Equatable {
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case equal
    case notEqual
}

public struct AnimationTransition: Sendable, Equatable {
    public var from: String
    public var to: String
    public var parameter: String
    public var comparison: AnimationTransitionComparison
    public var threshold: Float
    public var duration: Double

    public init(from: String,
                to: String,
                parameter: String,
                comparison: AnimationTransitionComparison,
                threshold: Float,
                duration: Double = 0.15) {
        self.from = from
        self.to = to
        self.parameter = parameter
        self.comparison = comparison
        self.threshold = threshold
        self.duration = max(0, duration)
    }
}

public struct AnimationStateMachine: Sendable, Equatable {
    public var initialState: String
    public var states: [AnimationState]
    public var transitions: [AnimationTransition]

    public init(initialState: String,
                states: [AnimationState],
                transitions: [AnimationTransition] = []) {
        self.initialState = initialState
        self.states = states
        self.transitions = transitions
    }
}

public struct AnimationGraph: Sendable, Equatable {
    public var blendSpaces1D: [AnimationBlendSpace1D]
    public var stateMachine: AnimationStateMachine

    public init(blendSpaces1D: [AnimationBlendSpace1D] = [],
                stateMachine: AnimationStateMachine) {
        self.blendSpaces1D = blendSpaces1D
        self.stateMachine = stateMachine
    }
}

/// Runtime state for an animation graph. The graph is authored data; playback fields
/// (`activeState`, times, transition fields) are mutated by `AnimationRuntime`.
public struct AnimationGraphPlayer: RuntimeComponent, Sendable, Equatable {
    public var graph: AnimationGraph
    public var parameters: [String: Float]
    public var activeState: String?
    public var previousState: String?
    public var activeTime: Double
    public var previousTime: Double
    public var transitionElapsed: Double
    public var transitionDuration: Double
    public var speed: Float
    public var isPlaying: Bool

    public init(graph: AnimationGraph,
                parameters: [String: Float] = [:],
                activeState: String? = nil,
                previousState: String? = nil,
                activeTime: Double = 0,
                previousTime: Double = 0,
                transitionElapsed: Double = 0,
                transitionDuration: Double = 0,
                speed: Float = 1,
                isPlaying: Bool = true) {
        self.graph = graph
        self.parameters = parameters
        self.activeState = activeState
        self.previousState = previousState
        self.activeTime = activeTime
        self.previousTime = previousTime
        self.transitionElapsed = transitionElapsed
        self.transitionDuration = max(0, transitionDuration)
        self.speed = speed
        self.isPlaying = isPlaying
    }
}

/// Per-entity skinning matrix palette ready for the GPU vertex shader.
///
/// Index i = joint_palette[i] = nodeWorldMatrix[jointNodeIndex[i]] × inverseBindMatrix[i]
public struct JointPalette: Sendable, Equatable {
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
public struct JointPaletteMap: Sendable, Equatable {
    public var palettes: [EntityID: JointPalette]

    public init(palettes: [EntityID: JointPalette] = [:]) {
        self.palettes = palettes
    }

    public func palette(for entity: EntityID) -> JointPalette? {
        palettes[entity]
    }
}
