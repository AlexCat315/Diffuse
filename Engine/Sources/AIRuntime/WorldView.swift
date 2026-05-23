import Foundation
import IntentRuntime

// MARK: - WorldPropertyValue helpers

extension WorldPropertyValue {
    /// Human-readable string used when storing a WorldPropertyValue as an InferredProperty.
    var inferredDisplayValue: String {
        switch self {
        case let .string(s): return s
        case let .float(f):  return String(format: "%.4g", f)
        case let .bool(b):   return b ? "true" : "false"
        case let .vec3(x, y, z): return "(\(x), \(y), \(z))"
        }
    }
}

// MARK: - InferredProperty

/// An AI-inferred semantic annotation on an entity, tagged with confidence and optional source.
///
/// The `authored` layer can always override `inferred` — see architecture.md §World.
public struct InferredProperty: Sendable, Equatable, Codable {
    /// String representation of the inferred value (e.g. "hero_character", "dramatic", "patrol").
    public var displayValue: String
    /// Confidence score in [0, 1] from the producing pipeline or Session.
    public var confidence: Double
    /// Identifier of the pipeline or model that produced this annotation.
    public var source: String?

    public init(displayValue: String, confidence: Double, source: String? = nil) {
        self.displayValue = displayValue
        self.confidence = confidence
        self.source = source
    }
}

// MARK: - WorldEntityRecord

/// An entity's full AI-visible state as maintained by Session's WorldView.
///
/// The three layers mirror architecture.md §World:
/// - `authored` — explicit properties (typed fields below), permanent truth
/// - `evaluated` — engine-computed derived values (world-space transform, etc.)
/// - `inferred` — AI semantic annotations with confidence scores
public struct WorldEntityRecord: Sendable, Equatable, Codable {
    public var ref: String
    public var name: String
    public var kind: String?
    public var parentRef: String?
    public var childRefs: [String]
    // Transform (authored)
    public var position: [Float]?       // [x, y, z] metres
    public var scale: [Float]?          // [x, y, z]; nil when uniform 1,1,1
    // Light (authored)
    public var lightType: String?
    public var lightIntensity: Float?
    public var lightColor: [Float]?     // [r, g, b] linear 0–1
    public var lightRange: Float?
    public var lightSpotInner: Float?
    public var lightSpotOuter: Float?
    // Camera (authored)
    public var cameraFovYDegrees: Float?
    public var cameraIsActive: Bool?
    // Mesh (authored)
    public var meshColor: [Float]?           // [r, g, b] linear 0–1; nil = default white
    // Physics — rigidbody (authored)
    public var rigidBodyMotionType: String?
    public var rigidBodyMass: Float?
    public var rigidBodyGravityScale: Float?
    public var rigidBodyAllowSleep: Bool?
    // Physics — collider (authored)
    public var colliderShape: String?        // "box" | "sphere" | "capsule" | "mesh" | "convex"
    public var colliderIsTrigger: Bool?
    public var colliderFriction: Float?
    public var colliderRestitution: Float?
    public var colliderDensity: Float?
    // Audio (authored)
    public var audioClip: String?
    public var audioVolume: Float?
    public var audioLoop: Bool?
    public var audioPlayOnAwake: Bool?
    // Selection state (not authored — updated by selectionChanged events)
    public var isSelected: Bool

    // Phase 5b layers
    /// Engine-computed derived properties (e.g. "worldPosition", "worldScale").
    public var evaluated: [String: WorldPropertyValue]
    /// AI semantic annotations (e.g. "semanticRole": "hero_character").
    public var inferred: [String: InferredProperty]

    public init(ref: String, name: String = "", kind: String? = nil) {
        self.ref = ref
        self.name = name
        self.kind = kind
        self.childRefs = []
        self.isSelected = false
        self.evaluated = [:]
        self.inferred = [:]
    }

