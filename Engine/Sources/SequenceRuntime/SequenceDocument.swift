import Foundation

public struct SMPTETimecode: Sendable, Equatable, Codable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int = 1, minutes: Int = 0, seconds: Int = 0, frames: Int = 0) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    public var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}

public struct TimeBase: Sendable, Equatable, Codable {
    public var fps: Int
    public var dropFrame: Bool
    public var startTimecode: SMPTETimecode

    public init(fps: Int = 24,
                dropFrame: Bool = false,
                startTimecode: SMPTETimecode = SMPTETimecode()) {
        self.fps = max(1, fps)
        self.dropFrame = dropFrame
        self.startTimecode = startTimecode
    }

    public func seconds(for frame: Int64) -> Double {
        Double(frame) / Double(fps)
    }

    public func timecode(for frame: Int64) -> SMPTETimecode {
        let safeFrame = max(Int(frame), 0)
        let fps = max(self.fps, 1)
        let totalFrames = startTimecode.frames + safeFrame
        let frames = totalFrames % fps
        let totalSeconds = startTimecode.seconds + (totalFrames / fps)
        let seconds = totalSeconds % 60
        let totalMinutes = startTimecode.minutes + (totalSeconds / 60)
        let minutes = totalMinutes % 60
        let hours = startTimecode.hours + (totalMinutes / 60)
        return SMPTETimecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames)
    }
}

public struct FrameRange: Sendable, Equatable, Codable {
    public var start: Int64
    public var end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var duration: Int64 {
        max(0, end - start)
    }

    public func contains(_ frame: Int64) -> Bool {
        frame >= start && frame < end
    }

    public func contains(_ other: FrameRange) -> Bool {
        other.start >= start && other.end <= end
    }

    public func intersects(_ other: FrameRange) -> Bool {
        start < other.end && other.start < end
    }
}

