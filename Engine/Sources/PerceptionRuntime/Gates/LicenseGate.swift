import Foundation

public enum PerceptionDistributionMode: String, Sendable, Equatable {
    case localDev = "local_dev"
    case internalTool = "internal_tool"
    case commercialBinary = "commercial_binary"
    case cloudService = "cloud_service"
}

public enum LicenseGateDecision: Sendable, Equatable, CustomStringConvertible {
    case allowed
    case allowedWithAttribution
    case disabledNonCommercial
    case disabledShareAlike
    case disabledUnknownWeightsLicense
    case disabledUnknownDatasetLineage
    case disabledPolicyViolation(String)

    public var description: String {
        switch self {
        case .allowed:
            return "allowed"
        case .allowedWithAttribution:
            return "allowed_with_attribution"
        case .disabledNonCommercial:
            return "disabled_non_commercial"
        case .disabledShareAlike:
            return "disabled_share_alike"
        case .disabledUnknownWeightsLicense:
            return "disabled_unknown_weights_license"
        case .disabledUnknownDatasetLineage:
            return "disabled_unknown_dataset_lineage"
        case let .disabledPolicyViolation(reason):
            return "disabled_policy_violation: \(reason)"
        }
    }
}

public struct LicenseGatePolicy: Sendable, Equatable {
    public var allowedCodeLicenses: Set<String>
    public var allowedWeightsLicenses: Set<String>
    public var allowUnknownDatasetLineageInLocalDev: Bool

    public static let commercialDefault = LicenseGatePolicy(
        allowedCodeLicenses: ["Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apple-System"],
        allowedWeightsLicenses: ["Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause", "Public-Domain", "Guava-Owned", "Apple-System"],
        allowUnknownDatasetLineageInLocalDev: true
    )

    public init(allowedCodeLicenses: Set<String>,
                allowedWeightsLicenses: Set<String>,
                allowUnknownDatasetLineageInLocalDev: Bool) {
        self.allowedCodeLicenses = allowedCodeLicenses
        self.allowedWeightsLicenses = allowedWeightsLicenses
        self.allowUnknownDatasetLineageInLocalDev = allowUnknownDatasetLineageInLocalDev
    }
}

public struct LicenseGate: Sendable {
    public var policy: LicenseGatePolicy

    public init(policy: LicenseGatePolicy = .commercialDefault) {
        self.policy = policy
    }

    public func evaluate(_ manifest: PerceptionModelManifest,
                         distributionMode: PerceptionDistributionMode) -> LicenseGateDecision {
        let license = manifest.license
        if license.nonCommercialOnly || license.commercialUse.lowercased().contains("non") {
            return .disabledNonCommercial
        }
        if license.requiresShareAlike {
            return .disabledShareAlike
        }
        guard policy.allowedCodeLicenses.contains(license.codeLicense) else {
            return .disabledPolicyViolation("code license '\(license.codeLicense)' is not allowed")
        }
        guard policy.allowedWeightsLicenses.contains(license.weightsLicense) else {
            if license.weightsLicense.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || license.weightsLicense.lowercased() == "unknown" {
                return .disabledUnknownWeightsLicense
            }
            return .disabledPolicyViolation("weights license '\(license.weightsLicense)' is not allowed")
        }
        if license.datasetLineage.isEmpty,
           !(distributionMode == .localDev && policy.allowUnknownDatasetLineageInLocalDev) {
            return .disabledUnknownDatasetLineage
        }
        return license.requiresAttribution ? .allowedWithAttribution : .allowed
    }
}