    /// Applies a single authored property change from a WorldEvent.
    public mutating func apply(property: String, value: WorldPropertyValue) {
        switch property {
        case "name":
            if case let .string(s) = value { name = s }
        case "kind":
            if case let .string(s) = value { kind = s }
        case "position":
            if case let .vec3(x, y, z) = value { position = [x, y, z] }
        case "scale":
            if case let .vec3(x, y, z) = value { scale = [x, y, z] }
        case "parentRef":
            if case let .string(s) = value { parentRef = s.isEmpty ? nil : s }
        case "lightType":
            if case let .string(s) = value { lightType = s }
        case "lightIntensity":
            if case let .float(f) = value { lightIntensity = f }
        case "lightColor":
            if case let .vec3(r, g, b) = value { lightColor = [r, g, b] }
        case "lightRange":
            if case let .float(f) = value { lightRange = f }
        case "lightSpotInner":
            if case let .float(f) = value { lightSpotInner = f }
        case "lightSpotOuter":
            if case let .float(f) = value { lightSpotOuter = f }
        case "cameraFovYDegrees":
            if case let .float(f) = value { cameraFovYDegrees = f }
        case "cameraIsActive":
            if case let .bool(b) = value { cameraIsActive = b }
        case "meshColor":
            if case let .vec3(r, g, b) = value { meshColor = [r, g, b] }
        case "rigidBodyMotionType":
            if case let .string(s) = value { rigidBodyMotionType = s }
        case "rigidBodyMass":
            if case let .float(f) = value { rigidBodyMass = f }
        case "rigidBodyGravityScale":
            if case let .float(f) = value { rigidBodyGravityScale = f }
        case "rigidBodyAllowSleep":
            if case let .bool(b) = value { rigidBodyAllowSleep = b }
        case "colliderShape":
            if case let .string(s) = value { colliderShape = s }
        case "colliderIsTrigger":
            if case let .bool(b) = value { colliderIsTrigger = b }
        case "colliderFriction":
            if case let .float(f) = value { colliderFriction = f }
        case "colliderRestitution":
            if case let .float(f) = value { colliderRestitution = f }
        case "colliderDensity":
            if case let .float(f) = value { colliderDensity = f }
        case "audioClip":
            if case let .string(s) = value { audioClip = s }
        case "audioVolume":
            if case let .float(f) = value { audioVolume = f }
        case "audioLoop":
            if case let .bool(b) = value { audioLoop = b }
        case "audioPlayOnAwake":
            if case let .bool(b) = value { audioPlayOnAwake = b }
        default:
            break
        }
    }
}

// MARK: - WorldViewEdit

/// A brief record of one applied Edit, kept in the recent-edit ring.
public struct WorldViewEdit: Sendable {
    public var summary: String
    public var revision: UInt64
    public var timestamp: Date

    public init(summary: String, revision: UInt64, timestamp: Date = Date()) {
        self.summary = summary
        self.revision = revision
        self.timestamp = timestamp
    }
}

// MARK: - WorldView

/// Session's incrementally-maintained understanding of the World.
///
/// Phase 5: delta-driven — WorldEvents update the entity index in O(1) per event.
/// apply(snapshot:) serves as the bootstrap path that seeds the index from a full scan.
public struct WorldView: Sendable {
    /// Per-entity authored state, keyed by entity ref ("scene:<id>").
    public private(set) var entityIndex: [String: WorldEntityRecord]
    public var sceneRevision: UInt64?
    public var selectedEntityRefs: [String]
    public var recentEdits: [WorldViewEdit]
    public var workflowMode: String?

    private static let maxRecentEdits = 20

    public init() {
        entityIndex = [:]
        selectedEntityRefs = []
        recentEdits = []
    }

    // MARK: - Delta-driven update (Phase 5)