public enum SequenceValue: Sendable, Equatable, Codable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case array([SequenceValue])
    case object([String: SequenceValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode([String: SequenceValue].self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([SequenceValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "unsupported SequenceValue payload")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum SequenceEvaluationPolicy: String, Sendable, Equatable, Codable {
    case lazy
    case eager
    case hybrid
}

public enum SequenceProvenance: String, Sendable, Equatable, Codable {
    case authored
    case inferred
    case proposal
    case baked
}

public struct SequenceRevision: Sendable, Equatable, Codable {
    public var id: String
    public var parentID: String?
    public var author: String
    public var createdAt: Date
    public var baseSceneRevisionID: String?
    public var baseSequenceRevisionID: String?
    public var transactionIDs: [String]

    public init(id: String = UUID().uuidString,
                parentID: String? = nil,
                author: String = "system",
                createdAt: Date = Date(),
                baseSceneRevisionID: String? = nil,
                baseSequenceRevisionID: String? = nil,
                transactionIDs: [String] = []) {
        self.id = id
        self.parentID = parentID
        self.author = author
        self.createdAt = createdAt
        self.baseSceneRevisionID = baseSceneRevisionID
        self.baseSequenceRevisionID = baseSequenceRevisionID
        self.transactionIDs = transactionIDs
    }
}

public struct SceneTargetReference: Sendable, Equatable, Codable {
    public var docURI: String
    public var targetID: String
    public var subPath: String?

    public init(docURI: String, targetID: String, subPath: String? = nil) {
        self.docURI = docURI
        self.targetID = targetID
        self.subPath = subPath
    }
}

public enum BindingFallbackStrategy: String, Sendable, Equatable, Codable {
    case skip
    case proxy
    case error
}

public enum BindingResolutionStatus: String, Sendable, Equatable, Codable {
    case bound
    case unbound
    case conflict
    case stale
}

public struct Binding: Sendable, Equatable, Codable {
    public var id: String
    public var abstractRole: String
    public var resolvedTarget: SceneTargetReference?
    public var requiredCapabilities: [String]
    public var fallbackStrategy: BindingFallbackStrategy
    public var resolutionStatus: BindingResolutionStatus
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString,
                abstractRole: String,
                resolvedTarget: SceneTargetReference? = nil,
                requiredCapabilities: [String] = [],
                fallbackStrategy: BindingFallbackStrategy = .skip,
                resolutionStatus: BindingResolutionStatus = .unbound,
                resolvedAt: Date? = nil) {
        self.id = id
        self.abstractRole = abstractRole
        self.resolvedTarget = resolvedTarget
        self.requiredCapabilities = requiredCapabilities
        self.fallbackStrategy = fallbackStrategy
        self.resolutionStatus = resolutionStatus
        self.resolvedAt = resolvedAt
    }
}

public enum OverrideTargetKind: String, Sendable, Equatable, Codable {
    case sceneInstance = "scene_instance"
    case componentField = "component_field"
    case materialParam = "material_param"
    case lightParam = "light_param"
    case cameraParam = "camera_param"
}

public enum OverrideValueKind: String, Sendable, Equatable, Codable {
    case absolute
    case additive
    case multiplicative
}

public enum ClipEase: String, Sendable, Equatable, Codable {
    case linear
    case easeIn = "ease_in"
    case easeOut = "ease_out"
    case easeInOut = "ease_in_out"
    case step
}

public struct ShotOverride: Sendable, Equatable, Codable {
    public var id: String
    public var targetKind: OverrideTargetKind
    public var targetRef: SceneTargetReference
    public var valueKind: OverrideValueKind
    public var value: SequenceValue
    public var blendInFrames: Int64
    public var blendOutFrames: Int64
    public var ease: ClipEase
    public var source: SequenceProvenance
    public var proposalID: String?

    public init(id: String = UUID().uuidString,
                targetKind: OverrideTargetKind,
                targetRef: SceneTargetReference,
                valueKind: OverrideValueKind = .absolute,
                value: SequenceValue,
                blendInFrames: Int64 = 0,
                blendOutFrames: Int64 = 0,
                ease: ClipEase = .linear,
                source: SequenceProvenance = .authored,
                proposalID: String? = nil) {
        self.id = id
        self.targetKind = targetKind
        self.targetRef = targetRef
        self.valueKind = valueKind
        self.value = value
        self.blendInFrames = blendInFrames
        self.blendOutFrames = blendOutFrames
        self.ease = ease
        self.source = source
        self.proposalID = proposalID
    }
}

public enum MarkerKind: String, Sendable, Equatable, Codable {
    case chapter
    case note
    case syncPoint = "sync_point"
    case renderSplit = "render_split"
}

public struct Marker: Sendable, Equatable, Codable {
    public var id: String
    public var frame: Int64
    public var kind: MarkerKind
    public var label: String
    public var colorToken: String

    public init(id: String = UUID().uuidString,
                frame: Int64,
                kind: MarkerKind,
                label: String,
                colorToken: String = "") {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.label = label
        self.colorToken = colorToken
    }
}

public enum CutTransition: String, Sendable, Equatable, Codable {
    case hard
    case dissolve
    case fadeIn = "fade_in"
    case fadeOut = "fade_out"
    case wipe
}

public struct Cut: Sendable, Equatable, Codable {
    public var id: String
    public var frame: Int64
    public var transition: CutTransition
    public var duration: Int64
    public var params: [String: SequenceValue]

    public init(id: String = UUID().uuidString,
                frame: Int64,
                transition: CutTransition,
                duration: Int64 = 0,
                params: [String: SequenceValue] = [:]) {
        self.id = id
        self.frame = frame
        self.transition = transition
        self.duration = duration
        self.params = params
    }
}

public enum ShotStatus: String, Sendable, Equatable, Codable {
    case planning
    case blocking
    case lighting
    case rendering
    case final
    case locked
}

public enum TrackKind: String, Sendable, Equatable, Codable {
    case animation
    case camera
    case audio
    case event
    case subscene
    case fx
    case lighting
    case postProcess = "post_process"
    case data
}

public struct ClipPayload: Sendable, Equatable, Codable {
    public var metadata: [String: SequenceValue]

    public init(metadata: [String: SequenceValue] = [:]) {
        self.metadata = metadata
    }

    public subscript(key: String) -> SequenceValue? {
        metadata[key]
    }
}

public struct Clip: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var shotRange: FrameRange
    public var sourceOffset: Int64
    public var timeWarp: Double
    public var enabled: Bool
    public var blendInFrames: Int64
    public var blendOutFrames: Int64
    public var ease: ClipEase
    public var weight: Double
    public var bindings: [Binding]
    public var payload: ClipPayload
    public var provenance: SequenceProvenance

    public init(id: String = UUID().uuidString,
                name: String,
                shotRange: FrameRange,
                sourceOffset: Int64 = 0,
                timeWarp: Double = 1,
                enabled: Bool = true,
                blendInFrames: Int64 = 0,
                blendOutFrames: Int64 = 0,
                ease: ClipEase = .linear,
                weight: Double = 1,
                bindings: [Binding] = [],
                payload: ClipPayload = ClipPayload(),
                provenance: SequenceProvenance = .authored) {
        self.id = id
        self.name = name
        self.shotRange = shotRange
        self.sourceOffset = sourceOffset
        self.timeWarp = timeWarp
        self.enabled = enabled
        self.blendInFrames = blendInFrames
        self.blendOutFrames = blendOutFrames
        self.ease = ease
        self.weight = weight
        self.bindings = bindings
        self.payload = payload
        self.provenance = provenance
    }
}

public struct Track: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var kind: TrackKind
    public var mute: Bool
    public var solo: Bool = false
    public var lock: Bool = false
    public var colorToken: String
    public var clips: [Clip]
    public var group: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case mute
        case colorToken = "color_token"
        case clips
        case group
    }

    public init(id: String = UUID().uuidString,
                name: String,
                kind: TrackKind,
                mute: Bool = false,
                solo: Bool = false,
                lock: Bool = false,
                colorToken: String = "",
                clips: [Clip] = [],
                group: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.mute = mute
        self.solo = solo
        self.lock = lock
        self.colorToken = colorToken
        self.clips = clips
        self.group = group
    }
}

