import Foundation

#if canImport(Vision)
import Vision
#endif

public final class AppleVisionPerceptionWorker: PerceptionWorker, @unchecked Sendable {
    public let manifest: PerceptionModelManifest
    private let licenseGate: LicenseGate
    private let distributionMode: PerceptionDistributionMode

    public init(licenseGate: LicenseGate = LicenseGate(),
                distributionMode: PerceptionDistributionMode = .localDev) {
        self.licenseGate = licenseGate
        self.distributionMode = distributionMode
        self.manifest = PerceptionModelManifest(
            modelID: "apple_vision_classify_image_v1",
            displayName: "Apple Vision Image Classifier",
            task: .classification,
            backendFamily: "apple_vision",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "apple_vision",
                                             fallbackRuntimes: [],
                                             devicePolicy: ["system"]),
            inputContract: "guava.perception.input.rgb_image.v1",
            outputContract: "guava.perception.output.classifications.v1",
            license: PerceptionLicenseMetadata(
                codeLicense: "Apple-System",
                weightsLicense: "Apple-System",
                datasetLineage: ["Apple system Vision model"],
                commercialUse: "allowed",
                redistribution: "system-provided",
                requiresAttribution: false,
                requiresShareAlike: false,
                nonCommercialOnly: false),
            source: PerceptionModelSource(trainingRepo: nil,
                                          commit: nil,
                                          exportTool: "system-framework",
                                          exportCommit: nil)
        )
    }

    public func analyzeImage(at url: URL,
                             requestID: String = UUID().uuidString,
                             maxResults: Int = 5) throws -> PerceptionResult {
        let decision = licenseGate.evaluate(manifest, distributionMode: distributionMode)
        guard decision == .allowed || decision == .allowedWithAttribution else {
            throw PerceptionRuntimeError.licenseDenied(decision)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PerceptionRuntimeError.fileNotFound(url.path)
        }

        let start = Date()

        #if canImport(Vision)
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw PerceptionRuntimeError.inferenceFailed(String(describing: error))
        }
        let classifications = (request.results ?? []).prefix(max(1, maxResults))
        guard !classifications.isEmpty else { throw PerceptionRuntimeError.noObservations }

        let observations = classifications.enumerated().map { index, item -> PerceptionObservation in
            let label = item.identifier
            let confidence = Double(item.confidence)
            let candidate = PerceptionSemanticCandidate(kind: "object_category",
                                                        label: normalizeLabel(label),
                                                        confidence: confidence)
            let evidence = PerceptionEvidence(kind: "system_classifier",
                                              source: manifest.modelID,
                                              confidence: confidence,
                                              detail: label)
            return .classification(ClassificationObservation(
                id: "classification_\(index)",
                label: label,
                labelSpace: "apple_vision_classification",
                confidence: confidence,
                semanticCandidates: [candidate],
                evidence: [evidence]
            ))
        }

        return PerceptionResult(
            requestID: requestID,
            modelID: manifest.modelID,
            modelVersion: "system",
            task: .classification,
            status: "success",
            observations: observations,
            timing: PerceptionTimingInfo(totalMilliseconds: Date().timeIntervalSince(start) * 1_000),
            provenance: PerceptionProvenance(source: "apple_vision",
                                             modelID: manifest.modelID)
        )
        #else
        throw PerceptionRuntimeError.workerUnavailable("Apple Vision is not available on this platform")
        #endif
    }

    private func normalizeLabel(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: ",")
            .first
            .map(String.init) ?? label
    }
}