    /// Applies a fine-grained WorldEvent to the entity index.
    public mutating func apply(event: WorldEvent) {
        switch event {
        case let .entityAdded(ref, name, kind):
            var record = WorldEntityRecord(ref: ref, name: name, kind: kind)
            record.isSelected = selectedEntityRefs.contains(ref)
            entityIndex[ref] = record

        case let .entityRemoved(ref):
            entityIndex.removeValue(forKey: ref)
            selectedEntityRefs.removeAll { $0 == ref }

        case let .entityAuthoredChanged(ref, property, value):
            entityIndex[ref, default: WorldEntityRecord(ref: ref)]
                .apply(property: property, value: value)

        case let .editApplied(_, summary, revision):
            recentEdits.append(WorldViewEdit(summary: summary, revision: revision))
            if recentEdits.count > Self.maxRecentEdits {
                recentEdits.removeFirst(recentEdits.count - Self.maxRecentEdits)
            }
            sceneRevision = revision

        case let .selectionChanged(refs):
            selectedEntityRefs = refs
            for key in entityIndex.keys {
                entityIndex[key]?.isSelected = refs.contains(key)
            }

        case let .entityEvaluatedChanged(ref, property, value):
            entityIndex[ref, default: WorldEntityRecord(ref: ref)].evaluated[property] = value

        case let .entityInferredUpdated(ref, property, value, confidence, source):
            var record = entityIndex[ref, default: WorldEntityRecord(ref: ref)]
            // Only update inferred if it doesn't shadow an authored property.
            let inferred = InferredProperty(
                displayValue: value.inferredDisplayValue,
                confidence: confidence,
                source: source)
            record.inferred[property] = inferred
            entityIndex[ref] = record
        }
    }

    // MARK: - Bootstrap (from full snapshot)

    /// Seeds the entity index from a SceneSemanticSnapshot. Used once at session
    /// creation or when a new project is opened — ongoing updates use apply(event:).
    public mutating func apply(snapshot: SceneSemanticSnapshot) {
        entityIndex.removeAll(keepingCapacity: true)
        for e in snapshot.entities {
            var record = WorldEntityRecord(ref: e.id, name: e.name, kind: e.kind)
            record.parentRef = e.parentRef
            record.childRefs = e.childRefs
            record.isSelected = e.isSelected
            if let pos = e.position { record.position = pos }
            if let s = e.scale { record.scale = s }
            record.lightType = e.lightType
            record.lightIntensity = e.lightIntensity
            record.lightColor = e.lightColor
            record.lightRange = e.lightRange
            record.lightSpotInner = e.lightSpotInner
            record.lightSpotOuter = e.lightSpotOuter
            record.cameraFovYDegrees = e.cameraFovYDegrees
            record.cameraIsActive = e.cameraIsActive
            record.meshColor = e.meshColor
            record.rigidBodyMotionType = e.rigidBodyMotionType
            record.rigidBodyMass = e.rigidBodyMass
            record.rigidBodyGravityScale = e.rigidBodyGravityScale
            record.rigidBodyAllowSleep = e.rigidBodyAllowSleep
            record.colliderShape = e.colliderShape
            record.colliderIsTrigger = e.colliderIsTrigger
            record.colliderFriction = e.colliderFriction
            record.colliderRestitution = e.colliderRestitution
            record.colliderDensity = e.colliderDensity
            record.audioClip = e.audioClip
            record.audioVolume = e.audioVolume
            record.audioLoop = e.audioLoop
            record.audioPlayOnAwake = e.audioPlayOnAwake
            if let wp = e.worldPosition {
                record.evaluated["worldPosition"] = .vec3(wp[0], wp[1], wp[2])
            }
            entityIndex[e.id] = record
        }
        sceneRevision = snapshot.sceneRevision
        workflowMode = snapshot.workspaceMode
        selectedEntityRefs = snapshot.entities.filter(\.isSelected).map(\.id)
    }

    // MARK: - Convenience wrappers (for callers that don't use WorldEvents)

    /// Records an applied edit to the recent-edit ring without a full WorldEvent.
    public mutating func apply(editSummary: String, revision: UInt64) {
        apply(event: .editApplied(editID: "", summary: editSummary, revision: revision))
    }

    /// Updates the active selection without a WorldEvent.
    public mutating func apply(selectionChanged entityRefs: [String]) {
        apply(event: .selectionChanged(refs: entityRefs))
    }
}