public struct Shot: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var range: FrameRange
    public var sourceOffset: Int64
    public var cameraBinding: Binding
    public var defaultSceneView: SceneTargetReference?
    public var overrides: [ShotOverride]
    public var tracks: [Track]
    public var notes: String?
    public var status: ShotStatus
    public var provenance: SequenceProvenance
    public var revision: SequenceRevision

    public init(id: String = UUID().uuidString,
                name: String,
                range: FrameRange,
                sourceOffset: Int64 = 0,
                cameraBinding: Binding,
                defaultSceneView: SceneTargetReference? = nil,
                overrides: [ShotOverride] = [],
                tracks: [Track] = [],
                notes: String? = nil,
                status: ShotStatus = .planning,
                provenance: SequenceProvenance = .authored,
                revision: SequenceRevision = SequenceRevision()) {
        self.id = id
        self.name = name
        self.range = range
        self.sourceOffset = sourceOffset
        self.cameraBinding = cameraBinding
        self.defaultSceneView = defaultSceneView
        self.overrides = overrides
        self.tracks = tracks
        self.notes = notes
        self.status = status
        self.provenance = provenance
        self.revision = revision
    }
}

public struct SequenceResolution: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int = 1920, height: Int = 1080) {
        self.width = width
        self.height = height
    }

    public static let hd1080 = SequenceResolution()
}

public struct AspectRatio: Sendable, Equatable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int = 16, height: Int = 9) {
        self.width = width
        self.height = height
    }

    public static let widescreen = AspectRatio()
}

public struct MotionBlurSettings: Sendable, Equatable, Codable {
    public var shutterAngleDegrees: Float
    public var samples: Int

