import Foundation

// MARK: - StructureExtractor output

public struct RawStructure: Sendable {
    public struct Node: Sendable {
        public var id: String
        public var name: String
        public var parentID: String?
        public var localTransform: [Float]  // column-major 4x4

        public init(id: String, name: String, parentID: String? = nil, localTransform: [Float] = []) {
            self.id = id; self.name = name; self.parentID = parentID; self.localTransform = localTransform
        }
    }

    public struct MeshRecord: Sendable {
        public var id: String
        public var nodeID: String
        public var vertexCount: Int
        public var faceCount: Int

        public init(id: String, nodeID: String, vertexCount: Int, faceCount: Int) {
            self.id = id; self.nodeID = nodeID; self.vertexCount = vertexCount; self.faceCount = faceCount
        }
    }

    public struct SubmeshRecord: Sendable {
        public var id: String
        public var meshID: String
        public var materialSlot: Int
        public var indexStart: Int
        public var indexCount: Int

        public init(id: String, meshID: String, materialSlot: Int, indexStart: Int, indexCount: Int) {
            self.id = id; self.meshID = meshID; self.materialSlot = materialSlot
            self.indexStart = indexStart; self.indexCount = indexCount
        }
    }

    public struct MaterialSlot: Sendable {
        public var id: String
        public var name: String
        public var sourceIndex: Int

        public init(id: String, name: String, sourceIndex: Int) {
            self.id = id; self.name = name; self.sourceIndex = sourceIndex
        }
    }

    public struct Bone: Sendable {
        public var id: String
        public var name: String
        public var parentID: String?

        public init(id: String, name: String, parentID: String? = nil) {
            self.id = id; self.name = name; self.parentID = parentID
        }
    }

    public struct Skeleton: Sendable {
        public var bones: [Bone]
        public init(bones: [Bone]) { self.bones = bones }
    }

    public struct MorphTarget: Sendable {
        public var id: String
        public var name: String
        public var meshID: String

        public init(id: String, name: String, meshID: String) {
            self.id = id; self.name = name; self.meshID = meshID
        }
    }

    public struct UVSet: Sendable {
        public var meshID: String
        public var channel: Int
        public var islandCount: Int

        public init(meshID: String, channel: Int, islandCount: Int) {
            self.meshID = meshID; self.channel = channel; self.islandCount = islandCount
        }
    }

    public var assetURI: String
    public var nodes: [Node]
    public var meshes: [MeshRecord]
    public var submeshes: [SubmeshRecord]
    public var materialSlots: [MaterialSlot]
    public var skeleton: Skeleton?
    public var morphTargets: [MorphTarget]
    public var uvSets: [UVSet]
    public var customProperties: [String: String]

    public init(assetURI: String,
                nodes: [Node] = [],
                meshes: [MeshRecord] = [],
                submeshes: [SubmeshRecord] = [],
                materialSlots: [MaterialSlot] = [],
                skeleton: Skeleton? = nil,
                morphTargets: [MorphTarget] = [],
                uvSets: [UVSet] = [],
                customProperties: [String: String] = [:]) {
        self.assetURI = assetURI
        self.nodes = nodes; self.meshes = meshes; self.submeshes = submeshes
        self.materialSlots = materialSlots; self.skeleton = skeleton
        self.morphTargets = morphTargets; self.uvSets = uvSets
        self.customProperties = customProperties
    }
}

// MARK: - GeometryAnalyzer output

public struct GeometrySignals: Sendable {
    public struct AABB: Sendable {
        public var min: (x: Float, y: Float, z: Float)
        public var max: (x: Float, y: Float, z: Float)

        public init(min: (Float, Float, Float), max: (Float, Float, Float)) {
            self.min = min; self.max = max
        }
    }

    public struct SymmetryAxis: Sendable {
        public var axis: (x: Float, y: Float, z: Float)
        public var confidence: Float

        public init(axis: (Float, Float, Float), confidence: Float) {
            self.axis = axis; self.confidence = confidence
        }
    }

    public struct ConnectedComponent: Sendable {
        public var id: String
        public var meshID: String
        public var faceCount: Int
        public var bounds: AABB

        public init(id: String, meshID: String, faceCount: Int, bounds: AABB) {
            self.id = id; self.meshID = meshID; self.faceCount = faceCount; self.bounds = bounds
        }
    }

    public struct Protrusion: Sendable {
        public var id: String
        public var length: Float
        public var baseRadius: Float

        public init(id: String, length: Float, baseRadius: Float) {
            self.id = id; self.length = length; self.baseRadius = baseRadius
        }
    }

    public struct SupportPlane: Sendable {
        public var id: String
        public var normal: (x: Float, y: Float, z: Float)
        public var area: Float

        public init(id: String, normal: (Float, Float, Float), area: Float) {
            self.id = id; self.normal = normal; self.area = area
        }
    }

    public var assetURI: String
    public var connectedComponents: [ConnectedComponent]
    public var symmetryAxes: [SymmetryAxis]
    public var protrusions: [Protrusion]
    public var supportPlanes: [SupportPlane]
    public var surfaceArea: Float
    public var volumeEstimate: Float

    public init(assetURI: String,
                connectedComponents: [ConnectedComponent] = [],
                symmetryAxes: [SymmetryAxis] = [],
                protrusions: [Protrusion] = [],
                supportPlanes: [SupportPlane] = [],
                surfaceArea: Float = 0,
                volumeEstimate: Float = 0) {
        self.assetURI = assetURI
        self.connectedComponents = connectedComponents; self.symmetryAxes = symmetryAxes
        self.protrusions = protrusions; self.supportPlanes = supportPlanes
        self.surfaceArea = surfaceArea; self.volumeEstimate = volumeEstimate
    }
}

