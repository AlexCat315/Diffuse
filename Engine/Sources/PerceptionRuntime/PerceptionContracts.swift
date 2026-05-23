import Foundation

public enum PerceptionTask: String, Codable, Sendable, Equatable {
    case classification
    case objectDetection = "object_detection"
    case instanceSegmentation = "instance_segmentation"
    case semanticSegmentation = "semantic_segmentation"
    case depthEstimation = "depth_estimation"
    case imageEmbedding = "image_embedding"
    case textImageGrounding = "text_image_grounding"
}

public struct PerceptionRuntimeConfig: Codable, Sendable, Equatable {
    public var preferredRuntime: String
    public var fallbackRuntimes: [String]
    public var devicePolicy: [String]

    public init(preferredRuntime: String,
                fallbackRuntimes: [String] = [],
                devicePolicy: [String] = ["cpu"]) {
        self.preferredRuntime = preferredRuntime
        self.fallbackRuntimes = fallbackRuntimes
        self.devicePolicy = devicePolicy
    }
}

public struct PerceptionLicenseMetadata: Codable, Sendable, Equatable {
    public var codeLicense: String
    public var weightsLicense: String
    public var datasetLineage: [String]
    public var commercialUse: String
    public var redistribution: String
    public var requiresAttribution: Bool
    public var requiresShareAlike: Bool
    public var nonCommercialOnly: Bool

    public init(codeLicense: String,
                weightsLicense: String,
                datasetLineage: [String] = [],
                commercialUse: String,
                redistribution: String,
                requiresAttribution: Bool = false,
                requiresShareAlike: Bool = false,
                nonCommercialOnly: Bool = false) {
        self.codeLicense = codeLicense
        self.weightsLicense = weightsLicense
        self.datasetLineage = datasetLineage
        self.commercialUse = commercialUse
        self.redistribution = redistribution
        self.requiresAttribution = requiresAttribution
        self.requiresShareAlike = requiresShareAlike
        self.nonCommercialOnly = nonCommercialOnly
    }
}

public struct PerceptionModelSource: Codable, Sendable, Equatable {
    public var trainingRepo: String?
    public var commit: String?
    public var exportTool: String?
    public var exportCommit: String?

    public init(trainingRepo: String? = nil,
                commit: String? = nil,
                exportTool: String? = nil,
                exportCommit: String? = nil) {
        self.trainingRepo = trainingRepo
        self.commit = commit
        self.exportTool = exportTool
        self.exportCommit = exportCommit
    }
}

public struct PerceptionModelManifest: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var modelID: String
    public var displayName: String
    public var task: PerceptionTask
    public var backendFamily: String
    public var runtime: PerceptionRuntimeConfig
    public var inputContract: String
    public var outputContract: String
    public var license: PerceptionLicenseMetadata
    public var source: PerceptionModelSource

    public init(schemaVersion: String = "guava.perception.model_manifest.v1",
                modelID: String,
                displayName: String,
                task: PerceptionTask,
                backendFamily: String,
                runtime: PerceptionRuntimeConfig,
                inputContract: String,
                outputContract: String,
                license: PerceptionLicenseMetadata,
                source: PerceptionModelSource = PerceptionModelSource()) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.displayName = displayName
        self.task = task
        self.backendFamily = backendFamily
        self.runtime = runtime
        self.inputContract = inputContract
        self.outputContract = outputContract
        self.license = license
        self.source = source
    }
}

public struct ArtifactRef: Codable, Sendable, Equatable {
    public var uri: String
    public var contentHash: String?
    public var mediaType: String
    public var semanticKind: String
    public var redaction: String

    public init(uri: String,
                contentHash: String? = nil,
                mediaType: String,
                semanticKind: String,
                redaction: String = "prompt_forbidden") {
        self.uri = uri
        self.contentHash = contentHash
        self.mediaType = mediaType
        self.semanticKind = semanticKind
        self.redaction = redaction
    }
}

public struct PerceptionSemanticCandidate: Codable, Sendable, Equatable {
    public var kind: String
    public var label: String
    public var confidence: Double

    public init(kind: String, label: String, confidence: Double) {
        self.kind = kind
        self.label = label
        self.confidence = confidence
    }
}

public struct PerceptionEvidence: Codable, Sendable, Equatable {
    public var kind: String
    public var source: String
    public var confidence: Double
    public var detail: String?

    public init(kind: String, source: String, confidence: Double, detail: String? = nil) {
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.detail = detail
    }
}

public enum PerceptionObservation: Codable, Sendable, Equatable {
    case classification(ClassificationObservation)

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public var id: String {
        switch self {
        case let .classification(obs): return obs.id
        }
    }

    public var primaryCandidate: PerceptionSemanticCandidate? {
        switch self {
        case let .classification(obs): return obs.semanticCandidates.first
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "classification":
            self = .classification(try values.decode(ClassificationObservation.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "Unknown perception observation kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .classification(obs):
            try values.encode("classification", forKey: .kind)
            try values.encode(obs, forKey: .payload)
        }
    }
}

public struct ClassificationObservation: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var labelSpace: String
    public var confidence: Double
    public var semanticCandidates: [PerceptionSemanticCandidate]
    public var evidence: [PerceptionEvidence]

    public init(id: String,
                label: String,
                labelSpace: String,
                confidence: Double,
                semanticCandidates: [PerceptionSemanticCandidate],
                evidence: [PerceptionEvidence]) {
        self.id = id
        self.label = label
        self.labelSpace = labelSpace
        self.confidence = confidence
        self.semanticCandidates = semanticCandidates
        self.evidence = evidence
    }
}

public struct PerceptionDiagnostic: Codable, Sendable, Equatable {
    public var severity: String
    public var message: String

    public init(severity: String, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct PerceptionTimingInfo: Codable, Sendable, Equatable {
    public var totalMilliseconds: Double

    public init(totalMilliseconds: Double) {
        self.totalMilliseconds = totalMilliseconds
    }
}

public struct PerceptionProvenance: Codable, Sendable, Equatable {
    public var source: String
    public var modelID: String

    public init(source: String, modelID: String) {
        self.source = source
        self.modelID = modelID
    }
}

public struct PerceptionResult: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var requestID: String
    public var modelID: String
    public var modelVersion: String
    public var task: PerceptionTask
    public var status: String
    public var observations: [PerceptionObservation]
    public var artifacts: [ArtifactRef]
    public var diagnostics: [PerceptionDiagnostic]
    public var timing: PerceptionTimingInfo
    public var provenance: PerceptionProvenance

    public init(schemaVersion: String = "guava.perception.result.v1",
                requestID: String,
                modelID: String,
                modelVersion: String,
                task: PerceptionTask,
                status: String,
                observations: [PerceptionObservation],
                artifacts: [ArtifactRef] = [],
                diagnostics: [PerceptionDiagnostic] = [],
                timing: PerceptionTimingInfo,
                provenance: PerceptionProvenance) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.task = task
        self.status = status
        self.observations = observations
        self.artifacts = artifacts
        self.diagnostics = diagnostics
        self.timing = timing
        self.provenance = provenance
    }
}

