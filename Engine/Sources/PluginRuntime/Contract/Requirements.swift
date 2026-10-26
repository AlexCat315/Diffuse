import Foundation

/// One declared dependency of a package.
///
/// `plugin.json` carries them as structured entries so the contract stays
/// machine-checkable:
///
/// ```json
/// "requires": [
///   { "kind": "plugin", "id": "studio.core", "minimum_version": 2 },
///   { "kind": "capability", "id": "studio.core.draw" }
/// ]
/// ```
///
/// Requirements express capability needs only. They grant no authority: every
/// plugin still needs its own authorization, and an unmet requirement fails
/// the enable closed instead of auto-enabling a dependency.
public struct PluginRequirement: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case plugin
        case capability
    }

    public var kind: Kind
    public var id: String
    /// Optional minimum version of the depended plugin or capability contract.
    public var minimumVersion: Int?

    public init(kind: Kind, id: String, minimumVersion: Int? = nil) {
        self.kind = kind
        self.id = id
        self.minimumVersion = minimumVersion
    }

    enum CodingKeys: String, CodingKey {
        case kind, id
        case minimumVersion = "minimum_version"
    }

    public var description: String {
        if let minimumVersion {
            return "\(kind.rawValue):\(id)@\(minimumVersion)+"
        }
        return "\(kind.rawValue):\(id)"
    }
}

/// One unmet requirement, reported by `PluginRequirementResolver.unmet`.
public enum PluginRequirementViolation: Sendable, Equatable, CustomStringConvertible {
    case missingPlugin(id: String, requiredBy: String, minimumVersion: Int?)
    case pluginVersionTooLow(id: String, requiredBy: String, minimumVersion: Int, actual: Int)
    case missingCapability(id: String, requiredBy: String, minimumVersion: Int?)
    case capabilityVersionTooLow(id: String, requiredBy: String, minimumVersion: Int, actual: Int)

    public var description: String {
        switch self {
        case let .missingPlugin(id, requiredBy, minimumVersion):
            let version = minimumVersion.map { " (minimum version \($0))" } ?? ""
            return "'\(requiredBy)' requires plugin '\(id)'\(version), which is not enabled"
        case let .pluginVersionTooLow(id, requiredBy, minimumVersion, actual):
            return "'\(requiredBy)' requires plugin '\(id)' version \(minimumVersion) or newer; enabled version is \(actual)"
        case let .missingCapability(id, requiredBy, minimumVersion):
            let version = minimumVersion.map { " (minimum version \($0))" } ?? ""
            return "'\(requiredBy)' requires capability '\(id)'\(version), which is not available"
        case let .capabilityVersionTooLow(id, requiredBy, minimumVersion, actual):
            return "'\(requiredBy)' requires capability '\(id)' version \(minimumVersion) or newer; available version is \(actual)"
        }
    }
}

/// Every unmet requirement of one package, thrown when enabling would mount a
/// plugin whose declared dependencies are absent.
public struct UnmetPluginRequirements: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var pluginID: String
    public var violations: [PluginRequirementViolation]

    public init(pluginID: String, violations: [PluginRequirementViolation]) {
        self.pluginID = pluginID
        self.violations = violations
    }

    public var description: String {
        "Plugin '\(pluginID)' declares unmet requirements: "
            + violations.map(\.description).joined(separator: "; ")
    }
    public var errorDescription: String? { description }
}

/// A disable request refused because other enabled plugins require the target.
public struct RequiredPluginStillNeeded: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public var pluginID: String
    public var dependents: [String]

    public init(pluginID: String, dependents: [String]) {
        self.pluginID = pluginID
        self.dependents = dependents
    }

    public var description: String {
        let list = dependents.sorted().map { "'\($0)'" }.joined(separator: ", ")
        return "'\(pluginID)' is required by \(list); disable those plugins first."
    }
    public var errorDescription: String? { description }
}

/// Resolves declared requirements against what is already mounted.
///
/// Enabling is incremental: a package may only be enabled while every
/// requirement is already satisfied, which keeps the enable order topological
/// (dependencies always precede dependents) and makes requirement cycles
/// impossible to create.
public enum PluginRequirementResolver {
    /// Every unmet requirement, in declaration order.
    public static func unmet(
        _ requirements: [PluginRequirement],
        requiredBy pluginID: String,
        enabledPlugins: [String: Int],
        providedCapabilities: [String: Int]
    ) -> [PluginRequirementViolation] {
        requirements.compactMap { requirement in
            switch requirement.kind {
            case .plugin:
                guard let actual = enabledPlugins[requirement.id] else {
                    return .missingPlugin(id: requirement.id,
                                          requiredBy: pluginID,
                                          minimumVersion: requirement.minimumVersion)
                }
                if let minimum = requirement.minimumVersion, actual < minimum {
                    return .pluginVersionTooLow(id: requirement.id,
                                                requiredBy: pluginID,
                                                minimumVersion: minimum,
                                                actual: actual)
                }
                return nil
            case .capability:
                guard let actual = providedCapabilities[requirement.id] else {
                    return .missingCapability(id: requirement.id,
                                              requiredBy: pluginID,
                                              minimumVersion: requirement.minimumVersion)
                }
                if let minimum = requirement.minimumVersion, actual < minimum {
                    return .capabilityVersionTooLow(id: requirement.id,
                                                    requiredBy: pluginID,
                                                    minimumVersion: minimum,
                                                    actual: actual)
                }
                return nil
            }
        }
    }

    /// Enabled plugins that require this plugin or one of its exact contracts.
    public static func dependents(of pluginID: String,
                                  providing capabilityIDs: Set<String>,
                                  among manifests: [String: CovePluginManifest]) -> [String] {
        manifests.compactMap { id, manifest in
            guard id != pluginID,
                  manifest.requires.contains(where: {
                      switch $0.kind {
                      case .plugin: return $0.id == pluginID
                      case .capability: return capabilityIDs.contains($0.id)
                      }
                  }) else {
                return nil
            }
            return id
        }.sorted()
    }
}