// MARK: - Geometry fingerprint (lookup key for SemanticMemoryStore)

public struct GeometryFingerprint: Sendable {
    /// Rotation/translation/uniform-scale-invariant shape descriptor (not sent to LLM).
    public var shapeDescriptor: [Float]
    /// Laplacian spectral hash — only consumed by KNN lookup, never by LLM.
    public var spectralHash: Data
    public var genus: Int
    public var boundaryLoops: Int
    public var faceCountBucket: Int
    public var scaleHint: Float
    public var version: Int

    public init(shapeDescriptor: [Float] = [],
                spectralHash: Data = Data(),
                genus: Int = 0,
                boundaryLoops: Int = 0,
                faceCountBucket: Int = 0,
                scaleHint: Float = 1.0,
                version: Int = 1) {
        self.shapeDescriptor = shapeDescriptor; self.spectralHash = spectralHash
        self.genus = genus; self.boundaryLoops = boundaryLoops
        self.faceCountBucket = faceCountBucket; self.scaleHint = scaleHint
        self.version = version
    }
}

// MARK: - CandidateRegionBuilder output

public enum RegionSource: String, Sendable, Codable {
    case structural
    case geometric
    case memory
}

public struct Region: Sendable {
    public struct Bounds: Sendable {
        public var centerX, centerY, centerZ: Float
        public var sizeX, sizeY, sizeZ: Float

        public static let zero = Bounds(centerX: 0, centerY: 0, centerZ: 0,
                                        sizeX: 0, sizeY: 0, sizeZ: 0)

        public init(centerX: Float, centerY: Float, centerZ: Float,
                    sizeX: Float, sizeY: Float, sizeZ: Float) {
            self.centerX = centerX; self.centerY = centerY; self.centerZ = centerZ
            self.sizeX = sizeX; self.sizeY = sizeY; self.sizeZ = sizeZ
        }
    }

    public var id: String
    public var source: RegionSource
    public var bounds: Bounds
    public var symmetryGroupID: String?
    public var parentRegionID: String?
    public var fingerprint: GeometryFingerprint

    public init(id: String,
                source: RegionSource,
                bounds: Bounds = .zero,
                symmetryGroupID: String? = nil,
                parentRegionID: String? = nil,
                fingerprint: GeometryFingerprint = GeometryFingerprint()) {
        self.id = id; self.source = source; self.bounds = bounds
        self.symmetryGroupID = symmetryGroupID; self.parentRegionID = parentRegionID
        self.fingerprint = fingerprint
    }
}

public struct CandidateRegionSet: Sendable {
    public var assetURI: String
    public var regions: [Region]

    public init(assetURI: String, regions: [Region] = []) {
        self.assetURI = assetURI; self.regions = regions
    }
}

// MARK: - SemanticAnalyzer output

public enum SemanticProvenance: String, Sendable, Codable {
    case structural
    case geometric
    case inferred
    case confirmed
}

public struct SemanticEvidence: Sendable {
    public var kind: String
    public var weight: Float
    public var detail: String?

    public init(kind: String, weight: Float, detail: String? = nil) {
        self.kind = kind; self.weight = weight; self.detail = detail
    }
}

public struct SemanticAlternative: Sendable {
    public var label: String
    public var confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label; self.confidence = confidence
    }
}

public struct SemanticProposal: Sendable {
    public var regionID: String
    public var label: String
    public var confidence: Float
    public var source: String               // backend identifier
    public var evidence: [SemanticEvidence]
    public var alternatives: [SemanticAlternative]
    public var provenance: SemanticProvenance

    public init(regionID: String,
                label: String,
                confidence: Float,
                source: String,
                evidence: [SemanticEvidence] = [],
                alternatives: [SemanticAlternative] = [],
                provenance: SemanticProvenance = .inferred) {
        self.regionID = regionID; self.label = label; self.confidence = confidence
        self.source = source; self.evidence = evidence; self.alternatives = alternatives
        self.provenance = provenance
    }
}

// MARK: - AmbiguityScorer output

public struct AmbiguityQuestion: Sendable {
    public struct Candidate: Sendable {
        public var label: String
        public var confidence: Float
        public var source: String

        public init(label: String, confidence: Float, source: String) {
            self.label = label; self.confidence = confidence; self.source = source
        }
    }

    public var regionID: String
    public var candidates: [Candidate]
    public var suggestedDefault: String?

    public init(regionID: String, candidates: [Candidate], suggestedDefault: String? = nil) {
        self.regionID = regionID; self.candidates = candidates; self.suggestedDefault = suggestedDefault
    }
}

public enum AmbiguityDecision: Sendable {
    case autoCommit([SemanticProposal])
    case needsConfirmation([AmbiguityQuestion])
}

// MARK: - Confirmation output

public struct SemanticConfirmation: Sendable {
    public enum Outcome: Sendable {
        case accepted(label: String)
        case renamed(to: String)
        case rejected
        case deferred
    }

    public var regionID: String
    public var outcome: Outcome
    public var confirmedBy: String
    public var confirmedAt: Date

    public init(regionID: String, outcome: Outcome, confirmedBy: String, confirmedAt: Date = Date()) {
        self.regionID = regionID; self.outcome = outcome
        self.confirmedBy = confirmedBy; self.confirmedAt = confirmedAt
    }
}