    public init(shutterAngleDegrees: Float = 180, samples: Int = 1) {
        self.shutterAngleDegrees = shutterAngleDegrees
        self.samples = samples
    }
}

public enum SequenceCacheKind: String, Sendable, Equatable, Codable {
    case physics
    case cloth
    case fluid
    case hair
    case gi
    case particle
    case renderProxy = "render_proxy"
}

public enum SequenceCacheInvalidationPolicy: String, Sendable, Equatable, Codable {
    case strict
    case tolerant
}

public enum SequenceCacheHitStrategy: String, Sendable, Equatable, Codable {
    case exact
    case nearestFrame = "nearest_frame"
    case interpolate
}

public struct SequenceCache: Sendable, Equatable, Codable {
    public var id: String
    public var kind: SequenceCacheKind
    public var shotID: String
    public var clipID: String?
    public var range: FrameRange
    public var storageURI: String
    public var sourceRevision: SequenceRevision
    public var invalidationPolicy: SequenceCacheInvalidationPolicy
    public var hitStrategy: SequenceCacheHitStrategy

    public init(id: String = UUID().uuidString,
                kind: SequenceCacheKind,
                shotID: String,
                clipID: String? = nil,
                range: FrameRange,
                storageURI: String,
                sourceRevision: SequenceRevision,
                invalidationPolicy: SequenceCacheInvalidationPolicy = .strict,
                hitStrategy: SequenceCacheHitStrategy = .exact) {
        self.id = id
        self.kind = kind
        self.shotID = shotID
        self.clipID = clipID
        self.range = range
        self.storageURI = storageURI
        self.sourceRevision = sourceRevision
        self.invalidationPolicy = invalidationPolicy
        self.hitStrategy = hitStrategy
    }
}

public struct SequenceDocument: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var sceneDocumentURI: String
    public var timeBase: TimeBase
    public var frameRange: FrameRange
    public var resolution: SequenceResolution
    public var aspectRatio: AspectRatio
    public var colorSpace: String
    public var motionBlur: MotionBlurSettings
    public var shots: [Shot]
    public var markers: [Marker]
    public var cuts: [Cut]
    public var caches: [SequenceCache]
    public var evaluationPolicy: SequenceEvaluationPolicy
    public var provenance: SequenceProvenance
    public var revision: SequenceRevision

    public init(id: String = UUID().uuidString,
                name: String,
                sceneDocumentURI: String,
                timeBase: TimeBase = TimeBase(),
                frameRange: FrameRange,
                resolution: SequenceResolution = .hd1080,
                aspectRatio: AspectRatio = .widescreen,
                colorSpace: String = "linear_srgb",
                motionBlur: MotionBlurSettings = MotionBlurSettings(),
                shots: [Shot] = [],
                markers: [Marker] = [],
                cuts: [Cut] = [],
                caches: [SequenceCache] = [],
                evaluationPolicy: SequenceEvaluationPolicy = .hybrid,
                provenance: SequenceProvenance = .authored,
                revision: SequenceRevision = SequenceRevision()) {
        self.id = id
        self.name = name
        self.sceneDocumentURI = sceneDocumentURI
        self.timeBase = timeBase
        self.frameRange = frameRange
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.colorSpace = colorSpace
        self.motionBlur = motionBlur
        self.shots = shots
        self.markers = markers
        self.cuts = cuts
        self.caches = caches
        self.evaluationPolicy = evaluationPolicy
        self.provenance = provenance
        self.revision = revision
    }

    public func shot(containing sequenceFrame: Int64) -> Shot? {
        shots.sorted {
            if $0.range.start == $1.range.start {
                return $0.id < $1.id
            }
            return $0.range.start < $1.range.start
        }.first { $0.range.contains(sequenceFrame) }
    }

    public func markers(at sequenceFrame: Int64) -> [Marker] {
        markers.filter { $0.frame == sequenceFrame }
    }
}