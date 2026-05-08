import Foundation
import IntentRuntime

// MARK: - WorldEntityRecord

/// An entity's authored state as maintained by Session's WorldView.
///
/// The record captures the properties that matter most to AI planning: name, role,
/// position, light/camera configuration, and physics motion type.
/// Each field corresponds to an authored property that can change via WorldEvent.
public struct WorldEntityRecord: Sendable, Equatable, Codable {
    public var ref: String
    public var name: String
    public var kind: String?
    public var parentRef: String?
    public var childRefs: [String]
    // Transform (authored)
    public var position: [Float]?       // [x, y, z] metres
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
    // Physics (authored)
    public var rigidBodyMotionType: String?
    // Selection state (not authored — updated by selectionChanged events)
    public var isSelected: Bool

    public init(ref: String, name: String = "", kind: String? = nil) {
        self.ref = ref
        self.name = name
        self.kind = kind
        self.childRefs = []
        self.isSelected = false
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
        case "rigidBodyMotionType":
            if case let .string(s) = value { rigidBodyMotionType = s }
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
            record.lightType = e.lightType
            record.lightIntensity = e.lightIntensity
            record.lightColor = e.lightColor
            record.lightRange = e.lightRange
            record.cameraFovYDegrees = e.cameraFovYDegrees
            record.cameraIsActive = e.cameraIsActive
            record.rigidBodyMotionType = e.rigidBodyMotionType
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
